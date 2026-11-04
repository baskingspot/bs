//! signal: ABRT
//! stderr: "panic: index out of bounds: index 76, len 64\n"
//! Proving checks (docs/slop/architecture.md, "Proving checks"): `i + 32 <
//! len` describes the `i` loaded there, not the value stored to `i`
//! after it, so `s[i..][0..16]` keeps its checks.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

var g: usize = 60;
var h: usize = 0;
var n: usize = 64;

fn main() callconv(.c) noreturn {
    const a: [64]u8 = @splat(7);
    const s: []const u8 = a[0..n];
    var i: usize = h;
    if (i + 32 < s.len) {
        i = g;
        rt.exit(s[i..][0..16][0]);
    }
    rt.exit(0);
}
