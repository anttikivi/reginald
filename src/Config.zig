//! Configuration resolved for the current run of Reginald. It is parsed from
//! the config file, environment variables, and command-line options. The types
//! of the configuration should match the precision that is available in
//! the different config sources so that the user's config can be represented
//! losslessly.

const Config = @This();

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const assert = std.debug.assert;
const StringHashMap = std.StringHashMap;

const Args = @import("Args.zig");
const filepath = @import("filepath.zig");
const output = @import("output.zig");
const toml = @import("toml.zig");

pub const Specs = @import("Config/Specs.zig");
pub const OptionSpec = @import("Config/Specs.zig").OptionSpec;
pub const OptionType = @import("Config/Specs.zig").OptionType;

allocator: Allocator,
file_directory: ?[]const u8,
values: StringHashMap(Value),

const is_debug = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;
const native_os = builtin.target.os.tag;

/// Basename of the default config files without the file extension.
const default_filename = "reginald";

/// Default config file extensions to look for.
const default_extensions = [_][]const u8{".toml"};

/// Helper constant that contains the different files that should be checked for
/// config files when trying to find it from "~/.config" or similar.
const unix_config_lookup = [_][]const u8{
    default_filename ++ std.fs.path.sep_str ++ default_filename,
    default_filename ++ std.fs.path.sep_str ++ "config",
    default_filename,
};

/// The default name for the plugins directory inside the lookup paths.
const plugin_dir_name = "plugins";

var stderr_buffer: [4096]u8 = undefined;

pub const Value = union(OptionType) {
    bool: bool,
    int: i64,
    string: []const u8,
    string_slice: []const []const u8,
    log_level: std.log.Level,
};

/// Initialize the config instance and parse the static config options into it.
/// This includes resolving the config file location and reading it and parsing
/// the static config option values from the file, from the environment
/// variables, and from the CLI options. The caller owns the created `Config`
/// and must call `deinit` on it.
pub fn init(self: *Config, gpa: Allocator, specs: *const Specs, args: *const Args) !void {
    self.* = .{
        .allocator = gpa,
        .file_directory = null,
        .values = .init(gpa),
    };
    errdefer self.deinit();

    var arena_instance = ArenaAllocator.init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    try self.parseStatic(arena, specs, null, args, true);

    const handle = try self.findFile(arena);
    defer if (!std.mem.eql(u8, self.get([]const u8, "config_file").?, "-")) handle.close();

    var file_buffer: [4096]u8 = undefined;
    var file_reader = handle.reader(&file_buffer);
    const file = &file_reader.interface;

    const file_data = try file.allocRemaining(arena, .unlimited);
    defer arena.free(file_data);

    var toml_value = try toml.parse(arena, file_data);
    defer toml_value.deinit(arena);

    try self.parseStatic(arena, specs, toml_value, args, false);
}

/// Free the memory allocated by the `Config`.
pub fn deinit(self: *Config) void {
    if (self.file_directory) |d| self.allocator.free(d);

    var val_it = self.values.valueIterator();
    while (val_it.next()) |v| {
        switch (v.*) {
            .string => |s| self.allocator.free(s),
            .string_slice => |strs| {
                for (strs) |s| {
                    self.allocator.free(s);
                }
                self.allocator.free(strs);
            },
            else => {},
        }
    }
    self.values.deinit();
}

pub fn format(self: *const Config, writer: *std.Io.Writer) !void {
    try writer.print(
        "{{\n  file_directory = \"{?s}\"\n  values = {{\n",
        .{self.file_directory},
    );
    var it = self.values.iterator();
    while (it.next()) |entry| {
        try writer.print("    {s} = ", .{entry.key_ptr.*});
        switch (entry.value_ptr.*) {
            .bool => |b| try writer.writeAll(if (b) "true" else "false"),
            .int => |i| try writer.print("{d}", .{i}),
            .string => |s| try writer.print("\"{s}\"", .{s}),
            .string_slice => |a| {
                try writer.writeByte('[');
                for (a) |s| {
                    try writer.print("\"{s}\",", .{s});
                }
                try writer.writeByte(']');
            },
            .log_level => |l| try writer.print("{s}", .{
                switch (l) {
                    .err => "error",
                    .warn => "warning",
                    .info => "info",
                    .debug => "debug",
                },
            }),
        }
        try writer.writeByte('\n');
    }
    try writer.writeAll("  }\n}");
}

