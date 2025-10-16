const std = @import("std");
const assert = std.debug.assert;

const reginald_name = "reginald";
const reginald_version: std.SemanticVersion = .{ .major = 0, .minor = 1, .patch = 0 };
const default_env_prefix = "REGINALD_";

const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    env_prefix: []const u8,
    version: []const u8,

    fn stepOptions(self: *const Options, b: *std.Build) *std.Build.Step.Options {
        const options = b.addOptions();

        options.addOption([]const u8, "name", self.name);
        options.addOption([]const u8, "env_prefix", self.env_prefix);
        options.addOption([]const u8, "version", self.version);

        return options;
    }
};

pub fn build(b: *std.Build) !void {
    const build_steps = .{
        .check = b.step("check", "Check if Reginald compiles"),
        .ci = b.step("ci", "Run the CI test suite"),
        .install = b.getInstallStep(),
        .run = b.step("run", "Run Reginald"),
        .@"test" = b.step("test", "Run tests"),
        .test_fmt = b.step("test-fmt", "Check formatting"),
        .test_toml = b.step("test-toml", "Run the `toml-test` test suite"),
        .test_unit = b.step("test-unit", "Run unit tests"),
    };

    const options: Options = .{
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
        .name = b.option(
            []const u8,
            "name",
            b.fmt("Name of the program. Default is \"{s}\"", .{reginald_name}),
        ) orelse reginald_name,
        .env_prefix = b.option(
            []const u8,
            "env-prefix",
            b.fmt(
                "Use this as the prefix for environment variables used by Reginald. Default is \"{s}\"",
                .{default_env_prefix},
            ),
        ) orelse default_env_prefix,
        .version = b.option(
            []const u8,
            "version",
            "Use this as the version string of Reginald",
        ) orelse resolveVersion(b) catch {
            std.debug.print("error: resolving version failed\n", .{});
            std.process.exit(1);
        },
    };

    buildCheck(b, build_steps.check, options);

    buildReginald(b, .{
        .install = build_steps.install,
        .run = build_steps.run,
    }, options);

    buildTest(b, .{
        .@"test" = build_steps.@"test",
        .test_fmt = build_steps.test_fmt,
        .test_toml = build_steps.test_toml,
        .test_unit = build_steps.test_unit,
    }, options);

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
    const name = std.mem.join(b.allocator, " ", &command) catch @panic("out of memory");
    system_command.setName(name);
    step.dependOn(&system_command.step);
}

/// Build Reginald without codegen.
fn buildCheck(b: *std.Build, step: *std.Build.Step, options: Options) void {
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = options.target,
        .optimize = options.optimize,
    });
    root_module.addOptions("build_options", options.stepOptions(b));

    const reginald = b.addExecutable(.{
        .name = "reginald",
        .root_module = root_module,
    });

    step.dependOn(&reginald.step);
}

/// Add the steps for building, installing, and running Reginald.
fn buildReginald(
    b: *std.Build,
    steps: struct {
        run: *std.Build.Step,
        install: *std.Build.Step,
    },
    options: Options,
) void {
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = options.target,
        .optimize = options.optimize,
    });
    root_module.addOptions("build_options", options.stepOptions(b));

    const reginald = b.addExecutable(.{
        .name = "reginald",
        .root_module = root_module,
    });
    b.installArtifact(reginald);

    const run_cmd = b.addRunArtifact(reginald);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    steps.run.dependOn(&run_cmd.step);
}

fn buildTest(b: *std.Build, steps: struct {
    @"test": *std.Build.Step,
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
    unit_tests.root_module.addOptions("build_options", options.stepOptions(b));

    if (options.target.result.os.tag != .windows) {
        unit_tests.linkLibC();
    }

    const run_unit_tests = b.addRunArtifact(unit_tests);
    steps.test_unit.dependOn(&run_unit_tests.step);

    buildTestToml(b, .{ .test_toml = steps.test_toml }, options);

    const run_fmt = b.addFmt(.{ .paths = &.{"."}, .check = true });
    steps.test_fmt.dependOn(&run_fmt.step);

    steps.@"test".dependOn(steps.test_unit);

    if (b.args == null) {
        steps.@"test".dependOn(steps.test_fmt);
        steps.@"test".dependOn(steps.test_toml);
    }
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
            .root_source_file = b.path("test/toml.zig"),
            .target = options.target,
            .optimize = options.optimize,
        }),
    });
    decoder.root_module.addImport("toml", toml);

    const run_toml_test = b.addSystemCommand(&[_][]const u8{"toml-test"});
    run_toml_test.addFileArg(decoder.getEmittedBin());

    steps.test_toml.dependOn(&run_toml_test.step);
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

        // We assume that Reginald won't be built before epoch so the timestamp isn't negative.
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

            // Check that the commit hash is prefixed with a 'g' (a Git convention).
            if (commit_id.len < 1 or commit_id[0] != 'g') {
                std.debug.print("Unexpected `git describe` output: {s}\n", .{git_describe});
                return version_string;
            }

            // The version is reformatted in accordance with the https://semver.org specification.
            return b.fmt("{s}-dev.{s}+{s}", .{ version_string, commit_height, commit_id[1..] });
        },
        else => {
            std.debug.print("Unexpected `git describe` output: {s}\n", .{git_describe});
            return version_string;
        },
    }
}
