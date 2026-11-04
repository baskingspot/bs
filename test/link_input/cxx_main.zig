//! Calls a C++ source of a -lc++ executable (build.zig,
//! `addLinkInputTests`); upstream prints the same.
const std = @import("std");
const builtin = @import("builtin");
extern fn cxx_run() c_int;
export fn zig_add(a: c_int, b: c_int) c_int {
    return a + b;
}
pub fn main() void {
    const r = cxx_run();
    std.debug.print("result {d}, link_libcpp {}\n", .{ r, builtin.link_libcpp });
}