pub fn parseBool(a: []const u8) error{InvalidValue}!bool {
    if (a.len > 5) {
        return error.InvalidValue;
    }

    var buf: [5]u8 = undefined;
    assert(a.len <= 5);
    const v = std.ascii.lowerString(&buf, a);

    if (std.mem.eql(u8, v, "true")) {
        return true;
    } else if (std.mem.eql(u8, v, "t")) {
        return true;
    } else if (std.mem.eql(u8, v, "1")) {
        return true;
    } else if (std.mem.eql(u8, v, "false")) {
        return false;
    } else if (std.mem.eql(u8, v, "f")) {
        return false;
    } else if (std.mem.eql(u8, v, "0")) {
        return false;
    }

    return error.InvalidValue;
}

pub fn get(self: *const Config, comptime T: type, key: []const u8) ?T {
    const val = self.values.get(key) orelse return null;

    return switch (T) {
        bool => switch (val) {
            .bool => |b| b,
            else => unreachable,
        },
        i64 => switch (val) {
            .int => |i| i,
            else => unreachable,
        },
        []const u8 => switch (val) {
            .string => |s| s,
            else => unreachable,
        },
        []const []const u8 => switch (val) {
            .string_slice => |s| s,
            else => unreachable,
        },
        std.log.Level => switch (val) {
            .log_level => |l| l,
            else => unreachable,
        },
        else => @compileError("unsupported config type: " ++ @typeName(T)),
    };
}

pub fn parseLogLevel(s: []const u8) error{InvalidValue}!std.log.Level {
    var buf: [8]u8 = undefined;
    if (s.len > buf.len) {
        return error.InvalidValue;
    }

    const l = std.ascii.lowerString(&buf, s);

    if (std.mem.eql(u8, l, "e") or std.mem.eql(u8, l, "err") or std.mem.eql(u8, l, "error")) {
        return .err;
    } else if (std.mem.eql(u8, l, "w") or std.mem.eql(u8, l, "warn") or
        std.mem.eql(u8, l, "warning"))
    {
        return .warn;
    } else if (std.mem.eql(u8, l, "i") or std.mem.eql(u8, l, "info")) {
        return .info;
    } else if (std.mem.eql(u8, l, "d") or std.mem.eql(u8, l, "debug")) {
        return .debug;
    }

    return error.InvalidValue;
}

fn parseStatic(
    self: *Config,
    arena: Allocator,
    specs: *const Specs,
    toml_value: ?toml.Value,
    args: *const Args,
    early: bool,
) !void {
    const extend = self.get(bool, "extend") orelse false;

    var spec_it = specs.specs.iterator();
    while (spec_it.next()) |entry| {
        const spec = entry.value_ptr;
        if (early != spec.early) {
            continue;
        }

        const key = entry.key_ptr.*;
        assert(key.len > 0);

        const val = try parseValue(arena, key, spec, toml_value, args, extend);
        assert(@as(OptionType, val) == spec.type);
        switch (val) {
            .string => |s| try self.values.put(key, .{ .string = try self.allocator.dupe(u8, s) }),
            .string_slice => |s| {
                var new = try self.allocator.alloc([]const u8, s.len);
                for (s, 0..) |v, i| {
                    new[i] = try self.allocator.dupe(u8, v);
                }
                try self.values.put(key, .{ .string_slice = new });
            },
            else => try self.values.put(key, val),
        }
    }
}

