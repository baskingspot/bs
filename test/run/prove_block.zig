//! signal: ABRT
//! stderr: "panic: integer overflow\n"
//! Proving checks (docs/slop/architecture.md, "Proving checks"): a block's
//! value has the bounds of the constants it exits with only when every
//! exit is a constant. Here one exit is `k` (200), so `b + 100` keeps its
//! overflow check although the other exit is 10.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

fn add(c: bool, k: u8) u8 {
    const b: u8 = if (c) 10 else k;
    return b + 100;
}

var flag = false;
var big: u8 = 200;

fn main() callconv(.c) noreturn {
    rt.exit(add(flag, big));
}
