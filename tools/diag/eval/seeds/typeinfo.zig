const std = @import("std");

const Config = struct { width: u32 = 80, height: u32 = 24, name: []const u8 = "term" };

fn fieldCount(comptime T: type) usize {
    return @typeInfo(T).@"struct".field_names.len;
}

fn isInt(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int, .comptime_int => true,
        else => false,
    };
}

pub fn main() void {
    const c: Config = .{};
    inline for (@typeInfo(Config).@"struct".field_names) |name| {
        std.debug.print("{s}\n", .{name});
    }
    std.debug.print("{d} {} {d}\n", .{ fieldCount(Config), isInt(u8), @field(c, "width") });
}
