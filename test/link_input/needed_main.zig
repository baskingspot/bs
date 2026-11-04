//! Links shared libraries a, b, c and d (needed_*.c): only a, which it
//! calls, and b, which a calls, are needed; c, which defines only the
//! program's own needed_host, and d, which needed_ref.c references
//! weakly, are left out of DT_NEEDED and do not load. a and b call back
//! into the program, which exports what they name.
const std = @import("std");
extern fn needed_a() c_int;
extern fn needed_has_d() c_int;

export fn needed_host() c_int {
    return 1;
}

pub fn main() void {
    std.debug.print("{d} {d}\n", .{ needed_a(), needed_has_d() });
}
