//! exit: 0
//! stderr: "21 75.5 10\n"
//! targets: x86_64-linux aarch64-macos aarch64-linux

// Floats live across calls stay in callee-saved registers (d8-d15 on
// aarch64), which every function that takes them saves and restores:
// `step` keeps eight floats across a call of itself, so each level's
// registers must survive the level below, and `scale` changes its
// caller's float variable through a pointer.
const std = @import("std");

noinline fn step(n: u32, x: f64) f64 {
    if (n == 0) return x;
    const a = x + 1;
    const b = x * 2;
    const c = a - 0.5;
    const d = b + c;
    const e: f32 = @floatCast(d);
    const f = e * 0.5;
    const g = a * b;
    const h = c + d;
    const r = step(n - 1, x + 0.25);
    return r + a + b + c + d + @as(f64, f) + g + h;
}

noinline fn scale(v: *f32) void {
    v.* *= 2;
}

pub fn main() void {
    var x: f64 = 1;
    _ = &x;
    var v: f32 = 5;
    scale(&v);
    std.debug.print("{d} {d} {d}\n", .{ step(1, x) - step(0, x) + x, step(3, x), v });
}
