//! Collection of utilities for scripting: an in-process sh+coreutils combo.
//!
//! Keep this as a single file, independent from the rest of the codebase, to
//! make it easier to reuse across different processes (eg build.zig).
//!
//! If possible, avoid shelling out to `sh` or other systems utils --- the whole
//! purpose here is to avoid any extra dependencies.
//!
//! The `exec_` family of methods provides a convenience wrapper around
//! `std.process.Child`:
//!   - It allows constructing the array of arguments using convenient
//!     interpolation syntax a-la `std.fmt` (but of course no actual string
//!     concatenation happens anywhere).
//!   - `std.process.Child` is versatile and has many knobs, but they might be
//!     hard to use correctly (eg, its easy to forget to check exit status).
//!     `Shell` instead is focused on providing a set of specific narrow
//!     use-cases (eg, parsing the output of a subprocess) and takes care of
//!     setting the right defaults.

// This file is originally from TigerBeetle
// (https://github.com/tigerbeetle/tigerbeetle), licensed under the Apache
// License, Version 2.0. It is modified by Antti Kivi. See THIRD_PARTY_NOTICES
// for more information.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;

const stdx = @import("stdx");
const MiB = stdx.MiB;

const Shell = @This();

/// For internal use by the `Shell` itself.
gpa: Allocator,

/// To improve ergonomics, any returned data is owned by the `Shell` and is
/// stored in this arena. This way, the user doesn't need to worry about
/// deallocating each individual string, as long as they don't forget to call
/// `Shell.destroy`.
arena: std.heap.ArenaAllocator,

/// Root directory of this repository.
///
/// This is initialized when a shell is created. It would be more flexible to
/// lazily initialize this on the first access, but, given that we always use
/// `Shell` in the context of our repository, eager initialization is more
/// ergonomic.
project_root: std.fs.Dir,

/// Shell's logical cwd which is used for all functions in this file. It might
/// be different from `std.fs.cwd()` and is set to `project_root` on init.
cwd: std.fs.Dir,

// Stack of working directories backing pushd/popd.
cwd_stack: [cwd_stack_max]std.fs.Dir,
cwd_stack_count: usize,

// Zig uses file-descriptor oriented APIs in the standard library, with the one
// exception being ChildProcess's cwd, which is required to be a path, rather
// than a file descriptor. This buffer is used to materialize the path to cwd
// when spawning a new process.
//   <https://github.com/ziglang/zig/issues/5190>
cwd_path_buffer: [std.fs.max_path_bytes]u8 = undefined,

env: std.process.EnvMap,

/// True if the process is run in CI (the CI env var is set).
ci: bool,

/// Absolute path to the Zig binary.
zig_exe: ?[]const u8,

const log = std.log.scoped(.shell);

const cwd_stack_max = 16;

const Argv = struct {
    args: ArrayList([]const u8),

    fn init() Argv {
        return .{ .args = .empty };
    }

    fn expand(gpa: Allocator, comptime cmd: []const u8, cmd_args: anytype) !Argv {
        var result = Argv.init();
        errdefer result.deinit(gpa);

        try expandArgv(gpa, &result, cmd, cmd_args);

        return result;
    }

    fn deinit(argv: *Argv, gpa: Allocator) void {
        for (argv.args.items) |arg| {
            gpa.free(arg);
        }

        argv.args.deinit(gpa);
    }

    fn slice(argv: *Argv) []const []const u8 {
        return argv.args.items;
    }

    fn appendNewArg(argv: *Argv, gpa: Allocator, comptime arg_fmt: []const u8, arg: anytype) !void {
        const arg_owned = try std.fmt.allocPrint(gpa, arg_fmt, arg);
        errdefer gpa.free(arg_owned);

        try argv.args.append(gpa, arg_owned);
    }

    fn extendLastArg(
        argv: *Argv,
        gpa: Allocator,
        comptime arg_fmt: []const u8,
        arg: anytype,
    ) !void {
        assert(argv.args.items.len > 0);

        const arg_allocated = try std.fmt.allocPrint(
            gpa,
            "{s}" ++ arg_fmt,
            .{argv.args.items[argv.args.items.len - 1]} ++ arg,
        );

        gpa.free(argv.args.items[argv.args.items.len - 1]);
        argv.args.items[argv.args.items.len - 1] = arg_allocated;
    }
};

