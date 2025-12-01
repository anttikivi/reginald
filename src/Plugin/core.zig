//! Core plugins that are included in Reginald.

const Manifest = @import("Manifest.zig");

pub const manifests = [_]Manifest{
    .{
        .name = "reginald-link",
        .type = .core,
        .namespace = "link",
    },
};
