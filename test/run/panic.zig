//! signal: ABRT
//! stdout: "before\n"
//! stderr: "panic: custom message\n"
const rt = @import("rt.zig");
pub const panic = rt.panic;
pub export fn _start() callconv(.naked) noreturn { asm volatile ("call %[main:P]" : : [main] "X" (&main)); }
var n: u32 = 3;
fn main() callconv(.c) noreturn {
    rt.print("before\n");
    if (n == 3) @panic("custom message");
    rt.exit(0);
}