pub fn create(gpa: Allocator) !*Shell {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();

    var project_root = try discoverProjectRoot();
    errdefer project_root.close();

    var cwd = try project_root.openDir(".", .{});
    errdefer cwd.close();

    var env = try std.process.getEnvMap(gpa);
    errdefer env.deinit();

    const ci = env.get("CI") != null;

    const result = try gpa.create(Shell);
    errdefer gpa.destroy(result);

    result.* = .{
        .gpa = gpa,
        .arena = arena,
        .project_root = project_root,
        .cwd = cwd,
        .cwd_stack = undefined,
        .cwd_stack_count = 0,
        .env = env,
        .ci = ci,
        .zig_exe = env.get("ZIG_EXE"),
    };

    return result;
}

pub fn destroy(shell: *Shell) void {
    const gpa = shell.gpa;

    assert(shell.cwd_stack_count == 0); // pushd not paired by popd

    shell.env.deinit();
    shell.cwd.close();
    shell.project_root.close();
    shell.arena.deinit();
    gpa.destroy(shell);
}

/// Runs the given command for side effects. Returns an error if exit status is
/// non-zero.
///
/// Supports interpolation using the following syntax:
///
/// ```
/// shell.exec("git branch {op} {branches}", .{
///     .op = "-D",
///     .branches = &.{"main", "feature"},
/// })
/// ```
pub fn exec(shell: *Shell, comptime cmd: []const u8, cmd_args: anytype) !void {
    var argv = try Argv.expand(shell.gpa, cmd, cmd_args);
    defer argv.deinit(shell.gpa);

    return execInner(shell, argv.slice(), .{});
}

/// Runs the given command and returns its output. If the output is a single
/// line, the final newline is stripped.
pub fn execStdout(shell: *Shell, comptime cmd: []const u8, cmd_args: anytype) ![]const u8 {
    var argv = try Argv.expand(shell.gpa, cmd, cmd_args);
    defer argv.deinit(shell.gpa);

    var captured_stdout: []const u8 = &.{};
    try execInner(shell, argv.slice(), .{
        .capture_stdout = &captured_stdout,
    });

    return captured_stdout;
}

pub fn execStdoutStderr(shell: *Shell, comptime cmd: []const u8, cmd_args: anytype) !struct {
    []const u8,
    []const u8,
} {
    var argv = try Argv.expand(shell.gpa, cmd, cmd_args);
    defer argv.deinit(shell.gpa);

    var captured_stdout: []const u8 = &.{};
    var captured_stderr: []const u8 = &.{};
    try execInner(shell, argv.slice(), .{
        .capture_stdout = &captured_stdout,
        .capture_stderr = &captured_stderr,
    });

    return .{ captured_stdout, captured_stderr };
}

pub fn execStdoutOptions(
    shell: *Shell,
    options: struct {
        stdin_slice: ?[]const u8 = null,
    },
    comptime cmd: []const u8,
    cmd_args: anytype,
) ![]const u8 {
    var argv = try Argv.expand(shell.gpa, cmd, cmd_args);
    defer argv.deinit(shell.gpa);

    var captured_stdout: []const u8 = &.{};
    try execInner(shell, argv.slice(), .{
        .stdin_slice = options.stdin_slice,
        .capture_stdout = &captured_stdout,
    });

    return captured_stdout;
}

/// Runs the Zig compiler.
pub fn execZig(shell: *Shell, comptime cmd: []const u8, cmd_args: anytype) !void {
    return shell.execZigOptions(.{}, cmd, cmd_args);
}

pub fn execZigOptions(
    shell: *Shell,
    options: struct {
        timeout: stdx.Duration = .minutes(10),
    },
    comptime cmd: []const u8,
    cmd_args: anytype,
) !void {
    var argv = Argv.init();
    defer argv.deinit(shell.gpa);

    try argv.appendNewArg(shell.gpa, "{s}", .{shell.zig_exe.?});
    try expandArgv(shell.gpa, &argv, cmd, cmd_args);

    return shell.execInner(argv.slice(), .{
        .timeout = options.timeout,
    });
}

pub fn spawn(
    shell: *Shell,
    options: struct {
        stdin_behavior: std.process.Child.StdIo = .Ignore,
        stdout_behavior: std.process.Child.StdIo = .Ignore,
        stderr_behavior: std.process.Child.StdIo = .Ignore,
    },
    comptime cmd: []const u8,
    cmd_args: anytype,
) !std.process.Child {
    var argv = try Argv.expand(shell.gpa, cmd, cmd_args);
    defer argv.deinit(shell.gpa);

    var child = std.process.Child.init(argv.slice(), shell.gpa);
    child.cwd = try shell.cwd.realpath(".", &shell.cwd_path_buffer);
    child.env_map = &shell.env;
    child.stdin_behavior = options.stdin_behavior;
    child.stdout_behavior = options.stdout_behavior;
    child.stderr_behavior = options.stderr_behavior;
    try child.spawn();

    return child;
}

