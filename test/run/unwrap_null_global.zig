//! signal: ABRT
//! stderr: "panic: attempt to use null value\n"
//! A store through `.?` of a null global optional is checked at run time.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

var global: ?struct { x: u8 } = null;

fn main() callconv(.c) noreturn {
    global.?.x = 5;
    rt.exit(0);
}
