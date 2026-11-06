//! signal: ABRT
//! stderr-contains: "panic: integer overflow\n"
//! stderr-contains: "prove_dead_loop.zig:15:15: 0x"
//! The code after `g - 5`, a checked sub that always overflows here, never
//! runs: its facts (the sub did not overflow) give `v` an empty range. Prove
//! still walks the loop after it and must not take that range's bounds for
//! a bound on `v` (it crashed casting `hi = -1` to u64). The sub's check
//! stays and fails as upstream's does.
const std = @import("std");
var g: u64 = 3;

pub fn main() void {
    if (g < 5) {
        var v: u64 = 1;
        v = g - 5;
        var s: u64 = 0;
        for (0..g) |j| s +%= j;
        std.debug.print("{} {}\n", .{ v, s });
    }
}
