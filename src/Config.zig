//! Configuration resolved for the current run of Reginald. It is parsed from
//! the config file, environment variables, and command-line options. The types
//! of the configuration should match the precision that is available in
//! the different config sources so that the user's config can be represented
//! losslessly.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Allocator = std.mem.Allocator;
const fs = std.fs;

const cli = @import("cli.zig");
const filepath = @import("filepath.zig");

/// Allocator that the config uses for its internal allocations.
allocator: Allocator,

/// Path to the config file.
config_file: []const u8 = "",

/// The base directory for resolving the configured paths within the program.
directory: []const u8 = ".",

// /// The maximum number of concurrent jobs to allow. If this is less than 1,
// /// unlimited concurrent jobs are allowed.
// max_jobs: i64 = -1,

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
    default_filename ++ std.fs.path.sep_str ++ default_filename,
    default_filename ++ std.fs.path.sep_str ++ "config",
    default_filename,
};

/// Type of a config value as a more general value instead of raw types.
pub const ValueType = enum { bool, int, string };

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

    // /// Subcommands for which the command-line option for this config option
    // /// should be created for instead of creating it as a global command-line
    // /// option.
    // subcommands: ?[]const cli.Subcommand = null,
};

pub const metadata = [_]Metadata{
    .{
        .name = "config_file",
        .long = "config",
        .short = 'c',
        .description = "use config file from `<path>`",
        .disable_config_file = true,
        .is_path = true,
    },
    .{
        .name = "directory",
        .short = 'd',
        .description = "run Reginald as if it was started from `<path>`",
        .is_path = true,
    },
    // .{
    //     .name = "max_jobs",
    //     .long = "jobs",
    //     .short = 'j',
    //     .description = "maximum number of jobs to run concurrently",
    //     .subcommands = &[_]cli.Subcommand{.apply},
    // },
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
    .{
        .name = "working_directory",
        .long = "chdir",
        .short = 'C',
        .description = "run Reginald as if it was started from `<path>`",
        .disable_config_file = true,
        .is_path = true,
    },
};

/// Initialize the config instance and parse the the global config options into
/// it. This includes resolving the config file location, reading it, and
/// parsing the global config option values from it, from the environment
/// variables, and from the CLI options. The caller owns the created `Config`
/// and must call `deinit` on it.
pub fn init(allocator: Allocator, args: cli.Parsed) !@This() {
    var cfg: @This() = .{ .allocator = allocator };
    errdefer cfg.deinit();

    try cfg.parseInitValue("working_directory", args);

    return cfg;
}

