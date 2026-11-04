//! signal: ABRT
//! stderr: "panic: index out of bounds: index 18446744073709551615, len 4\n"
//! Proving checks (docs/architecture.md, "Proving checks"): `i +% 1 <=
//! len` does not give `i < len`, since `+%` wraps: with `i` the largest
//! `usize`, `i +% 1` is 0, so `a[i]` keeps its check.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

var g: usize = ~@as(usize, 0);

fn main() callconv(.c) noreturn {
    const a: [4]u16 = @splat(7);
    const i: usize = g;
    if (i +% 1 <= a.len) rt.exit(@truncate(a[i]));
    rt.exit(0);
}
