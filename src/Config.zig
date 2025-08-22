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

const cli = @import("cli.zig");
const CountingAllocator = @import("CountingAllocator.zig");
const filepath = @import("filepath.zig");
const toml = @import("toml.zig");

allocator: Allocator,
values: StringHashMap(Value),
counting_allocator: ?CountingAllocator = null,

/// Lookup table for option specs by the config key. Apart from handling
/// the static config fields, this map is used in order to include
/// the plugin-defined options in the lookup.
pub var specs: StringHashMap(OptionSpec) = undefined;

pub const config_file_spec: OptionSpec = .{
    .early = true,
    .type = .string,
    .long = "config",
    .short = 'c',
    .environment_variable = "CONFIG",
    .description = "use config file from `<path>`",
    .disable_config_file_option = true,
    .is_path = true,
};
pub const directory_spec: OptionSpec = .{
    .type = .string,
    .default = .{ .string = "." },
    .short = 'd',
    .description = "run Reginald as if it was started from `<path>`",
    .disable_config_file_option = true,
    .is_path = true,
};
pub const extend_spec: OptionSpec = .{
    .early = true,
    .type = .bool,
    .short = 'e',
    .description = "extend the slices in the config with values from each sources instead of overriding",
    .disable_config_file_option = true,
};
pub const @"logging.enabled_spec": OptionSpec = .{
    .type = .bool,
    .default = .{ .bool = true },
    .long = "log",
    .description = "enable logging",
};
pub const @"logging.level_spec": OptionSpec = .{
    .type = .log_level,
    .default = .{ .log_level = .info },
    .long = "log-level",
    .description = "set logging level so that only log messages with level greater than of equal to `<level>` are enabled",
};
pub const plugin_paths_spec: OptionSpec = .{
    .type = .string_slice,
    .short = 'P',
    .description = "search for plugins from `<paths>`",
    .is_path = true,
};
pub const print_help_spec: OptionSpec = .{
    .type = .bool,
    .long = "help",
    .short = 'h',
    .description = "show the help message and exit",
    .disable_environment_variable = true,
    .disable_config_file_option = true,
};
pub const print_version_spec: OptionSpec = .{
    .type = .bool,
    .long = "version",
    .description = "print the version information and exit",
    .disable_environment_variable = true,
    .disable_config_file_option = true,
};
pub const quiet_spec: OptionSpec = .{
    .type = .bool,
    .short = 'q',
    .description = "silence all output expect errors",
};
pub const verbose_spec: OptionSpec = .{
    .type = .bool,
    .short = 'v',
    .description = "print more verbose output",
};
pub const working_directory_spec: OptionSpec = .{
    .early = true,
    .type = .string,
    .default = .{ .string = "." },
    .long = "chdir",
    .short = 'C',
    .description = "run Reginald as if it was started from `<path>`",
    .disable_config_file_option = true,
    .is_path = true,
};

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

pub const OptionType = enum {
    bool,
    int,
    string,
    string_slice,
    log_level,
};

/// Represents the data for creating command-line options and config file
/// entries and checking environment variables for a config option.
const OptionSpec = struct {
    /// If true, this option is parsed during the first pass when parsing
    /// the static config options. An option should be marked as `early` only if
    /// it is strictly required for parsing the rest of the static config
    /// options.
    early: bool = false,

    type: OptionType,
    default: ?Value = null,

    /// Name of the long command-line option. If not set but the command-line
    /// option is not disabled, the name of the field will be used.
    long: ?[]const u8 = null,

    /// The one-letter command-line option.
    short: ?u8 = null,

    /// The name of the environment variable that is checked for the value of
    /// this option. The prefix for the environment variables is prepended to
    /// this value. The default is the name of option. The name of the variable
    /// is always converted to uppercase.
    environment_variable: ?[]const u8 = null,

    /// The name of the variable in the config file that is checked for
    /// the value of this option. The default is the name of option where all
    /// underscores are replaced by hyphens.
    config_file_key: ?[]const u8 = null,

    /// Short description of the option on the command-line help output.
    description: ?[]const u8 = null,

    disable_cli_option: bool = false,
    disable_environment_variable: bool = false,
    disable_config_file_option: bool = false,

    /// If this config option is a string and it should represent a path, this
    /// should be `true` so that it is parsed as a path. Paths are expanded,
    /// i.e. user home directories are expanded. Environment variables are
    /// expanded in all strings.
    ///
    /// TODO: Is there need to expand environment variables in all strings.
    is_path: bool = false,
};

