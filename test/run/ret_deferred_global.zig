//! exit: 0
//! stderr: "30 30 10 0\n"
//! A result over 16 bytes returned from a global's memory is copied to
//! the caller's result memory also when the function has no result alloc
//! of its own (`rvo_alloc` null): the load the `ret` reads in place is
//! of a constant address, which must not pass for that alloc.
const std = @import("std");
var cache: struct { t: f64 = -1, m: [4]f64 = .{ 0, 0, 0, 0 } } = .{};
var whole: [4]u64 = .{ 1, 2, 3, 4 };
noinline fn matrix(t: f64) [4]f64 {
    if (t == cache.t) return cache.m;
    const m: [4]f64 = .{ t, t * 2, t * 3, t * 4 };
    cache = .{ .t = t, .m = m };
    return m;
}
noinline fn global(fresh: bool) [4]u64 {
    if (!fresh) return whole;
    const z: [4]u64 = .{ 0, 0, 0, 0 };
    return z;
}
fn sum(a: anytype) u64 {
    var s: u64 = 0;
    for (a) |x| s += @intFromFloat(@as(f64, if (@TypeOf(x) == f64) x else @floatFromInt(x)));
    return s;
}
pub fn main() void {
    const a = matrix(3);
    const b = matrix(3);
    std.debug.print("{d} {d} {d} {d}\n", .{ sum(a), sum(b), sum(global(false)), sum(global(true)) });
}
