// SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
//
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const usage =
    \\Usage: reginald [--version] [-h | --help] [--log-level debug|info|warn|err]
    \\                <command> [<args>]
    \\
    \\Commands:
    \\
    \\  help        Print the usage of the subcommand given as the next argument and
    \\              exit
    \\  plan        Resolve and print the execution plan for the current configuration
    \\  version     Print the program version number and exit
    \\
    \\Global options:
    \\
    \\  -h, --help
    \\      Print this help message and exit
    \\  --log-level debug|info|warn|err
    \\      Print log messages that are either equal to or have greater severity than
    \\      the set level
    \\  --version
    \\      Print the program version number and exit
    \\
;

var stderr_buffer: [4096]u8 = undefined;
var stdout_buffer: [4096]u8 = undefined;

const Cmd = enum {
    @"-h",
    @"--help",
    @"--version",
    plan,
    version,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);

    if (args.len <= 1) {
        try printIncorrectUsage(io, "expected arguments", .{});
    }

    const cmd = args[1];
    switch (std.meta.stringToEnum(Cmd, cmd) orelse printIncorrectUsage(
        io,
        "unknown argument: {s}",
        .{cmd},
    )) {
        .@"-h", .@"--help" => return printHelp(io, usage),
        .@"--version", .version => return printVersion(io),
        .plan => {},
    }
    return std.process.cleanExit(io);
}

fn printIncorrectUsage(io: Io, comptime fmt: []const u8, args: anytype) noreturn {
    var stderr_writer = Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    stderr.writeAll(usage) catch {};
    stderr.flush() catch {};
    std.process.fatal(fmt, args);
}

fn printHelp(io: Io, msg: []const u8) !void {
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.writeAll(msg);
    try stdout.flush();
    return std.process.cleanExit(io);
}

fn printVersion(io: Io) !void {
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    // TODO: Get the version from the build process.
    try stdout.print("0.0.0\n", .{});
    try stdout.flush();
    return std.process.cleanExit(io);
}

// vim: set colorcolumn=86,100:
