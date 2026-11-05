//! A C object's strong `wfn` replaces the Zig code's weak export of it,
//! as in ld (build.zig); upstream prints the same.
const std = @import("std");
fn zigWfn() callconv(.c) c_int {
    return 1;
}
comptime {
    @export(&zigWfn, .{ .name = "wfn", .linkage = .weak });
}
extern fn wfn() c_int;
extern fn c_wfn() c_int;
pub fn main() void {
    std.debug.print("{d} {d}\n", .{ wfn(), c_wfn() });
}
