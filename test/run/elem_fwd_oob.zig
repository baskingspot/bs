//! signal: ABRT
//! stderr-contains: "panic: index out of bounds: index 5, len 3\n"
//! stderr-contains: "    const line = lines[i];\n                      ^\n"
//! A copy of a slice element read in place (`elem_fwd.zig`) keeps its
//! bounds check, and its panic, on the copy's line.
const std = @import("std");

const Line = struct { start: u32, end: u32, pad: [14]f32 = @splat(0), cs: u32, ce: u32 };

noinline fn get(lines: []const Line, i: usize) u32 {
    const line = lines[i];
    return line.start + line.end;
}

pub fn main() void {
    var lines: [3]Line = undefined;
    for (&lines, 0..) |*ln, i| ln.* = .{ .start = @intCast(i), .end = 1, .cs = 0, .ce = 0 };
    var i: usize = 5;
    _ = &i;
    std.debug.print("{}\n", .{get(&lines, i)});
}
