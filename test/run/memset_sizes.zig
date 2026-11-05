//! exit: 0
//! stderr: "222741200 222742127 222743157 222744290 222745526 222746865 222749852 222751500 222753251 222765920 222768392 222770967 222817832 222821952 222826175 223000760 223008176 223015695 226313240 226340432 226367727 275116700 277639376 277745775 286019250 \n222741200 222741200 222743649 222743649 222746610 222746610 222750083 222754068 222754068 222769095 222775128 222775128 222831695 222841824 222841824 223055199 223073520 223073520 227148735 227216208 227216208 287837700 290972880 290972880 301387350 \n222741200 222741200 222741200 222741200 222737132 222737132 222737132 222732144 222732144 222726236 222719408 222719408 222693404 222682896 222682896 222583580 222565712 222565712 220688156 220626128 220626128 193089200 191670992 191670992 186961500 \n222741200 222741200 222741200 222741200 222741200 222741200 222741200 222738936 222738936 222738936 222735680 222735680 222731432 222726192 222726192 222704520 222695312 222695312 222209736 222176720 222176720 214770200 214388432 214388432 213189560 \n222741200 222741200 222741200 222741200 222741740 222741740 222741740 222742340 222742340 222743000 222743720 222743720 222746240 222747200 222747200 222755600 222757040 222757040 222892400 222896720 222896720 224743700 224837840 224837840 225150200 \n222741200 222740372 222739452 222738440 222737336 222736140 222733472 222732000 222730436 222719120 222716912 222714612 222672752 222669072 222665300 222509360 222502736 222496020 219550640 219526352 219501972 175959200 173705936 173610900 166221000 \n15987178197214944928 15987178197214945903 15987178197214950193 15987178197214968133 15987178197214971253 15987178197214974568 15987178197215929483 15987178197216554653 15987178197214945410 15987178197214949404 15987178197214974789 15987178197214982506 15987178197216762141 15987178197214945265 15987178197214947985 15987178197214952913 15987178197215235549 15987178197214946773 15987178197214953709 15987178197214965541 15987178197215564893 15987178197214986285 15987178197605139733 15987178197239861533 15987178197214948783 15987178197215153433 15987178197214959160 15987178197214948213 \n"
//! `@memset` of 1-, 2-, 4- and 8-byte elements at the edges of its size
//! classes. A slice's length in bytes picks two overlapping stores up to
//! 16, 16-byte stores from both ends up to 64, a loop of 64-byte blocks
//! up to 1 KB, and `rep stos` above; an array's known size picks
//! straight stores up to 128 bytes. Elements are runtime values (also negative ones, whose upper register bits must
//! not leak into the pattern) and constants, and the words on both sides
//! of each destination must stay untouched.
const std = @import("std");

var buf: [2200]u8 align(16) = undefined;

fn sum(b: []const u8) u64 {
    var s: u64 = 0;
    for (b, 0..) |x, i| s +%= @as(u64, x) *% (i + 1);
    return s;
}

/// Fills `n` elements at byte offset `at` of `buf` with `v` and sums
/// `buf`, guards included.
noinline fn slice(comptime T: type, at: usize, n: usize, v: T) u64 {
    @memset(&buf, 0x5c);
    const p: [*]T = @ptrCast(@alignCast(&buf[at]));
    @memset(p[0..n], v);
    return sum(&buf);
}

fn Guarded(comptime T: type, comptime n: usize) type {
    return extern struct { lo: u64 = 0x1111_1111_1111_1111, a: [n]T, hi: u64 = 0x2222_2222_2222_2222 };
}

noinline fn array(comptime T: type, comptime n: usize, v: T) u64 {
    var g: Guarded(T, n) = .{ .a = undefined };
    @memset(&g.a, v);
    return sum(std.mem.asBytes(&g.a)) +% g.lo *% 3 +% g.hi *% 5;
}

noinline fn arrayConst(comptime T: type, comptime n: usize, comptime v: T) u64 {
    var g: Guarded(T, n) = .{ .a = undefined };
    @memset(&g.a, v);
    return sum(std.mem.asBytes(&g.a)) +% g.lo *% 3 +% g.hi *% 5;
}

fn line(vals: []const u64) void {
    for (vals) |v| std.debug.print("{d} ", .{v});
    std.debug.print("\n", .{});
}

noinline fn run(k: u8, h: i16, w: u32, q: u64, f: f32) void {
    const lens = [_]usize{ 0, 1, 2, 3, 4, 5, 7, 8, 9, 15, 16, 17, 31, 32, 33, 63, 64, 65, 255, 256, 257, 1000, 1024, 1025, 1100 };
    var r: [lens.len]u64 = undefined;
    for (lens, &r) |n, *o| o.* = slice(u8, 8, n, k);
    line(&r);
    for (lens, &r) |n, *o| o.* = slice(i16, 8, n / 2, h);
    line(&r);
    for (lens, &r) |n, *o| o.* = slice(u32, 16, n / 4, w);
    line(&r);
    for (lens, &r) |n, *o| o.* = slice(u64, 8, n / 8, q);
    line(&r);
    for (lens, &r) |n, *o| o.* = slice(f32, 8, n / 4, f);
    line(&r);
    for (lens, &r) |n, *o| o.* = slice(u8, 8, n, 0);
    line(&r);
    line(&.{
        array(u8, 1, k),         array(u8, 3, k),         array(u8, 7, k),                 array(u8, 15, k),
        array(u8, 16, k),        array(u8, 17, k),        array(u8, 100, k),               array(u8, 128, k),
        array(i16, 1, h),        array(i16, 3, h),        array(i16, 8, h),                array(i16, 9, h),
        array(i16, 64, h),       array(u32, 1, w),        array(u32, 3, w),                array(u32, 5, w),
        array(u32, 32, w),       array(u64, 1, q),        array(u64, 2, q),                array(u64, 3, q),
        array(u64, 16, q),       array(f32, 7, f),        array(u8, 2000, k),              array(u32, 300, w),
        arrayConst(u8, 9, 0x5a), arrayConst(i16, 20, -2), arrayConst(u32, 7, 0x8000_0001), arrayConst(u64, 5, 0x0102_0304_0506_0708),
    });
}

pub fn main() void {
    run(0xc3, -0x1235, 0x8102_0304, 0x1122_3344_5566_7788, -1.5);
}
