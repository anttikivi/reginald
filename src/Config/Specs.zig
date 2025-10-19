const std = @import("std");
const build_options = @import("build_options");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const StringHashMap = std.StringHashMap;

const Value = @import("../Config.zig").Value;

allocator: Allocator,

/// Lookup table for option specs by the config key. Apart from handling
/// the static config fields, this map is used in order to include
/// the plugin-defined options in the lookup.
specs: StringHashMap(OptionSpec),
long_options: StringHashMap([]const u8),
short_options: [256]?[]const u8,

pub const config_file: OptionSpec = .{
    .early = true,
    .type = .string,
    .long = "config",
    .short = 'c',
    .environment_variable = "CONFIG",
    .description = "Use config file from `<path>`. If <path> is set to `-`, Reginald reads config from stdin.",
    .disable_config_file_option = true,
    .is_path = true,
};
pub const directory: OptionSpec = .{
    .type = .string,
    .default = .{ .string = "." },
    .short = 'd',
    .description = "run Reginald as if it was started from `<path>`",
    .disable_config_file_option = true,
    .is_path = true,
};
pub const extend: OptionSpec = .{
    .early = true,
    .type = .bool,
    .short = 'e',
    .description = "extend the slices in the config with values from each sources instead of overriding",
    .disable_config_file_option = true,
};
pub const @"logging.enabled": OptionSpec = .{
    .type = .bool,
    .default = .{ .bool = true },
    .long = "log",
    .description = "enable logging",
};
pub const @"logging.level": OptionSpec = .{
    .type = .log_level,
    .default = .{ .log_level = .info },
    .long = "log-level",
    .description = "set logging level so that only log messages with level greater than of equal to `<level>` are enabled",
};
pub const plugin_paths: OptionSpec = .{
    .type = .string_slice,
    .short = 'P',
    .description = "search for plugins from `<paths>`",
    .is_path = true,
};
pub const print_help: OptionSpec = .{
    .type = .bool,
    .long = "help",
    .short = 'h',
    .description = "show the help message and exit",
    .disable_environment_variable = true,
    .disable_config_file_option = true,
};
pub const print_version: OptionSpec = .{
    .type = .bool,
    .long = "version",
    .description = "print the version information and exit",
    .disable_environment_variable = true,
    .disable_config_file_option = true,
};
pub const quiet: OptionSpec = .{
    .type = .bool,
    .short = 'q',
    .description = "silence all output expect errors",
};
pub const verbose: OptionSpec = .{
    .type = .bool,
    .short = 'v',
    .description = "print more verbose output",
};
pub const working_directory: OptionSpec = .{
    .early = true,
    .type = .string,
    .default = .{ .string = "." },
    .long = "chdir",
    .short = 'C',
    .description = "run Reginald as if it was started from `<path>`",
    .disable_config_file_option = true,
    .is_path = true,
};

pub const OptionType = enum {
    bool,
    int,
    string,
    string_slice,
    log_level,
};

/// Represents the data for creating command-line options and config file
/// entries and checking environment variables for a config option.
pub const OptionSpec = struct {
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

    pub fn defaultValue(self: *const @This()) Value {
        const value: Value = if (self.default) |def| def else switch (self.type) {
            .bool => .{ .bool = false },
            .int => .{ .int = 0 },
            .string => .{ .string = "" },
            .string_slice => .{ .string_slice = &[_][]const u8{} },
            .log_level => .{ .log_level = .info },
        };

        assert(@as(OptionType, value) == self.type);

        return value;
    }

    /// Return or construct the name of the environment variable for this spec.
    /// The caller owns the result and must free it.
    pub fn getEnvVarName(
        self: *const @This(),
        gpa: Allocator,
        key: []const u8,
    ) Allocator.Error![]const u8 {
        assert(!self.disable_environment_variable);
        assert(key.len > 0);
        assert(key.len <= 1024);

        const base = self.environment_variable orelse key;
        const prefixed = try std.mem.concat(gpa, u8, &[_][]const u8{
            build_options.env_prefix,
            base,
        });
        defer gpa.free(prefixed);

        std.mem.replaceScalar(u8, prefixed, '-', '_');
        std.mem.replaceScalar(u8, prefixed, '.', '_');

        var buf: [1024]u8 = undefined;
        assert(prefixed.len <= 1024);
        const variable = std.ascii.upperString(&buf, prefixed);

        assert(variable.len > 0);
        assert(std.mem.indexOfAny(u8, variable, "abcdefghijklmnopqrstuvwxyz") == null);

        return try gpa.dupe(u8, variable);
    }
};

/// Initialize the config specs and build the lookup tables. The caller owns
/// the memory and must call `deinit` on it.
pub fn init(self: *@This(), gpa: Allocator) !void {
    self.* = .{
        .allocator = gpa,
        .specs = .init(gpa),
        .long_options = .init(gpa),
        .short_options = .{null} ** 256,
    };

    inline for (@typeInfo(@This()).@"struct".decls) |decl| {
        comptime if (@TypeOf(@field(@This(), decl.name)) != OptionSpec) {
            continue;
        };

        const spec: OptionSpec = @field(@This(), decl.name);
        const key = try self.allocator.dupe(u8, decl.name);

        // The names are duplicated to have the static declaration names behave
        // the same with the spec names that come from the plugins. We need to
        // allocate a few more strings but gain a simpler flow.
        try self.specs.put(key, spec);

        const long_option = if (spec.long) |l| try self.allocator.dupe(u8, l) else blk: {
            const tmp = try self.allocator.dupe(u8, decl.name);
            std.mem.replaceScalar(u8, tmp, '.', '-');
            std.mem.replaceScalar(u8, tmp, '_', '-');
            break :blk tmp;
        };
        assert(long_option.len > 0);

        try self.long_options.put(long_option, key);

        if (spec.short) |c| {
            self.short_options[c] = key;
        }
    }
}

pub fn deinit(self: *@This()) void {
    var long_it = self.long_options.keyIterator();
    while (long_it.next()) |key| {
        self.allocator.free(key.*);
    }
    self.long_options.deinit();

    var key_it = self.specs.keyIterator();
    while (key_it.next()) |key| {
        self.allocator.free(key.*);
    }
    self.specs.deinit();
}

pub fn get(self: *const @This(), key: []const u8) ?OptionSpec {
    return self.specs.get(key);
}
