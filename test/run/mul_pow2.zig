//! exit: 0
//! stderr: "c4dd8590c52734a5\n"
//! targets: x86_64-linux aarch64-macos aarch64-linux

// Multiplies by a constant power of two, which aarch64 lowers as shifts
// left: wrapping, and `@mulWithOverflow` with its bit stored, branched on
// from the flags, and its value used in registers, with the constant on
// either side, at both ends of each type's range of shifts.
const std = @import("std");

noinline fn wrapR(comptime T: type, comptime c: T, x: T) T {
    return x *% c;
}
noinline fn wrapL(comptime T: type, comptime c: T, x: T) T {
    return c *% x;
}
noinline fn ovfR(comptime T: type, comptime c: T, x: T) struct { T, u1 } {
    const r = @mulWithOverflow(x, c);
    return .{ r[0], r[1] };
}
noinline fn ovfL(comptime T: type, comptime c: T, x: T) struct { T, u1 } {
    const r = @mulWithOverflow(c, x);
    return .{ r[0], r[1] };
}
noinline fn ovfBranch(comptime T: type, comptime c: T, x: T) u32 {
    const r = @mulWithOverflow(x, c);
    return if (r[1] != 0) 7 else 3;
}
noinline fn ovfUse(comptime T: type, comptime c: T, x: T) T {
    const v, const o = @mulWithOverflow(x, c);
    return (v >> 1) ^ @divTrunc(v, 3) +% @as(T, o);
}

var h: u64 = 0;
fn mix(v: anytype) void {
    h = (h ^ @as(u64, @truncate(@as(u128, @bitCast(@as(i128, v)))))) *% 0x100000001b3;
}

fn run(comptime T: type) void {
    const bits = @typeInfo(T).int.bits;
    const signed = @typeInfo(T).int.signedness == .signed;
    const max = std.math.maxInt(T);
    const min = std.math.minInt(T);
    inline for (.{ 1, 2, 7, bits - 2, bits - 1 }) |k| if (k >= 1 and k < bits - @intFromBool(signed)) {
        const c: T = 1 << k;
        const edges = [_]comptime_int{ 0, 1, 3, max, max - 1, min, min + 1, max >> k, (max >> k) + 1, min >> k, (min >> k) - 1, -1, max >> 1, min >> 1 };
        var xs: [edges.len + 8]T = undefined;
        inline for (edges, 0..) |v, i| xs[i] = if (v >= min and v <= max) v else 0;
        var rnd = std.Random.DefaultPrng.init(@as(u64, k) * 7919 + bits);
        for (xs[edges.len..]) |*x| x.* = rnd.random().int(T);
        for (xs) |x| {
            mix(wrapR(T, c, x));
            mix(wrapL(T, c, x));
            const a = ovfR(T, c, x);
            mix(a[0]);
            mix(a[1]);
            const b = ovfL(T, c, x);
            mix(b[0]);
            mix(b[1]);
            mix(ovfBranch(T, c, x));
            mix(ovfUse(T, c, x));
        }
    };
}

pub fn main() void {
    inline for (.{ u8, i8, u16, i32, u33, i33, u63, u64, i64 }) |T| run(T);
    std.debug.print("{x}\n", .{h});
}
