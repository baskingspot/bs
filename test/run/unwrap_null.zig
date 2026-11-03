//! signal: ABRT
//! stderr: "panic: attempt to use null value\n"
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

fn main() callconv(.c) noreturn {
    var o: ?u8 = null;
    _ = &o;
    rt.exit(o.?);
}
