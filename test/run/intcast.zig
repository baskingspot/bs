//! signal: ABRT
//! stderr: "panic: integer does not fit in destination type\n"
//! upstream-signal: SEGV
const rt = @import("rt.zig");

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

fn main() callconv(.c) noreturn {
    var big: u32 = 300;
    _ = &big;
    const small: u8 = @intCast(big);
    rt.exit(small);
}
