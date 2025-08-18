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
const assert = std.debug.assert;
const fs = std.fs;
const mem = std.mem;
const meta = std.meta;
const StructField = std.builtin.Type.StructField;

const cli = @import("cli.zig");
const filepath = @import("filepath.zig");
const toml = @import("toml.zig");

/// Allocator that the config uses for its internal allocations.
allocator: Allocator,

/// Path to the config file.
config_file: []const u8 = "",

/// The base directory for resolving the configured paths within the program.
directory: []const u8 = ".",

// /// The maximum number of concurrent jobs to allow. If this is less than 1,
// /// unlimited concurrent jobs are allowed.
// max_jobs: i64 = -1,

/// The configuration for logging.
logging: Logging = .{},

/// The directories to look up for plugins.
plugin_directories: []const []const u8 = defaultPluginDirs(),

/// If true, the program shows the help message and exits. When this is set to
/// true, the actual config instance should never be loaded.
print_help: bool = false,

/// If true, the program shows the version and exits. When this is set to true,
/// the actual config instance should never be loaded.
print_version: bool = false,

/// Whether quiet output is enabled.
quiet: bool = false,

/// Whether verbose output is enabled.
verbose: bool = false,

/// The current working directory that maybe set with the `-C` option.
/// The config file's location is resolved relative to this directory, and it's
/// used as the default `directory`.
working_directory: []const u8 = ".",

const native_os = builtin.target.os.tag;

/// Basename of the default config files without the file extension.
const default_filename = "reginald";

/// Default config file extensions to look for.
const default_extensions = [_][]const u8{".toml"};

/// Helper constant that contains the different files that should be checked for
/// config files when trying to find it from "~/.config" or similar.
const unix_config_lookup = [_][]const u8{
    default_filename ++ fs.path.sep_str ++ default_filename,
    default_filename ++ fs.path.sep_str ++ "config",
    default_filename,
};

/// The default name for the plugins directory inside the lookup paths.
const plugin_dir_name = "plugins";

/// Type for the global logging configuration.
pub const Logging = struct {
    /// Whether logs are enabled.
    enabled: bool = true,

    /// The selected logging level. Only messages of this or higher level will
    /// be printed.
    level: std.log.Level = .info,
};

/// Type of a config value as a more general value instead of raw types.
pub const OptionType = enum {
    bool,
    int,
    string,

    /// A string slice but the values are assumed to be paths. This is achieved
    /// by having a config option that is a slice of strings that is marked as
    /// a path. The difference to a normal string slice, if one is ever added,
    /// is that this allows specifying multiple paths in one argument using
    /// the platform-specific path delimiter.
    paths,
};

/// Represents the data for creating command-line options and config file
/// entries and checking environment variables for a config option.
pub const OptionInfo = struct {
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
    config_file_name: ?[]const u8 = null,

    /// Short description of the option on the command-line help output.
    description: ?[]const u8 = null,

    /// If set to true, no command-line option is generated for this option.
    disable_cli_option: bool = false,

    /// If set to true, value for this config option is not checked from
    /// an environment variable.
    disable_env: bool = false,

    /// If set to true, value for this config option is not checked from
    /// the config file.
    disable_config_file: bool = false,

    /// If this config option is a string and it should represent a path, this
    /// should be `true` so that it is parsed as a path. Paths are expanded,
    /// i.e. user home directories are expanded. Environment variables are
    /// expanded in all strings.
    ///
    /// TODO: Is there need to expand environment variables in all strings.
    is_path: bool = false,

    /// If true, this option will accept a string instead of the type in
    /// `Config`. The value is converted into the config value by calling
    /// the parser when checking the values.
    is_parsed: bool = false,
};

pub const LoggingInfo = struct {
    enabled: OptionInfo,
    level: OptionInfo,
};

