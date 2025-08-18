const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const cli = @import("cli.zig");
const Config = @import("Config.zig");
const CountingAllocator = @import("CountingAllocator.zig");
const filepath = @import("filepath.zig");
const StaticAllocator = @import("StaticAllocator.zig");
const toml = @import("toml.zig");

const native_os = builtin.target.os.tag;
var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub const std_options: std.Options = .{
    .log_level = .debug,
};

pub fn main() !void {
    comptime {
        Config.checkInfo();
    }

    var gpa, const is_debug = gpa: {
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

    var total_counter: ?CountingAllocator = null;
    if (is_debug) {
        total_counter = CountingAllocator.init(gpa);
        gpa = total_counter.?.allocator();
    }
    defer if (is_debug) {
        std.debug.print("Currently allocated: {d}\n", .{total_counter.?.liveSize()});
        std.debug.print("Total allocated: {d}\n", .{total_counter.?.alloc_size});
        total_counter.?.deinit();
    };

    const args = try std.process.argsAlloc(gpa);
    const args_freed = false;
    defer if (!args_freed) {
        std.process.argsFree(gpa, args);
    };

    assert(args.len > 0);

    const stderr_writer = std.io.getStdErr().writer();
    var parsed_args = try cli.parseArgsLaxly(gpa, args[1..], stderr_writer);
    var parsed_args_freed = false;
    defer if (!parsed_args_freed) {
        parsed_args.deinit();
    };

    var stdout_buffer = std.io.bufferedWriter(std.io.getStdOut().writer());
    const stdout_writer = stdout_buffer.writer();

    // If there are no unknown arguments and help or version was invoked, we can
    // short-circuit into printing them and skip parsing the config and plugins.
    if (parsed_args.args.len == 0) {
        if (parsed_args.values.get("print_help")) |h| {
            switch (h) {
                .bool => {
                    try stdout_writer.writeAll("help message!\n");
                    try stdout_buffer.flush();
                    return;
                },
                else => unreachable,
            }
        } else if (parsed_args.values.get("print_version")) |v| {
            switch (v) {
                .bool => {
                    try stdout_writer.writeAll(build_options.exe_name ++ " " ++ build_options.version ++ "\n");
                    try stdout_writer.writeAll("Licensed under the Apache License, Version 2.0: <https://www.apache.org/licenses/LICENSE-2.0>\n");
                    try stdout_buffer.flush();
                    return;
                },
                else => unreachable,
            }
        }
    }

    var config_counter: ?CountingAllocator = null;
    if (is_debug) {
        config_counter = CountingAllocator.init(gpa);
    }
    defer if (is_debug) {
        std.debug.print("Currently allocated in config: {d}\n", .{config_counter.?.liveSize()});
        std.debug.print("Total allocated in config: {d}\n", .{config_counter.?.alloc_size});
        config_counter.?.deinit();
    };
    var config_allocator_instance: ?StaticAllocator = null;
    if (is_debug) {
        config_allocator_instance = StaticAllocator.init(config_counter.?.allocator());
    }
    defer if (is_debug) {
        config_allocator_instance.?.deinit();
    };
    const config_allocator = if (is_debug) config_allocator_instance.?.allocator() else gpa;

    var cfg = try Config.init(config_allocator, gpa, parsed_args);
    defer cfg.deinit();

    std.debug.print("wd: {s}\n", .{cfg.working_directory});
    std.debug.print("config: {s}\n", .{cfg.config_file});

    parsed_args.deinit();
    parsed_args_freed = true;
}

// if (args.len <= 1) {
//     var bw = std.io.bufferedWriter(std.io.getStdOut().writer());
//     const w = bw.writer();
//     try w.writeAll("usage!\n");
//     try bw.flush();
//     return;
// }

// const cfg_file = Config.loadFile(gpa, parsed_args, wd) catch |err| {
//     switch (err) {
//         error.FileNotFound, error.IsDir => {
//             try std.io.getStdErr().writer().print("config file not found\n", .{});
//
//             return err;
//         },
//         else => return err,
//     }
// };
// defer gpa.free(cfg_file);
//
// var diag: toml.Diagnostics = undefined;
// var toml_value = toml.parseWithDiagnostics(gpa, cfg_file, &diag) catch |e| {
//     try errw.print("{}\n", .{diag});
//     return e;
// };
// defer toml_value.deinit(gpa);

test {
    std.testing.refAllDecls(@This());
}
