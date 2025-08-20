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
const fs = std.fs;
const mem = std.mem;
const meta = std.meta;
const StructField = std.builtin.Type.StructField;

const cli = @import("cli.zig");
const @"comptime" = @import("comptime.zig");
const filepath = @import("filepath.zig");
const toml = @import("toml.zig");

allocator: Allocator,

/// Path to the config file.
config_file: []const u8 = "",

/// The base directory for resolving the configured paths within the program.
directory: []const u8 = ".",

/// When true, the config values that are slices are extended to the values from
/// the previous sources instead of having the value with the highest priority
/// override the ones that came before.
extend: bool = false,

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

pub const Logging = struct {
    /// Whether logs are enabled.
    enabled: bool = true,

    /// The selected logging level. Only messages of this or higher level will
    /// be printed.
    level: std.log.Level = .info,
};

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
    parse_from_string: bool = false,

    fn fileKey(self: *const @This(), arena: Allocator, name: []const u8) ![]const u8 {
        if (self.config_file_name) |s| {
            return s;
        }

        const s = try arena.dupe(u8, name);
        mem.replaceScalar(u8, s, '_', '-');
        return s;
    }
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
    extend: OptionInfo = .{
        .short = 'e',
        .description = "extend the slices in the config with values from each sources instead of overriding",
    },
    logging: LoggingInfo = .{
        .enabled = .{
            .long = "log",
            .description = "enable logging",
        },
        .level = .{
            .long = "log-level",
            .description = "set logging level so that only log messages with level greater than of equal to `<level>` are enabled",
            .parse_from_string = true,
        },
    },
    plugin_directories: OptionInfo = .{
        .long = "plugin-paths",
        .short = 'P',
        .environment_variable = "PLUGIN_PATHS",
        .config_file_name = "plugin-paths",
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
    // errdefer cfg.deinit(allocator);

    var arena_instance = ArenaAllocator.init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    cfg.config_file = try parseField(
        []const u8,
        arena,
        "config_file",
        comptime comptimeOptionInfo("config_file"),
        cfg.config_file,
        null,
        args,
        false,
    );
    cfg.working_directory = try parseField(
        []const u8,
        arena,
        "working_directory",
        comptime comptimeOptionInfo("working_directory"),
        cfg.working_directory,
        null,
        args,
        false,
    );

    const file_data = try cfg.loadFile(arena);
    defer arena.free(file_data);

    var diag: toml.Diagnostics = undefined;
    var toml_value = toml.parseWithDiagnostics(arena, file_data, &diag) catch |e| {
        try std.io.getStdErr().writer().print("{}\n", .{diag});
        return e;
    };
    defer toml_value.deinit(arena);
    assert(toml_value == .table);

    var parsed_keys: ArrayListUnmanaged([]const u8) = .empty;
    defer parsed_keys.deinit(arena);

    try parsed_keys.appendSlice(arena, &[_][]const u8{ "config_file", "working_directory" });

    cfg.extend = try parseField(
        bool,
        arena,
        "extend",
        comptime comptimeOptionInfo("extend"),
        cfg.extend,
        toml_value,
        args,
        cfg.extend,
    );
    try parsed_keys.append(arena, "extend");

    try parseStruct(arena, &cfg, "", &parsed_keys, toml_value, args, cfg.extend);

    // We know that we cannot search duplicate plugin directories after
    // expanding the paths so we might as well remove them here.
    {
        var found_paths: ArrayListUnmanaged([]const u8) = .empty;
        defer found_paths.deinit(arena);

        for (cfg.plugin_directories) |dir| {
            var contains = false;
            for (found_paths.items) |p| {
                if (mem.eql(u8, dir, p)) {
                    contains = true;
                }
            }

            if (!contains) {
                try found_paths.append(arena, dir);
            }
        }

        var new_value = try arena.alloc([]const u8, found_paths.items.len);
        for (found_paths.items, 0..) |p, i| {
            new_value[i] = try arena.dupe(u8, p);
        }
        cfg.plugin_directories = new_value;
    }

    inline for (meta.fields(Config)) |field| {
        switch (field.type) {
            []const u8 => @field(cfg, field.name) = try cfg.allocator.dupe(
                u8,
                @field(cfg, field.name),
            ),
            []const []const u8 => {
                const value = @field(cfg, field.name);
                var new_value = try cfg.allocator.alloc([]const u8, value.len);
                for (value, 0..) |v, i| {
                    new_value[i] = try cfg.allocator.dupe(u8, v);
                }
                @field(cfg, field.name) = new_value;
            },
            else => {}, // no-op
        }
    }

    return cfg;
}

