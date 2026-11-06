//! signal: ABRT
//! stdout: "6\n"
//! stderr: "panic: index out of bounds: index 4, len 4\n"
//! Proving checks (docs/slop/architecture.md, "Proving checks"): a
//! variable a loop does not store holds in it what it held before, so
//! `lim <= 4` from before the loop bounds `i < lim` and `a[i]` keeps no
//! check. `lim2` is stored in a loop nested in the second, so it gets no
//! such bound there: `a[i]` keeps its check, which fails.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

var n: usize = 3;
var big: usize = 10;

fn main() callconv(.c) noreturn {
    const a: [4]u8 = .{ 1, 2, 3, 4 };
    var x: u64 = 0;
    var lim: usize = n;
    if (lim > 4) rt.exit(1);
    for (0..lim) |i| x += a[i];
    rt.printInt(x);
    var lim2: usize = n;
    if (lim2 > 4) rt.exit(1);
    var i: usize = 0;
    while (i < lim2) : (i += 1) {
        x += a[i];
        var k: usize = 0;
        while (k < 1) : (k += 1) lim2 = big;
    }
    lim = 0;
    rt.exit(@truncate(x + lim));
}
