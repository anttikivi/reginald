pub const Manifest = @import("Plugin/Manifest.zig");

/// The plugin name prefix that is not taken into account in the plugin's
/// namespace.
pub const prefix = "reginald-";

/// The special token used in the `args` array of a plugin's manifest to denote
/// the plugin executable.
pub const exec_token = "$EXEC";

/// The special token used in the `args` array of a plugin's manifest to denote
/// the runtime executable.
pub const runtime_token = "$RUNTIME";