pub const GlobalOptionInfo = struct {
    config_file: OptionInfo = .{
        .long = "config",
        .short = 'c',
        .environment_variable = "CONFIG",
        .description = "use config file from `<path>`",
        .disable_config_file = true,
        .is_path = true,
    },
    directory: OptionInfo = .{
        .short = 'd',
        .description = "run Reginald as if it was started from `<path>`",
        .is_path = true,
    },
    logging: LoggingInfo = .{
        .enabled = .{
            .long = "log",
            .description = "enable logging",
        },
        .level = .{
            .long = "log-level",
            .description = "set logging level so that only log messages with level greater than of equal to `<level>` are enabled",
            .is_parsed = true,
        },
    },
    plugin_directories: OptionInfo = .{
        .long = "plugin-dirs",
        .short = 'P',
        .description = "search for plugins from `<paths>`",
        .is_path = true,
    },
    print_help: OptionInfo = .{
        .long = "help",
        .short = 'h',
        .description = "show the help message and exit",
        .disable_env = true,
        .disable_config_file = true,
    },
    print_version: OptionInfo = .{
        .long = "version",
        .description = "print the version information and exit",
        .disable_env = true,
        .disable_config_file = true,
    },
    quiet: OptionInfo = .{
        .short = 'q',
        .description = "silence all output expect errors",
    },
    verbose: OptionInfo = .{
        .short = 'v',
        .description = "print more verbose output",
    },
    working_directory: OptionInfo = .{
        .long = "chdir",
        .short = 'C',
        .description = "run Reginald as if it was started from `<path>`",
        .disable_config_file = true,
        .is_path = true,
    },
};

pub const global_option_info: GlobalOptionInfo = .{};

/// Initialize the config instance and parse the the global config options into
/// it. This includes resolving the config file location, reading it, and
/// parsing the global config option values from it, from the environment
/// variables, and from the CLI options. The caller owns the created `Config`
/// and must call `deinit` on it.
///
/// The first `Allocator` passed into the function should the allocator that
/// the `Config` uses to do the permanent allocations of the values. The second
/// `Allocator` is used to create a temporary arena that is used for
/// the temporary allocations during the initialization.
pub fn init(allocator: Allocator, gpa: Allocator, args: cli.Parsed) !Config {
    var cfg: Config = .{ .allocator = allocator };
    errdefer cfg.deinit();

    var arena_instance = std.heap.ArenaAllocator.init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    try cfg.parseInitValue(arena, "config_file", args);
    try cfg.parseInitValue(arena, "working_directory", args);

    const file_data = try cfg.loadFile(arena);
    defer arena.free(file_data);

    var diag: toml.Diagnostics = undefined;
    var toml_value = toml.parseWithDiagnostics(arena, file_data, &diag) catch |e| {
        const stderr_writer = std.io.getStdErr().writer();
        try stderr_writer.print("{}\n", .{diag});
        return e;
    };
    defer toml_value.deinit(arena);

    for (toml_value.table.keys()) |key| {
        std.debug.print("{s}\n", .{key});
    }

    return cfg;
}

/// Free the memory allocated by the `Config`.
pub fn deinit(self: *Config) void {
    self.allocator.free(self.working_directory);
    self.allocator.free(self.config_file);
}

/// Ensure that the additional information for the Config fields match
/// the Config fields.
pub fn checkInfo() void {
    assert(std.meta.fields(Config).len == std.meta.fields(@TypeOf(Config.global_option_info)).len + 1);

    for (std.meta.fields(Config)) |field| {
        if (std.mem.eql(u8, field.name, "allocator")) {
            continue;
        }

        var found = false;
        for (std.meta.fields(@TypeOf(Config.global_option_info))) |info_field| {
            if (std.mem.eql(u8, field.name, info_field.name)) {
                found = true;
            }
        }

        assert(found);
    }

    for (std.meta.fields(@TypeOf(Config.global_option_info))) |field| {
        assert(@hasField(Config, field.name));
    }
}

/// Convert an ASCII string given as a config values to a bool.
pub fn parseBool(a: []const u8) !bool {
    if (a.len > 5) {
        return error.InvalidValue;
    }

    var buf: [5]u8 = undefined;
    const v = std.ascii.lowerString(&buf, a);

    if (mem.eql(u8, v, "true")) {
        return true;
    } else if (mem.eql(u8, v, "t")) {
        return true;
    } else if (mem.eql(u8, v, "1")) {
        return true;
    } else if (mem.eql(u8, v, "false")) {
        return false;
    } else if (mem.eql(u8, v, "f")) {
        return false;
    } else if (mem.eql(u8, v, "0")) {
        return false;
    }

    return error.InvalidValue;
}

