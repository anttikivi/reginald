const std = @import("std");

pub fn build(b: *std.Build) void {
    const test_reuse_step = b.step("test-reuse", "Check the project for REUSE compliance");

    const uvx_program = b.findProgram(&.{"uvx"}, &.{});
    if (uvx_program) |uvx| {
        const uvx_reuse = b.addSystemCommand(&.{
            uvx,
            "--from=reuse[charset-normalizer]",
            "reuse",
            "lint",
        });
        uvx_reuse.setCwd(b.path("."));
        uvx_reuse.stdio = .inherit;
        test_reuse_step.dependOn(&uvx_reuse.step);
    } else |err| switch (err) {
        error.FileNotFound => std.debug.print(
            "not running \"uvx reuse lint\", uvx not found\n",
            .{},
        ),
    }
}