/// Free the memory allocated by the `Config`.
pub fn deinit(self: *Config) void {
    inline for (meta.fields(Config)) |field| {
        switch (field.type) {
            []const u8 => self.allocator.free(@field(self, field.name)),
            []const []const u8 => {
                for (@field(self, field.name)) |v| {
                    self.allocator.free(v);
                }
                self.allocator.free(@field(self, field.name));
            },
            else => {}, // no-op
        }
    }
}

/// Ensure that the additional information for the Config fields match
/// the Config fields.
pub fn checkInfo() void {
    assert(meta.fields(Config).len == meta.fields(@TypeOf(Config.global_option_info)).len + 1);

    for (meta.fields(Config)) |field| {
        if (mem.eql(u8, field.name, "allocator")) {
            continue;
        }

        var found = false;
        for (meta.fields(@TypeOf(Config.global_option_info))) |info_field| {
            if (mem.eql(u8, field.name, info_field.name)) {
                found = true;
            }
        }

        assert(found);
    }

    for (meta.fields(@TypeOf(Config.global_option_info))) |field| {
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

                    if (info.parse_from_string) {
                        return .string;
                    }

                    return switch (@FieldType(Config, field.name)) {
                        bool => .bool,
                        i64 => .int,
                        []const u8 => .string,
                        []const []const u8 => .paths,
                        else => @compileError("config field '" ++ field.name ++ "' has invalid type: " ++ @typeName(@FieldType(Config, field.name))),
                    };
                },
                LoggingInfo => if (dot_index) |i| {
                    const logging_info = @field(global_option_info, field.name);
                    const logging_field_name = name[i + 1 ..];
                    const info_fields: []const StructField = meta.fields(@TypeOf(logging_info));
                    inline for (info_fields) |info_field| {
                        if (mem.eql(u8, logging_field_name, info_field.name)) {
                            const info = @field(logging_info, info_field.name);

                            if (info.parse_from_string) {
                                return .string;
                            }

                            return switch (@FieldType(Logging, info_field.name)) {
                                bool => .bool,
                                i64 => .int,
                                []const u8 => .string,
                                []const []const u8 => .paths,
                                else => @compileError("logging config field '" ++ info_field.name ++ "' has invalid type: " ++ @typeName(@FieldType(Logging, info_field.name))),
                            };
                        }
                    }

                    return error.InvalidKey;
                } else {
                    return error.InvalidKey;
                },
                else => @compileError("expected OptionInfo or LoggingInfo, found '" ++ @typeName(field.type) ++ "'"),
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
                    try std.io.getStdErr().writer().print(
                        "no config info matching key '{s}'\n",
                        .{name},
                    );
                    return error.InvalidKey;
                },
                else => @compileError("expected OptionInfo or LoggingInfo, found '" ++ @typeName(field.type) ++ "'"),
            }
        }
    }

    return null;
}

fn comptimeOptionInfo(comptime key: []const u8) OptionInfo {
    const parts = @"comptime".splitScalar(u8, key, '.');

    switch (parts.len) {
        0 => @compileError("invalid option info key: " ++ key),
        1 => if (@FieldType(@TypeOf(global_option_info), key) != OptionInfo) {
            @compileError("key '" ++ key ++ "' does not yield an OptionInfo");
        } else {
            return @field(global_option_info, key);
        },
        2 => if (mem.eql(u8, parts[0], "logging")) {
            return @field(global_option_info.logging, parts[1]);
        } else {
            @compileError("no option info for '" ++ key ++ "'");
        },
        else => @compileError("no option info for '" ++ key ++ "'"),
    }
}

