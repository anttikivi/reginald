// This file is originally from TigerBeetle
// (https://github.com/tigerbeetle/tigerbeetle), licensed under the Apache
// License, Version 2.0. It is modified by Antti Kivi. See THIRD_PARTY_NOTICES
// for more information.

const std = @import("std");
const assert = std.debug.assert;

// Import these as `const GiB = units.GiB;`
pub const kib = 1 << 10;
pub const mib = 1 << 20;
pub const gib = 1 << 30;
pub const tib = 1 << 40;
pub const pib = 1 << 50;

comptime {
    assert(kib == 1024);
    assert(mib == 1024 * kib);
    assert(gib == 1024 * mib);
    assert(tib == 1024 * gib);
    assert(pib == 1024 * tib);
}

/// Non-negative time difference between two `Instant`s.
pub const Duration = struct {
    ns: u64,

    pub fn ms(amount_ms: u64) Duration {
        return .{ .ns = amount_ms * std.time.ns_per_ms };
    }

    pub fn seconds(amount_seconds: u64) Duration {
        return .{ .ns = amount_seconds * std.time.ns_per_s };
    }

    pub fn minutes(amount_minutes: u64) Duration {
        return .{ .ns = amount_minutes * std.time.ns_per_min };
    }
};