/// Free the memory allocated by the `Config`.
pub fn deinit(self: *@This()) void {
    self.allocator.free(self.working_directory);
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

pub fn valueType(m: Metadata) !ValueType {
    // We need to loop through the fields instead of using the built-in
    // functions for accessing by name as the parameter is not known at compile
    // time.
    inline for (std.meta.fields(@This())) |field| {
        if (std.mem.eql(u8, field.name, m.name)) {
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

fn fieldValueType(comptime name: []const u8) ValueType {
    // We need to loop through the fields instead of using the built-in
    // functions for accessing by name as the parameter is not known at compile
    // time.
    return switch (@FieldType(@This(), name)) {
        bool => .bool,
        i64 => .int,
        []const u8 => .string,
        else => @compileError("Config field " ++ name ++ " has invalid type"),
    };
}

/// Parse a config value that is required for the initialization of the program
/// and reading the rest of the config values.
fn parseInitValue(self: *@This(), comptime name: []const u8, args: cli.Parsed) !void {
    const meta = findMetadata(name) orelse return error.UnknownOption;
    const vt = fieldValueType(name);

    if (args.values.get(meta.name)) |val| {
        if (@as(ValueType, val) != vt) {
            return error.TypeMismatch;
        }

        @field(self, name) = switch (@FieldType(@This(), name)) {
            bool => val.bool,
            i64 => val.int,
            []const u8 => blk: {
                if (meta.is_path) {
                    break :blk try filepath.expand(self.allocator, val.string);
                } else {
                    break :blk try filepath.expandEnv(self.allocator, val.string);
                }
            },
            else => @compileError("Config field " ++ name ++ " has invalid type"),
        };

        return;
    }

    if (meta.disable_env) {
        return;
    }

    const meta_env = meta.environment_variable orelse meta.name;
    var env_name = try std.mem.concat(
        self.allocator,
        u8,
        &[_][]const u8{ build_options.env_prefix, "_", meta_env },
    );
    defer self.allocator.free(env_name);

    std.mem.replaceScalar(u8, env_name, '-', '_');

    var buf: [1024]u8 = undefined;
    env_name = std.ascii.upperString(&buf, env_name);

    if (std.process.getEnvVarOwned(self.allocator, env_name)) |s| {
        defer self.allocator.free(s);
        if (s.len != 0) {
            @field(self, name) = switch (@FieldType(@This(), name)) {
                bool => try parseBool(s),
                i64 => try std.fmt.parseInt(i64, s, 0),
                []const u8 => blk: {
                    if (meta.is_path) {
                        break :blk try filepath.expand(self.allocator, s);
                    } else {
                        break :blk try filepath.expandEnv(self.allocator, s);
                    }
                },
                else => @compileError("Config field " ++ name ++ " has invalid type"),
            };
        }
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {}, // no-op, use default
        else => return err,
    }

    if (@FieldType(@This(), name) == []const u8) {
        @field(self, name) = try self.allocator.dupe(u8, @field(self, name));
    }
}

/// Return the config metadata entry for the given name or null if no entry is
/// found for the name.
fn findMetadata(name: []const u8) ?Metadata {
    inline for (metadata) |m| {
        if (std.mem.eql(u8, m.name, name)) {
            return m;
        }
    }

    return null;
}

/// Find the first matching config file and load its contents. The caller owns
/// the returned contents and should call `free` on them.
pub fn loadFile(allocator: Allocator, parsed_args: cli.Parsed, wd_path: ?[]const u8) ![]const u8 {
    var env_path: ?[]const u8 = null;
    if (std.process.getEnvVarOwned(allocator, build_options.env_prefix ++ "CONFIG")) |s| {
        env_path = s;
    } else |err| {
        switch (err) {
            error.EnvironmentVariableNotFound => {}, // no-op
            else => return err,
        }
    }

    var opt_path: ?[]const u8 = null;
    if (parsed_args.values.get("config_file")) |file| {
        switch (file) {
            .string => |s| opt_path = s,
            else => unreachable,
        }
    }

    var path: ?[]const u8 = null;

    if (opt_path) |s| {
        if (env_path) |p| {
            allocator.free(p);
        }

        path = try allocator.dupe(u8, s);
    } else if (env_path) |s| {
        path = s; // We already own s.
    }

    if (path) |p| {
        defer allocator.free(p);

        const f = try filepath.expand(allocator, p);
        defer allocator.free(f);

        var wd = fs.cwd();
        if (wd_path) |s| {
            wd = try wd.openDir(s, .{});
        }
        defer if (wd_path != null) {
            wd.close();
        };

        return try loadOne(allocator, f, &wd);
    }

    // If the user uses an option or environment variable to set the config
    // file, the lookup should fail if that file is not present. Otherwise, we
    // should continue and check the default file locations.
    var wd = fs.cwd();
    if (wd_path) |s| {
        wd = try wd.openDir(s, .{});
    }
    defer if (wd_path != null) {
        wd.close();
    };

    // Current working directory first as that's the most natural place.
    inline for (default_extensions) |e| {
        if (loadOne(allocator, default_filename ++ e, &wd)) |result| {
            return result;
        } else |err| {
            switch (err) {
                error.FileNotFound, error.IsDir => {},
                else => return err,
            }
        }
    }

    if (std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME")) |xdg| {
        defer allocator.free(xdg);

        // I think this is the encouraged way to handle the lookups.
        var dir = try wd.openDir(xdg, .{});
        defer dir.close();

        if (tryPaths(allocator, unix_config_lookup, &dir)) |result| {
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
        const dirname = try filepath.expand(allocator, "%APPDATA%");
        defer allocator.free(dirname);

        var dir = try wd.openDir(dirname, .{});
        defer dir.close();

        if (tryPaths(allocator, [_][]const u8{ default_filename, "config" }, &dir)) |result| {
            return result;
        } else |err| {
            switch (err) {
                error.FileNotFound => {},
                else => return err,
            }
        }
    } else if (native_os.isDarwin()) {
        const app_support_j = try fs.path.join(
            allocator,
            &[_][]const u8{ "~", "Library", "Application Support", default_filename },
        );
        defer allocator.free(app_support_j);

        const app_support_name = try filepath.expand(allocator, app_support_j);
        defer allocator.free(app_support_name);

        var app_support = try wd.openDir(app_support_name, .{});
        defer app_support.close();

        if (tryPaths(allocator, [_][]const u8{ default_filename, "config" }, &app_support)) |result| {
            return result;
        } else |err| {
            switch (err) {
                error.FileNotFound => {},
                else => return err,
            }
        }
    }

    if (native_os != .windows and native_os != .uefi) {
        const home_cfg_j = try fs.path.join(allocator, &[_][]const u8{ "~", ".config" });
        defer allocator.free(home_cfg_j);

        const home_cfg_name = try filepath.expand(allocator, home_cfg_j);
        defer allocator.free(home_cfg_name);

        var home_cfg = try wd.openDir(home_cfg_name, .{});
        defer home_cfg.close();

        if (tryPaths(allocator, unix_config_lookup, &home_cfg)) |result| {
            return result;
        } else |err| {
            switch (err) {
                error.FileNotFound => {},
                else => return err,
            }
        }

        const home_j = try fs.path.join(allocator, &[_][]const u8{ "~", default_filename });
        defer allocator.free(home_j);

        const home_name = try filepath.expand(allocator, home_j);
        defer allocator.free(home_name);

        var home = try wd.openDir(home_name, .{});
        defer home.close();

        if (tryPaths(allocator, [_][]const u8{ default_filename, "." ++ default_filename }, &home)) |result| {
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
fn loadOne(allocator: Allocator, f: []const u8, dir: *std.fs.Dir) ![]const u8 {
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
    return try dir.readFileAlloc(allocator, f, 1 << 20);
}

fn tryPaths(allocator: Allocator, comptime paths: anytype, dir: *std.fs.Dir) ![]const u8 {
    inline for (paths) |f| {
        inline for (default_extensions) |e| {
            if (loadOne(allocator, f ++ e, dir)) |result| {
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
