//! signal: ABRT
//! stderr: "panic: sentinel mismatch: expected 0, found 100\n"
//! upstream-signal: SEGV
const rt = @import("rt.zig");

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

fn main() callconv(.c) noreturn {
    var buf: [4]u8 = .{ 1, 2, 100, 4 };
    var n: usize = 2;
    _ = &n;
    const s = buf[0..n :0];
    rt.exit(s[0]);
}
