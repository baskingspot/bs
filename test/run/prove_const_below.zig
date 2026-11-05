//! signal: ABRT
//! stderr: "panic: index out of bounds: index 5, len 5\n"
//! Proving checks (docs/slop/architecture.md, "Proving checks"): a
//! constant is below what an unsigned `x + c` is below when it is at most
//! `c`, so in a loop to `s.len`, `s[0]` needs no check. Only for an exact
//! `x + c`: `g +% 5 < s.len` with `g` the largest `usize` is `4 < 5`,
//! which says nothing of `5 < s.len`, so `s[5]` keeps its check and
//! fails.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

var g: usize = ~@as(usize, 0);
var n: usize = 5;

noinline fn first(s: []const u8) u64 {
    var t: u64 = 0;
    for (0..s.len) |i| t +%= s[0] +% i;
    return t;
}

fn main() callconv(.c) noreturn {
    const a: [8]u8 = @splat(7);
    const s: []const u8 = a[0..n];
    // 5 × 7 + (0 + 1 + 2 + 3 + 4) = 45.
    if (first(s) != 45) rt.exit(1);
    if (g +% 5 < s.len) rt.exit(s[5]);
    rt.exit(0);
}
