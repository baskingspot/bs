//! signal: ABRT
//! stdout: "5040\n"
//! stderr: "panic: index out of bounds: index 252, len 251\n"
//! Proving checks (docs/slop/architecture.md, "Proving checks"): counting
//! by a checked `i += 6` from 0, `i` stays a multiple of 6, so below 250
//! it is at most 246 and `st[i + 4]` keeps no check. An add whose
//! overflow bit is ignored wraps past 2^8 to 2 and then reaches 248, so
//! there the check stays, and fails.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

var st: [251]u8 = @splat(1);
var iters: usize = 100;

fn main() callconv(.c) noreturn {
    var i: u8 = 0;
    var sum: u64 = 0;
    while (i < 240) : (i += 6) {
        if (i < 250) sum += st[i + 4] * @as(u64, i) + 9;
    }
    rt.printInt(sum);
    i = 0;
    var k: usize = 0;
    while (k < iters) : (k += 1) {
        if (i < 250) sum += st[i + 4];
        i = @addWithOverflow(i, 6)[0];
    }
    rt.exit(@truncate(sum));
}
