//! exit: 0
//! stderr: "0 7218000 6305400 10185400 9861320 8804250 200000 7717400 20100 20100 true 11490750 3900000 40950 26520 89167 500 7020 180\n15987178197216579808 15987178197327501789 15987178197216265713 15987178197215730541 15987178197215144733 15987178197216579808 15987178197218520253 15987178197317280733 15987178197317480608 15987178197216769608 15987178197327062732 15987178197327941704 15987178197214966513 15987178197216245233 15987178197216255453 15987178197215645269 15987178197254376709 15987178197255629269 15987178197215699383 15987178197221250133 15987178197217300957\n"
//! A `@splat` of a scalar over 128 bytes, comptime-known or not, fills
//! its destination with one `rep stos` (`fillSplat`): of bytes when every
//! byte of a constant element is equal, else of the element's width.
//! A runtime one of 8 to 128 bytes is stored eight bytes at a time
//! (`splatWords`), also a negative element that sign-extends. From 129
//! bytes to 1 KB a loop of 16-byte stores fills it instead of `rep stos`
//! (`fillLoop`), as it does an `@memset` of an array of that size;
//! `edges` checks sizes at both ends of that range, with the bytes on
//! both sides of each array untouched.
const std = @import("std");
const E = enum(u16) { a = 0x1234, b = 0x0101 };
var sink: usize = 0;
noinline fn sum(b: []const u8) u64 {
    var s: u64 = 0;
    for (b, 0..) |x, i| s +%= @as(u64, x) *% (i + 1);
    return s;
}
fn bytes(p: anytype) []const u8 {
    return std.mem.asBytes(p);
}
noinline fn run(k: u8, w: u32, f: f32, p: *u8, n: i16) void {
    var a1: [400]u8 = @splat(0);
    var a2: [400]u8 = @splat(0x5a);
    var a3: [300]u16 = @splat(0x1234);
    var a4: [100]u32 = @splat(0x7f7f7f7f);
    var a5: [40]u64 = @splat(0xdead_beef_cafe_f00d);
    var a6: [300]u8 = @splat(k);
    var a7: [100]u32 = @splat(w);
    var a8: [100]f32 = @splat(f);
    var a9: [200]bool = @splat(true);
    var a10: [100]E = @splat(.b);
    var a11: [30]*u8 = @splat(p);
    var a12: [150]i16 = @splat(-2);
    var a13: [100]u32 = @splat(@as(u32, k) << 8);
    var a14: [20]u8 = @splat(k);
    var a15: [16]u8 = @splat(k);
    var a16: [13]i16 = @splat(n);
    var a17: [5]u32 = @splat(w);
    var a18: [8]u8 = @splat(k);
    var a19: [3]u32 = @splat(w);
    _ = .{ &a1, &a2, &a3, &a4, &a5, &a6, &a7, &a8, &a9, &a10, &a11, &a12, &a13, &a14, &a15, &a16, &a17, &a18, &a19 };
    std.debug.print("{d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {} {d} {d} {d} {d} {d} {d} {d} {d}\n", .{
        sum(bytes(&a1)),  sum(bytes(&a2)),  sum(bytes(&a3)),  sum(bytes(&a4)),  sum(bytes(&a5)),  sum(bytes(&a6)),
        sum(bytes(&a7)),  sum(bytes(&a8)),  sum(bytes(&a9)),  sum(bytes(&a10)), a11[29] == p,     sum(bytes(&a12)),
        sum(bytes(&a13)), sum(bytes(&a14)), sum(bytes(&a15)), sum(bytes(&a16)), sum(bytes(&a17)), sum(bytes(&a18)),
        sum(bytes(&a19)),
    });
}
fn Guarded(comptime T: type, comptime n: usize) type {
    return extern struct { lo: u64 = 0x1111_1111_1111_1111, a: [n]T, hi: u64 = 0x2222_2222_2222_2222 };
}
noinline fn edge(comptime T: type, comptime n: usize, v: T) u64 {
    var g: Guarded(T, n) = .{ .a = @splat(v) };
    _ = &g;
    return sum(bytes(&g.a)) +% g.lo *% 3 +% g.hi *% 5;
}
noinline fn edgeConst(comptime T: type, comptime n: usize, comptime v: T) u64 {
    var g: Guarded(T, n) = .{ .a = @splat(v) };
    _ = &g;
    return sum(bytes(&g.a)) +% g.lo *% 3 +% g.hi *% 5;
}
noinline fn memsetEdge(comptime T: type, comptime n: usize, v: T) u64 {
    var g: Guarded(T, n) = .{ .a = undefined };
    @memset(&g.a, v);
    return sum(bytes(&g.a)) +% g.lo *% 3 +% g.hi *% 5;
}
noinline fn edges(k: u8, h: u16, w: u32, q: u64) void {
    std.debug.print("{d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d}\n", .{
        memsetEdge(u8, 129, k),                     memsetEdge(u16, 512, h), memsetEdge(u32, 257, w),  memsetEdge(u64, 18, q),
        memsetEdge(f32, 100, @bitCast(w)),          edge(u8, 129, k),        edge(u8, 191, k),         edge(u8, 1024, k),
        edge(u8, 1025, k),                          edge(u16, 65, h),        edge(u16, 511, h),        edge(u16, 513, h),
        edge(u32, 33, w),                           edge(u32, 255, w),       edge(u32, 256, w),        edge(u64, 17, q),
        edge(u64, 127, q),                          edge(u64, 129, q),       edgeConst(u8, 129, 0x5a), edgeConst(u16, 300, 0x1234),
        edgeConst(u64, 128, 0x0102_0304_0506_0708),
    });
}
pub fn main() void {
    var x: u8 = 1;
    run(0xc3, 0x01020304, -1.5, &x, -3);
    edges(0xc3, 0xbeef, 0x01020304, 0x1122_3344_5566_7788);
}
