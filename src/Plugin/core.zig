const Manifest = @import("Manifest.zig");

pub const manifests = [_]Manifest{
    .{
        .name = "link",
        .type = .core,
    },
};
