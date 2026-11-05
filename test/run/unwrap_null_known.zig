//! signal: ABRT
//! stderr: "ok\npanic: attempt to use null value\n"
//! `.?` of a null known at comptime, in runtime code, is the panic it
//! would be at run time, as upstream, and code that never runs it
//! compiles: zlob calls `pthread_join.?(h, null)`, a null constant
//! without libc's threads. `orelse unreachable` and `try` of a known
//! error behave the same.
const std = @import("std");
const rt = @import("rt.zig");
pub const panic = rt.panic;

const maybe: ?u32 = null;
const join: ?*const fn (u32) callconv(.c) u32 = null;
const bad: error{Bad}!u32 = error.Bad;

fn tried() !u32 {
    return try bad;
}

pub fn main() void {
    var c = false;
    _ = &c;
    if (c) std.debug.print("{d}\n", .{maybe.?});
    if (c) _ = join.?(1);
    if (c) std.debug.print("{d}\n", .{maybe orelse unreachable});
    const p = &maybe;
    if (c) std.debug.print("{d}\n", .{p.*.?});
    std.debug.print("{s}\n", .{if (tried()) |_| "no" else |_| "ok"});
    c = true;
    if (c) std.debug.print("{d}\n", .{maybe.?});
}
