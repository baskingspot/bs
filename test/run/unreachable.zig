//! signal: ABRT
//! stderr: "panic: reached unreachable code\n"
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

fn main() callconv(.c) noreturn {
    var b = true;
    _ = &b;
    if (b) unreachable;
    rt.exit(0);
}