fn parseValue(
    arena: Allocator,
    key: []const u8,
    spec: *const OptionSpec,
    toml_value: ?toml.Value,
    args: *const Args,
    extend: bool,
) !Value {
    var value = spec.defaultValue();
    assert(@as(OptionType, value) == spec.type);
    assert(key.len > 0);

    if (!spec.disable_config_file_option) {
        if (toml_value) |root| {
            assert(root == .table);
            const toml_key = try getTomlKey(arena, key, spec);
            if (getTomlValue(toml_key, root)) |val| {
                const new = parseTomlValue(arena, spec.type, val) catch |err| switch (err) {
                    error.InvalidValue => return output.fail(
                        "config field '{s}' has invalid value: {f}",
                        .{ toml_key, val },
                    ),
                    error.InvalidType => return output.fail(
                        "config field '{s}' expected {t}, found {t}",
                        .{ toml_key, spec.type, val },
                    ),
                    error.OutOfMemory => return err,
                };
                value = try mergeValue(arena, value, new, extend);
            }
        }
    }

    if (!spec.disable_environment_variable) {
        const env_var = try spec.getEnvVarName(arena, key);
        if (std.process.getEnvVarOwned(arena, env_var)) |val| {
            const new = parseFromString(arena, spec.type, val) catch |err| switch (err) {
                error.InvalidValue, error.InvalidCharacter => return output.fail(
                    "environment variable '{s}' has invalid value: {s}",
                    .{ env_var, val },
                ),
                error.Overflow => return output.fail(
                    "value in environment variable '{s}' would overflow '{s}': {s}",
                    .{
                        env_var,
                        switch (spec.type) {
                            .int => "i64",
                            else => unreachable,
                        },
                        val,
                    },
                ),
                error.OutOfMemory => return error.OutOfMemory,
            };
            value = try mergeValue(arena, value, new, extend);
        } else |err| {
            switch (err) {
                error.EnvironmentVariableNotFound => {}, // continue

                // Rather than surface the error upstream, let's panic as it can safely
                // be assumed that all of the environment variable names are valid.
                error.InvalidWtf8 => std.debug.panic("invalid wtf-8: {s}", .{key}),
                error.OutOfMemory => return err,
            }
        }
    }

    if (!spec.disable_cli_option) {
        if (args.values.get(key)) |val| {
            assert(@as(OptionType, val) == spec.type);
            value = try mergeValue(arena, value, val, extend);
        }
    }

    assert(@as(OptionType, value) == spec.type);

    switch (value) {
        .string, .string_slice => value = try expandValue(arena, value, spec.is_path),
        else => {},
    }

    assert(@as(OptionType, value) == spec.type);

    return value;
}

fn mergeValue(arena: Allocator, old: Value, new: Value, extend: bool) Allocator.Error!Value {
    assert(@as(OptionType, old) == @as(OptionType, new));

    return switch (old) {
        .string_slice => |old_slice| blk: {
            if (!extend) {
                break :blk new;
            }

            var list: ArrayListUnmanaged([]const u8) = .empty;
            try list.appendSlice(arena, old_slice);
            try list.appendSlice(arena, new.string_slice);

            break :blk .{ .string_slice = try list.toOwnedSlice(arena) };
        },
        else => new,
    };
}

fn expandValue(arena: Allocator, value: Value, is_path: bool) filepath.ExpandError!Value {
    assert(@as(OptionType, value) == .string or @as(OptionType, value) == .string_slice);

    const new: Value = switch (value) {
        .string => |s| .{
            .string = blk: {
                if (is_path) {
                    break :blk try filepath.expand(arena, s);
                } else {
                    break :blk try filepath.expandEnv(arena, s);
                }
            },
        },
        .string_slice => |slice| .{
            .string_slice = blk: {
                var new = try arena.alloc([]const u8, slice.len);
                if (is_path) {
                    for (slice, 0..) |s, i| {
                        new[i] = try filepath.expand(arena, s);
                    }
                } else {
                    for (slice, 0..) |s, i| {
                        new[i] = try filepath.expandEnv(arena, s);
                    }
                }

                break :blk new;
            },
        },
        else => unreachable,
    };

    assert(@as(OptionType, new) == @as(OptionType, value));

    return new;
}

fn parseTomlValue(arena: Allocator, option_type: OptionType, val: toml.Value) !Value {
    return switch (option_type) {
        .bool => switch (val) {
            .bool => |b| .{ .bool = b },
            else => return error.InvalidType,
        },
        .int => switch (val) {
            .int => |i| .{ .int = i },
            else => return error.InvalidType,
        },
        .string => switch (val) {
            .string => |s| .{ .string = s },
            else => return error.InvalidType,
        },
        .string_slice => switch (val) {
            .array => |arr| blk: {
                var list: ArrayListUnmanaged([]const u8) = .empty;
                for (arr.items) |item| {
                    if (item == .string) {
                        try list.append(arena, item.string);
                    } else {
                        return error.InvalidType;
                    }
                }

                break :blk .{ .string_slice = try list.toOwnedSlice(arena) };
            },
            else => return error.InvalidType,
        },
        .log_level => switch (val) {
            .string => |s| .{ .log_level = try parseLogLevel(s) },
            else => return error.InvalidType,
        },
    };
}

