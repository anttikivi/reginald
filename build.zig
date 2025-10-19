// This file is derived from TigerBeetle
// (https://github.com/tigerbeetle/tigerbeetle), licensed under the Apache
// License, Version 2.0. It is modified by Antti Kivi. See THIRD_PARTY_NOTICES
// for more information.

const std = @import("std");
const ArrayList = std.ArrayList;

const reginald_name = "reginald";
const reginald_version: std.SemanticVersion = .{ .major = 0, .minor = 1, .patch = 0 };
const default_env_prefix = "REGINALD_";

const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    install_prefix: []const u8,
    name: []const u8,
    version: []const u8,
    flat: bool,
    env_prefix: []const u8,
    log_level: []const u8,

    fn buildOptions(self: Options, b: *std.Build) *std.Build.Step.Options {
        const options = b.addOptions();
        options.addOption([]const u8, "name", self.name);
        options.addOption([]const u8, "version", self.version);
        options.addOption([]const u8, "env_prefix", self.env_prefix);
        options.addOption([]const u8, "log_level", self.log_level);
        return options;
    }

    fn testOptions(self: Options, b: *std.Build) *std.Build.Step.Options {
        const options = b.addOptions();
        options.addOption([]const u8, "install_prefix", self.install_prefix);
        options.addOption(bool, "flat", self.flat);
        return options;
    }
};

const TestPlugin = struct {
    name: []const u8,
    path: []const u8,
    language: enum { zig },
};

pub fn build(b: *std.Build) !void {
    const build_steps = .{
        .check = b.step("check", "Check if Reginald compiles"),
        .ci = b.step("ci", "Run the CI test suite"),
        .install = b.getInstallStep(),
        .run = b.step("run", "Run Reginald"),
        .@"test" = b.step("test", "Run tests"),
        .test_end_to_end = b.step("test-e2e", "Run the end-to-end tests"),
        .test_fmt = b.step("test-fmt", "Check formatting"),
        .test_plugins = b.step("test-plugins", "Build the test plugins"),
        .test_toml = b.step("test-toml", "Run the `toml-test` test suite"),
        .test_unit = b.step("test-unit", "Run unit tests"),
    };

    const options: Options = .{
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
        .install_prefix = b.install_prefix,
        .name = b.option(
            []const u8,
            "name",
            b.fmt("Name of the program. Default is \"{s}\"", .{reginald_name}),
        ) orelse reginald_name,
        .version = b.option(
            []const u8,
            "version",
            "Use this as the version string of Reginald",
        ) orelse resolveVersion(b) catch {
            std.debug.print("error: resolving version failed\n", .{});
            std.process.exit(1);
        },
        .flat = b.option(
            bool,
            "flat",
            "Put files into the installation prefix in a manner suited for upstream distribution rather than a posix file system hierarchy standard",
        ) orelse false,
        .env_prefix = b.option(
            []const u8,
            "env-prefix",
            b.fmt(
                "Use this as the prefix for environment variables used by Reginald. Default is \"{s}\"",
                .{default_env_prefix},
            ),
        ) orelse default_env_prefix,
        .log_level = logLevelOption(b),
    };

    buildCheck(b, build_steps.check, options);

    buildReginald(b, .{
        .install = build_steps.install,
        .run = build_steps.run,
    }, options);

    buildTest(b, .{
        .@"test" = build_steps.@"test",
        .test_end_to_end = build_steps.test_end_to_end,
        .test_fmt = build_steps.test_fmt,
        .test_toml = build_steps.test_toml,
        .test_unit = build_steps.test_unit,
    }, options);

    buildTestPlugins(b, build_steps.test_plugins, options);

    buildCi(b, build_steps.ci);
}

fn buildCi(b: *std.Build, step: *std.Build.Step) void {
    const CiMode = enum { all, check, default, @"test" };

    const mode: CiMode = if (b.args) |args| mode: {
        if (args.len != 1) {
            step.dependOn(&b.addFail("invalid CI mode").step);
            return;
        }

        if (std.meta.stringToEnum(CiMode, args[0])) |m| {
            break :mode m;
        } else {
            step.dependOn(&b.addFail("invalid CI mode").step);
            return;
        }
    } else .default;

    const all = mode == .all;
    const default = all or mode == .default;

    if (default or mode == .check) {
        buildCiStep(b, step, .{"test-fmt"});
        buildCiStep(b, step, .{"check"});
    }

    if (default or mode == .@"test") {
        buildCiStep(b, step, .{"test"});
    }
}

