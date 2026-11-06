//! exit: 0
//! stderr: "2 4 18446744073709551611 1 10 1\n1 -9223372036854775807 4 -9223372036854775808 18446744073709551611 4\n"
//! Overflow operations on constants, folded once inlining substitutes
//! them (`rewrite.overflowConst`): products of two u64s up to
//! (2^64-1)^2, which does not fit an i128, and the signed and additive
//! extremes.
const std = @import("std");

fn f(a: u64, b: u64) u64 {
    const r = @mulWithOverflow(a, b);
    return r[0] +% r[1];
}

fn mulU(a: u64, b: u64) u64 {
    const r = @mulWithOverflow(a, b);
    return r[0] *% 3 +% r[1];
}

fn mulI(a: i64, b: i64) i64 {
    const r = @mulWithOverflow(a, b);
    return r[0] *% 3 +% r[1];
}

fn addU(a: u64, b: u64) u64 {
    const r = @addWithOverflow(a, b);
    return r[0] *% 3 +% r[1];
}

fn subI(a: i64, b: i64) i64 {
    const r = @subWithOverflow(a, b);
    return r[0] *% 3 +% r[1];
}

pub fn main() void {
    const M = std.math.maxInt(u64);
    const lo = std.math.minInt(i64);
    const hi = std.math.maxInt(i64);
    std.debug.print("{} {} {} {} {} {}\n", .{ f(M, M), mulU(M, M), mulU(M, 2), mulU(1 << 63, 1 << 63), mulU((1 << 63) + 1, (1 << 63) + 3), mulU(1 << 32, 1 << 32) });
    std.debug.print("{} {} {} {} {} {}\n", .{ mulI(lo, lo), mulI(lo, -1), mulI(hi, hi), mulI(lo, 1), addU(M, M), subI(lo, hi) });
}
