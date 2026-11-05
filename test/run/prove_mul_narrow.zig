//! signal: ABRT
//! stderr: "panic: integer overflow\n"
//! Proving checks (docs/slop/architecture.md, "Proving checks"): a value
//! is within its own type's bounds, so a u32 times a u32 fits a u64, but
//! a u33 times a u32 need not.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

var x: u32 = 0xffff_ffff;
var y: u33 = 0x1_ffff_ffff;

fn main() callconv(.c) noreturn {
    const fits = @as(u64, x) * @as(u64, x);
    if (fits != 0xffff_fffe_0000_0001) rt.exit(1);
    const big = @as(u64, y) * @as(u64, x);
    rt.exit(@truncate(big));
}
