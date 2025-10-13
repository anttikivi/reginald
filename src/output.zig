const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const Config = @import("Config.zig");

var output: Output = undefined;

pub const Output = struct {
    configured: bool = false,
    mode: Mode = .default,
    stderr: *std.Io.Writer = undefined,
    stdout: *std.Io.Writer = undefined,
    stderr_buffer: [4096]u8 = undefined,
    stdout_buffer: [4096]u8 = undefined,
    stderr_writer: std.fs.File.Writer,
    stdout_writer: std.fs.File.Writer,

    fn fail(self: *Output, comptime format: []const u8, args: anytype) error{ Reported, WriteFailed } {
        if (!builtin.is_test) {
            try self.stderr.print(format, args);
            try self.stderr.writeByte('\n');
            try self.stderr.flush();
        }

        return error.Reported;
    }

    fn flush(self: *Output) error{WriteFailed}!void {
        if (builtin.is_test) {
            return;
        }

        assert(self.configured);

        try self.stdout.flush();
    }

    fn print(self: *Output, comptime format: []const u8, args: anytype) !void {
        if (builtin.is_test) {
            return;
        }

        assert(self.configured);

        try self.stdout.print(format, args);
    }
};

const Mode = enum { default, quiet, verbose };

/// Initialize the global output instance. If the instance is initialized but
/// not configured by using `configure`, it may only be used for error output.
pub fn init() void {
    output = .{
        .stderr_writer = std.fs.File.stderr().writer(&output.stderr_buffer),
        .stdout_writer = std.fs.File.stdout().writer(&output.stdout_buffer),
    };

    output.stderr = &output.stderr_writer.interface;
    output.stdout = &output.stdout_writer.interface;
}

/// Configure the output instance to be used for normal output.
pub fn configure(cfg: *const Config) void {
    assert(!output.configured);

    const quiet = cfg.get(bool, "quiet").?;
    const verbose = cfg.get(bool, "verbose").?;

    output.mode = if (quiet) .quiet else if (verbose) .verbose else .default;
    output.configured = true;

    assert(output.configured);
}

/// Prints an error message and a line feed to stderr and flushes. It returns
/// an error that denotes that the failure is already reported to the user.
pub fn fail(comptime format: []const u8, args: anytype) error{ Reported, WriteFailed } {
    return output.fail(format, args);
}

/// Flushes the standard output buffer of the default output.
pub fn flush() error{WriteFailed}!void {
    try output.flush();
}

/// Prints a message to stdout.
pub fn print(comptime format: []const u8, args: anytype) !void {
    try output.print(format, args);
}
