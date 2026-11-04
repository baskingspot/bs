//! Imports from a shared library zap links against (build.zig,
//! `addLinkInputTests`); upstream's link prints the same.
const std = @import("std");
extern fn shared_get() c_int;
extern fn shared_twice(x: c_int) c_int;
extern fn c_shared() c_int;
extern var shared_counter: c_int;
pub fn main() void {
    const a = shared_get();
    const b = c_shared();
    std.debug.print("{d} {d} {d} {d}\n", .{ a, b, shared_twice(21), shared_counter });
}
