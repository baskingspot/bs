//! signal: ABRT
//! stderr: "panic: index out of bounds: index 18446744073709551611, len 64\n"
//! Proving checks (docs/architecture.md, "Proving checks"): `i +% 32 <
//! len` gives no bound on `i + 16`, since `+%` wraps: with `i` 20 below
//! the largest `usize`, `i +% 32` is 11, so `s[i..][0..16]` keeps its
//! checks.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

var g: usize = ~@as(usize, 0) - 20;
var n: usize = 64;

fn main() callconv(.c) noreturn {
    const a: [64]u8 = @splat(7);
    const s: []const u8 = a[0..n];
    const i = g;
    if (i +% 32 < s.len) rt.exit(s[i..][0..16][0]);
    rt.exit(0);
}