/// Finds the root of Reginald repository. Caller is responsible for closing
/// the `Dir`.
fn discoverProjectRoot() !std.fs.Dir {
    var current = try std.fs.cwd().openDir(".", .{});
    errdefer current.close();

    for (0..16) |_| {
        if (current.statFile("src/test/Shell.zig")) |_| {
            return current;
        } else |err| switch (err) {
            error.FileNotFound => {
                const parent = try current.openDir("..", .{});
                current.close();
                current = parent;
            },
            else => return err,
        }
    }

    return error.DiscoverProjectRootDepthExceeded;
}

fn execInner(
    shell: *Shell,
    argv: []const []const u8,
    options: struct {
        stdin_slice: ?[]const u8 = null,

        // Optional out parameters:
        capture_stdout: ?*[]const u8 = null,
        capture_stderr: ?*[]const u8 = null,

        output_limit_bytes: usize = 128 * MiB,
        timeout: stdx.Duration = .minutes(10),
    },
) !void {
    const argv_formatted = try std.mem.join(shell.gpa, " ", argv);
    defer shell.gpa.free(argv_formatted);

    var stdin_writer: ?std.Thread = null;
    defer if (stdin_writer) |thread| thread.join();

    const Streams = enum { stdout, stderr };
    var poller: ?std.io.Poller(Streams) = null;
    defer if (poller) |*p| p.deinit();

    errdefer |err| {
        log.err("process failed with {s}: {s}", .{ @errorName(err), argv_formatted });
        if (poller) |*p| {
            inline for (comptime std.enums.values(Streams)) |stream| {
                // if (p.fifo(stream).count > 0) {
                if (p.reader(stream).bufferedLen() > 0) {
                    const s = p.toOwnedSlice(stream) catch @panic("OOM");
                    defer shell.gpa.free(s);

                    log.err("{s}:\n++++\n{s}++++\n", .{ @tagName(stream), s });
                }
            }
        }
    }

    var child = std.process.Child.init(argv, shell.gpa);
    child.cwd = try shell.cwd.realpath(".", &shell.cwd_path_buffer);
    child.env_map = &shell.env;
    child.stdin_behavior = if (options.stdin_slice != null) .Pipe else .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();
    errdefer {
        _ = child.kill() catch {};
    }

    if (options.stdin_slice) |stdin_slice| {
        stdin_writer = try writeStdin(&child, stdin_slice);
    }

    poller = std.io.poll(shell.gpa, Streams, .{
        .stdout = child.stdout.?,
        .stderr = child.stderr.?,
    });

    {
        defer inline for (comptime std.enums.values(Streams)) |stream| {
            assert(poller.?.reader(stream).bufferedLen() == poller.?.reader(stream).end);
        };

        const deadline: i128 = std.time.nanoTimestamp() + options.timeout.ns;
        for (0..1_000_000) |_| {
            const timeout: i128 = deadline - std.time.nanoTimestamp();
            if (timeout <= 0) {
                return error.ExecTimeout;
            }

            if (!try poller.?.pollTimeout(@intCast(timeout))) {
                break;
            }

            inline for (comptime std.enums.values(Streams)) |stream| {
                if (poller.?.reader(stream).buffer.len > options.output_limit_bytes) {
                    return error.StdoutStreamTooLong;
                }
            }
        } else @panic("exec: safety counter exceeded");
    }

    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) return error.ExecNonZeroExitStatus,
        else => return error.ExecFailed,
    }

    inline for (
        .{ options.capture_stdout, options.capture_stderr },
        .{ .stdout, .stderr },
    ) |capture_destination, capture_stream| {
        if (capture_destination) |destination| {
            // const stream = poller.?.fifo(capture_stream).readableSlice(0);
            const stream = poller.?.toOwnedSlice(capture_stream) catch @panic("OOM");
            defer shell.gpa.free(stream);

            const trailing_newline = if (std.mem.indexOfScalar(u8, stream, '\n')) |first_newline|
                first_newline == stream.len - 1
            else
                false;
            const len_without_newline = stream.len - @intFromBool(trailing_newline);
            destination.* = try shell.arena.allocator().dupe(u8, stream[0..len_without_newline]);
        }
    }
}

