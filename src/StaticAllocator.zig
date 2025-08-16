//! An allocator wrapper which can be disabled at runtime. We use this for
//! allocating at startup and then disable it to prevent accidental dynamic
//! allocation at runtime.

// This file is based on code from TigerBeetle
// (https://github.com/tigerbeetle/tigerbeetle), licensed under the Apache
// License, version 2.0.
//
// The code has been adapted to match the style of this project.

const std = @import("std");
const Alignment = std.mem.Alignment;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const StaticAllocator = @This();

child_allocator: Allocator,
state: State,

const State = enum {
    /// Allow `alloc` and `resize`. (To make `errdefer` cleanup easier to write
    /// we also allow calling `free`, in which case we switch state to `.deinit`
    /// and no longer allow `alloc` or `resize`.)
    init,
    /// Don't allow any calls.
    static,
    /// Allow `free` but not `alloc` and `resize`.
    deinit,
};

pub fn init(child_allocator: Allocator) StaticAllocator {
    return .{
        .child_allocator = child_allocator,
        .state = .init,
    };
}

pub fn deinit(self: *StaticAllocator) void {
    self.* = undefined;
}

pub fn toStatic(self: *StaticAllocator) void {
    assert(self.state == .init);
    self.state = .static;
}

pub fn toDeinit(self: *StaticAllocator) void {
    assert(self.state == .static);
    self.state = .deinit;
}

pub fn allocator(self: *StaticAllocator) Allocator {
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

fn alloc(ctx: *anyopaque, len: usize, ptr_align: Alignment, ret_addr: usize) ?[*]u8 {
    const self: *StaticAllocator = @alignCast(@ptrCast(ctx));
    assert(self.state == .init);
    return self.child_allocator.rawAlloc(len, ptr_align, ret_addr);
}

fn resize(ctx: *anyopaque, buf: []u8, buf_align: Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *StaticAllocator = @alignCast(@ptrCast(ctx));
    assert(self.state == .init);
    return self.child_allocator.rawResize(buf, buf_align, new_len, ret_addr);
}

fn remap(ctx: *anyopaque, buf: []u8, buf_align: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const self: *StaticAllocator = @alignCast(@ptrCast(ctx));
    assert(self.state == .init);
    return self.child_allocator.rawRemap(buf, buf_align, new_len, ret_addr);
}

fn free(ctx: *anyopaque, buf: []u8, buf_align: Alignment, ret_addr: usize) void {
    const self: *StaticAllocator = @alignCast(@ptrCast(ctx));
    assert(self.state == .init or self.state == .deinit);
    // Once you start freeing, you don't stop.
    self.state = .deinit;
    return self.child_allocator.rawFree(buf, buf_align, ret_addr);
}
