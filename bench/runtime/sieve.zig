//! Sieve of Eratosthenes: tight loops over a byte array, with bounds checks.
const std = @import("std");

/// Exported and mutable, so no compiler treats the problem size as known.
export var scale: usize = 1;

pub fn main() void {
    const n: usize = (8 << 20) * scale;
    const flags = std.heap.page_allocator.alloc(bool, n) catch @panic("oom");
    defer std.heap.page_allocator.free(flags);
    var total: usize = 0;
    var round: usize = 0;
    while (round < 4) : (round += 1) {
        @memset(flags, true);
        flags[0] = false;
        flags[1] = false;
        var i: usize = 2;
        while (i * i < n) : (i += 1) {
            if (!flags[i]) continue;
            var j = i * i;
            while (j < n) : (j += i) flags[j] = false;
        }
        var count: usize = 0;
        for (flags) |f| count += @intFromBool(f);
        total += count;
    }
    std.debug.print("{d}\n", .{total});
}
