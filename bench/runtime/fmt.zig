//! std.fmt through a std.Io.Writer: formatting integers and strings,
//! interface (vtable) calls, and slices.
const std = @import("std");

/// Exported and mutable, so no compiler treats the problem size as known.
export var scale: usize = 1;

pub fn main() void {
    const n: usize = 300_000 * scale;
    var buf: [256]u8 = undefined;
    var total: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var w: std.Io.Writer = .fixed(&buf);
        w.print("{d} {x} {s}:{d:>8}\n", .{ i, i *% 0x9e3779b9, "item", i % 977 }) catch @panic("full");
        total +%= w.buffered().len + w.buffered()[w.buffered().len / 2];
    }
    std.debug.print("{d}\n", .{total});
}
