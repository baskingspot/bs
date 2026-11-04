//! `@Vector(128, bool)` C arguments between Zig and C (vecbool.c); upstream prints the same.
const std = @import("std");
const V = @Vector(128, bool);
extern fn c_v(V) void;
extern fn c_iv(c_long, c_long, c_long, V, c_long) void;
extern fn c_v7(c_long, c_long, c_long, c_long, c_long, c_long, V, c_long) void;
extern fn c_calls_zig() void;
fn show(n: []const u8, v: V) void {
    var buf: [128]u8 = undefined;
    inline for (0..128) |i| buf[i] = if (v[i]) '1' else '0';
    std.debug.print("{s} {s}\n", .{ n, &buf });
}
export fn zig_v(v: V) void {
    show("zig_v", v);
}
export fn zig_iv(a: c_long, b: c_long, c: c_long, v: V, d: c_long) void {
    std.debug.print("zig_iv {} {} {} {}", .{ a, b, c, d });
    show("", v);
}
pub fn main() void {
    var v: V = @splat(false);
    inline for (0..128) |i| v[i] = (i % 3 == 0) or i == 127;
    c_v(v);
    c_iv(1, 2, 3, v, 4);
    c_v7(1, 2, 3, 4, 5, 6, v, 7);
    const p: *const fn (V) callconv(.c) void = &c_v;
    p(v);
    c_calls_zig();
}
