// SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
//
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const testing = std.testing;

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

var stdout_buffer: [4096]u8 = undefined;

const Cmd = enum {
    @"-h",
    @"--help",
    @"--version",
    plan,
    version,
};

const GlobalOptions = struct {
    log_level: ?std.log.Level = null,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var args = try init.minimal.args.toSlice(arena);

    if (args.len <= 1) {
        try printIncorrectUsage(io, "expected arguments", .{});
    }

    var global_opts: GlobalOptions = .{};
    var cmd: Cmd = undefined;

    args = args[1..];
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        const arg_cmd = std.meta.stringToEnum(Cmd, arg) orelse {
            if (std.mem.startsWith(u8, arg, "--log-level")) {
                const val = parseLongOptionValue(args[i..], "--log-level") catch
                    printIncorrectUsage(io, "option \"--log-level\" requires a value", .{});

                global_opts.log_level = std.meta.stringToEnum(std.log.Level, val) orelse {
                    printIncorrectUsage(io, "invalid log level: {s}", .{val});
                };

                if (arg.len == "--log-level".len) {
                    i += 1;
                }
            } else {
                printIncorrectUsage(io, "unknown argument: {s}", .{arg});
            }

            continue;
        };

        cmd = arg_cmd;
        break;
    }

    switch (cmd) {
        .@"-h", .@"--help" => return printHelp(io, usage),
        .@"--version", .version => return printVersion(io),
        .plan => return cmdPlan(io, args[i..]),
    }
}

/// Parse the value of a long command-line option that requires a value. The args slice should start
/// with the option currently being parsed. The function assumes that the current argument matches
/// the option.
fn parseLongOptionValue(args: []const []const u8, option: []const u8) error{NoValue}![]const u8 {
    assert(args.len > 0);
    assert(option.len > 0);
    assert(std.mem.startsWith(u8, args[0], option));

    const arg = args[0];

    if (arg.len == option.len) {
        if (args.len <= 1) {
            return error.NoValue;
        }

        return args[1];
    }

    assert(arg.len > option.len);

    if (arg[option.len] != '=') {
        return error.NoValue;
    }

    return arg[option.len + 1 ..];
}

fn printIncorrectUsage(io: Io, comptime fmt: []const u8, args: anytype) noreturn {
    Io.File.stderr().writeStreamingAll(io, usage) catch {};
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

fn cmdPlan(io: Io, args: []const []const u8) !void {
    _ = args;

    return std.process.cleanExit(io);
}

test parseLongOptionValue {
    {
        const args = &.{ "--log-level", "info" };
        const result = try parseLongOptionValue(args, "--log-level");
        try testing.expectEqualStrings("info", result);
    }
    {
        const args = &.{"--log-level=info"};
        const result = try parseLongOptionValue(args, "--log-level");
        try testing.expectEqualStrings("info", result);
    }
    {
        const args = &.{"--log-level="};
        const result = try parseLongOptionValue(args, "--log-level");
        try testing.expectEqualStrings("", result);
    }
    {
        const args = &.{"--log-level"};
        const result = parseLongOptionValue(args, "--log-level");
        try testing.expectError(error.NoValue, result);
    }
}

// vim: set colorcolumn=86,100:
