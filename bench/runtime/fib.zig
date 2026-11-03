//! Recursive calls: call overhead, argument passing, and the return path.
const std = @import("std");

/// Exported and mutable, so no compiler treats the problem size as known.
export var scale: usize = 1;

fn fib(n: u32) u64 {
    return if (n < 2) n else fib(n - 1) + fib(n - 2);
}

pub fn main() void {
    const n: u32 = 35 + @as(u32, @intCast(scale));
    std.debug.print("{d}\n", .{fib(n)});
}
