//! Calls into two objects that define the same COMDAT group (build.zig,
//! `addLinkInputTests`); upstream's link prints the same.
const std = @import("std");
extern fn comdat_call1() c_int;
extern fn comdat_call2() c_int;
pub fn main() void {
    std.debug.print("{d} {d}\n", .{ comdat_call1(), comdat_call2() });
}
