//! signal: ABRT
//! stdout: "127\n8589934591\n"
//! stderr: "panic: integer overflow\n"
//! Proving checks (docs/slop/architecture.md, "Proving checks"): an
//! unsigned `a << b` that can shift out no bits is `a * 2^b`: `1 << a`
//! for a `u6` `a` is at least 1, so `- 1` keeps no check, and a widened
//! `u32 << 1` plus a `u1` fits. A `u64 << 1` may lose its top bit, so
//! `+ 2` keeps its check, which fails.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

var a: u6 = 7;
var l: u32 = 0xffff_ffff;
var c: u1 = 1;
var big: u64 = 0x7fff_ffff_ffff_ffff;

fn main() callconv(.c) noreturn {
    rt.printInt((@as(usize, 1) << a) - 1);
    rt.printInt((@as(u64, l) << 1) + c);
    rt.exit(@truncate((big << 1) + 2));
}
