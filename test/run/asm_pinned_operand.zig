//! exit: 0
//! stderr: "42 7\n"
//! Inline assembly may name an operand pinned to a register (`{rax}`)
//! in its template, as upstream: an indirect call through the input, and
//! an output named at its own size.
const std = @import("std");
fn target(x: u64) callconv(.c) u64 {
    return x + 1;
}
pub fn main() void {
    const f: *const fn (u64) callconv(.c) u64 = &target;
    var r: u64 = undefined;
    asm volatile ("callq *%[callee]"
        : [ret] "={rax}" (r),
        : [callee] "{rax}" (f),
          [arg] "{rdi}" (@as(u64, 41)),
        : .{ .rcx = true, .rdx = true, .rsi = true, .r8 = true, .r9 = true, .r10 = true, .r11 = true, .memory = true });
    var w: u32 = undefined;
    asm volatile ("movl $7, %[w]"
        : [w] "={ecx}" (w),
    );
    std.debug.print("{d} {d}\n", .{ r, w });
}
