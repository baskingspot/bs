//! exit: 0
//! stderr: "0 7218000 6305400 10185400 9861320 8804250 200000 7717400 20100 20100 true 11490750 3900000 40950\n"
//! A `@splat` of a scalar over 128 bytes, comptime-known or not, fills
//! its destination with one `rep stos` (`fillSplat`): of bytes when every
//! byte of a constant element is equal, else of the element's width.
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
noinline fn run(k: u8, w: u32, f: f32, p: *u8) void {
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
    _ = .{ &a1, &a2, &a3, &a4, &a5, &a6, &a7, &a8, &a9, &a10, &a11, &a12, &a13, &a14 };
    std.debug.print("{d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {} {d} {d} {d}\n", .{
        sum(bytes(&a1)), sum(bytes(&a2)), sum(bytes(&a3)), sum(bytes(&a4)), sum(bytes(&a5)), sum(bytes(&a6)),
        sum(bytes(&a7)), sum(bytes(&a8)), sum(bytes(&a9)), sum(bytes(&a10)), a11[29] == p, sum(bytes(&a12)), sum(bytes(&a13)), sum(bytes(&a14)),
    });
}
pub fn main() void {
    var x: u8 = 1;
    run(0xc3, 0x01020304, -1.5, &x);
}
