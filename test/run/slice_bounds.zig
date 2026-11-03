//! signal: ABRT
//! stderr: "panic: index out of bounds: index 6, len 4\n"
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

fn main() callconv(.c) noreturn {
    var buf: [4]u8 = .{ 1, 2, 3, 4 };
    var n: usize = 6;
    _ = &n;
    const s = buf[0..n];
    rt.exit(s[0]);
}
