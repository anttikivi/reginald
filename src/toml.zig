pub const Value = @import("toml/value.zig").Value;
pub const Array = @import("toml/value.zig").Array;
pub const Table = @import("toml/value.zig").Table;
pub const Datetime = @import("toml/value.zig").Datetime;
pub const Date = @import("toml/value.zig").Date;
pub const Time = @import("toml/value.zig").Time;

pub const Diagnostics = @import("toml/decoder.zig").Diagnostics;
pub const parse = @import("toml/decoder.zig").parse;
pub const parseWithDiagnostics = @import("toml/decoder.zig").parseWithDiagnostics;
