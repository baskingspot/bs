//! exit: 0
//! stderr: "4 2.5 4\n"
//! A float block result computed in its register before a call (the
//! left operand of `e.from + ... * ease(..)`) lives across the call: the
//! block keeps its XMM register, and the call saves it, also when the
//! block result is the operand's register (`Live.share`).
const std = @import("std");
pub const Curve = enum { ease_out, ease_in_out, linear };
const Entry = struct { value: f32, target: f32, from: f32 = 0, elapsed: f32 = 0 };
noinline fn tween(e: *Entry, target: f32, duration: f32, curve: Curve) f32 {
    const p = e.elapsed / duration;
    return if (p >= 1) target else e.from + (target - e.from) * ease(curve, p);
}
pub noinline fn ease(curve: Curve, x: f32) f32 {
    const p: [4]f32 = switch (curve) {
        .linear => return x,
        .ease_out => .{ 0, 0, 0.58, 1 },
        .ease_in_out => .{ 0.42, 0, 0.58, 1 },
    };
    var t = x;
    t = t * p[2];
    return t + p[1];
}
pub fn main() void {
    var a: Entry = .{ .value = 4, .target = 4, .from = 4, .elapsed = 0.05 };
    var b: Entry = .{ .value = 0, .target = 4, .from = 1, .elapsed = 0.075 };
    var c: Entry = .{ .value = 0, .target = 4, .from = 1, .elapsed = 0.3 };
    std.debug.print("{d} {d} {d}\n", .{ tween(&a, 4, 0.15, .ease_out), tween(&b, 4, 0.15, .linear), tween(&c, 4, 0.15, .ease_out) });
}
