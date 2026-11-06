//! signal: ABRT
//! stdout: "90\n"
//! stderr: "panic: integer overflow\n"
//! Proving checks (docs/slop/architecture.md, "Proving checks"): past `i <
//! 4 * n`'s overflow check, `2 * n` fits and is at least 2, so `2 * n` and
//! `% (2 * n)` keep no checks. `5 * n` may not fit, so its check stays,
//! and fails.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

var n: u64 = 5;
var huge: u64 = 0x3fff_ffff_ffff_ffff;

noinline fn sum(m: u64) u64 {
    var s: u64 = 0;
    var i: u64 = 0;
    while (i < 4 * m) : (i += 1) s +%= i % (2 * m);
    return s;
}

noinline fn over(m: u64) u64 {
    if (m == 0 or 0 >= 4 * m) return 0;
    return 5 * m;
}

fn main() callconv(.c) noreturn {
    rt.printInt(sum(n));
    rt.exit(@truncate(over(huge)));
}
