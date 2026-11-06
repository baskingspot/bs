//! signal: ABRT
//! stderr-contains: "panic: index out of bounds: index 14, len 12\n"
//! stderr-contains: "panic_prong_inlined.zig:21:46: 0x"
//! stderr-contains: " in regBytes (panic_prong_inlined.zig)\n        0...16 => return std.mem.asBytes(&r.v[n]),\n                                             ^\n"
//! stderr-contains: "panic_prong_inlined.zig:41:31: 0x"
//! stderr-contains: " in reg (panic_prong_inlined.zig)\n    const bytes = try regBytes(r, n);\n                              ^\n"
//! stderr-contains: "panic_prong_inlined.zig:48:31: 0x"
//! stderr-contains: " in sum (panic_prong_inlined.zig)\n    for (ns) |n| t += (try reg(r, n)).*;\n                              ^\n"
//! stderr-contains: "panic_prong_inlined.zig:57:43: 0x"
//! stderr-contains: " in main (panic_prong_inlined.zig)\n    std.debug.print(\"sum {d}\\n\", .{try sum(&r, &ns)});\n                                          ^\n"
// A panic in the hot prong of callees that inline only because their
// error-returning branches do not count toward the budget
// (docs/slop/architecture.md, "Inlining within a budget"): the stack trace
// has the frames of the uninlined calls, as upstream's.
const std = @import("std");

const Regs = struct { v: [12]u64 };

fn regBytes(r: *Regs, n: u16) error{ Unsupported, Invalid }![]u8 {
    switch (n) {
        0...16 => return std.mem.asBytes(&r.v[n]),
        17...32 => return error.Unsupported,
        33...40 => return error.Unsupported,
        41...48 => return error.Unsupported,
        49 => return error.Unsupported,
        50...55 => return error.Unsupported,
        58...59 => return error.Unsupported,
        62 => return error.Unsupported,
        63 => return error.Unsupported,
        64 => return error.Unsupported,
        65 => return error.Unsupported,
        66 => return error.Unsupported,
        67...82 => return error.Unsupported,
        118...125 => return error.Unsupported,
        130...145 => return error.Unsupported,
        else => return error.Invalid,
    }
}

fn reg(r: *Regs, n: u16) error{ Unsupported, Invalid, Size }!*align(1) u64 {
    const bytes = try regBytes(r, n);
    if (bytes.len != @sizeOf(u64)) return error.Size;
    return @ptrCast(bytes);
}

noinline fn sum(r: *Regs, ns: []const u16) error{ Unsupported, Invalid, Size }!u64 {
    var t: u64 = 0;
    for (ns) |n| t += (try reg(r, n)).*;
    return t;
}

pub fn main() !void {
    var r: Regs = undefined;
    for (&r.v, 0..) |*x, i| x.* = i * 10;
    var ns = [_]u16{ 1, 14 };
    _ = &ns;
    std.debug.print("sum {d}\n", .{try sum(&r, &ns)});
}
