//! signal: ABRT
//! stderr: "panic: index out of bounds: index 5, len 3\n"
//! Proving checks (docs/slop/architecture.md, "Proving checks"): in the else
//! side, `i` is still 5, whatever the then side stored, so `s[i]` keeps
//! its check although `s.len >= 1` is known.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

fn pick(s: []const u8, c: bool) u8 {
    if (s.len < 1) return 0;
    var i: usize = 5;
    if (c) {
        i = 0;
    } else {
        return s[i];
    }
    return s[i];
}

var flag = false;

fn main() callconv(.c) noreturn {
    const bytes = [_]u8{ 1, 2, 3, 9, 9, 9 };
    rt.exit(pick(bytes[0..3], flag));
}
