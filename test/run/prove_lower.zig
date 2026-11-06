//! signal: ABRT
//! stdout: "6400\n"
//! stderr: "panic: integer overflow\n"
//! Proving checks (docs/slop/architecture.md, "Proving checks"): past
//! `while (i < 16)`, `i` is at least 16, and a loop that only adds to it
//! keeps that at its start, so `s[i - 16]` keeps no overflow check. A loop
//! that also subtracts from `i` does not, so its check stays, and fails.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

var drop: usize = 40;

fn main() callconv(.c) noreturn {
    var s: [80]u64 = undefined;
    var i: usize = 0;
    while (i < 16) : (i += 1) s[i] = 100;
    while (i < 80) : (i += 1) s[i] = s[i - 16];
    var sum: u64 = 0;
    for (s) |x| sum += x;
    rt.printInt(sum - 1600);
    i = 16;
    while (i < 80) : (i += 1) {
        sum +%= s[i - 16];
        if (i == drop) i -= 30;
    }
    rt.exit(@truncate(sum));
}
