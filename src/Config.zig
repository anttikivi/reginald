// SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
//
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const native_os = builtin.target.os.tag;
const CliOptions = @import("root").CliOptions;

const Config = @This();

filetype: Filetype,
jobs: ?i8 = null,

const filenames = [_][]const u8{"reginald.json"};
const lookup_paths = [_][]const u8{
    "reginald" ++ std.fs.path.sep_str ++ "reginald.json",
    "reginald" ++ std.fs.path.sep_str ++ "config.json",
    "reginald.json",
};

var file_buffer: [4096]u8 = undefined;

const Handle = struct {
    file: Io.File,
    /// Full path of the file with the possible search directories prepended to it.
    path: []const u8,

    fn deinit(self: @This(), gpa: Allocator, io: Io) void {
        if (!std.mem.eql(u8, self.path, "-")) {
            self.file.close(io);
            gpa.free(self.path);
        }
    }
};

const Filetype = union(enum) {
    json: std.json.Parsed(std.json.Value),
};

pub fn deinit(self: Config) void {
    switch (self.filetype) {
        .json => |json| json.deinit(),
    }
}

pub fn findAndParse(
    gpa: Allocator,
    io: Io,
    environ_map: *std.process.Environ.Map,
    cli_opts: *const CliOptions,
) Config {
    const handle: Handle = blk: {
        if (cli_opts.config) |filename| {
            if (std.mem.eql(u8, filename, "-")) {
                break :blk .{
                    .file = Io.File.stdin(),
                    .path = "-",
                };
            }

            break :blk .{
                .file = Io.Dir.cwd().openFile(io, filename, .{}) catch |err| {
                    std.process.fatal("failed to open config file \"{s}\": {t}", .{ filename, err });
                },
                .path = gpa.dupe(u8, filename) catch |err| {
                    std.process.fatal("failed to duplicate config file name: {t}", .{err});
                },
            };
        } else {
            break :blk findFile(gpa, io, environ_map) catch |err| switch (err) {
                error.OutOfMemory => std.process.fatal(
                    "out of memory while finding the config file",
                    .{},
                ),
            };
        }
    };
    defer handle.deinit(gpa, io); // TODO: Save to config when the file can be modified

    var file_reader = handle.file.reader(io, &file_buffer);
    const file = &file_reader.interface;

    const content = file.allocRemaining(gpa, .unlimited) catch |err| {
        std.process.fatal("failed to read config file \"{s}\": {t}", .{ handle.path, err });
    };
    defer gpa.free(content);

    // TODO: Detect the config file type when support is added.
    // TODO: Add JSON diagnostics.
    const parsed_json = std.json.parseFromSlice(std.json.Value, gpa, content, .{}) catch |err| {
        if (std.mem.eql(u8, handle.path, "-")) {
            std.process.fatal("failed to parse JSON config from standard input: {t}", .{err});
        } else {
            std.process.fatal(
                "failed to parse JSON config file \"{s}\": {t}",
                .{ handle.path, err },
            );
        }
    };
    defer parsed_json.deinit();

    const val = parsed_json.value;
    var obj: std.json.ObjectMap = undefined;

    switch (val) {
        .object => |o| obj = o,
        else => |tag| std.process.fatal(
            "invalid JSON config type: expected object, got {t}",
            .{tag},
        ),
    }

    var config: Config = .{ .filetype = .{ .json = parsed_json } };

    var it = obj.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "jobs")) {
            switch (entry.value_ptr.*) {
                .integer => |i| {
                    if (i < std.math.minInt(i8) or i > std.math.maxInt(i8)) {
                        config.jobs = @intCast(i);
                    }
                },
                else => |tag| std.process.fatal(
                    "invalid value for config entry \"jobs\": expected integer, got {t}",
                    .{tag},
                ),
            }
        }

        std.process.fatal("unknown config entry \"{s}\" in {s}", .{ entry.key_ptr.*, handle.path });
    }

    return config;
}

/// Try to find a config file from the default locations and return a `Handle` with the file and
/// extra information for later utility. The caller own the `Handle`.
fn findFile(gpa: Allocator, io: Io, environ_map: *std.process.Environ.Map) Allocator.Error!Handle {
    const cwd = Io.Dir.cwd();

    for (filenames) |filename| {
        const file = cwd.openFile(io, filename, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => std.process.fatal(
                "failed to open config file \"{s}\": {t}",
                .{ filename, err },
            ),
        };
        return .{
            .file = file,
            .path = filename,
        };
    }

    if (environ_map.get("XDG_CONFIG_HOME")) |dirname| {
        var dir = cwd.openDir(io, dirname, .{}) catch |err| {
            std.process.fatal("failed to open XDG_CONFIG_HOME ({s}): {t}", .{ dirname, err });
        };
        defer dir.close(io);

        for (lookup_paths) |path| {
            const file = dir.openFile(io, path, .{}) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => std.process.fatal(
                    "failed to open config file \"{s}{c}{s}\": {t}",
                    .{ dirname, std.fs.path.sep, path, err },
                ),
            };
            errdefer file.close(io);
            const full_path = try std.fs.path.join(gpa, &.{ dirname, path });
            return .{
                .file = file,
                .path = full_path,
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
                const file = dir.openFile(io, path, .{}) catch |err| switch (err) {
                    error.FileNotFound => continue,
                    else => std.process.fatal(
                        "failed to open config file \"{s}{c}{s}\": {t}",
                        .{ dirname, std.fs.path.sep, path, err },
                    ),
                };
                errdefer file.close(io);
                const full_path = try std.fs.path.join(gpa, &.{ dirname, path });
                return .{
                    .file = file,
                    .path = full_path,
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
                    const file = d.openFile(io, filename, .{}) catch |err| switch (err) {
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
                    errdefer file.close(io);
                    const full_path = try std.fs.path.join(
                        gpa,
                        &.{
                            home_dir_path.?,
                            lookup_dir,
                            filename,
                        },
                    );
                    return .{
                        .file = file,
                        .path = full_path,
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
                    const file = d.openFile(io, path, .{}) catch |err| switch (err) {
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
                    errdefer file.close(io);
                    const full_path = try std.fs.path.join(
                        gpa,
                        &.{
                            home_dir_path.?,
                            lookup_dir,
                            path,
                        },
                    );
                    return .{
                        .file = file,
                        .path = full_path,
                    };
                }
            }
        }
    }

    std.process.fatal("could not find a config file", .{});
}
