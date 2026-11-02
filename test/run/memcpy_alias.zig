//! signal: ABRT
//! stderr: "panic: @memcpy arguments alias\n"
//! upstream-signal: SEGV
const rt = @import("rt.zig");

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

fn main() callconv(.c) noreturn {
    var buf: [8]u8 = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var i: usize = 2;
    _ = &i;
    // The destination [2, 6) overlaps the source [3, 7).
    @memcpy(buf[i..][0..4], buf[3..7]);
    rt.exit(buf[0]);
}