fn buildCiStep(b: *std.Build, step: *std.Build.Step, command: anytype) void {
    const argv = .{ b.graph.zig_exe, "build" } ++ command;
    const system_command = b.addSystemCommand(&argv);
    const name = std.mem.join(b.allocator, " ", &command) catch @panic("OOM");
    system_command.setName(name);
    step.dependOn(&system_command.step);
}

/// Build Reginald without codegen.
fn buildCheck(b: *std.Build, step: *std.Build.Step, options: Options) void {
    const reginald = b.addExecutable(.{
        .name = options.name,
        .root_module = createReginaldModule(b, options),
    });
    step.dependOn(&reginald.step);
}

fn buildReginald(
    b: *std.Build,
    steps: struct {
        run: *std.Build.Step,
        install: *std.Build.Step,
    },
    options: Options,
) void {
    const reginald = b.addExecutable(.{
        .name = options.name,
        .root_module = createReginaldModule(b, options),
    });

    const install_reginald = b.addInstallArtifact(
        reginald,
        .{ .dest_dir = if (options.flat) .{ .override = .prefix } else .default },
    );
    steps.install.dependOn(&install_reginald.step);

    const run_cmd = std.Build.Step.Run.create(b, b.fmt("run exe {s}", .{options.name}));
    run_cmd.addFileArg(reginald.getEmittedBin());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    steps.run.dependOn(&run_cmd.step);
}

fn buildTest(b: *std.Build, steps: struct {
    @"test": *std.Build.Step,
    test_end_to_end: *std.Build.Step,
    test_fmt: *std.Build.Step,
    test_toml: *std.Build.Step,
    test_unit: *std.Build.Step,
}, options: Options) void {
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = options.target,
            .optimize = options.optimize,
        }),
    });
    unit_tests.root_module.addOptions("build_options", options.buildOptions(b));
    unit_tests.root_module.addOptions("test_options", options.testOptions(b));

    if (options.target.result.os.tag != .windows) {
        unit_tests.linkLibC();
    }

    const run_unit_tests = b.addRunArtifact(unit_tests);
    steps.test_unit.dependOn(&run_unit_tests.step);

    buildTestEndToEnd(b, steps.test_end_to_end, options);
    buildTestToml(b, .{ .test_toml = steps.test_toml }, options);

    const run_fmt = b.addFmt(.{ .paths = &.{"."}, .check = true });
    steps.test_fmt.dependOn(&run_fmt.step);

    steps.@"test".dependOn(steps.test_unit);

    if (b.args == null) {
        steps.@"test".dependOn(steps.test_end_to_end);
        steps.@"test".dependOn(steps.test_fmt);
        steps.@"test".dependOn(steps.test_toml);
    }
}

fn buildTestEndToEnd(b: *std.Build, step: *std.Build.Step, options: Options) void {
    const end_to_end_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test/end_to_end_tests.zig"),
            .target = options.target,
            .optimize = options.optimize,
        }),
    });

    // These modules are outside of the test tree, so we need to add them
    // manually to the build. Not the cleanest solution but works for now.
    end_to_end_tests.root_module.addImport(
        "bit_set",
        b.addModule("bit_set", .{ .root_source_file = b.path("src/bit_set.zig") }),
    );
    end_to_end_tests.root_module.addImport(
        "units",
        b.addModule("units", .{ .root_source_file = b.path("src/units.zig") }),
    );
    end_to_end_tests.root_module.addOptions("build_options", options.buildOptions(b));
    end_to_end_tests.root_module.addOptions("test_options", options.testOptions(b));

    const run_end_to_end_tests = b.addRunArtifact(end_to_end_tests);
    run_end_to_end_tests.setEnvironmentVariable("ZIG_EXE", b.graph.zig_exe);
    step.dependOn(&run_end_to_end_tests.step);
}

fn buildTestToml(
    b: *std.Build,
    steps: struct { test_toml: *std.Build.Step },
    options: Options,
) void {
    const toml = b.createModule(.{
        .root_source_file = b.path("src/toml.zig"),
        .target = options.target,
        .optimize = options.optimize,
    });

    const decoder = b.addExecutable(.{
        .name = "toml-decoder",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test/toml_decoder.zig"),
            .target = options.target,
            .optimize = options.optimize,
        }),
    });
    decoder.root_module.addImport("toml", toml);

    const toml_test = b.findProgram(&.{"toml-test"}, &.{}) catch |err| switch (err) {
        // Explicitly switch on the error so we can catch new possible error
        // types in the future.
        error.FileNotFound => {
            // TODO: Add a script for installing `toml-test` to the repository.
            steps.test_toml.dependOn(&b.addFail("\"toml-test\" not found").step);
            return;
        },
    };
    const run_toml_test = b.addSystemCommand(&[_][]const u8{toml_test});
    run_toml_test.addFileArg(decoder.getEmittedBin());

    steps.test_toml.dependOn(&run_toml_test.step);
}

