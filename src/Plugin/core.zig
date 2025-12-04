//! Core plugins that are included in Reginald.

const std = @import("std");
const assert = std.debug.assert;

const Manifest = @import("Manifest.zig");
const Plugin = @import("../Plugin.zig");

pub const manifests = [_]Manifest{
    .{
        .name = "reginald-link",
        .type = .core,
    },
};

comptime {
    for (manifests) |m| {
        assert(std.mem.startsWith(u8, m.name, Plugin.prefix));
        assert(m.type == .core);
    }
}
