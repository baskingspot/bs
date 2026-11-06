//! signal: ABRT
//! stderr-contains: "panic: index out of bounds: index 14, len 12\n"
//! stderr-contains: "panic_switch_inlined.zig:21:46: 0x"
//! stderr-contains: " in regBytes (panic_switch_inlined.zig)\n        0...16 => return std.mem.asBytes(&r.v[n]),\n                                             ^\n"
//! stderr-contains: "panic_switch_inlined.zig:28:36: 0x"
//! stderr-contains: " in sum (panic_switch_inlined.zig)\n"
//! stderr-contains: " in main (panic_switch_inlined.zig)\n"

// A panic in a case of the switch that ends the body of a function the
// backend inlines (`regBytes` into `sum`): the inlined call ends after the
// switch, not before it, so the case's code keeps the callee's frame, as
// upstream's and as built without inlining (`zig build test` compares the
// two traces).
const std = @import("std");

const Regs = struct { v: [12]u64 };

fn regBytes(r: *Regs, n: u16) error{Invalid}![]u8 {
    switch (n) {
        17 => return error.Invalid,
        0...16 => return std.mem.asBytes(&r.v[n]),
        else => return error.Invalid,
    }
}

noinline fn sum(r: *Regs, ns: []const u16) error{Invalid}!u64 {
    var t: u64 = 0;
    for (ns) |n| t += (try regBytes(r, n))[0];
    return t;
}

pub fn main() !void {
    var r: Regs = undefined;
    for (&r.v, 0..) |*x, i| x.* = i * 10;
    var ns = [_]u16{ 1, 14 };
    _ = &ns;
    std.debug.print("sum {d}\n", .{try sum(&r, &ns)});
}
