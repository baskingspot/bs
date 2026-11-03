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
    var x: i128 = -0x7fff_ffff_ffff_ffff_ffff_ffff_ffff_fff0;
    _ = &x;
    x *= 3;
    rt.exit(@truncate(@as(u128, @bitCast(x))));
}
