const build_options = @import("build_options");
const builtin = @import("builtin");
const std = @import("std");

const Shell = @import("Shell.zig");
const TmpReginald = @import("TmpReginald.zig");

const native_os = builtin.target.os.tag;

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

test "plugins no runtime field" {
    var shell = try Shell.create(std.testing.allocator);
    defer shell.destroy();

    var tmp_reginald = try TmpReginald.init(std.testing.allocator, shell, .{ .flat = true });
    defer tmp_reginald.deinit(std.testing.allocator);

    const plugin_path = if (native_os == .windows) blk: {
        break :blk build_options.plugin_dir_escaped ++ "\\\\no_runtime";
    } else blk: {
        break :blk build_options.plugin_dir_escaped ++ std.fs.path.sep_str ++ "no_runtime";
    };

    const config = try std.fmt.allocPrint(std.testing.allocator,
        \\plugin-paths = ["{s}"]
    , .{plugin_path});
    defer std.testing.allocator.free(config);

    const stderr = try shell.testFailingExecStderrOptions(
        .{ .stdin_slice = config },
        "{reginald} --config - --log=false",
        .{ .reginald = tmp_reginald.reginald_exe },
    );

    try std.testing.expectStringStartsWith(stderr, "type for plugin \"reginald-python\" is set to \"runtime\" but no runtime name was provided in the manifest file");
}
