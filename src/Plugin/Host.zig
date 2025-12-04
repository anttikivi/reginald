//! The runtime host of plugins.

const Host = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Manifest = @import("Manifest.zig");
const Plugin = @import("../Plugin.zig");
const Runtime = @import("Runtime.zig");

plugins: []Plugin,
runtimes: []Runtime,

pub fn init(gpa: Allocator, manifests: []Manifest) !Host {
    var host: Host = .{
        .plugins = try gpa.alloc(Plugin, manifests.len),
        .runtimes = undefined,
    };
    errdefer host.deinit(gpa);

    for (manifests, 0..) |manifest, i| {
        try host.plugins[i].init(gpa, manifest);
    }

    var runtimes: ArrayList(Runtime) = .empty;
    for (host.plugins) |plugin| {
        if (plugin.runtime) |rt| {
            try runtimes.append(gpa, .{
                .name = rt,
            });
        }
    }
    host.runtimes = try runtimes.toOwnedSlice(gpa);

    return host;
}

pub fn deinit(self: *Host, gpa: Allocator) void {
    gpa.free(self.runtimes);

    for (self.plugins) |*p| {
        p.deinit(gpa);
    }
    gpa.free(self.plugins);
}
