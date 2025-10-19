const std = @import("std");
const Shell = @import("Shell.zig");
const TmpReginald = @import("TmpReginald.zig");

test "unconfigured run" {
    var shell = try Shell.create(std.testing.allocator);
    defer shell.destroy();

    var tmp_reginald = try TmpReginald.init(std.testing.allocator, shell, .{ .flat = true });
    defer tmp_reginald.deinit(std.testing.allocator);

    const stderr = try shell.testFailingExecStderr(
        "{reginald}",
        .{ .reginald = tmp_reginald.reginald_exe },
    );

    try std.testing.expectStringStartsWith(stderr, "could not find a config file");
}

test "empty stdin config" {
    var shell = try Shell.create(std.testing.allocator);
    defer shell.destroy();

    var tmp_reginald = try TmpReginald.init(std.testing.allocator, shell, .{ .flat = true });
    defer tmp_reginald.deinit(std.testing.allocator);

    _, _ = try shell.execStdoutStderrOptions(
        .{
            .stdin_slice =
            \\plugin-paths = []
            ,
        },
        "{reginald} --config -",
        .{ .reginald = tmp_reginald.reginald_exe },
    );
}
