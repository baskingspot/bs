//! Links the object `zap build-obj` merged from merge_lib.zig, merge.c and
//! tls.c.
const std = @import("std");
extern fn z(x: c_int) c_int;
extern fn c_name() [*:0]const u8;
extern var c_counter: c_int;
extern fn c_tls() c_int;

pub fn main() void {
    const r = z(20);
    std.debug.print("{d} {s} {d} {d}\n", .{ r, c_name(), c_counter, c_tls() });
}
