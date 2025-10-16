const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Host = @import("Plugin/Host.zig");
pub const Manifest = @import("Plugin/Manifest.zig");

const Plugin = @This();

allocator: Allocator,
child_process: ?std.process.Child = null,
name: []const u8,
type: Type,
exec: []const u8 = "",
// runtime: ?[]const u8 = null,
// args: []const []const u8 = &.{},
namespace: []const u8 = "",
path: ?[]const u8 = null,

buffer: []u8,
fba: std.heap.FixedBufferAllocator,

/// The default memory buffer size of a plugin in bytes.
pub const default_buffer_size = 16 * 1024; // 16KiB

/// The plugin name prefix that is not taken into account in the plugin's
/// namespace.
pub const prefix = "reginald-";

/// The special token used in the `args` array of a plugin's manifest to denote
/// the plugin executable.
pub const exec_token = "$EXEC";

/// The special token used in the `args` array of a plugin's manifest to denote
/// the runtime executable.
pub const runtime_token = "$RUNTIME";

/// The states of a plugin.
pub const State = enum { not_started, ready, running, stopped };

/// The plugin types. The type of a plugin determines the execution strategy
/// for it.
pub const Type = enum { core, standalone, runtime };

pub fn init(self: *Plugin, gpa: Allocator, manifest: Manifest) !void {
    self.* = .{
        .allocator = undefined,
        .name = try gpa.dupe(u8, manifest.name),
        .type = manifest.type,
        .buffer = undefined,
        .fba = undefined,
    };

    if (manifest.exec.len > 0) {
        self.exec = try gpa.dupe(u8, manifest.exec);
    }

    if (std.mem.eql(u8, manifest.name, manifest.namespace)) {
        self.namespace = self.name;
    } else {
        self.namespace = try gpa.dupe(u8, manifest.namespace);
    }

    if (manifest.path) |p| {
        self.path = try gpa.dupe(u8, p);
    }

    // TODO: See if there will be a need to customize the buffer size.
    self.buffer = try gpa.alloc(u8, default_buffer_size);
    self.fba = .init(self.buffer);
    self.allocator = self.fba.allocator();
}

pub fn deinit(self: *Plugin, gpa: Allocator) void {
    gpa.free(self.buffer);

    if (self.path) |p| {
        gpa.free(p);
    }

    if (!std.mem.eql(u8, self.name, self.namespace)) {
        gpa.free(self.namespace);
    }

    if (self.exec.len > 0) {
        gpa.free(self.exec);
    }

    gpa.free(self.name);
}
