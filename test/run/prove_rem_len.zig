//! signal: ABRT
//! stdout: "4\n2\n"
//! stderr: "panic: index out of bounds: index 3, len 3\n"
//! Proving checks (docs/slop/architecture.md, "Proving checks"): past the
//! divide-by-zero check, unsigned `h % s.len` is below `s.len`, and
//! `i < @min(a.len, b.len)` is below `a.len`, so their indexes keep no
//! check. `h % (s.len + 1)` may be `s.len`, so that one stays, and fails.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

var h: u64 = 1234;
var s: []const u8 = &.{ 2, 4, 6 };
var t: []const u8 = &.{ 1, 1 };

noinline fn shorter(a: []const u8, b: []const u8) u64 {
    var x: u64 = 0;
    for (0..@min(a.len, b.len)) |i| x += a[i] * b[i];
    return x;
}

fn main() callconv(.c) noreturn {
    rt.printInt(s[h % s.len]);
    rt.printInt(shorter(s, t) - 4);
    rt.exit(s[(h + 1) % (s.len + 1)]);
}
