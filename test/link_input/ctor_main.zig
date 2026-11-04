//! Prints the order the constructors in ctor.c ran in (build.zig,
//! `addLinkInputTests`); upstream's link prints the same.
const std = @import("std");
extern var ctor_log: [8]c_int;
extern var ctor_n: c_int;
pub fn main() void {
    std.debug.print("{any}\n", .{ctor_log[0..@intCast(ctor_n)]});
}
