//! signal: ABRT
//! stdout: "2\n"
//! stderr: "panic: integer overflow\n"
//! Proving checks (docs/slop/architecture.md, "Proving checks"): past
//! `while (i < 16)`, a loop that grows `i` by a checked add keeps `16 <=
//! i`, so `s[i - 16]` keeps no check. A wrapping add crosses 2^8 back
//! below 16 (16, 116, 216, 60, 160, 4), so there the check stays, and
//! fails.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

var s: [256]u8 = @splat(1);
var iters: usize = 100;

fn main() callconv(.c) noreturn {
    var i: u8 = 0;
    while (i < 16) : (i += 1) {}
    var sum: u64 = 0;
    var k: usize = 0;
    while (k < 2) : (k += 1) {
        sum += s[i - 16];
        i += 100;
    }
    rt.printInt(sum);
    i = 0;
    while (i < 16) : (i += 1) {}
    k = 0;
    while (k < iters) : (k += 1) {
        sum += s[i - 16];
        i +%= 100;
    }
    rt.exit(@truncate(sum));
}
