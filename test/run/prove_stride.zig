//! signal: ABRT
//! stdout: "8\n"
//! stderr: "panic: index out of bounds: index 32, len 32\n"
//! Proving checks (docs/slop/architecture.md, "Proving checks"): `i`
//! counts from 0 by 4 while below 32, so it is at most 28 and `st[i + 3]`
//! keeps no check. Counting from 1, `i` reaches 29 and `st[i + 3]` keeps
//! its check, which fails.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

var start: usize = 1;

fn main() callconv(.c) noreturn {
    var st: [32]u8 = @splat(0);
    var i: usize = 0;
    while (i < 32) : (i += 4) st[i + 3] += 1;
    var n: u64 = 0;
    for (st) |x| n += x;
    rt.printInt(n);
    i = 1;
    while (i < 32) : (i += 4) st[i + 3] += 1;
    rt.exit(st[31] + @as(u8, @truncate(start)));
}
