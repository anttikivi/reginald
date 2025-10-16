const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Args = @import("Args.zig");
const Config = @import("Config.zig");
const Plugin = @import("Plugin.zig");
const output = @import("output.zig");

const native_os = builtin.target.os.tag;
var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

var stdout_buffer: [4096]u8 = undefined;

/// The runtime log level. It is set according to the config options.
///
/// NOTE: This is a global, which is not good, but there is no need to introduce
/// excessive complexity to get rid of this.
pub var log_level: std.log.Level = Config.Specs.@"logging.level".default.?.log_level;

/// Custom logging function for Reginald. Instead of restricting the logging
/// level during compile time, the function checks the runtime logging level
/// that is set according to the user's config.
///
/// TODO: Right now, the logging uses the same logic as the default logging
/// function of the standard library but only if the level that is used is
/// enabled. We will implement proper log formatting later.
pub fn runtimeLog(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(message_level) > @intFromEnum(log_level)) {
        return;
    }

    const level_txt = comptime message_level.asText();
    const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
    var buffer: [64]u8 = undefined;
    const stderr = std.debug.lockStderrWriter(&buffer);
    defer std.debug.unlockStderrWriter();
    nosuspend stderr.print(level_txt ++ prefix2 ++ format ++ "\n", args) catch return;
}

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = runtimeLog,
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

    output.init();

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
                    try stdout.writeAll(build_options.name ++ " " ++ build_options.version ++ "\n");
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

    output.configure(&cfg);

    var working_dir = try std.fs.cwd().openDir(cfg.get([]const u8, "working_directory").?, .{});
    defer working_dir.close();

    var dir = try working_dir.openDir(cfg.get([]const u8, "directory").?, .{});
    defer dir.close();

    log_level = cfg.get(std.log.Level, "logging.level").?;

    std.log.debug("logging initialized", .{});
    std.log.info("running Reginald version {s}", .{build_options.version});
    std.log.debug("using directory \"{?s}\"", .{cfg.get([]const u8, "directory")});
    std.log.debug("using config file \"{?s}\"", .{cfg.get([]const u8, "config_file")});

    const manifests = try Plugin.Manifest.loadAll(gpa, &cfg, dir);
    defer gpa.free(manifests);
    defer for (manifests) |*m| {
        m.deinit(gpa);
    };

    var plugin_host = try Plugin.Host.init(gpa, manifests);
    defer plugin_host.deinit(gpa);
}

test {
    std.testing.refAllDecls(@This());
}
