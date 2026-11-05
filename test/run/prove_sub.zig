//! signal: ABRT
//! stderr: "panic: index out of bounds: index 4, len 4\n"
//! Proving checks (docs/slop/architecture.md, "Proving checks"): `j - k <
//! len` follows from `j <= len` only when `k >= 1`. `k` is 0 here, so
//! `a[j - k]` keeps its check.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

var j: usize = 4;
var k: usize = 0;

fn main() callconv(.c) noreturn {
    const a: [4]u8 = .{ 1, 2, 3, 4 };
    const s: []const u8 = &a;
    if (j <= s.len) rt.exit(s[j - k]);
    rt.exit(0);
}
