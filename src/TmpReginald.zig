// SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
//
// SPDX-License-Identifier: GPL-3.0-or-later

//! TmpReginald creates and runs a temporary instance of Reginald for testing.

const TmpReginald = @This();

const build_options = @import("build_options");
const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Io = std.Io;
const testing = std.testing;

reginald_exe: [:0]const u8,
tmp_dir: std.testing.TmpDir,

const prefix = "zig-out";

pub const Error = error{
    BuildFailed,
    RunFailed,
} || std.process.RunError;

pub const Result = struct {
    argv: []const []const u8,
    cmd: []const u8,
    code: u8,
    stdout: []const u8,
    stderr: []const u8,

    pub fn deinit(self: *@This(), gpa: Allocator) void {
        gpa.free(self.argv);
        gpa.free(self.cmd);
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }
};

pub fn init(gpa: Allocator, io: Io) Error!TmpReginald {
    comptime assert(builtin.is_test);

    const result = try std.process.run(gpa, io, .{
        .argv = &.{
            build_options.zig_exe,
            "build",
            "--prefix",
            prefix,
        },
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("\"zig build\" failed:\n{s}\n", .{result.stderr});
            return error.BuildFailed;
        },
        else => {
            std.debug.print("\"zig build\" failed:\n{s}\n", .{result.stderr});
            return error.BuildFailed;
        },
    }

    const exe = try std.fs.path.join(gpa, &.{
        prefix,
        "bin",
        comptime "reginald" ++ builtin.target.exeFileExt(),
    });
    defer gpa.free(exe);

    const reginald_exe = try Io.Dir.cwd().realPathFileAlloc(io, exe, gpa);
    errdefer gpa.free(reginald_exe);

    const tmp_dir = std.testing.tmpDir(.{});
    errdefer tmp_dir.cleanup();

    return .{
        .reginald_exe = reginald_exe,
        .tmp_dir = tmp_dir,
    };
}

pub fn deinit(self: *TmpReginald, gpa: Allocator) void {
    self.tmp_dir.cleanup();
    gpa.free(self.reginald_exe);
}

/// Run the built Reginald binary with the given options, wait for the run to finish, and store
/// the output. Reginald should always run from beginning to end without user interaction so this
/// function waits for the result as the test wouldn't have anything meaningful to do in
/// the meantime.
pub fn run(
    self: *const TmpReginald,
    gpa: Allocator,
    io: Io,
    args: []const []const u8,
) Error!Result {
    comptime assert(builtin.is_test);

    const argv = try std.mem.concat(gpa, []const u8, &.{ &.{self.reginald_exe}, args });
    errdefer gpa.free(argv);

    const cmd = try std.mem.join(gpa, " ", argv);
    errdefer gpa.free(cmd);

    const result = try std.process.run(gpa, io, .{
        .argv = &.{self.reginald_exe},
        .cwd = .{ .dir = self.tmp_dir.dir },
    });
    errdefer gpa.free(result.stdout);
    errdefer gpa.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            return .{
                .argv = argv,
                .cmd = cmd,
                .code = code,
                .stdout = result.stdout,
                .stderr = result.stderr,
            };
        },
        else => {
            std.debug.print("failed to run \"{s}\":\n{s}\n", .{ cmd, result.stderr });
            return error.RunFailed;
        },
    }
}

pub fn runExpectStderrStartsWith(
    self: *TmpReginald,
    gpa: Allocator,
    io: Io,
    args: []const []const u8,
    expected_starts_with: []const u8,
    expected_exit_code: u8,
) !void {
    comptime assert(builtin.is_test);

    var result = try self.run(gpa, io, args);
    defer result.deinit(gpa);

    try testing.expectStringStartsWith(result.stderr, expected_starts_with);
    try testing.expectEqual(expected_exit_code, result.code);
}
