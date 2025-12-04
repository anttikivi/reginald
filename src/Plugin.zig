const Plugin = @This();

const build_options = @import("build_options");
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;

const Config = @import("Config.zig");
const core = @import("Plugin/core.zig");
const Host = @import("Plugin/Host.zig");
const Manifest = @import("Plugin/Manifest.zig");
const units = @import("units.zig");
const kib = units.kib;

/// The allocator that the plugin client uses.
allocator: Allocator,
child_process: ?std.process.Child = null,
name: []const u8,
type: ExecutableType,
exec: []const u8 = "",
runtime: ?[]const u8 = null,
// args: []const []const u8 = &.{},
namespace: []const u8 = "",
path: ?[]const u8 = null,

/// The memory buffer used by the plugin client after initialization.
buffer: []u8,

/// The allocator instance that creates the allocator to use during the plugin
/// execution.
fba: std.heap.FixedBufferAllocator,

/// The default memory buffer size of a plugin in bytes.
pub const default_buffer_size = 16 * kib;

/// The plugin name prefix that is not taken into account in the plugin's
/// namespace.
pub const prefix = build_options.name ++ "-";

/// The special token used in the `args` array of a plugin's manifest to denote
/// the plugin executable.
pub const exec_token = "$EXEC";

/// The special token used in the `args` array of a plugin's manifest to denote
/// the runtime executable.
pub const runtime_token = "$RUNTIME";

/// The plugin executable types. The type of a plugin determines the execution
/// strategy for it.
pub const ExecutableType = enum { core, standalone, runtime };

/// The states of a plugin.
pub const State = enum { not_started, ready, running, stopped };

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

    if (manifest.runtime) |rt| {
        self.runtime = try gpa.dupe(u8, rt);
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

/// Find all of the plugin manifest files in the plugin search paths and create
/// the plugin instances from them.
pub fn createAll(gpa: Allocator, cfg: *const Config, dir: std.fs.Dir) ![]Plugin {
    var result: ArrayList(Plugin) = .empty;
    errdefer result.deinit(gpa);

    const manifests = try Manifest.loadAll(gpa, cfg, dir);
    defer gpa.free(manifests);
    defer for (manifests) |*m| m.deinit(gpa);

    return result.toOwnedSlice(gpa);
}
