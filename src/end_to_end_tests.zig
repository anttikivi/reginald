// SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
//
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const testing = std.testing;

const TmpReginald = @import("TmpReginald.zig");

test "no arguments" {
    var tmp_reginald = try TmpReginald.init(testing.allocator, testing.io);
    defer tmp_reginald.deinit(testing.allocator);

    var result = try tmp_reginald.run(testing.allocator, testing.io, &.{});
    defer result.deinit(testing.allocator);

    try tmp_reginald.runExpectStderrStartsWith(
        testing.allocator,
        testing.io,
        &.{},
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
    ,
        1,
    );
}
