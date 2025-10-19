const std = @import("std");
const Shell = @import("Shell.zig");
const TmpReginald = @import("TmpReginald.zig");

test "unconfigured run" {
    var shell = try Shell.create(std.testing.allocator);
    defer shell.destroy();

    var tmp_reginald = try TmpReginald.init(std.testing.allocator, shell, .{ .flat = true });
    defer tmp_reginald.deinit(std.testing.allocator);

    _, _ = try shell.execStdoutStderr("{reginald}", .{ .reginald = tmp_reginald.reginald_exe });
}
