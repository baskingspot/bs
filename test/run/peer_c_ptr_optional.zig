//! exit: 0
//! stderr: "[*c][*c]u8 true true\n"
//! A C pointer and an optional pointer peer as a C pointer, as upstream,
//! so a null C pointer equals a null optional: zlob's tests compare a
//! `[*c][*c]u8` field with `@as(?[*][*c]u8, null)` through
//! std.testing.expectEqual.
const std = @import("std");

const Glob = extern struct { pathc: usize, pathv: [*c][*c]u8 };

fn reset(g: *Glob) void {
    g.pathv = null;
    g.pathc = 0;
}

pub fn main() !void {
    var g: Glob = undefined;
    reset(&g);
    const none: ?[*][*c]u8 = null;
    const T = @TypeOf(none, g.pathv);
    const a: T = none;
    std.debug.print("{s} {} {}\n", .{ @typeName(T), a == g.pathv, (if (g.pathc == 0) g.pathv else none) == null });
    try std.testing.expectEqual(@as(?[*][*c]u8, null), g.pathv);
}