fn parseFromString(arena: Allocator, option_type: OptionType, val: []const u8) !Value {
    assert(val.len > 0);

    return switch (option_type) {
        .bool => .{ .bool = try parseBool(val) },
        .int => .{ .int = try std.fmt.parseInt(i64, val, 0) },
        .string => .{ .string = val },
        .string_slice => blk: {
            var list: ArrayListUnmanaged([]const u8) = .empty;

            // TODO: Don't use the path delimiter for values other than paths.
            var iter = std.mem.splitScalar(u8, val, std.fs.path.delimiter);
            while (iter.next()) |s| {
                try list.append(arena, s);
            }

            break :blk .{ .string_slice = try list.toOwnedSlice(arena) };
        },
        .log_level => .{ .log_level = try parseLogLevel(val) },
    };
}

fn getTomlKey(
    arena: Allocator,
    key: []const u8,
    spec: *const OptionSpec,
) Allocator.Error![]const u8 {
    assert(key.len > 0);

    const toml_key = spec.config_file_key orelse blk: {
        const tmp = try arena.dupe(u8, key);
        std.mem.replaceScalar(u8, tmp, '_', '-');
        break :blk tmp;
    };

    assert(toml_key.len > 0);

    return toml_key;
}

fn getTomlValue(key: []const u8, root: toml.Value) ?toml.Value {
    assert(root == .table);
    assert(key.len > 0);

    var result = root;

    var iter = std.mem.splitScalar(u8, key, '.');
    while (iter.next()) |s| {
        if (result != .table) {
            return null;
        }

        if (result.table.get(s)) |val| {
            result = val;
        } else {
            return null;
        }
    }

    return result;
}

fn getEnvVarValue(arena: Allocator, key: []const u8) error{OutOfMemory}!?[]const u8 {
    if (std.process.getEnvVarOwned(arena, key)) |val| {
        return val;
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,

        // Rather than surface the error upstream, let's panic as it can safely
        // be assumed that all of the environment variable names are valid.
        error.InvalidWtf8 => std.debug.panic("invalid wtf-8: {s}", .{key}),
        else => return err,
    }
}

/// Find the first matching config file and open it. If the config option for
/// the config file is set, this function only looks up that location and fails
/// if the path doesn't contain a file. If the config option for the config file
/// is not set, this function tries platform-dependent default locations and set
/// the config option for the file path to the successful location.
///
/// The caller owns the returned `File` and must call `close` on it.
fn findFile(self: *Config, arena: Allocator) !std.fs.File {
    const config_file = self.get([]const u8, "config_file").?;
    if (std.mem.eql(u8, config_file, "-")) {
        self.file_directory = null;
        return std.fs.File.stdin();
    }

    const wd_path = self.get([]const u8, "working_directory").?;
    var wd = try std.fs.cwd().openDir(wd_path, .{});
    defer wd.close();

    if (!std.mem.eql(u8, config_file, "")) {
        self.file_directory = try self.allocator.dupe(u8, wd_path);

        return wd.openFile(config_file, .{ .mode = .read_only }) catch |err| {
            return switch (err) {
                error.AccessDenied => output.fail("access denied: {s}", .{config_file}),
                error.FileNotFound => output.fail(
                    "config file at '{s}' does not exist",
                    .{config_file},
                ),
                error.IsDir => output.fail("file at '{s}' is a directory", .{config_file}),
                else => output.fail("failed to open config file at '{s}'", .{config_file}),
            };
        };
    }

    // Current working directory first as that's the most natural place.
    inline for (default_extensions) |e| {
        if (self.openFile(default_filename ++ e, wd)) |result| {
            self.file_directory = try self.allocator.dupe(u8, wd_path);
            return result;
        } else |err| {
            switch (err) {
                error.FileNotFound, error.IsDir => {},
                else => return err,
            }
        }
    }

    if (std.process.getEnvVarOwned(arena, "XDG_CONFIG_HOME")) |xdg| {
        defer arena.free(xdg);

        if (try self.tryDir(wd, xdg, unix_config_lookup)) |result| {
            return result;
        }
    } else |err| {
        switch (err) {
            error.EnvironmentVariableNotFound => {}, // no-op
            else => return err,
        }
    }

    if (native_os == .windows or native_os == .uefi) {
        // TODO: Are these the correct paths for Windows?
        const dirname = try filepath.expand(arena, "%APPDATA%");
        defer arena.free(dirname);

        if (try self.tryDir(wd, dirname, [_][]const u8{ default_filename, "config" })) |result| {
            return result;
        }
    } else if (native_os.isDarwin()) {
        const app_support_joined = try std.fs.path.join(arena, &[_][]const u8{
            "~",
            "Library",
            "Application Support",
            default_filename,
        });
        defer arena.free(app_support_joined);

        const app_support_expanded = try filepath.expand(arena, app_support_joined);
        defer arena.free(app_support_expanded);

        if (try self.tryDir(
            wd,
            app_support_expanded,
            [_][]const u8{ default_filename, "config" },
        )) |result| {
            return result;
        }
    }

    if (native_os != .windows and native_os != .uefi) {
        const home_config_joined = try std.fs.path.join(arena, &[_][]const u8{ "~", ".config" });
        defer arena.free(home_config_joined);

        const home_config_expanded = try filepath.expand(arena, home_config_joined);
        defer arena.free(home_config_expanded);

        if (try self.tryDir(wd, home_config_expanded, unix_config_lookup)) |result| {
            return result;
        }

        const home_joined = try std.fs.path.join(arena, &[_][]const u8{ "~", default_filename });
        defer arena.free(home_joined);

        const home_name_expanded = try filepath.expand(arena, home_joined);
        defer arena.free(home_name_expanded);

        if (try self.tryDir(
            wd,
            home_name_expanded,
            [_][]const u8{ default_filename, "." ++ default_filename },
        )) |result| {
            return result;
        }
    }

    return output.fail("could not find a config file", .{});
}

