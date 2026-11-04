//! exit: 0
//! stderr: "3093136960\nnull 9\n"
//! An optional with a bool, integer, or enum payload of up to 8 bytes in
//! all lives in a register as its bytes: wrapped, unwrapped, and tested
//! for null there, with signed and unsigned payloads, the flag at byte 1,
//! 2 and 4, null constants, and optionals read from struct fields, arrays,
//! and memory written through a pointer. Prints what upstream's
//! ReleaseSafe build prints.
const std = @import("std");
const En = enum(i8) { a = -3, b = 7 };
noinline fn ft(x: u8) ?u4 {
    if (x > 3) return @truncate(x);
    return null;
}
noinline fn fi(x: i32) ?i4 {
    if (x < 0) return @truncate(x);
    return null;
}
noinline fn fb(x: u32) ?bool {
    if (x == 0) return null;
    return x > 10;
}
noinline fn f32o(x: u32) ?u32 {
    if (x % 3 == 0) return null;
    return x *% 0x9e3779b9;
}
noinline fn fe(x: u8) ?En {
    return switch (x % 3) { 0 => null, 1 => .a, else => .b };
}
noinline fn f24(x: u32) ?i24 {
    if (x & 1 == 0) return null;
    return @truncate(@as(i32, @bitCast(x)));
}
const S = struct { o: ?u8, k: u8 };
noinline fn fs(s: S) u32 {
    return if (s.o) |v| @as(u32, v) + s.k else 1000 + @as(u32, s.k);
}
noinline fn sum(xs: []const u8) u32 {
    var s: u32 = 0;
    for (xs) |x| {
        if (ft(x)) |v| s += v;
        if (fi(@as(i32, x) - 100)) |v| s +%= @bitCast(@as(i32, v));
        if (fb(x)) |b| s += @as(u32, @intFromBool(b)) * 1000;
        if (f32o(x)) |v| s +%= v;
        if (fe(x)) |e| s +%= @bitCast(@as(i32, @intFromEnum(e)));
        if (f24(x)) |v| s +%= @bitCast(@as(i32, v));
        var o: ?u16 = null;
        if (x > 50) o = x;
        if (o != null) s +%= o.? * 3;
        var arr = [_]?u8{ null, x };
        _ = &arr;
        if (arr[1]) |v| s +%= v;
        if (arr[0] == null) s +%= 1;
        s +%= fs(.{ .o = if (x > 9) x else null, .k = 2 });
    }
    return s;
}
pub fn main() void {
    const xs = [_]u8{ 1, 5, 9, 2, 200, 17, 0, 255, 33, 64, 128, 99 };
    std.debug.print("{}\n", .{sum(&xs)});
    var p: ?u8 = 5;
    const pp = &p;
    pp.* = null;
    std.debug.print("{any} {any}\n", .{ p, ft(9) });
}
