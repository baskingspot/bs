//! Calls a C object that calls glibc, linked with -lc (build.zig,
//! `addLinkInputTests`); upstream prints the same.
const std = @import("std");
extern fn c_fmt(x: c_int) [*:0]const u8;
extern fn c_errno() c_int;
extern fn c_puts(s: [*:0]const u8) void;
extern fn c_qsort() c_int;
export fn zig_twice(x: c_int) c_int {
    return 2 * x;
}
pub fn main() void {
    c_puts(c_fmt(21));
    std.debug.print("{d} {d}\n", .{ c_errno(), c_qsort() });
}
