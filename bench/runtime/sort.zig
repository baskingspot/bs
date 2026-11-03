//! std.mem.sort (block sort) and std.mem.sortUnstable (pdqsort) on u32s:
//! generic std code, comparator calls, and memory traffic.
const std = @import("std");

/// Exported and mutable, so no compiler treats the problem size as known.
export var scale: usize = 1;

pub fn main() void {
    const n: usize = (1 << 19) * scale;
    const gpa = std.heap.page_allocator;
    const a = gpa.alloc(u32, n) catch @panic("oom");
    defer gpa.free(a);
    const b = gpa.alloc(u32, n) catch @panic("oom");
    defer gpa.free(b);
    var x: u32 = 2463534242;
    for (a, b) |*p, *q| {
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        p.* = x;
        q.* = x;
    }
    std.mem.sort(u32, a, {}, std.sort.asc(u32));
    std.mem.sortUnstable(u32, b, {}, std.sort.asc(u32));
    var sum: u64 = 0;
    for (a, b, 0..) |p, q, i| {
        if (p != q) @panic("sorts disagree");
        sum +%= @as(u64, p) *% i;
    }
    std.debug.print("{d}\n", .{sum});
}
