//! exit: 0
//! stderr: "42 7 9\n"
//! A global `var` initialized with an extern function, coerced to a
//! function pointer, as zarrow's codec tables of ZSTD_ and LZ4F_
//! functions are. The program exports the symbols itself.
const std = @import("std");

extern fn ext_bound(n: usize) callconv(.c) usize;
extern fn ext_add(a: usize, b: usize) callconv(.c) usize;

export fn impl_bound(n: usize) callconv(.c) usize {
    return n * 2;
}
export fn impl_add(a: usize, b: usize) callconv(.c) usize {
    return a + b;
}
comptime {
    @export(&impl_bound, .{ .name = "ext_bound" });
    @export(&impl_add, .{ .name = "ext_add" });
}

const Codec = struct {
    bound: *const fn (usize) callconv(.c) usize,
    add: *const fn (usize, usize) callconv(.c) usize,
};

var g: *const fn (usize) callconv(.c) usize = ext_bound;
var codec: Codec = .{ .bound = ext_bound, .add = ext_add };
const codec_const: Codec = .{ .bound = ext_bound, .add = ext_add };

pub fn main() void {
    std.debug.print("{d} {d} {d}\n", .{ g(21), codec.add(3, 4), codec_const.add(codec.bound(2), 5) });
}
