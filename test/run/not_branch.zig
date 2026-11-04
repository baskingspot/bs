//! exit: 0
//! stderr: "2 1 101 110 111\n42 7 5 9\n5 3 135 4 6\n0 1 200 999\n"
//! A branch on `!cond` tests the flags of cond negated: integer and
//! float comparisons (unordered NaN), optionals, error unions, an overflow
//! bit, a bool, and a condition that is also read as a value or negated
//! twice. Prints what upstream's ReleaseSafe build prints.
const std = @import("std");
noinline fn lt(a: i32, b: i32) u32 {
    if (!(a < b)) return 1;
    return 2;
}
noinline fn fl(a: f64, b: f64) u32 {
    var r: u32 = 0;
    if (!(a > b)) r += 1;
    if (!(a <= b)) r += 10;
    if (!(a == b)) r += 100;
    return r;
}
noinline fn opt(p: ?*u32) u32 {
    if (!(p == null)) return p.?.*;
    return 7;
}
noinline fn eu(x: anyerror!u32) u32 {
    const ok = if (x) |_| true else |_| false;
    if (!ok) return 9;
    return x catch unreachable;
}
noinline fn multi(a: u64, b: u64) u64 {
    const c = a == b;
    if (!c) return @as(u64, @intFromBool(c)) + 5;
    return 3;
}
noinline fn loop(n: u32) u32 {
    var i: u32 = 0;
    var s: u32 = 0;
    while (!(i >= n)) : (i += 1) s +%= i * 3;
    return s;
}
noinline fn plain(b: bool) u32 {
    if (!b) return 4;
    return 6;
}
noinline fn dbl(a: u8) u32 {
    if (!!(a > 3)) return 1;
    return 0;
}
noinline fn ovf(a: u8, b: u8) u32 {
    const r = @addWithOverflow(a, b);
    if (!(r[1] == 1)) return r[0];
    return 999;
}
pub fn main() void {
    var u: u32 = 42;
    std.debug.print("{} {} {} {} {}\n", .{ lt(1, 2), lt(3, 2), fl(1, 2), fl(2, 1), fl(std.math.nan(f64), 1) });
    std.debug.print("{} {} {} {}\n", .{ opt(&u), opt(null), eu(5), eu(error.X) });
    std.debug.print("{} {} {} {} {}\n", .{ multi(1, 2), multi(2, 2), loop(10), plain(false), plain(true) });
    std.debug.print("{} {} {} {}\n", .{ dbl(2), dbl(9), ovf(100, 100), ovf(200, 100) });
}
