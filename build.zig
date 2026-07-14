// SPDX-FileCopyrightText: © 2026 Antti Kivi <antti@anttikivi.com>
//
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const Io = std.Io;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const build_options = b.addOptions();

    const docs_step = b.step("docs", "Build and install documentation");

    const docs_reginald_step = b.step(
        "docs-reginald",
        "Build and install documentation for the main application",
    );
    const docs_reginald = b.addObject(.{
        .name = "reginald",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });
    docs_reginald.root_module.addOptions("build_options", build_options);
    const install_docs_reginald = b.addInstallDirectory(.{
        .source_dir = docs_reginald.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "share/doc/reginald",
    });
    b.getInstallStep().dependOn(&install_docs_reginald.step);
    docs_reginald_step.dependOn(&install_docs_reginald.step);
    docs_step.dependOn(docs_reginald_step);

    const exe = b.addExecutable(.{
        .name = "reginald",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    exe.root_module.addOptions("build_options", build_options);

    const run_exe = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run Reginald");
    run_step.dependOn(&run_exe.step);

    const fmt_include_paths = &.{ "src", "build.zig" };

    const fmt_step = b.step("fmt", "Modify source files in place to have conforming formatting");
    const do_fmt = b.addFmt(.{ .paths = fmt_include_paths });
    fmt_step.dependOn(&do_fmt.step);

    const fmt_reuse_step = b.step(
        "fmt-reuse",
        "Annotate the source files with license information",
    );

    const uvx_program = b.findProgram(&.{"uvx"}, &.{});
    if (uvx_program) |uvx| {
        const uvx_reuse = b.addSystemCommand(&.{
            uvx,
            "--from=reuse[charset-normalizer]",
            "reuse",
            "annotate",
            "--copyright=Antti Kivi <antti@anttikivi.com>",
            "--license=GPL-3.0-or-later",
            "--copyright-prefix=spdx-symbol",
        });

        const io = b.graph.io;
        const cwd: Io.Dir = .cwd();

        const build_root = b.build_root.path.?;
        var dir = cwd.openDir(io, build_root, .{ .iterate = true }) catch |err| std.debug.panic(
            "unable to open directory {s}: {t}",
            .{ build_root, err },
        );
        defer dir.close(io);

        var walker = dir.walk(b.allocator) catch @panic("OOM");
        defer walker.deinit();

        while (walker.next(io) catch |err| std.debug.panic(
            "failed to walk directory {s}: {t}",
            .{ build_root, err },
        )) |entry| {
            if (entry.kind != .file) {
                continue;
            }

            if (std.mem.find(u8, entry.path, ".git") != null) {
                continue;
            }

            if (std.mem.find(u8, entry.path, ".zig-cache") != null) {
                continue;
            }

            if (std.mem.find(u8, entry.path, "zig-out") != null) {
                continue;
            }

            if (!std.mem.endsWith(u8, entry.path, ".zig")) {
                continue;
            }

            uvx_reuse.addFileArg(b.path(entry.path));
        }

        uvx_reuse.setCwd(b.path("."));
        uvx_reuse.stdio = .inherit;
        fmt_reuse_step.dependOn(&uvx_reuse.step);
    } else |err| switch (err) {
        error.FileNotFound => std.debug.print(
            "not running \"uvx reuse annotate\", uvx not found\n",
            .{},
        ),
    }

    const test_step = b.step("test", "Run all the tests");
    test_step.dependOn(&exe.step);

    const test_unit_step = b.step("test-unit", "Run the unit tests");
    const test_unit = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_unit_step.dependOn(&b.addRunArtifact(test_unit).step);
    test_step.dependOn(test_unit_step);

    const test_e2e_step = b.step("test-e2e", "Run the end-to-end tests");
    const test_e2e = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/end_to_end_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    test_e2e.root_module.addOptions("build_options", build_options);
    build_options.addOption([:0]const u8, "zig_exe", b.graph.zig_exe);

    test_e2e_step.dependOn(&b.addRunArtifact(test_e2e).step);
    test_step.dependOn(test_e2e_step);

    const test_fmt_step = b.step(
        "test-fmt",
        "Check whether the source files have conforming formatting",
    );
    const check_fmt = b.addFmt(.{
        .paths = fmt_include_paths,
        .check = true,
    });
    test_fmt_step.dependOn(&check_fmt.step);
    test_step.dependOn(test_fmt_step);

    const test_reuse_step = b.step("test-reuse", "Check the project for REUSE compliance");

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