const Value = union(OptionType) {
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
pub fn init(gpa: Allocator, args: cli.Parsed) !Config {
    // var cfg: Config = .{ .allocator = undefined,  .values = undefined };
    //
    // // Let's include the counting allocator for now.
    // const cfg_gpa = blk: {
    //     if (is_debug) {
    //         cfg.counting_allocator = .init(gpa);
    //         break :blk cfg.counting_allocator.?.allocator();
    //     } else {
    //         break :blk gpa;
    //     }
    // };
    //
    // cfg.allocator = cfg_gpa;
    // cfg.values = .init(cfg_gpa);
    var cfg: Config = .{ .allocator = gpa, .values = .init(gpa) };

    var arena_instance = ArenaAllocator.init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    try cfg.parseStatic(arena, null, args, true);
    try cfg.parseStatic(arena, null, args, false);

    return cfg;
}

/// Free the memory allocated by the `Config`.
pub fn deinit(self: *Config) void {
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

/// Build the lookup table for the config option specs. The caller owns
/// the memory of the global table and must call `deinitTable` to free
/// the memory.
pub fn initTable(gpa: Allocator) !void {
    specs = .init(gpa);

    inline for (@typeInfo(Config).@"struct".decls) |decl| {
        comptime if (!std.mem.endsWith(u8, decl.name, "_spec")) {
            continue;
        };

        const spec = @field(Config, decl.name);
        const key = decl.name[0 .. decl.name.len - @as([]const u8, "_spec").len];

        try specs.put(key, spec);
    }
}

/// TODO: Is this necessary?
pub fn deinitTable() void {
    specs.deinit();
}

pub fn parseBool(a: []const u8) !bool {
    if (a.len > 5) {
        return error.InvalidValue;
    }

    var buf: [5]u8 = undefined;
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

pub fn get(self: *Config, comptime T: type, key: []const u8) ?T {
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

pub fn parseLogLevel(s: []const u8) !std.log.Level {
    var buf: [8]u8 = undefined;
    if (s.len > buf.len) {
        return fail("invalid value for log level: {s}\n", .{s});
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

    return fail("invalid value for log level: {s}\n", .{s});
}

fn parseStatic(self: *Config, arena: Allocator, toml_value: ?toml.Value, args: cli.Parsed, comptime early: bool) !void {
    inline for (@typeInfo(Config).@"struct".decls) |decl| {
        comptime if (!std.mem.endsWith(u8, decl.name, "_spec")) {
            continue;
        };

        const spec: OptionSpec = @field(Config, decl.name);

        comptime if (early != spec.early) {
            continue;
        };

        const key = decl.name[0 .. decl.name.len - @as([]const u8, "_spec").len];
        std.debug.print("parsing {s}\n", .{key});

        if (parseValue(arena, key, spec, toml_value, args)) |val| {
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
        } else |err| return err;
    }
}

fn parseValue(arena: Allocator, key: []const u8, spec: OptionSpec, toml_value: ?toml.Value, args: cli.Parsed) !Value {
    var value: Value = if (spec.default) |def| def else switch (spec.type) {
        .bool => .{ .bool = false },
        .int => .{ .int = 0 },
        .string => .{ .string = "" },
        .string_slice => .{ .string_slice = &[_][]const u8{} },
        .log_level => .{ .log_level = .info },
    };

    if (!spec.disable_config_file_option) {
        if (toml_value) |root| {
            assert(root == .table);
            if (getTomlValue(spec.config_file_key orelse key, root)) |val| {
                const new = try parseTomlValue(arena, spec.type, val);
                value = try mergeValue(arena, value, new, false);
            }
        }
    }

    if (!spec.disable_environment_variable) {
        if (try getEnvVarValue(arena, key, spec)) |val| {
            const new = try parseFromString(arena, spec.type, val);
            value = try mergeValue(arena, value, new, false);
        }
    }

    if (!spec.disable_cli_option) {
        if (args.values.get(key)) |val| {
            const new: Value = switch (spec.type) {
                .bool => switch (val) {
                    .bool => |b| .{ .bool = b },
                    else => unreachable,
                },
                .int => switch (val) {
                    .int => |i| .{ .int = i },
                    else => unreachable,
                },
                .string => switch (val) {
                    .string => |s| .{ .string = s },
                    else => unreachable,
                },
                .string_slice => switch (val) {
                    .string_slice => |s| .{ .string_slice = s },
                    else => unreachable,
                },
                .log_level => switch (val) {
                    .log_level => |l| .{ .log_level = l },
                    else => unreachable,
                },
            };
            value = try mergeValue(arena, value, new, false);
        }
    }

    return value;
}

fn mergeValue(arena: Allocator, old: Value, new: Value, extend: bool) !Value {
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

fn parseTomlValue(arena: Allocator, option_type: OptionType, val: toml.Value) !Value {
    return switch (option_type) {
        .bool => switch (val) {
            .bool => |b| .{ .bool = b },
            else => return error.WrongType,
        },
        .int => switch (val) {
            .int => |i| .{ .int = i },
            else => return error.WrongType,
        },
        .string => switch (val) {
            .string => |s| .{ .string = s },
            else => return error.WrongType,
        },
        .string_slice => switch (val) {
            .array => |arr| blk: {
                var list: ArrayListUnmanaged([]const u8) = .empty;
                for (arr.items) |item| {
                    if (item == .string) {
                        try list.append(arena, item.string);
                    } else {
                        return error.WrongType;
                    }
                }

                break :blk .{ .string_slice = try list.toOwnedSlice(arena) };
            },
            else => return error.WrongType,
        },
        .log_level => switch (val) {
            .string => |s| .{ .log_level = try parseLogLevel(s) },
            else => return error.WrongType,
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

fn getTomlValue(key: []const u8, root: toml.Value) ?toml.Value {
    assert(root == .table);

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

fn getEnvVarValue(arena: Allocator, key: []const u8, spec: OptionSpec) !?[]u8 {
    assert(!spec.disable_environment_variable);

    const base_variable = spec.environment_variable orelse key;
    const prefixed = try std.mem.concat(arena, u8, &[_][]const u8{
        build_options.env_prefix,
        "_",
        base_variable,
    });

    std.mem.replaceScalar(u8, prefixed, '-', '_');
    std.mem.replaceScalar(u8, prefixed, '.', '_');

    var buf: [1024]u8 = undefined;
    const variable = std.ascii.upperString(&buf, prefixed);

    if (std.process.getEnvVarOwned(arena, variable)) |val| {
        return val;
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return err,
    }
}

/// Find the first matching config file and load its contents. The caller owns
/// the returned contents and should call `free` on them.
fn loadFile(self: *Config, arena: Allocator) ![]const u8 {
    var wd = try std.fs.cwd().openDir(self.working_directory, .{});
    defer wd.close();

    if (!std.mem.eql(u8, self.config_file, "")) {
        return try loadOne(arena, self.config_file, &wd);
    }

    // Current working directory first as that's the most natural place.
    inline for (default_extensions) |e| {
        if (loadOne(arena, default_filename ++ e, &wd)) |result| {
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

        // I think this is the encouraged way to handle the lookups.
        var dir = try wd.openDir(xdg, .{});
        defer dir.close();

        if (tryPaths(arena, unix_config_lookup, &dir)) |result| {
            return result;
        } else |err| {
            switch (err) {
                error.FileNotFound => {},
                else => return err,
            }
        }
    } else |err| {
        switch (err) {
            error.EnvironmentVariableNotFound => {}, // no-op
            else => return err,
        }
    }

    if (native_os == .windows or native_os == .uefi) {
        // TODO: Are these the correct paths for Windows? I don't know it that
        // well.
        const dirname = try filepath.expand(arena, "%APPDATA%");
        defer arena.free(dirname);

        var dir = try wd.openDir(dirname, .{});
        defer dir.close();

        if (tryPaths(arena, [_][]const u8{ default_filename, "config" }, &dir)) |result| {
            return result;
        } else |err| {
            switch (err) {
                error.FileNotFound => {},
                else => return err,
            }
        }
    } else if (native_os.isDarwin()) {
        const app_support_joined = try std.fs.path.join(
            arena,
            &[_][]const u8{ "~", "Library", "Application Support", default_filename },
        );
        defer arena.free(app_support_joined);

        const app_support_expanded = try filepath.expand(arena, app_support_joined);
        defer arena.free(app_support_expanded);

        var app_support_dir = try wd.openDir(app_support_expanded, .{});
        defer app_support_dir.close();

        if (tryPaths(
            arena,
            [_][]const u8{ default_filename, "config" },
            &app_support_dir,
        )) |result| {
            return result;
        } else |err| {
            switch (err) {
                error.FileNotFound => {},
                else => return err,
            }
        }
    }

    if (native_os != .windows and native_os != .uefi) {
        const home_config_joined = try std.fs.path.join(arena, &[_][]const u8{ "~", ".config" });
        defer arena.free(home_config_joined);

        const home_config_expanded = try filepath.expand(arena, home_config_joined);
        defer arena.free(home_config_expanded);

        var home_config_dir = try wd.openDir(home_config_expanded, .{});
        defer home_config_dir.close();

        if (tryPaths(arena, unix_config_lookup, &home_config_dir)) |result| {
            return result;
        } else |err| {
            switch (err) {
                error.FileNotFound => {},
                else => return err,
            }
        }

        const home_joined = try std.fs.path.join(arena, &[_][]const u8{ "~", default_filename });
        defer arena.free(home_joined);

        const home_name_expanded = try filepath.expand(arena, home_joined);
        defer arena.free(home_name_expanded);

        var home_dir = try wd.openDir(home_name_expanded, .{});
        defer home_dir.close();

        if (tryPaths(
            arena,
            [_][]const u8{ default_filename, "." ++ default_filename },
            &home_dir,
        )) |result| {
            return result;
        } else |err| {
            switch (err) {
                error.FileNotFound => {},
                else => return err,
            }
        }
    }

    return error.FileNotFound;
}

/// Try to load a config file. Caller owns the result and should call `free` on
/// it.
fn loadOne(arena: Allocator, f: []const u8, dir: *std.fs.Dir) ![]const u8 {
    const stat = try dir.statFile(f);
    const size = stat.size;
    const max_size = 1 << 20;

    if (size > max_size) {
        const err = fail(
            "config files over 1MB are not currently allowed, current size is {d} bytes\nthis is only temporary safeguard during development and will be removed in the future\n",
            .{size},
        );
        switch (err) {
            error.InvalidConfig => return error.FileTooBig,
            else => return err,
        }
    }

    // TODO: Is one MB enough?
    return try dir.readFileAlloc(arena, f, 1 << 20);
}

fn tryPaths(arena: Allocator, comptime paths: anytype, dir: *std.fs.Dir) ![]const u8 {
    inline for (paths) |f| {
        inline for (default_extensions) |e| {
            if (loadOne(arena, f ++ e, dir)) |result| {
                return result;
            } else |err| {
                switch (err) {
                    error.FileNotFound, error.IsDir => {},
                    else => return err,
                }
            }
        }
    }

    return error.FileNotFound;
}

fn defaultPluginDirs() []const []const u8 {
    const xdg_plugin_dir: []const u8 =
        "$XDG_DATA_HOME" ++ std.fs.path.sep_str ++ default_filename ++ std.fs.path.sep_str ++ plugin_dir_name;
    return blk: {
        if (native_os == .windows or native_os == .uefi) {
            break :blk &.{
                xdg_plugin_dir,
                "%LOCALAPPDATA%" ++ std.fs.path.sep_str ++ default_filename ++ std.fs.path.sep_str ++ plugin_dir_name,
            };
        } else if (native_os.isDarwin()) {
            break :blk &.{
                xdg_plugin_dir,
                "~" ++ std.fs.path.sep_str ++ "Library" ++ std.fs.path.sep_str ++ "Application Support" ++ std.fs.path.sep_str ++ default_filename ++ std.fs.path.sep_str ++ plugin_dir_name,
                "~" ++ std.fs.path.sep_str ++ ".local" ++ std.fs.path.sep_str ++ "share" ++ std.fs.path.sep_str ++ default_filename ++ std.fs.path.sep_str ++ plugin_dir_name,
            };
        } else {
            break :blk &.{
                xdg_plugin_dir,
                "~" ++ std.fs.path.sep_str ++ ".local" ++ std.fs.path.sep_str ++ "share" ++ std.fs.path.sep_str ++ default_filename ++ std.fs.path.sep_str ++ plugin_dir_name,
            };
        }
    };
}

// TODO: Correct errors.
fn fail(comptime format: []const u8, args: anytype) error{ InvalidConfig, WriteFailed } {
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    try stderr.print(format, args);
    try stderr.flush();

    return error.InvalidConfig;
}
