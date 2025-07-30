//! Configuration resolved for the current run of Reginald. It is parsed from
//! the config file, environment variables, and command-line options. The types
//! of the configuration should match the precision that is available in
//! the different config sources so that the user's config can be represented
//! losslessly.

const Config = @This();

const std = @import("std");

/// Path to the config file.
config_file: []const u8 = "",

/// All of the relative paths are resolved relative to this.
working_directory: []const u8 = ".",

/// The maximum number of concurrent jobs to allow. If this is less than 1,
/// unlimited concurrent jobs are allowed.
max_jobs: i64 = -1,

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

/// Type of a config value as a more general value instead of raw types.
const ValueType = enum {
    bool,
    int,
    string,
};

/// Represents the data for creating command-line options and config file
/// entries and checking environment variables for a config option.
pub const Metadata = struct {
    /// Name of the config field in `Config`.
    name: []const u8,

    /// Name of the long command-line option. If not set but the command-line
    /// option is not disable, the name of the field will be used.
    long: ?[]const u8 = null,

    /// The one-letter command-line option.
    short: ?u8 = null,

    /// Short description of the option on the command-line help output.
    description: ?[]const u8 = null,

    /// If not null and set to true, no command-line option is generated for
    /// this option.
    disable_option: ?bool = null,

    /// If not null and set to true, value for this config option is not checked
    /// from an environment variable.
    disable_env: ?bool = null,

    /// Subcommands for which the command-line option for this config option
    /// should be created for instead of creating it as a global command-line
    /// option.
    subcommands: ?[]const []const u8 = null,
};

pub const metadata = [_]Metadata{
    .{
        .name = "config_file",
        .long = "config",
        .short = 'c',
        .description = "use config file from `<path>`",
    },
    .{
        .name = "working_directory",
        .long = "directory",
        .short = 'C',
        .description = "run Reginald as if it was started from `<path>`",
    },
    .{
        .name = "max_jobs",
        .long = "jobs",
        .short = 'j',
        .description = "maximum number of jobs to run concurrently",
        .subcommands = &[_][]const u8{"apply"},
    },
    .{
        .name = "print_help",
        .long = "help",
        .short = 'h',
        .description = "show the help message and exit",
        .disable_env = true,
    },
    .{
        .name = "print_version",
        .long = "version",
        .description = "print the version information and exit",
        .disable_env = true,
    },
    .{
        .name = "quiet",
        .short = 'q',
        .description = "silence all output expect errors",
    },
    .{
        .name = "verbose",
        .short = 'v',
        .description = "print more verbose output",
    },
};

pub fn valueType(meta: Metadata) !ValueType {
    // We need to loop through the fields instead of using the built-in
    // functions for accessing by name as the parameter is not known at compile
    // time.
    inline for (std.meta.fields(Config)) |field| {
        if (std.mem.eql(u8, field.name, meta.name)) {
            return switch (field.type) {
                bool => .bool,
                i64 => .int,
                []const u8 => .string,
                else => error.InvalidField,
            };
        }
    }

    return error.UnknownField;
}

/// Convert an ASCII string given as a config values to a bool.
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
