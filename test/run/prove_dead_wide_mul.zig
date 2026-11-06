//! exit: 0
//! stderr: "7\n"
//! Under `x < n` with `n` 0, `x` has an empty range, so the branch never
//! runs. Prove must decide nothing from it: asking whether the u128
//! product overflows read the widened operand's largest value, `hi = -1`,
//! and crashed casting it to u64.
const std = @import("std");
var g: u64 = 7;
var h: u128 = 9;

pub fn main() void {
    var n: u64 = 0;
    _ = &n;
    const x = g;
    if (x < n) {
        const p = @as(u128, @as(u32, @truncate(x))) * h;
        std.debug.print("{}\n", .{p});
    }
    std.debug.print("{}\n", .{x});
}
