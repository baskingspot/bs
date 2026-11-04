//! signal: ABRT
//! stderr: "panic: integer overflow\n"
//! Proving checks (docs/slop/architecture.md, "Proving checks"): facts compare
//! values, whatever their width. `@as(i16, x) < 130` bounds the `i8` `x`
//! by 129, not by 130 read as an `i8` (-126), so `x + 1` keeps its check.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

var g: i8 = 127;

fn main() callconv(.c) noreturn {
    const x: i8 = g;
    if (@as(i16, x) < 130) {
        const y = x + 1;
        rt.exit(@bitCast(y));
    }
    rt.exit(0);
}