/// Expands `cmd` into an array of command arguments, substituting values from
/// `cmd_args`.
///
/// This avoids shell injection by construction as it doesn't concatenate
/// strings.
fn expandArgv(gpa: Allocator, argv: *Argv, comptime cmd: []const u8, cmd_args: anytype) !void {
    @setEvalBranchQuota(5_000);
    // Mostly copy-paste from std.fmt.format

    comptime var pos: usize = 0;

    // For arguments like `reginald-{version}.exe`, we want to concatenate
    // literal suffix ("reginald-") and prefix (".exe") to the value of
    // `version` interpolated argument.
    //
    // These two variables track the spaces around `{}` syntax.
    comptime var concat_left: bool = false;
    comptime var concat_right: bool = false;

    const arg_count = std.meta.fields(@TypeOf(cmd_args)).len;
    comptime var args_used: stdx.BitSet(arg_count) = .{};

    comptime assert(std.mem.indexOfScalar(u8, cmd, '\'') == null); // Intentionally unsupported.
    comptime assert(std.mem.indexOfScalar(u8, cmd, '"') == null);

    inline while (pos < cmd.len) {
        inline while (pos < cmd.len and (cmd[pos] == ' ' or cmd[pos] == '\n')) {
            pos += 1;
        }

        const pos_start = pos;
        inline while (pos < cmd.len) : (pos += 1) {
            switch (cmd[pos]) {
                ' ', '\n', '{' => break,
                else => {},
            }
        }

        const pos_end = pos;
        if (pos_start != pos_end) {
            if (concat_right) {
                assert(pos_start > 0 and cmd[pos_start - 1] == '}');
                try argv.extendLastArg(gpa, "{s}", .{cmd[pos_start..pos_end]});
            } else {
                try argv.appendNewArg(gpa, "{s}", .{cmd[pos_start..pos_end]});
            }
        }

        concat_left = false;
        concat_right = false;

        if (pos >= cmd.len) {
            break;
        }

        if (cmd[pos] == ' ' or cmd[pos] == '\n') {
            continue;
        }

        comptime assert(cmd[pos] == '{');

        concat_left = pos > 0 and cmd[pos - 1] != ' ' and cmd[pos - 1] != '\n';
        if (concat_left) {
            assert(argv.slice().len > 0);
        }

        pos += 1;

        const pos_arg_start = pos;
        inline while (pos < cmd.len and cmd[pos] != '}') : (pos += 1) {}
        const pos_arg_end = pos;

        if (pos >= cmd.len) {
            @compileError("Missing closing }");
        }

        comptime assert(cmd[pos] == '}');
        concat_right = pos + 1 < cmd.len and cmd[pos + 1] != ' ' and cmd[pos + 1] != '\n';
        pos += 1;

        const arg_name = comptime cmd[pos_arg_start..pos_arg_end];
        const arg_or_slice = @field(cmd_args, arg_name);
        comptime args_used.set(for (std.meta.fieldNames(@TypeOf(cmd_args)), 0..) |field, index| {
            if (std.mem.eql(u8, field, arg_name)) {
                break index;
            }
        } else unreachable);

        const T = @TypeOf(arg_or_slice);

        if (@typeInfo(T) == .int or @typeInfo(T) == .comptime_int) {
            if (concat_left) {
                try argv.extendLastArg(gpa, "{d}", .{arg_or_slice});
            } else {
                try argv.appendNewArg(gpa, "{d}", .{arg_or_slice});
            }
        } else if (std.meta.Elem(T) == u8) {
            if (concat_left) {
                try argv.extendLastArg(gpa, "{s}", .{arg_or_slice});
            } else {
                try argv.appendNewArg(gpa, "{s}", .{arg_or_slice});
            }
        } else if (std.meta.Elem(T) == []const u8) {
            if (concat_left or concat_right) {
                @compileError("Can't concatenate slices");
            }

            for (arg_or_slice) |arg_part| {
                try argv.append_new_arg("{s}", .{arg_part});
            }
        } else {
            @compileError("Unsupported argument type");
        }
    }

    comptime if (args_used.count() != arg_count) {
        @compileError("Unused argument");
    };
}

fn writeStdin(child: *std.process.Child, stdin: []const u8) !std.Thread {
    assert(child.stdin != null);
    defer child.stdin = null;

    // Spawn a thread to avoid deadlock between us writing to stdin and reading
    // from stdout.
    return try std.Thread.spawn(
        .{},
        struct {
            fn writeStdin(destination: std.fs.File, source: []const u8) void {
                defer destination.close();

                // TODO: Update to the new Writer.
                destination.writeAll(source) catch {};
            }
        }.writeStdin,
        .{ child.stdin.?, stdin },
    );
}
