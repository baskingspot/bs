//! exit: 0
//! stderr: "6238276526611678927\n"
//! Switch ranges whose bounds are the type's ends compare only the other
//! bound, or nothing for a range over the whole type.
const std = @import("std");
fn cls(x: u8) u8 {
    return switch (x) {
        0...9 => 1,
        10...200 => 2,
        else => 3,
    };
}
fn full(x: u4) u8 {
    return switch (x) {
        0...15 => 9,
    };
}
fn top(x: i8) u8 {
    return switch (x) {
        -128...-1 => 1,
        100...127 => 2,
        else => 0,
    };
}
fn wide(x: u64) u8 {
    return switch (x) {
        0...5 => 1,
        0xffff_ffff_0000_0000...0xffff_ffff_ffff_ffff => 2,
        else => 0,
    };
}
pub fn main() void {
    var t: u64 = 0;
    for (0..256) |i| {
        t = t *% 31 +% cls(@intCast(i)) +% top(@bitCast(@as(u8, @intCast(i))));
        t +%= full(@truncate(i));
    }
    for ([_]u64{ 0, 5, 6, 0xffff_ffff_0000_0000, 0xffff_fffe_ffff_ffff, std.math.maxInt(u64) }) |v| t = t *% 31 +% wide(v);
    for (0..36) |d| t = t *% 7 +% std.fmt.digitToChar(@intCast(d), if (d % 2 == 0) .lower else .upper);
    std.debug.print("{d}\n", .{t});
}
