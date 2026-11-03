//! std.AutoHashMap(u64, u64): hashing, probing, growth, and lookups.
const std = @import("std");

/// Exported and mutable, so no compiler treats the problem size as known.
export var scale: usize = 1;

pub fn main() void {
    const n: u64 = (1 << 18) * scale;
    var map: std.AutoHashMap(u64, u64) = .init(std.heap.page_allocator);
    defer map.deinit();
    var i: u64 = 0;
    while (i < n) : (i += 1) map.put(i *% 0x9e3779b97f4a7c15, i) catch @panic("oom");
    var sum: u64 = 0;
    i = 0;
    while (i < 4 * n) : (i += 1) {
        if (map.get((i % (2 * n)) *% 0x9e3779b97f4a7c15)) |v| sum +%= v;
    }
    std.debug.print("{d} {d}\n", .{ map.count(), sum });
}
