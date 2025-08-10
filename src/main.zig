const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const cli = @import("cli.zig");
const Config = @import("Config.zig");
const filepath = @import("filepath.zig");
const toml = @import("toml.zig");

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
    // if (args.len <= 1) {
    //     var bw = std.io.bufferedWriter(std.io.getStdOut().writer());
    //     const w = bw.writer();
    //     try w.writeAll("usage!\n");
    //     try bw.flush();
    //     return;
    // }

    _ = arena;

    const errw = std.io.getStdErr().writer();
    var parsed_args = try cli.parseArgsLaxly(gpa, args[1..], errw);
    defer parsed_args.deinit();

    const wd = try workingDirPath(gpa, parsed_args);
    defer if (wd) |s| {
        gpa.free(s);
    };

    const cfg_file = Config.loadFile(gpa, parsed_args, wd) catch |err| {
        switch (err) {
            error.FileNotFound, error.IsDir => {
                try std.io.getStdErr().writer().print("config file not found\n", .{});

                return err;
            },
            else => return err,
        }
    };
    defer gpa.free(cfg_file);

    var diag: toml.Diagnostics = undefined;
    var toml_value = toml.parseWithDiagnostics(gpa, cfg_file, &diag) catch |e| {
        try errw.print("{}\n", .{diag});
        return e;
    };
    defer toml_value.deinit(gpa);
}

/// Resolve the working directory of the current run. Caller owns the return
/// value and should call `free` on it if it is not null. A null return value
/// means that the current working directory should be used.
fn workingDirPath(allocator: Allocator, parsed_args: cli.Parsed) !?[]const u8 {
    if (parsed_args.values.get("working_directory")) |wd| {
        switch (wd) {
            .string => |s| return try filepath.expand(allocator, s),
            else => unreachable,
        }
    }

    if (std.process.getEnvVarOwned(allocator, build_options.env_prefix ++ "DIRECTORY")) |s| {
        defer allocator.free(s);
        return try filepath.expand(allocator, s);
    } else |err| {
        switch (err) {
            error.EnvironmentVariableNotFound => {}, // no-op
            else => return err,
        }
    }

    return null;
}

test {
    std.testing.refAllDecls(@This());
}
