const std = @import("std");

extern fn asm_cpp_add(x: u64) u64;
extern fn asm_plain_mul(a: u64, b: u64) u64;
extern fn asm_cpp_abs() u64;
extern const asm_abs_value: u8;

pub fn main() void {
    std.debug.print("{d} {d} {x} {x}\n", .{ asm_cpp_add(2), asm_plain_mul(6, 7), asm_cpp_abs(), @intFromPtr(&asm_abs_value) });
}
