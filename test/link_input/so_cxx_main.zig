//! Loads the shared library of C++ that `bs build-lib -dynamic -lc++`
//! links from so_cxx.cpp, by its soname.
const std = @import("std");
extern fn sxx_run(n: c_int) c_int;

pub fn main() void {
    std.debug.print("sxx {d} {d}\n", .{ sxx_run(7), sxx_run(1234) });
}
