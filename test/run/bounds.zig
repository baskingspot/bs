//! signal: ABRT
//! stderr: "panic: index out of bounds: index 5, len 3\n"
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

fn main() callconv(.c) noreturn {
    const a = [_]u8{ 1, 2, 3 };
    var i: usize = 5;
    _ = &i;
    rt.exit(a[i]);
}
