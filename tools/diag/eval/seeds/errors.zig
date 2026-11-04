const std = @import("std");

const ParseError = error{ Empty, TooLong };

fn parseName(s: []const u8) ParseError![]const u8 {
    if (s.len == 0) return error.Empty;
    if (s.len > 8) return error.TooLong;
    return s;
}

fn firstChar(s: []const u8) !u8 {
    const name = try parseName(s);
    return name[0];
}

pub fn main() !void {
    const c = try firstChar("zig");
    const fallback = parseName("") catch "anon";
    if (parseName("much too long")) |n| {
        std.debug.print("{s}\n", .{n});
    } else |err| {
        std.debug.print("error: {s}\n", .{@errorName(err)});
    }
    std.debug.print("{c} {s}\n", .{ c, fallback });
}
