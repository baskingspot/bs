//! SysV aggregates between Zig and C, both ways (abi.c); upstream prints
//! the same.
const std = @import("std");

const S16 = extern struct { a: u64, b: u64 };
const D2 = extern struct { x: f64, y: f64 };
const F3 = extern struct { x: f32, y: f32, z: f32 };
const MIX = extern struct { a: u32, f: f32, d: f64 };
const DSI = extern struct { d: f64, c: [3]u8 };
const S3 = extern struct { a: u8, b: u8, c: u8 };
const S24 = extern struct { a: u64, b: u64, c: u64 };

extern fn c_s16(S16, D2, F3) S16;
extern fn c_mix(MIX, DSI, S3) MIX;
extern fn c_f3() F3;
extern fn c_s24(S24) S24;
extern fn c_dsi(c_int, S16, S16, S16, MIX) DSI;
extern fn c_va(n: c_int, ...) f64;
extern fn c_calls_zig(*const fn (S16, D2, F3) callconv(.c) S16) void;
extern fn fflush(?*anyopaque) c_int;

export fn zig_s16(s: S16, d: D2, f: F3) S16 {
    std.debug.print("zig_s16 {} {} {d} {d} {d} {d} {d}\n", .{ s.a, s.b, d.x, d.y, f.x, f.y, f.z });
    return .{ .a = s.a * 3, .b = s.b * 3 };
}
export fn zig_mix(m: MIX, d: DSI, s: S3) MIX {
    std.debug.print("zig_mix {} {d} {d} {d} {any} {} {} {}\n", .{ m.a, m.f, m.d, d.d, d.c, s.a, s.b, s.c });
    return .{ .a = m.a + 100, .f = m.f + 100, .d = m.d + 100 };
}
export fn zig_dsi(i: c_int, a: S16, b: S16, c: S16, m: MIX) DSI {
    std.debug.print("zig_dsi {} {} {} {} {} {} {} {} {d} {d}\n", .{ i, a.a, a.b, b.a, b.b, c.a, c.b, m.a, m.f, m.d });
    return .{ .d = 0.75, .c = .{ 1, 2, 3 } };
}
export fn zig_va(n: c_int, ...) callconv(.c) f64 {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    var sum: f64 = 0;
    for (0..@intCast(n)) |_| {
        const m = @cVaArg(&ap, MIX);
        const d = @cVaArg(&ap, D2);
        sum += @as(f64, @floatFromInt(m.a)) + m.f + m.d + d.x + d.y;
    }
    return sum;
}

pub fn main() void {
    const s = c_s16(.{ .a = 1, .b = 2 }, .{ .x = 0.5, .y = 1.5 }, .{ .x = 4, .y = 5, .z = 6 });
    const m = c_mix(.{ .a = 7, .f = 0.5, .d = 3.25 }, .{ .d = 9.5, .c = .{ 10, 11, 12 } }, .{ .a = 13, .b = 14, .c = 15 });
    const f = c_f3();
    const l = c_s24(.{ .a = 1, .b = 2, .c = 3 });
    const d = c_dsi(5, .{ .a = 1, .b = 2 }, .{ .a = 3, .b = 4 }, .{ .a = 5, .b = 6 }, .{ .a = 7, .f = 8, .d = 9 });
    _ = fflush(null);
    std.debug.print("{} {} | {} {d} {d} | {d} {d} {d} | {} {} {} | {d} {any}\n", .{ s.a, s.b, m.a, m.f, m.d, f.x, f.y, f.z, l.a, l.b, l.c, d.d, d.c });
    std.debug.print("c_va {d}\n", .{c_va(2, MIX{ .a = 1, .f = 2, .d = 3 }, D2{ .x = 4, .y = 5 }, MIX{ .a = 6, .f = 7, .d = 8 }, D2{ .x = 9, .y = 10 })});
    c_calls_zig(&zig_s16);
}
