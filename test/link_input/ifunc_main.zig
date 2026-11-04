//! Calls ifunc.c's indirect functions from Zig and through C, and checks
//! that their addresses are the same whoever takes them.
const std = @import("std");
extern fn c_triple(x: c_int) c_int;
extern fn c_add(x: c_int) c_int;
extern fn c_call(x: c_int) c_int;
extern fn c_triple_ptr() *const fn (c_int) callconv(.c) c_int;
extern const c_add_ptr: *const fn (c_int) callconv(.c) c_int;

pub fn main() void {
    std.debug.print("{d} {d} {d} {d} {d} {} {}\n", .{
        c_triple(14),
        c_add(40),
        c_call(1),
        c_triple_ptr()(5),
        c_add_ptr(7),
        c_triple_ptr() == &c_triple,
        c_add_ptr == &c_add,
    });
}