fn parseStruct(
    arena: Allocator,
    ptr: anytype,
    comptime prefix: []const u8,
    parsed_keys: *ArrayListUnmanaged([]const u8),
    file_data: ?toml.Value,
    args: cli.Parsed,
    extend: bool,
) !void {
    const T = @TypeOf(ptr.*);

    switch (@typeInfo(T)) {
        .@"struct" => |@"struct"| {
            inline for (@"struct".fields) |field| {
                comptime if (mem.eql(u8, field.name, "allocator")) {
                    continue;
                };

                // Tasks are parsed in a single pass after loading the plugin
                // manifests.
                comptime if (mem.eql(u8, field.name, "tasks")) {
                    continue;
                };

                const key = if (prefix.len > 0) prefix ++ "." ++ field.name else field.name;

                var is_parsed = false;
                for (parsed_keys.items) |item| {
                    if (mem.eql(u8, item, key)) {
                        is_parsed = true;
                    }
                }

                if (!is_parsed) {
                    if (@typeInfo(field.type) == .@"struct") {
                        const struct_data: ?toml.Value = blk: {
                            if (mem.eql(u8, field.name, "logging")) {
                                if (file_data.?.table.get("logging")) |value| {
                                    switch (value) {
                                        .table => |t| break :blk .{ .table = t },
                                        else => {
                                            try std.io.getStdErr().writer().print(
                                                "config value for `{s}` is `{s}`, expected `{s}`\n",
                                                .{ key, @tagName(value), "table" },
                                            );
                                            return error.InvalidConfig;
                                        },
                                    }
                                }
                            }

                            try std.io.getStdErr().writer().print(
                                "unexpected config struct with key '{s}'\n",
                                .{field.name},
                            );
                            return error.InvalidConfig;
                        };
                        try parseStruct(
                            arena,
                            &@field(ptr.*, field.name),
                            key,
                            parsed_keys,
                            struct_data,
                            args,
                            extend,
                        );
                        try parsed_keys.append(arena, key);
                    } else {
                        const option_info = comptime comptimeOptionInfo(key);
                        @field(ptr.*, field.name) = try parseField(
                            @FieldType(T, field.name),
                            arena,
                            key,
                            option_info,
                            @field(ptr.*, field.name),
                            file_data,
                            args,
                            extend,
                        );
                        try parsed_keys.append(arena, key);
                    }
                }
            }
        },
        else => @compileError("expected a struct, got " ++ @typeName(T)),
    }

    std.debug.print("Parsed keys:\n", .{});

    for (parsed_keys.items) |item| {
        std.debug.print("- {s}\n", .{item});
    }

    if (file_data) |data| {
        assert(data == .table);

        const keys = data.table.keys();
        for (keys) |k| {
            var contains = false;

            if (prefix.len > 0) {
                for (parsed_keys.items) |p| {
                    const option_info = (try optionInfo(p)).?;
                    if (mem.startsWith(u8, p, prefix ++ ".")) {
                        if (mem.eql(u8, k, try option_info.fileKey(arena, p[prefix.len + 1 ..]))) {
                            contains = true;
                        }
                    }
                }
            } else {
                for (parsed_keys.items) |p| {
                    if (mem.eql(u8, p, "logging")) {
                        if (mem.eql(u8, p, k)) {
                            contains = true;
                        }
                    } else {
                        const option_info = (try optionInfo(p)).?;
                        if (mem.eql(u8, k, try option_info.fileKey(arena, p))) {
                            contains = true;
                        }
                    }
                }
            }

            if (!contains) {
                if (prefix.len > 0) {
                    try std.io.getStdErr().writer().print(
                        "unknown key in config file: {s}.{s}\n",
                        .{ prefix, k },
                    );
                } else if (mem.eql(u8, k, "tasks")) {
                    continue;
                } else {
                    try std.io.getStdErr().writer().print(
                        "unknown key in config file: {s}\n",
                        .{k},
                    );
                }
                return error.InvalidConfig;
            }
        }
    }
}

fn parseField(
    comptime T: type,
    arena: Allocator,
    key: []const u8,
    option_info: OptionInfo,
    default: T,
    file_data: ?toml.Value,
    args: cli.Parsed,
    extend: bool,
) !T {
    var value: T = default;

    const last_key = if (mem.lastIndexOfScalar(u8, key, '.')) |i| key[i + 1 ..] else key;

    if (try parseFileValue(T, arena, last_key, option_info, value, file_data, extend)) |new_value| {
        value = new_value;
    }

    if (try parseEnvValue(T, arena, key, option_info, value, extend)) |new_value| {
        value = new_value;
    }

    if (try parseArgValue(T, arena, key, option_info, value, args, extend)) |new_value| {
        value = new_value;
    }

    return blk: switch (T) {
        []const u8 => if (option_info.is_path) {
            break :blk try filepath.expand(arena, value);
        } else {
            break :blk try filepath.expandEnv(arena, value);
        },
        []const []const u8 => {
            var new_value = try arena.alloc([]const u8, value.len);

            if (option_info.is_path) {
                for (value, 0..) |v, i| {
                    new_value[i] = try filepath.expand(arena, v);
                }
            } else {
                for (value, 0..) |v, i| {
                    new_value[i] = try filepath.expandEnv(arena, v);
                }
            }

            break :blk new_value;
        },
        else => value,
    };
}

