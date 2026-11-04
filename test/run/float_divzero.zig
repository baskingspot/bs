//! signal: ABRT
//! stderr: "panic: division by zero\n"
// Under `@setFloatMode(.optimized)`, float division by zero is illegal
// behavior with a safety check, as upstream; strict division is not.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

fn main() callconv(.c) noreturn {
    var d: f32 = 0;
    _ = &d;
    // Strict: infinity, no check.
    if (!(1.0 / d > 3.0e38)) rt.exit(1);
    optimized(d);
}

fn optimized(d: f32) noreturn {
    @setFloatMode(.optimized);
    rt.exit(@intFromFloat(@rem(@as(f32, 7), d)));
}