/// Get the type of the given config option by name.
pub fn optionType(name: []const u8) !?OptionType {
    var field_name = name;
    const dot_index = mem.indexOfScalar(u8, name, '.');
    if (dot_index) |i| {
        field_name = name[0..i];
    }

    const fields: []const StructField = meta.fields(@TypeOf(global_option_info));
    inline for (fields) |field| {
        if (mem.eql(u8, field_name, field.name)) {
            switch (field.type) {
                OptionInfo => {
                    const info = @field(global_option_info, field.name);

                    if (info.is_parsed) {
                        return .string;
                    }

                    return switch (@FieldType(Config, field.name)) {
                        bool => .bool,
                        i64 => .int,
                        []const u8 => .string,
                        []const []const u8 => .paths,
                        else => @compileError("Config field '" ++ field.name ++ "' has invalid type: " ++ @typeName(@FieldType(Config, field.name))),
                    };
                },
                LoggingInfo => if (dot_index) |i| {
                    const logging_info = @field(global_option_info, field.name);
                    const logging_field_name = name[i + 1 ..];
                    const info_fields: []const StructField = meta.fields(@TypeOf(logging_info));
                    inline for (info_fields) |info_field| {
                        if (mem.eql(u8, logging_field_name, info_field.name)) {
                            const info = @field(logging_info, info_field.name);

                            if (info.is_parsed) {
                                return .string;
                            }

                            return switch (@FieldType(Logging, info_field.name)) {
                                bool => .bool,
                                i64 => .int,
                                []const u8 => .string,
                                []const []const u8 => .paths,
                                else => @compileError("Logging config field '" ++ info_field.name ++ "' has invalid type: " ++ @typeName(@FieldType(Logging, info_field.name))),
                            };
                        }
                    }

                    return error.InvalidKey;
                } else {
                    return error.InvalidKey;
                },
                else => @compileError("Expected OptionInfo or LoggingInfo, found '" ++ @typeName(field.type) ++ "'"),
            }
        }
    }

    return null;
}

/// Get the option info of the given config option by name.
pub fn optionInfo(name: []const u8) !?OptionInfo {
    var field_name = name;
    const dot_index = mem.indexOfScalar(u8, name, '.');
    if (dot_index) |i| {
        field_name = name[0..i];
    }

    const fields: []const StructField = meta.fields(@TypeOf(global_option_info));
    inline for (fields) |field| {
        if (mem.eql(u8, field_name, field.name)) {
            switch (field.type) {
                OptionInfo => {
                    return @field(global_option_info, field.name);
                },
                LoggingInfo => if (dot_index) |i| {
                    const logging_info = @field(global_option_info, field.name);
                    const logging_field_name = name[i + 1 ..];
                    const info_fields: []const StructField = meta.fields(@TypeOf(logging_info));
                    inline for (info_fields) |info_field| {
                        if (mem.eql(u8, logging_field_name, info_field.name)) {
                            return @field(logging_info, info_field.name);
                        }
                    }

                    return error.InvalidKey;
                } else {
                    return error.InvalidKey;
                },
                else => @compileError("Expected OptionInfo or LoggingInfo, found '" ++ @typeName(field.type) ++ "'"),
            }
        }
    }

    return null;
}

