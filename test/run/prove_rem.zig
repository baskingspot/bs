//! signal: ABRT
//! stdout: "34\n"
//! stderr: "panic: integer does not fit in destination type\n"
//! Proving checks (docs/slop/architecture.md, "Proving checks"): `a % 100`
//! of an unsigned `a` is below 100, so its `@intCast` to `u8` keeps no
//! check, but `@rem` of a negative `b` is negative, so that one stays.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

var a: u64 = 1234;
var b: i64 = -7;

fn main() callconv(.c) noreturn {
    const lo: u8 = @intCast(a % 100);
    rt.printInt(lo);
    const r: u8 = @intCast(@rem(b, 4));
    rt.exit(r);
}
