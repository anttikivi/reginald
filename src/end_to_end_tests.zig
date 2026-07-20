// SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
//
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const testing = std.testing;

const TmpReginald = @import("TmpReginald.zig");

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

test "no arguments" {
    var tmp_reginald = try TmpReginald.init(testing.allocator, testing.io);
    defer tmp_reginald.deinit(testing.allocator);

    try tmp_reginald.runExpectStderrStartsWith(
        testing.allocator,
        testing.io,
        &.{},
        usage,
        1,
    );
}

test "--help" {
    var tmp_reginald = try TmpReginald.init(testing.allocator, testing.io);
    defer tmp_reginald.deinit(testing.allocator);

    try tmp_reginald.runExpectStdoutEquals(
        testing.allocator,
        testing.io,
        &.{"--help"},
        usage,
        0,
    );
}

test "-h" {
    var tmp_reginald = try TmpReginald.init(testing.allocator, testing.io);
    defer tmp_reginald.deinit(testing.allocator);

    try tmp_reginald.runExpectStdoutEquals(
        testing.allocator,
        testing.io,
        &.{"-h"},
        usage,
        0,
    );
}

test "--version" {
    var tmp_reginald = try TmpReginald.init(testing.allocator, testing.io);
    defer tmp_reginald.deinit(testing.allocator);

    try tmp_reginald.runExpectStdoutEquals(
        testing.allocator,
        testing.io,
        &.{"--version"},
        "0.0.0\n",
        0,
    );
}

test "version" {
    var tmp_reginald = try TmpReginald.init(testing.allocator, testing.io);
    defer tmp_reginald.deinit(testing.allocator);

    try tmp_reginald.runExpectStdoutEquals(
        testing.allocator,
        testing.io,
        &.{"version"},
        "0.0.0\n",
        0,
    );
}

test "--log-level=info version" {
    var tmp_reginald = try TmpReginald.init(testing.allocator, testing.io);
    defer tmp_reginald.deinit(testing.allocator);

    try tmp_reginald.runExpectStdoutEquals(
        testing.allocator,
        testing.io,
        &.{ "--log-level=info", "version" },
        "0.0.0\n",
        0,
    );
}

test "--log-level info --version" {
    var tmp_reginald = try TmpReginald.init(testing.allocator, testing.io);
    defer tmp_reginald.deinit(testing.allocator);

    try tmp_reginald.runExpectStdoutEquals(
        testing.allocator,
        testing.io,
        &.{ "--log-level", "info", "--version" },
        "0.0.0\n",
        0,
    );
}

test "unknown subcommand" {
    var tmp_reginald = try TmpReginald.init(testing.allocator, testing.io);
    defer tmp_reginald.deinit(testing.allocator);

    try tmp_reginald.runExpectStderrContains(
        testing.allocator,
        testing.io,
        &.{"foo"},
        "unknown argument: foo",
        1,
    );
}

test "unknown global option" {
    var tmp_reginald = try TmpReginald.init(testing.allocator, testing.io);
    defer tmp_reginald.deinit(testing.allocator);

    try tmp_reginald.runExpectStderrContains(
        testing.allocator,
        testing.io,
        &.{"--foo"},
        "unknown argument: --foo",
        1,
    );
}

test "--log-level without a value" {
    var tmp_reginald = try TmpReginald.init(testing.allocator, testing.io);
    defer tmp_reginald.deinit(testing.allocator);

    try tmp_reginald.runExpectStderrContains(
        testing.allocator,
        testing.io,
        &.{"--log-level"},
        "option \"--log-level\" requires a value",
        1,
    );
}

test "--log-level with an invalid value" {
    var tmp_reginald = try TmpReginald.init(testing.allocator, testing.io);
    defer tmp_reginald.deinit(testing.allocator);

    try tmp_reginald.runExpectStderrContains(
        testing.allocator,
        testing.io,
        &.{"--log-level=bad"},
        "invalid log level: bad",
        1,
    );
}

test "plan with an unknown option" {
    var tmp_reginald = try TmpReginald.init(testing.allocator, testing.io);
    defer tmp_reginald.deinit(testing.allocator);

    try tmp_reginald.runExpectStderrContains(
        testing.allocator,
        testing.io,
        &.{ "plan", "--foo" },
        "unknown argument: --foo",
        1,
    );
}

test "plan --config without a value" {
    var tmp_reginald = try TmpReginald.init(testing.allocator, testing.io);
    defer tmp_reginald.deinit(testing.allocator);

    try tmp_reginald.runExpectStderrContains(
        testing.allocator,
        testing.io,
        &.{ "plan", "--config" },
        "option \"--config\" requires a value",
        1,
    );
}

test "plan --jobs without a value" {
    var tmp_reginald = try TmpReginald.init(testing.allocator, testing.io);
    defer tmp_reginald.deinit(testing.allocator);

    try tmp_reginald.runExpectStderrContains(
        testing.allocator,
        testing.io,
        &.{ "plan", "--jobs" },
        "option \"--jobs\" requires a value",
        1,
    );
}

test "--log-level specified twice" {
    var tmp_reginald = try TmpReginald.init(testing.allocator, testing.io);
    defer tmp_reginald.deinit(testing.allocator);

    try tmp_reginald.runExpectStderrContains(
        testing.allocator,
        testing.io,
        &.{ "--log-level=info", "--log-level=warn", "version" },
        "option \"--log-level\" can only be specified once",
        1,
    );
}

test "plan --config with a nonexistent file" {
    var tmp_reginald = try TmpReginald.init(testing.allocator, testing.io);
    defer tmp_reginald.deinit(testing.allocator);

    try tmp_reginald.runExpectStderrContains(
        testing.allocator,
        testing.io,
        &.{ "plan", "--config", "nonexistent.json" },
        "failed to open config file \"nonexistent.json\"",
        1,
    );
}

test "plan --config specified twice" {
    var tmp_reginald = try TmpReginald.init(testing.allocator, testing.io);
    defer tmp_reginald.deinit(testing.allocator);

    try tmp_reginald.runExpectStderrContains(
        testing.allocator,
        testing.io,
        &.{ "plan", "--config", "a", "--config", "b" },
        "option \"--config\" can only be specified once",
        1,
    );
}

test "plan --jobs with a non-numeric value" {
    var tmp_reginald = try TmpReginald.init(testing.allocator, testing.io);
    defer tmp_reginald.deinit(testing.allocator);

    try tmp_reginald.runExpectStderrContains(
        testing.allocator,
        testing.io,
        &.{ "plan", "--jobs=abc" },
        "failed to parse value of option \"--jobs\"",
        1,
    );
}

test "plan --jobs with an overflowing value" {
    var tmp_reginald = try TmpReginald.init(testing.allocator, testing.io);
    defer tmp_reginald.deinit(testing.allocator);

    try tmp_reginald.runExpectStderrContains(
        testing.allocator,
        testing.io,
        &.{ "plan", "--jobs=99999" },
        "value for \"--jobs\" does not fit",
        1,
    );
}

test "plan --config with a valid file" {
    var tmp_reginald = try TmpReginald.init(testing.allocator, testing.io);
    defer tmp_reginald.deinit(testing.allocator);

    try tmp_reginald.tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "reginald.json",
        .data = "{}",
    });

    try tmp_reginald.runExpectStdoutEquals(
        testing.allocator,
        testing.io,
        &.{ "plan", "--config", "reginald.json" },
        "",
        0,
    );
}
