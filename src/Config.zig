// SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
//
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const native_os = builtin.target.os.tag;
const CliOptions = @import("root").CliOptions;

const Config = @This();

jobs: i8,

const filenames = [_][]const u8{"reginald.json"};
const lookup_paths = [_][]const u8{
    "reginald" ++ std.fs.path.sep_str ++ "reginald.json",
    "reginald" ++ std.fs.path.sep_str ++ "config.json",
    "reginald.json",
};

pub fn findAndParse(
    io: Io,
    environ_map: *std.process.Environ.Map,
    cli_opts: *const CliOptions,
) void {
    const config_file = blk: {
        if (cli_opts.config) |filename| {
            break :blk Io.Dir.cwd().openFile(io, filename, .{}) catch |err| {
                std.process.fatal("failed to open config file \"{s}\": {t}", .{ filename, err });
            };
        } else {
            break :blk findFile(io, environ_map);
        }
    };
    defer config_file.close(io);
}

fn findFile(io: Io, environ_map: *std.process.Environ.Map) Io.File {
    const cwd = Io.Dir.cwd();
    for (filenames) |filename| {
        return cwd.openFile(io, filename, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => std.process.fatal(
                "failed to open config file \"{s}\": {t}",
                .{ filename, err },
            ),
        };
    }

    if (environ_map.get("XDG_CONFIG_HOME")) |dirname| {
        var dir = cwd.openDir(io, dirname, .{}) catch |err| {
            std.process.fatal("failed to open XDG_CONFIG_HOME ({s}): {t}", .{ dirname, err });
        };
        defer dir.close(io);

        for (lookup_paths) |path| {
            return dir.openFile(io, path, .{}) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => std.process.fatal(
                    "failed to open config file \"{s}{c}{s}\": {t}",
                    .{ dirname, std.fs.path.sep, path, err },
                ),
            };
        }
    }

    if (native_os == .windows) {
        // TODO: Is this the correct Windows location?
        if (environ_map.get("APPDATA")) |dirname| {
            var dir = cwd.openDir(io, dirname, .{}) catch |err| {
                std.process.fatal("failed to open APPDATA ({s}): {t}", .{ dirname, err });
            };
            defer dir.close(io);

            for (lookup_paths) |path| {
                return dir.openFile(io, path, .{}) catch |err| switch (err) {
                    error.FileNotFound => continue,
                    else => std.process.fatal(
                        "failed to open config file \"{s}{c}{s}\": {t}",
                        .{ dirname, std.fs.path.sep, path, err },
                    ),
                };
            }
        }
    }

    const home_dir_path = environ_map.get("HOME");
    const home_dir = blk: {
        if (home_dir_path) |dirname| {
            break :blk cwd.openDir(io, dirname, .{}) catch |err| std.process.fatal(
                "failed to open home directory ({s}): {t}",
                .{ dirname, err },
            );
        }

        break :blk null;
    };
    defer if (home_dir) |dir| dir.close(io);

    if (native_os.isDarwin()) {
        if (home_dir) |home| {
            const lookup_dir =
                "Library" ++
                std.fs.path.sep_str ++
                "Application Support" ++
                std.fs.path.sep_str ++
                "reginald";
            const dir = home.openDir(io, lookup_dir, .{}) catch |err| switch (err) {
                error.FileNotFound => null,
                else => std.process.fatal(
                    "failed to open {s}{c}{s}: {t}",
                    .{
                        home_dir_path.?,
                        std.fs.path.sep,
                        lookup_dir,
                        err,
                    },
                ),
            };
            defer if (dir) |d| d.close(io);

            if (dir) |d| {
                for (filenames) |filename| {
                    return d.openFile(io, filename, .{}) catch |err| switch (err) {
                        error.FileNotFound => continue,
                        else => std.process.fatal(
                            "failed to open config file {s}{c}{s}{c}{s}: {t}",
                            .{
                                home_dir_path.?,
                                std.fs.path.sep,
                                lookup_dir,
                                std.fs.path.sep,
                                filename,
                                err,
                            },
                        ),
                    };
                }
            }
        }
    }

    if (native_os != .windows) {
        if (home_dir) |home| {
            const lookup_dir = ".config";
            const dir = home.openDir(io, lookup_dir, .{}) catch |err| switch (err) {
                error.FileNotFound => null,
                else => std.process.fatal(
                    "failed to open {s}{c}{s}: {t}",
                    .{
                        home_dir_path.?,
                        std.fs.path.sep,
                        lookup_dir,
                        err,
                    },
                ),
            };
            defer if (dir) |d| d.close(io);

            if (dir) |d| {
                for (lookup_paths) |path| {
                    return d.openFile(io, path, .{}) catch |err| switch (err) {
                        error.FileNotFound => continue,
                        else => std.process.fatal(
                            "failed to open config file {s}{c}{s}{c}{s}: {t}",
                            .{
                                home_dir_path.?,
                                std.fs.path.sep,
                                lookup_dir,
                                std.fs.path.sep,
                                path,
                                err,
                            },
                        ),
                    };
                }
            }
        }
    }

    std.process.fatal("could not find a config file", .{});
}
