//! exit: 0
//! stderr: "23 7\n"
//! Inline assembly may operate on memory with an ALU instruction, as
//! compiler_rt's `__zig_probe_stack` does (`orl $0,16(%rsp)`), with an
//! immediate or a register source.
const std = @import("std");
var g: u64 = 5;
var h: u32 = 7;
pub fn main() void {
    asm volatile (
        \\addq $3, (%%rdi)
        \\orl $0x10, (%%rdi)
        \\subq %[k], (%%rdi)
        \\orl $0, 16(%%rsp)
        \\cmpl $7, (%%rdx)
        :
        : [p] "{rdi}" (&g),
          [k] "{rsi}" (@as(u64, 1)),
          [q] "{rdx}" (&h),
        : .{ .memory = true, .cc = true });
    std.debug.print("{d} {d}\n", .{ g, h });
}
