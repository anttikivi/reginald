const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Args = @import("Args.zig");
const Config = @import("Config.zig");

const native_os = builtin.target.os.tag;
var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

var stdout_buffer: [4096]u8 = undefined;

pub const std_options: std.Options = .{
    .log_level = .debug,
};

pub fn main() !void {
    const gpa, const is_debug = gpa: {
        if (native_os == .wasi) {
            break :gpa .{ std.heap.wasm_allocator, false };
        }

        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    const raw_args = try std.process.argsAlloc(gpa);
    const raw_args_freed = false;
    defer if (!raw_args_freed) {
        std.process.argsFree(gpa, raw_args);
    };

    assert(raw_args.len > 0);

    var specs: Config.Specs = undefined;
    try specs.init(gpa);
    defer specs.deinit();

    var parsed_args: Args = undefined;
    try parsed_args.parseLaxly(gpa, raw_args[1..], &specs);
    defer parsed_args.deinit();

    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    // If there are no unknown arguments and help or version was invoked, we can
    // short-circuit into printing them and skip parsing the config and plugins.
    if (parsed_args.args.len == 0) {
        if (parsed_args.values.get("print_help")) |h| {
            switch (h) {
                .bool => {
                    try stdout.writeAll("help message!\n");
                    try stdout.flush();
                    return;
                },
                else => unreachable,
            }
        } else if (parsed_args.values.get("print_version")) |v| {
            switch (v) {
                .bool => {
                    try stdout.writeAll(build_options.exe_name ++ " " ++ build_options.version ++ "\n");
                    try stdout.writeAll("Licensed under the Apache License, Version 2.0: <https://www.apache.org/licenses/LICENSE-2.0>\n");
                    try stdout.flush();
                    return;
                },
                else => unreachable,
            }
        }
    }

    var cfg: Config = undefined;
    try cfg.init(gpa, &specs, &parsed_args);
    defer cfg.deinit();

    // TODO: Add the logging level to some kind of runtime logging function.
}

// if (args.len <= 1) {
//     var bw = std.io.bufferedWriter(std.io.getStdOut().writer());
//     const w = bw.writer();
//     try w.writeAll("usage!\n");
//     try bw.flush();
//     return;
// }

test {
    std.testing.refAllDecls(@This());
}
