//! exit: 0
//! stdout: "fffffffe 1 ffffffff 80000000 7fffffff 0 1 0 100 f\n4091724160 32769 16712064 -186465920 -257 3477570305 16744449 32767 0 7 14 3\n"
//! targets: x86_64-linux aarch64-macos aarch64-linux
//! A u32 result of arithmetic that wraps, and the bit operations at 32
//! bits and below, have no bits above their type when widened (aarch64
//! computes them on w registers, which zero-extend).
const std = @import("std");

noinline fn ops(a: u32, b: u32, k: u5) [10]u64 {
    return .{
        a +% a,
        a *% a,
        b -% a,
        a << k,
        a >> 1,
        (b -% a) +% 1,
        ~(a -% 1),
        ~a,
        a / (b >> 8),
        a % (b >> 4),
    };
}

noinline fn bitops(a: u32, h: u16, t: u24, i: i32, j: i16) [12]i64 {
    return .{
        @byteSwap(a),
        @byteSwap(h),
        @byteSwap(t),
        @byteSwap(i),
        @byteSwap(j),
        @bitReverse(a),
        @bitReverse(t),
        @bitReverse(j),
        @clz(t),
        @ctz(h),
        @popCount(a),
        @clz(a >> 3),
    };
}

pub fn main(init: std.process.Init) !void {
    var buf: [128]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &buf);
    const w = &fw.interface;
    const r = ops(0xffffffff, 0xfffffffe, 31);
    for (r, 0..) |x, i| try w.print("{x}{s}", .{ x, if (i == r.len - 1) "\n" else " " });
    const b = bitops(0x80c1e2f3, 0x0180, 0x8001ff, -0x7f3e1d0c, -2);
    for (b, 0..) |x, i| try w.print("{d}{s}", .{ x, if (i == b.len - 1) "\n" else " " });
    try w.flush();
}
