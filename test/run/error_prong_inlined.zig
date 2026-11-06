//! exit: 1
//! stderr-contains: "sum 190\ncaught Unsupported at trace index 3\nerror: Invalid\n"
//! stderr-contains: "error_prong_inlined.zig:38:17: 0x"
//! stderr-contains: " in regBytes (error_prong_inlined.zig)\n        else => return error.Invalid,\n                ^\n"
//! stderr-contains: "error_prong_inlined.zig:43:19: 0x"
//! stderr-contains: " in reg (error_prong_inlined.zig)\n    const bytes = try regBytes(r, n);\n                  ^\n"
//! stderr-contains: "error_prong_inlined.zig:50:24: 0x"
//! stderr-contains: " in sum (error_prong_inlined.zig)\n    for (ns) |n| t += (try reg(r, n)).*;\n                       ^\n"
//! stderr-contains: "error_prong_inlined.zig:63:9: 0x"
//! stderr-contains: " in main (error_prong_inlined.zig)\n    _ = try sum(&r, &worse);\n        ^\n"
// Callees whose only size over the budget is in branches that return an
// error (docs/slop/architecture.md, "Inlining within a budget"), shaped
// like std.debug's `dwarfRegisterBytes` and `regNative`, inline into
// `sum`. Their error returns still push the error return trace where they
// are inlined, so a caught error leaves the same trace index as upstream's
// and the returned one prints the inlined callees' frames.
const std = @import("std");

const Regs = struct { v: [17]u64 };

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
    var ok = [_]u16{ 1, 2, 16 };
    var bad = [_]u16{ 3, 40 };
    var worse = [_]u16{ 4, 200 };
    _ = .{ &ok, &bad, &worse };
    std.debug.print("sum {d}\n", .{try sum(&r, &ok)});
    _ = sum(&r, &bad) catch |e| std.debug.print("caught {s} at trace index {d}\n", .{ @errorName(e), @errorReturnTrace().?.index });
    _ = try sum(&r, &worse);
}
