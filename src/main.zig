// SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
//
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    std.debug.print("Hello, World!\n", .{});

    return std.process.cleanExit(io);
}
