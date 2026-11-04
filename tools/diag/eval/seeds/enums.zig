const std = @import("std");

const Color = enum(u8) { red, green, blue };

fn describe(c: Color) []const u8 {
    return switch (c) {
        .red => "warm",
        .green, .blue => "cool",
    };
}

pub fn main() void {
    var raw: u8 = 2;
    _ = &raw;
    const c: Color = @enumFromInt(raw);
    const back: u8 = @intFromEnum(c);
    const parsed = std.meta.stringToEnum(Color, "green") orelse .red;
    std.debug.print("{s} {d} {s} {s}\n", .{ @tagName(c), back, describe(parsed), describe(c) });
}
