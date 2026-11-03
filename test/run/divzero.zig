//! signal: ABRT
//! stderr: "panic: division by zero\n"
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

fn main() callconv(.c) noreturn {
    var d: u32 = 0;
    _ = &d;
    rt.exit(@intCast(100 / d));
}
