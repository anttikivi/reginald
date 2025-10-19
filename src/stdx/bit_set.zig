// This file is originally from TigerBeetle
// (https://github.com/tigerbeetle/tigerbeetle), licensed under the Apache
// License, Version 2.0. It is modified by Antti Kivi. See THIRD_PARTY_NOTICES
// for more information.

const std = @import("std");
const assert = std.debug.assert;

/// Use a dynamic bitset for larger sizes.
pub fn BitSet(comptime with_capacity: u9) type {
    assert(with_capacity <= 256);

    return struct {
        // While mathematically 0 and 1 are symmetric, we intentionally bias
        // the API to use zeros default, as zero-initialization reduces binary
        // size.
        bits: Word = 0,

        pub const Word = for (.{ u8, u16, u32, u64, u128, u256 }) |w| {
            if (@bitSizeOf(w) >= with_capacity) {
                break w;
            }
        } else unreachable;

        pub fn isSet(bit_set: @This(), index: usize) bool {
            assert(index < bit_set.capacity());
            return bit_set.bits & bit(index) != 0;
        }

        pub fn count(bit_set: @This()) usize {
            return @popCount(bit_set.bits);
        }

        pub inline fn capacity(_: @This()) usize {
            return with_capacity;
        }

        pub fn full(bit_set: @This()) bool {
            return bit_set.count() == bit_set.capacity();
        }

        pub fn empty(bit_set: @This()) bool {
            return bit_set.bits == 0;
        }

        pub fn firstSet(bit_set: @This()) ?usize {
            if (bit_set.bits == 0) {
                return null;
            }

            return @ctz(bit_set.bits);
        }

        pub fn firstUnset(bit_set: @This()) ?usize {
            const result = @ctz(~bit_set.bits);
            return if (result < bit_set.capacity()) result else null;
        }

        pub fn set(bit_set: *@This(), index: usize) void {
            assert(index < bit_set.capacity());
            bit_set.bits |= bit(index);
        }

        pub fn unset(bit_set: *@This(), index: usize) void {
            assert(index < bit_set.capacity());
            bit_set.bits &= ~bit(index);
        }

        pub fn setValue(bit_set: *@This(), index: usize, value: bool) void {
            if (value) {
                bit_set.set(index);
            } else {
                bit_set.unset(index);
            }
        }

        fn bit(index: usize) Word {
            assert(index < with_capacity);
            return @as(Word, 1) << @intCast(index);
        }

        pub fn iterate(bit_set: @This()) Iterator {
            return .{ .bits_remain = bit_set.bits };
        }

        pub const Iterator = struct {
            bits_remain: Word,

            pub fn next(it: *@This()) ?usize {
                const result = @ctz(it.bits_remain);
                if (result >= with_capacity) {
                    return null;
                }

                it.bits_remain &= it.bits_remain - 1;

                return result;
            }
        };
    };
}
