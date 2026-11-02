//! signal: ABRT
//! stderr: "panic: integer part of floating point value out of bounds\n"
//! upstream-signal: SEGV
const rt = @import("rt.zig");

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

fn main() callconv(.c) noreturn {
    var f: f32 = 256.0;
    _ = &f;
    const x: u8 = @intFromFloat(f);
    rt.exit(x);
}
