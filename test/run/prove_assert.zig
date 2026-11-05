//! signal: ABRT
//! stderr: "panic: reached unreachable code\n"
//! Proving checks (docs/slop/architecture.md, "Proving checks"): an
//! `unreachable` the user wrote goes when the facts prove it is not
//! reached: `x < y and y < x` (also as `&`) is false everywhere. `x < y
//! & x <= y` is true where `x < y`, so that one stays, and is reached.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

var x: u32 = 2;
var y: u32 = 3;

fn main() callconv(.c) noreturn {
    const lt = x < y;
    const gt = y < x;
    const le = x <= y;
    if (lt and gt) unreachable;
    if (lt & gt) unreachable;
    if (lt & le) unreachable;
    rt.exit(0);
}
