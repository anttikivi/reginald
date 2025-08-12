//! An allocator that takes an existing allocator, wraps it, and keeps track of
//! how many bytes are currently allocated using it.

// This file is based on code from TigerBeetle
// (https://github.com/tigerbeetle/tigerbeetle), licensed under the Apache
// License, version 2.0.
//
// The code has been adapted to match the style of this project.

const std = @import("std");
const Alignment = std.mem.Alignment;
const Allocator = std.mem.Allocator;

const Self = @This();

child_allocator: Allocator,
alloc_size: u64 = 0,
free_size: u64 = 0,

pub fn init(child_allocator: Allocator) Self {
    return .{ .child_allocator = child_allocator };
}

pub fn deinit(self: *Self) void {
    self.* = undefined;
}

pub fn allocator(self: *Self) Allocator {
    return .{
        .ptr = self,
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        },
    };
}

pub fn liveSize(self: *Self) u64 {
    return self.alloc_size - self.free_size;
}

fn alloc(ctx: *anyopaque, len: usize, ptr_align: Alignment, ret_addr: usize) ?[*]u8 {
    const self: *Self = @alignCast(@ptrCast(ctx));
    self.alloc_size += len;
    return self.child_allocator.rawAlloc(len, ptr_align, ret_addr);
}

fn resize(ctx: *anyopaque, buf: []u8, buf_align: Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *Self = @alignCast(@ptrCast(ctx));

    if (self.child_allocator.rawResize(buf, buf_align, new_len, ret_addr)) {
        if (new_len > buf.len) {
            self.alloc_size += new_len - buf.len;
        } else {
            self.free_size += buf.len - new_len;
        }
        return true;
    } else {
        return false;
    }
}

fn remap(ctx: *anyopaque, buf: []u8, buf_align: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const self: *Self = @alignCast(@ptrCast(ctx));
    if (self.child_allocator.rawRemap(buf, buf_align, new_len, ret_addr)) |remapped| {
        if (new_len > buf.len) {
            self.alloc_size += new_len - buf.len;
        } else {
            self.free_size += buf.len - new_len;
        }
        return remapped;
    }
    return null;
}

fn free(ctx: *anyopaque, buf: []u8, buf_align: Alignment, ret_addr: usize) void {
    const self: *Self = @alignCast(@ptrCast(ctx));
    self.free_size += buf.len;
    return self.child_allocator.rawFree(buf, buf_align, ret_addr);
}
