//! Win64 calls between Zig and C (win64.c); upstream prints the same.
const std = @import("std");
const win: std.lang.CallingConvention = .{ .x86_64_win = .{} };
const ByRef = extern struct { val: c_int, arr: [15]c_int };
const S3 = extern struct { a: u8, b: u8, c: u8 };
const S8 = extern struct { a: u32, b: u32 };
const D2 = extern struct { x: f64, y: f64 };
extern fn c_win_byref(ByRef) callconv(win) ByRef;
extern fn c_win_mix(c_int, f64, S8, f32, S3, D2, c_longlong, f64) callconv(win) f64;
extern fn c_win_s8(S8) callconv(win) S8;
extern fn c_win_u128(u128) callconv(win) u128;
extern fn c_win_va(c_int, ...) callconv(win) void;
extern fn c_calls(*const fn (c_int, f64, S8, f32, S3, D2, c_longlong, f64) callconv(win) f64) void;
extern fn fflush(?*anyopaque) c_int;
export fn zig_win_mix(a: c_int, b: f64, s: S8, c: f32, t: S3, d: D2, e: c_longlong, f: f64) callconv(win) f64 {
    std.debug.print("zig_win_mix {} {d} {} {} {d} {} {} {} {d} {d} {} {d}\n", .{ a, b, s.a, s.b, c, t.a, t.b, t.c, d.x, d.y, e, f });
    return @as(f64, @floatFromInt(a)) + b + c + @as(f64, @floatFromInt(e)) + f;
}
export fn zig_win_byref(in: ByRef) callconv(win) ByRef {
    var r = in;
    r.val *= 3;
    return r;
}
// Variadic: C passes `b` (a ByRef) by reference, floats in both
// registers.
export fn zig_win_va(n: c_int, ...) callconv(win) f64 {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    var s: f64 = 0;
    var i: c_int = 0;
    while (i < n) : (i += 1) {
        s += @cVaArg(&ap, f64);
        s += @floatFromInt(@cVaArg(&ap, u64));
    }
    var cp = @cVaCopy(&ap);
    defer @cVaEnd(&cp);
    const b = @cVaArg(&ap, ByRef);
    return s + @as(f64, @floatFromInt(b.val + b.arr[14] + @cVaArg(&ap, c_int) + @cVaArg(&cp, ByRef).val));
}
export fn zig_win_sum(n: c_int, ...) callconv(win) c_int {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    var s: c_int = 0;
    var i: c_int = 0;
    while (i < n) : (i += 1) s += @cVaArg(&ap, c_int);
    return s;
}
pub fn main() void {
    var b: ByRef = .{ .val = 1, .arr = undefined };
    b.arr[3] = 9;
    const r = c_win_byref(b);
    const m = c_win_mix(1, 2.5, .{ .a = 3, .b = 4 }, 5.5, .{ .a = 6, .b = 7, .c = 8 }, .{ .x = 9.5, .y = 10.5 }, 11, 12.5);
    const s = c_win_s8(.{ .a = 1, .b = 2 });
    const u = c_win_u128((@as(u128, 7) << 64) | std.math.maxInt(u64));
    c_win_va(4, @as(u64, 1), @as(f64, 2.5), @as(u64, 3), @as(f64, 4.5));
    _ = fflush(null);
    std.debug.print("byref {} {} mix {d} s8 {} {} u128 {x}\n", .{ r.val, r.arr[3], m, s.a, s.b, u });
    c_calls(&zig_win_mix);
    std.debug.print("sum {}\n", .{zig_win_sum(3, @as(c_int, 1), @as(c_int, 2), @as(c_int, 39))});
}
