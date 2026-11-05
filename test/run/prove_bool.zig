//! signal: ABRT
//! stderr: "panic: index out of bounds: index 9, len 4\n"
//! Proving checks (docs/slop/architecture.md, "Proving checks"): where `a
//! or b` is true, either may be false, so `i < s.len or wide` does not
//! prove `s[i]`, while `i < s.len and wide` would.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

var i: usize = 9;
var wide = true;

fn main() callconv(.c) noreturn {
    const a: [4]u8 = .{ 1, 2, 3, 4 };
    const s: []const u8 = &a;
    if (i < s.len and wide) rt.exit(s[i]);
    if (i < s.len or wide) rt.exit(s[i]);
    rt.exit(0);
}
