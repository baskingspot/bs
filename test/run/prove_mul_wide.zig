//! signal: ABRT
//! stderr: "panic: integer overflow\n"
//! Proving checks (docs/slop/architecture.md, "Proving checks"): the
//! product of two u64 values fits a u128, so that check goes, but not a
//! u127, so this one stays.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

var a: u64 = 0xffff_ffff_ffff_ffff;
var b: u64 = 0xffff_ffff_ffff_ffff;

fn main() callconv(.c) noreturn {
    const fits = @as(u128, a) * @as(u128, b);
    if (fits != 0xffff_ffff_ffff_fffe_0000_0000_0000_0001) rt.exit(1);
    const big = @as(u127, a) * @as(u127, b);
    rt.exit(@truncate(big));
}