fn buildTestPlugins(b: *std.Build, step: *std.Build.Step, options: Options) void {
    const test_plugins = resolveTestPlugins(b, step) catch |err| switch (err) {
        error.AccessFailed => return,
        else => {
            step.dependOn(&b.addFail(b.fmt("failed to resolve the test plugins: {t}", .{err})).step);
            return;
        },
    };

    // TODO: Add non-Zig plugins.
    for (test_plugins) |tp| {
        const plugin = b.addExecutable(.{
            .name = b.fmt("{s}-{s}", .{ options.name, tp.name }),
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.pathJoin(&.{ tp.path, "src", "main.zig" })),
                .target = options.target,
                .optimize = options.optimize,
            }),
        });

        const dest_path = b.pathJoin(&.{ "plugins", tp.name });

        const install = b.addInstallArtifact(plugin, .{
            .dest_dir = .{
                .override = .{
                    .custom = dest_path,
                },
            },
        });

        const manifest_src = b.path(b.pathJoin(&.{ tp.path, "reginald-plugin.json" }));
        const install_manifest = b.addInstallFileWithDir(
            manifest_src,
            .{ .custom = dest_path },
            "reginald-plugin.json",
        );

        const plugin_step = b.step(
            b.fmt("test-plugin-{s}", .{tp.name}),
            b.fmt("Build and install test plugin \"{s}\"", .{tp.name}),
        );
        plugin_step.dependOn(&install.step);
        plugin_step.dependOn(&install_manifest.step);

        step.dependOn(plugin_step);
    }
}

fn resolveTestPlugins(b: *std.Build, step: *std.Build.Step) ![]TestPlugin {
    var result: ArrayList(TestPlugin) = .empty;
    defer result.deinit(b.allocator);

    const plugins_path = b.pathJoin(&.{ "src", "test", "plugins" });
    var plugin_dir = try std.fs.cwd().openDir(plugins_path, .{ .iterate = true });
    defer plugin_dir.close();

    var it = plugin_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) {
            continue;
        }

        var dir = try plugin_dir.openDir(entry.name, .{});
        defer dir.close();

        dir.access(b.pathJoin(&.{ "src", "main.zig" }), .{}) catch |err| switch (err) {
            // TODO: Add handling for non-Zig testing plugins.
            error.FileNotFound => continue,
            else => {
                step.dependOn(&b.addFail(b.fmt(
                    "cannot access \"{s}\": {t}",
                    .{
                        b.pathJoin(&.{ plugins_path, entry.name, "src", "main.zig" }),
                        err,
                    },
                )).step);
                return error.AccessFailed;
            },
        };

        const path = b.pathJoin(&.{ plugins_path, entry.name });

        try result.append(b.allocator, .{
            .name = try b.allocator.dupe(u8, entry.name),
            .path = path,
            .language = .zig,
        });
    }

    return result.toOwnedSlice(b.allocator);
}

fn createReginaldModule(b: *std.Build, options: Options) *std.Build.Module {
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = options.target,
        .optimize = options.optimize,
    });
    root_module.addOptions("build_options", options.buildOptions(b));
    return root_module;
}

