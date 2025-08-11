const std = @import("std");

pub const Value = @import("toml/decoder.zig").Value;
pub const Array = @import("toml/decoder.zig").Array;
pub const Table = @import("toml/decoder.zig").Table;
pub const Datetime = @import("toml/decoder.zig").Datetime;
pub const Date = @import("toml/decoder.zig").Date;
pub const Time = @import("toml/decoder.zig").Time;

pub const Diagnostics = @import("toml/decoder.zig").Diagnostics;

pub const parse = @import("toml/decoder.zig").parse;
pub const parseWithDiagnostics = @import("toml/decoder.zig").parseWithDiagnostics;

test {
    std.testing.refAllDecls(@This());
}
