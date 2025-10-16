//! The runtime host of plugins.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Manifest = @import("Manifest.zig");
const Plugin = @import("../Plugin.zig");

const Host = @This();

plugins: []Plugin,

pub fn init(gpa: Allocator, manifests: []Manifest) !Host {
    var host: Host = .{
        .plugins = try gpa.alloc(Plugin, manifests.len),
    };
    errdefer host.deinit(gpa);

    for (manifests, 0..) |manifest, i| {
        try host.plugins[i].init(gpa, manifest);
    }

    return host;
}

pub fn deinit(self: *Host, gpa: Allocator) void {
    for (self.plugins) |*p| {
        p.deinit(gpa);
    }
    gpa.free(self.plugins);
}
