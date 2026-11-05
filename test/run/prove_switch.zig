//! signal: ABRT
//! stderr: "panic: index out of bounds: index 7, len 3\n"
//! Proving checks (docs/slop/architecture.md, "Proving checks"): the check
//! `s[i]` passed in one switch case proves nothing in the next.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

var sink: u8 = 0;

fn pick(x: u8, s: []const u8, i: usize) u8 {
    switch (x) {
        0 => {
            sink = s[i];
            return 1;
        },
        1 => return s[i],
        else => return 0,
    }
}

var idx: usize = 7;
var sel: u8 = 1;

fn main() callconv(.c) noreturn {
    const bytes = [_]u8{ 1, 2, 3, 9, 9, 9, 9, 9 };
    rt.exit(pick(sel, bytes[0..3], idx));
}
