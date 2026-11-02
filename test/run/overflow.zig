//! signal: ABRT
//! stderr: "panic: integer overflow\n"
//! upstream-signal: SEGV
const rt = @import("rt.zig");

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

fn main() callconv(.c) noreturn {
    var x: u8 = 250;
    x += 10;
    rt.exit(x);
}
