const std = @import("std");

fn average(values: []const u32) f64 {
    var total: u64 = 0;
    for (values) |v| total += v;
    const count: f64 = @floatFromInt(values.len);
    const sum: f64 = @floatFromInt(total);
    return sum / count;
}

pub fn main() void {
    const big: u64 = 300;
    const small: u8 = @truncate(big);
    const idx: usize = 2;
    const narrow: u16 = @intCast(idx);
    const bits: u32 = @bitCast(@as(f32, 1.0));
    const rounded: i32 = @intFromFloat(@round(average(&.{ 1, 2, 4 })));
    std.debug.print("{d} {d} {x} {d}\n", .{ small, narrow, bits, rounded });
}