/// Try the config file opening with the given path. The point of this helper is
/// to avoid return with `FileNotFound` if one of the default lookup locations
/// doesn't exist.
fn tryDir(
    self: *Config,
    wd: std.fs.Dir,
    path: []const u8,
    comptime file_paths: anytype,
) !?std.fs.File {
    var dir = wd.openDir(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer dir.close();

    if (self.tryPaths(file_paths, dir)) |result| {
        self.file_directory = try self.allocator.dupe(u8, path);
        return result;
    } else |err| {
        switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
    }

    return null;
}

/// Try to open a file from the given path and print the correct error message
/// on error.
fn openFile(self: *Config, path: []const u8, wd: std.fs.Dir) !std.fs.File {
    var file = wd.openFile(path, .{ .mode = .read_only }) catch |err| {
        switch (err) {
            error.AccessDenied, error.FileNotFound, error.IsDir => {},
            else => return output.fail("failed to open config file at '{s}'", .{path}),
        }
        return err;
    };
    errdefer file.close();

    try self.values.put("config_file", .{ .string = try self.allocator.dupe(u8, path) });
    return file;
}

fn tryPaths(self: *Config, comptime paths: anytype, dir: std.fs.Dir) !std.fs.File {
    inline for (paths) |f| {
        inline for (default_extensions) |e| {
            if (self.openFile(f ++ e, dir)) |result| {
                return result;
            } else |err| {
                switch (err) {
                    error.AccessDenied, error.FileNotFound, error.IsDir => {},
                    else => return err,
                }
            }
        }
    }

    return error.FileNotFound;
}

fn defaultPluginDirs() []const []const u8 {
    const sep_str = std.fs.path.sep_str;
    const xdg_plugin_dir: []const u8 =
        "$XDG_DATA_HOME" ++ sep_str ++ default_filename ++ sep_str ++ plugin_dir_name;
    return blk: {
        if (native_os == .windows or native_os == .uefi) {
            break :blk &.{
                xdg_plugin_dir,
                "%LOCALAPPDATA%" ++ sep_str ++ default_filename ++ sep_str ++ plugin_dir_name,
            };
        } else if (native_os.isDarwin()) {
            break :blk &.{
                xdg_plugin_dir,
                "~" ++ sep_str ++ "Library" ++ sep_str ++ "Application Support" ++ sep_str ++ default_filename ++ sep_str ++ plugin_dir_name,
                "~" ++ sep_str ++ ".local" ++ sep_str ++ "share" ++ sep_str ++ default_filename ++ sep_str ++ plugin_dir_name,
            };
        } else {
            break :blk &.{
                xdg_plugin_dir,
                "~" ++ sep_str ++ ".local" ++ sep_str ++ "share" ++ sep_str ++ default_filename ++ sep_str ++ plugin_dir_name,
            };
        }
    };
}
