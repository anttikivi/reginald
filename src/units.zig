// This file is originally from TigerBeetle
// (https://github.com/tigerbeetle/tigerbeetle), licensed under the Apache
// License, Version 2.0. It is modified by Antti Kivi. See THIRD_PARTY_NOTICES
// for more information.

const std = @import("std");
const assert = std.debug.assert;

// Import these as `const GiB = stdx.GiB;`
pub const KiB = 1 << 10;
pub const MiB = 1 << 20;
pub const GiB = 1 << 30;
pub const TiB = 1 << 40;
pub const PiB = 1 << 50;

comptime {
    assert(KiB == 1024);
    assert(MiB == 1024 * KiB);
    assert(GiB == 1024 * MiB);
    assert(TiB == 1024 * GiB);
    assert(PiB == 1024 * TiB);
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