fn parseFileValue(
    comptime T: type,
    arena: Allocator,
    key: []const u8,
    option_info: OptionInfo,
    prev: T,
    file_data: ?toml.Value,
    extend: bool,
) !?T {
    if (option_info.disable_config_file or file_data == null) {
        return null;
    }

    assert(file_data.? == .table);

    const file_key = try option_info.fileKey(arena, key);
    // const file_key: []const u8 = blk: {
    //     if (option_info.config_file_name) |s| {
    //         break :blk s;
    //     } else {
    //         const s = try arena.dupe(u8, key);
    //         mem.replaceScalar(u8, s, '_', '-');
    //         break :blk s;
    //     }
    // };
    if (file_data.?.table.get(file_key)) |value| {
        return blk: switch (T) {
            bool => switch (value) {
                .bool => |b| break :blk b,
                else => |v| {
                    try std.io.getStdErr().writer().print(
                        "value `{}` given for `{s}` in config file has type `{s}`, expected `{s}`\n",
                        .{ v, file_key, @tagName(value), "bool" },
                    );
                    return error.InvalidConfig;
                },
            },
            i64 => switch (value) {
                .int => |i| break :blk i,
                else => |v| {
                    try std.io.getStdErr().writer().print(
                        "value `{}` given for `{s}` in config file has type `{s}`, expected `{s}`\n",
                        .{ v, file_key, @tagName(value), "int" },
                    );
                    return error.InvalidConfig;
                },
            },
            []const u8 => switch (value) {
                .string => |s| {
                    break :blk try arena.dupe(u8, s);
                },
                else => |v| {
                    try std.io.getStdErr().writer().print(
                        "value `{}` given for `{s}` in config file has type `{s}`, expected `{s}`\n",
                        .{ v, file_key, @tagName(value), "string" },
                    );
                    return error.InvalidConfig;
                },
            },
            []const []const u8 => switch (value) {
                .string => |str| {
                    var values: ArrayListUnmanaged([]const u8) = .empty;
                    defer values.deinit(arena);

                    if (extend) {
                        try values.appendSlice(arena, prev);
                    }

                    var str_iter = mem.splitScalar(u8, str, fs.path.delimiter);
                    while (str_iter.next()) |s| {
                        try values.append(arena, s);
                    }

                    var new_value = try arena.alloc([]u8, values.items.len);
                    for (values.items, 0..) |val, i| {
                        new_value[i] = try arena.dupe(u8, val);
                    }

                    break :blk new_value;
                },
                .array => |arr| {
                    var values: ArrayListUnmanaged([]const u8) = .empty;
                    defer values.deinit(arena);

                    if (extend) {
                        try values.appendSlice(arena, prev);
                    }

                    for (arr.items) |item| {
                        switch (item) {
                            .string => |s| try values.append(arena, s),
                            else => |v| {
                                try std.io.getStdErr().writer().print(
                                    "value `{}` given in `{s}` in config file has type `{s}`, expected string\n",
                                    .{ v, file_key, @tagName(item) },
                                );
                                return error.InvalidConfig;
                            },
                        }
                    }

                    var new_value = try arena.alloc([]u8, values.items.len);
                    for (values.items, 0..) |val, i| {
                        new_value[i] = try arena.dupe(u8, val);
                    }

                    break :blk new_value;
                },
                else => |v| {
                    try std.io.getStdErr().writer().print(
                        "value `{}` given for `{s}` in config file has type `{s}`, expected string or array\n",
                        .{ v, file_key, @tagName(value) },
                    );
                    return error.InvalidConfig;
                },
            },
            std.log.Level => switch (value) {
                .string => |s| break :blk try parseLogLevel(s),
                else => |v| {
                    try std.io.getStdErr().writer().print(
                        "value `{}` given for `{s}` in config file has type `{s}`, expected `{s}`\n",
                        .{ v, file_key, @tagName(value), "string" },
                    );
                    return error.InvalidConfig;
                },
            },
            else => @compileError("config field with invalid type: " ++ @typeName(T)),
        };
    }

    return null;
}

