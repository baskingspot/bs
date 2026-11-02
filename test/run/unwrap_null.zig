//! signal: ABRT
//! stderr: "panic: attempt to use null value\n"
//! upstream-signal: SEGV
const rt = @import("rt.zig");

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
