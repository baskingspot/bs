//! An allocator that keeps freed large blocks for reuse, in front of the
//! general-purpose allocator. SmpAllocator maps each block above its
//! largest size class (64 KiB) with mmap and unmaps it on free. With
//! CodeGen workers running, each unmap interrupts every other core to
//! flush its TLB, and a block mapped again faults in its pages one by one.
//! On ghostty's lib-vt the mmap, munmap and mremap calls, the TLB flushes
//! and the page faults took about 12% of a cold build (2026-11-04).
//!
//! Large blocks are rounded up to a size class, so a block serves any
//! request of its class and grows within it in place. A freed block goes
//! on its class's list unless the lists already hold `cap` bytes. One
//! lock guards the lists: large blocks are rare next to small ones.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const BlockCache = @This();

child: Allocator,
/// Bytes the lists may hold.
cap: usize,
cached: usize = 0,
mutex: std.atomic.Mutex = .unlocked,
/// Per class, the first free block; each holds the next one's address in
/// its first word.
heads: [class_count]usize = @splat(0),

/// The smallest block kept: SmpAllocator's slab size.
const min_class = 16;
const class_count = (@bitSizeOf(usize) - min_class) * 4;

pub fn allocator(c: *BlockCache) Allocator {
    return .{ .ptr = c, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
}

/// Gives the cached blocks back to the child.
pub fn deinit(c: *BlockCache) void {
    for (&c.heads, 0..) |*head, i| {
        while (head.* != 0) {
            const block: [*]u8 = @ptrFromInt(head.*);
            head.* = @as(*usize, @ptrCast(@alignCast(block))).*;
            c.child.rawFree(block[0..classSize(i)], .of(usize), @returnAddress());
        }
    }
    c.cached = 0;
}

/// The class of a block of `len` bytes, or null if the child serves it
/// directly. Each power of two has four classes, so a block wastes at most
/// a fifth of itself.
fn classOf(len: usize) ?usize {
    if (len < 1 << min_class) return null;
    const e = std.math.log2_int(usize, len);
    const step_log = e - 2;
    // 4..8: the size in quarters of 2^e, rounded up.
    const q = (len + (@as(usize, 1) << step_log) - 1) >> step_log;
    return (e - min_class) * 4 + q - 4;
}

fn classSize(class: usize) usize {
    return (4 + class % 4) << @intCast(class / 4 + min_class - 2);
}

fn lock(c: *BlockCache) void {
    while (!c.mutex.tryLock()) std.atomic.spinLoopHint();
}

fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    const c: *BlockCache = @ptrCast(@alignCast(ctx));
    const class = classOf(len) orelse return c.child.rawAlloc(len, alignment, ret_addr);
    // Cached blocks are page-aligned.
    if (alignment.toByteUnits() <= std.heap.pageSize()) {
        c.lock();
        defer c.mutex.unlock();
        const head = c.heads[class];
        if (head != 0) {
            const block: [*]u8 = @ptrFromInt(head);
            c.heads[class] = @as(*usize, @ptrCast(@alignCast(block))).*;
            c.cached -= classSize(class);
            return block;
        }
    }
    return c.child.rawAlloc(classSize(class), alignment, ret_addr);
}

fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    const c: *BlockCache = @ptrCast(@alignCast(ctx));
    const old = classOf(memory.len);
    const new = classOf(new_len);
    if (old == null and new == null) return c.child.rawResize(memory, alignment, new_len, ret_addr);
    return old != null and old == new;
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const c: *BlockCache = @ptrCast(@alignCast(ctx));
    const old = classOf(memory.len);
    const new = classOf(new_len);
    if (old == null and new == null) return c.child.rawRemap(memory, alignment, new_len, ret_addr);
    if (old == null or new == null) return null;
    if (old == new) return memory.ptr;
    return c.child.rawRemap(memory.ptr[0..classSize(old.?)], alignment, classSize(new.?), ret_addr);
}

fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
    const c: *BlockCache = @ptrCast(@alignCast(ctx));
    const class = classOf(memory.len) orelse return c.child.rawFree(memory, alignment, ret_addr);
    const size = classSize(class);
    {
        c.lock();
        defer c.mutex.unlock();
        if (c.cached + size <= c.cap) {
            @as(*usize, @ptrCast(@alignCast(memory.ptr))).* = c.heads[class];
            c.heads[class] = @intFromPtr(memory.ptr);
            c.cached += size;
            return;
        }
    }
    c.child.rawFree(memory.ptr[0..size], alignment, ret_addr);
}

test "size classes" {
    try std.testing.expectEqual(null, classOf((64 << 10) - 1));
    // Each class's size is its upper bound.
    for ([_]usize{ 64 << 10, 70 << 10, 80 << 10, 81 << 10, 127 << 10, 128 << 10, 129 << 10, 3 << 20, (3 << 20) + 1 }, [_]usize{ 64 << 10, 80 << 10, 80 << 10, 96 << 10, 128 << 10, 128 << 10, 160 << 10, 3 << 20, 7 << 19 }) |len, size| {
        try std.testing.expectEqual(size, classSize(classOf(len).?));
    }
}

test "reuses large blocks within its cap" {
    var c: BlockCache = .{ .child = std.heap.page_allocator, .cap = 3 << 17 };
    defer c.deinit();
    const a = c.allocator();
    // Small blocks go to the child.
    const small = try a.alloc(u8, 100);
    a.free(small);
    try std.testing.expectEqual(0, c.cached);
    // A block of 70 KiB is in the 80 KiB class: it grows within it in
    // place, and a freed one serves the next request of its class.
    var big = try a.alloc(u8, 70 << 10);
    try std.testing.expect(a.resize(big, 78 << 10));
    big = big.ptr[0 .. 78 << 10];
    try std.testing.expect(!a.resize(big, 81 << 10));
    try std.testing.expect(!a.resize(big, 1000));
    const p = big.ptr;
    a.free(big);
    try std.testing.expectEqual(80 << 10, c.cached);
    const again = try a.alloc(u8, 65 << 10);
    try std.testing.expectEqual(p, again.ptr);
    try std.testing.expectEqual(0, c.cached);
    // Growing past the class moves it to another, contents and all.
    again[100] = 7;
    const grown = try a.realloc(again, 200 << 10);
    try std.testing.expectEqual(7, grown[100]);
    // A 224 KiB and a 256 KiB block exceed the cap: the second goes to the
    // child.
    const other = try a.alloc(u8, 256 << 10);
    a.free(grown);
    a.free(other);
    try std.testing.expectEqual(224 << 10, c.cached);
}