fn parseEnvValue(
    comptime T: type,
    arena: Allocator,
    key: []const u8,
    option_info: OptionInfo,
    prev: T,
    extend: bool,
) !?T {
    if (option_info.disable_env) {
        return null;
    }

    const base_var_name = option_info.environment_variable orelse key;
    const concat_var_name = try mem.concat(
        arena,
        u8,
        &[_][]const u8{ build_options.env_prefix, "_", base_var_name },
    );

    mem.replaceScalar(u8, concat_var_name, '-', '_');
    mem.replaceScalar(u8, concat_var_name, '.', '_');

    var buf: [1024]u8 = undefined;
    const var_name = std.ascii.upperString(&buf, concat_var_name);

    if (std.process.getEnvVarOwned(arena, var_name)) |s| {
        if (s.len > 0) {
            return switch (T) {
                bool => try parseBool(s),
                i64 => try std.fmt.parseInt(i64, s, 0),
                []const u8 => try arena.dupe(u8, s),
                []const []const u8 => blk: {
                    var values: ArrayListUnmanaged([]const u8) = .empty;
                    defer values.deinit(arena);

                    if (extend) {
                        try values.appendSlice(arena, prev);
                    }

                    var str_iter = mem.splitScalar(u8, s, fs.path.delimiter);
                    while (str_iter.next()) |u| {
                        try values.append(arena, u);
                    }

                    var new_value = try arena.alloc([]u8, values.items.len);
                    for (values.items, 0..) |val, i| {
                        new_value[i] = try arena.dupe(u8, val);
                    }

                    break :blk new_value;
                },
                std.log.Level => try parseLogLevel(s),
                else => @compileError("config field " ++ key ++ " has invalid type"),
            };
        }
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return err,
    }

    return null;
}

fn parseArgValue(
    comptime T: type,
    arena: Allocator,
    key: []const u8,
    option_info: OptionInfo,
    prev: T,
    args: cli.Parsed,
    extend: bool,
) !?T {
    if (option_info.disable_cli_option) {
        return null;
    }

    if (args.values.get(key)) |val| {
        assert(@as(OptionType, val) == (try optionType(key)).?);

        return switch (T) {
            bool => val.bool,
            i64 => val.int,
            []const u8 => try arena.dupe(u8, val.string),
            []const []const u8 => blk: {
                var values: ArrayListUnmanaged([]const u8) = .empty;
                defer values.deinit(arena);

                if (extend) {
                    try values.appendSlice(arena, prev);
                }

                for (val.paths) |v| {
                    try values.append(arena, v);
                }

                var new_value = try arena.alloc([]u8, values.items.len);
                for (values.items, 0..) |v, i| {
                    new_value[i] = try arena.dupe(u8, v);
                }

                break :blk new_value;
            },
            std.log.Level => try parseLogLevel(val.string),
            else => @compileError("config field '" ++ key ++ "' has invalid type"),
        };
    }

    return null;
}

fn parseLogLevel(s: []const u8) !std.log.Level {
    var buf: [8]u8 = undefined;
    if (s.len > buf.len) {
        try std.io.getStdErr().writer().print("invalid value for log level: {s}\n", .{s});
        return error.InvalidConfig;
    }

    const l = std.ascii.lowerString(&buf, s);

    if (mem.eql(u8, l, "e") or mem.eql(u8, l, "err") or mem.eql(u8, l, "error")) {
        return .err;
    } else if (mem.eql(u8, l, "w") or mem.eql(u8, l, "warn") or mem.eql(u8, l, "warning")) {
        return .warn;
    } else if (mem.eql(u8, l, "i") or mem.eql(u8, l, "info")) {
        return .info;
    } else if (mem.eql(u8, l, "d") or mem.eql(u8, l, "debug")) {
        return .debug;
    }

    try std.io.getStdErr().writer().print("invalid value for log level: {s}\n", .{s});
    return error.InvalidConfig;
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