fn defaultPluginDirs() []const []const u8 {
    const xdg_plugin_dir: []const u8 =
        "$XDG_DATA_HOME" ++ fs.path.sep_str ++ default_filename ++ fs.path.sep_str ++ plugin_dir_name;
    return blk: {
        if (native_os == .windows or native_os == .uefi) {
            break :blk &.{
                xdg_plugin_dir,
                "%LOCALAPPDATA%" ++ fs.path.sep_str ++ default_filename ++ fs.path.sep_str ++ plugin_dir_name,
            };
        } else if (native_os.isDarwin()) {
            break :blk &.{
                xdg_plugin_dir,
                "~" ++ fs.path.sep_str ++ "Library" ++ fs.path.sep_str ++ "Application Support" ++ fs.path.sep_str ++ default_filename ++ fs.path.sep_str ++ plugin_dir_name,
                "~" ++ fs.path.sep_str ++ ".local" ++ fs.path.sep_str ++ "share" ++ fs.path.sep_str ++ default_filename ++ fs.path.sep_str ++ plugin_dir_name,
            };
        } else {
            break :blk &.{
                xdg_plugin_dir,
                "~" ++ fs.path.sep_str ++ ".local" ++ fs.path.sep_str ++ "share" ++ fs.path.sep_str ++ default_filename ++ fs.path.sep_str ++ plugin_dir_name,
            };
        }
    };
}

/// Parse a config value that is required for the initialization of the program
/// and reading the rest of the config values.
fn parseInitValue(self: *Config, arena: Allocator, comptime name: []const u8, args: cli.Parsed) !void {
    const option_info = (try optionInfo(name)).?;
    const option_type = (try optionType(name)).?;

    if (args.values.get(name)) |val| {
        if (@as(OptionType, val) != option_type) {
            return error.TypeMismatch;
        }

        @field(self, name) = switch (@FieldType(Config, name)) {
            bool => val.bool,
            i64 => val.int,
            []const u8 => blk: {
                if (option_info.is_path) {
                    break :blk try self.allocator.dupe(u8, try filepath.expand(arena, val.string));
                } else {
                    break :blk try self.allocator.dupe(
                        u8,
                        try filepath.expandEnv(arena, val.string),
                    );
                }
            },
            else => @compileError("Config field '" ++ name ++ "' has invalid type"),
        };

        return;
    }

    if (option_info.disable_env) {
        return;
    }

    const meta_env_var = option_info.environment_variable orelse name;
    const var_name_alloc = try mem.concat(
        arena,
        u8,
        &[_][]const u8{ build_options.env_prefix, "_", meta_env_var },
    );
    defer arena.free(var_name_alloc);

    mem.replaceScalar(u8, var_name_alloc, '-', '_');

    var buf: [1024]u8 = undefined;
    const var_name = std.ascii.upperString(&buf, var_name_alloc);

    if (std.process.getEnvVarOwned(arena, var_name)) |s| {
        defer arena.free(s);
        if (s.len != 0) {
            @field(self, name) = switch (@FieldType(Config, name)) {
                bool => try parseBool(s),
                i64 => try std.fmt.parseInt(i64, s, 0),
                []const u8 => blk: {
                    if (option_info.is_path) {
                        break :blk try self.allocator.dupe(u8, try filepath.expand(arena, s));
                    } else {
                        break :blk try self.allocator.dupe(u8, try filepath.expandEnv(arena, s));
                    }
                },
                else => @compileError("Config field " ++ name ++ " has invalid type"),
            };
        }
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {}, // no-op, use default
        else => return err,
    }

    if (@FieldType(Config, name) == []const u8) {
        @field(self, name) = try self.allocator.dupe(u8, @field(self, name));
    }
}

/// Find the first matching config file and load its contents. The caller owns
/// the returned contents and should call `free` on them.
fn loadFile(self: *Config, arena: Allocator) ![]const u8 {
    var wd = try fs.cwd().openDir(self.working_directory, .{});
    defer wd.close();

    if (!mem.eql(u8, self.config_file, "")) {
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
        const app_support_joined = try fs.path.join(
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
        const home_config_joined = try fs.path.join(arena, &[_][]const u8{ "~", ".config" });
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

        const home_joined = try fs.path.join(arena, &[_][]const u8{ "~", default_filename });
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
        const w = std.io.getStdErr().writer();
        try w.print(
            "config files over 1MB are not currently allowed, current size is {d} bytes\n",
            .{size},
        );
        try w.print(
            "this is only temporary safeguard during development and will be removed in the future\n",
            .{},
        );

        return error.FileTooBig;
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
