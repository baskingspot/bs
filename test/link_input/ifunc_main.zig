//! Calls ifunc.c's target_clones function, which zap refuses to link.
const std = @import("std");
extern fn c_triple(x: c_int) c_int;
pub fn main() void {
    std.debug.print("{d}\n", .{c_triple(14)});
}
