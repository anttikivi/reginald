const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const cli = @import("cli.zig");
const Config = @import("Config.zig");

const native_os = builtin.target.os.tag;
var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub fn main() !void {
    // TODO: It could be ok to remove these safety checks.
    comptime {
        if (std.meta.fields(Config).len != Config.metadata.len) {
            @compileError("length of the config metadata does not match the config");
        }

        for (std.meta.fields(Config)) |field| {
            var found = false;
            for (Config.metadata) |m| {
                if (std.mem.eql(u8, field.name, m.name)) {
                    found = true;
                }
            }
            if (!found) {
                @compileError("config field " ++ field.name ++ " not present in metadata");
            }
        }

        for (Config.metadata) |m| {
            if (!@hasField(Config, m.name)) {
                @compileError("metadata name " ++ m.name ++ " not present in config");
            }
        }
    }

    const gpa, const is_debug = gpa: {
        if (native_os == .wasi) break :gpa .{ std.heap.wasm_allocator, false };
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };
    var arena_instance = std.heap.ArenaAllocator.init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const args = try std.process.argsAlloc(arena);
    assert(args.len > 0);

    return mainArgs(gpa, arena, args);
}

fn mainArgs(gpa: Allocator, arena: Allocator, args: []const []const u8) !void {
    if (args.len <= 1) {
        var bw = std.io.bufferedWriter(std.io.getStdOut().writer());
        const w = bw.writer();
        try w.writeAll("usage!\n");
        try bw.flush();
        return;
    }

    _ = arena;

    var bw = std.io.bufferedWriter(std.io.getStdErr().writer());
    const w = bw.writer();
    try cli.parseArgsLaxly(gpa, args, w);
    try bw.flush();
}

test {
    std.testing.refAllDecls(@This());
}
