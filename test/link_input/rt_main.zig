//! Calls test/link_input/rt.c, whose compiler_rt references zap resolves
//! as upstream does (build.zig, `addLinkInputTests`).
const std = @import("std");
extern fn rt_widen(d: f64) f128;
extern fn rt_narrow(q: f128) f64;
extern fn rt_eq(a: f128, b: f128) c_int;
extern fn rt_lt(a: f128, b: f128) c_int;
extern fn rt_mul(a: f128, b: f128) f128;
extern fn rt_to_int(q: f128) c_longlong;
extern fn rt_half_up(h: f16) f32;
extern fn rt_half_down(f: f32) f16;
extern fn rt_div(a: u128, b: u128) c_ulonglong;
extern fn rt_atomic(x: c_long) c_long;
extern fn rt_cpu() c_int;
pub fn main() void {
    const q = rt_widen(1.5);
    std.debug.print("{d} {d} {d} {d} {d} {d} {d} {d} {d}\n", .{
        rt_narrow(rt_mul(q, q)),
        rt_eq(q, rt_widen(1.5)),
        rt_lt(q, rt_widen(1.25)),
        rt_to_int(rt_mul(q, rt_widen(-4))),
        rt_half_up(rt_half_down(0.375)),
        rt_div(@as(u128, 1) << 100, @as(u128, 1) << 90),
        rt_atomic(5),
        @as(f32, rt_half_down(2.5)),
        rt_cpu(),
    });
}