fn resolveVersion(b: *std.Build) ![]const u8 {
    if (!std.process.can_spawn) {
        std.debug.print(
            "error: version cannot be resolved from Git. You must provide Reginald version using -Dversion\n",
            .{},
        );
        std.process.exit(1);
    }
    const version_string = b.fmt("{d}.{d}.{d}", .{
        reginald_version.major,
        reginald_version.minor,
        reginald_version.patch,
    });

    // TODO: Check before the actual releases.
    var code: u8 = undefined;
    const untrimmed = b.runAllowFail(&[_][]const u8{
        "git",
        "-C",
        b.build_root.path orelse ".",
        "--git-dir",
        ".git",
        "describe",
        "--match",
        "v*.*.*",
        "--tags",
        "--abbrev=9",
    }, &code, .Ignore) catch {
        // If the above command fails, there is probably no Git tags yet. In that case we need
        // to format a custom version based on the current time.
        const untrimmed = b.runAllowFail(&[_][]const u8{
            "git",
            "-C",
            b.build_root.path orelse ".",
            "--git-dir",
            ".git",
            "describe",
            "--always",
            "--abbrev=40",
            "--dirty",
        }, &code, .Ignore) catch {
            return version_string;
        };
        const commit = std.mem.trim(u8, untrimmed, " \n\r");

        if (!std.mem.endsWith(u8, commit, "-dirty")) {
            const untrimmed_date = b.runAllowFail(&[_][]const u8{
                "git",
                "-C",
                b.build_root.path orelse ".",
                "--git-dir",
                ".git",
                "show",
                "-s",
                "--date=format:%Y%m%d%H%M%S",
                "--format=%cd",
                std.mem.trimRight(u8, commit, "-dirty"),
            }, &code, .Ignore) catch {
                return version_string;
            };
            const date = std.mem.trim(u8, untrimmed_date, " \n\r");
            return b.fmt("{s}-dev.{s}+{s}", .{
                version_string,
                date,
                std.mem.trimRight(u8, commit, "-dirty"),
            });
        }

        const now = std.time.timestamp();

        // We assume that Reginald won't be built before epoch so the timestamp
        // isn't negative.
        const epoch_secs = std.time.epoch.EpochSeconds{ .secs = @as(u64, @intCast(now)) };
        const epoch_day = epoch_secs.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const year = year_day.year;
        const month_day = year_day.calculateMonthDay();
        const month = month_day.month.numeric();
        const day = month_day.day_index + 1;
        const day_secs = epoch_secs.getDaySeconds();
        const hour = day_secs.getHoursIntoDay();
        const minute = day_secs.getMinutesIntoHour();
        const second = day_secs.getSecondsIntoMinute();

        var buffer: [14]u8 = undefined;
        _ = try std.fmt.bufPrint(
            &buffer,
            "{d:0>4}{d:0>2}{d:0>2}{d:0>2}{d:0>2}{d:0>2}",
            .{ year, month, day, hour, minute, second },
        );

        return b.fmt("{s}-dev.{s}+{s}", .{ version_string, buffer, commit });
    };
    const git_describe = std.mem.trim(u8, untrimmed, " \n\r");

    switch (std.mem.count(u8, git_describe, "-")) {
        0 => {
            if (!std.mem.eql(u8, git_describe, version_string)) {
                std.debug.print("Reginald version '{s}' does not match Git tag '{s}'\n", .{ version_string, git_describe });
                std.process.exit(1);
            }

            return version_string;
        },
        2 => {
            // Untagged development build (e.g. 0.10.0-dev.2025+ecf0050a9).
            var it = std.mem.splitScalar(u8, git_describe, '-');
            const tagged_ancestor = it.first();
            const commit_height = it.next().?;
            const commit_id = it.next().?;

            const ancestor_ver = try std.SemanticVersion.parse(tagged_ancestor);
            if (reginald_version.order(ancestor_ver) != .gt) {
                std.debug.print("Reginald version '{f}' must be greater than tagged ancestor '{f}'\n", .{ reginald_version, ancestor_ver });
                std.process.exit(1);
            }

            // Check that the commit hash is prefixed with a 'g' (a Git
            // convention).
            if (commit_id.len < 1 or commit_id[0] != 'g') {
                std.debug.print("Unexpected `git describe` output: {s}\n", .{git_describe});
                return version_string;
            }

            // The version is reformatted in accordance with
            // the https://semver.org specification.
            return b.fmt("{s}-dev.{s}+{s}", .{ version_string, commit_height, commit_id[1..] });
        },
        else => {
            std.debug.print("Unexpected `git describe` output: {s}\n", .{git_describe});
            return version_string;
        },
    }
}

fn logLevelOption(b: *std.Build) []const u8 {
    const option = b.option(
        []const u8,
        "log-level",
        b.fmt(
            "Minimum log level to include in the compilation. To allow setting all log levels with runtime configuration, this should be \"{t}\". Default is \"{t}\"",
            .{
                std.log.Level.debug,
                std.log.Level.debug,
            },
        ),
    ) orelse @tagName(std.log.Level.debug);

    if (std.meta.stringToEnum(std.log.Level, option) == null) {
        std.debug.print("invalid log level: {s}\n", .{option});
        std.process.exit(1);
    }

    return option;
}
