const std = @import("std");

extern fn ir_mul(a: i32, b: i32) i32;
extern fn ir_bc_sub(a: i32, b: i32) i32;

pub fn main() void {
    std.debug.print("{d} {d}\n", .{ ir_mul(6, 7), ir_bc_sub(50, 8) });
}
