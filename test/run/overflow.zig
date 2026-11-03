//! signal: ABRT
//! stderr: "panic: integer overflow\n"
const rt = @import("rt.zig");
pub const panic = rt.panic;

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
