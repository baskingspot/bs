//! Calls a1.c and a2.c through a library or an object that bs made of
//! their objects alone, without a Zig root or C sources.
const std = @import("std");
extern fn a1(x: c_int) c_int;

pub fn main() void {
    std.debug.print("{d}\n", .{a1(3)});
}
