const Config = @This();

const std = @import("std");

/// Path to the config file.
config_file: []const u8 = "",

/// All of the relative paths are resolved relative to this.
working_directory: []const u8 = ".",

/// The maximum number of concurrent jobs to allow. If this is less than 1,
/// unlimited concurrent jobs are allowed.
max_jobs: i32 = -1,

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
