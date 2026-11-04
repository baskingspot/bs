const std = @import("std");

pub fn main() void {
    var prng: std.Random.DefaultPrng = .init(12345);
    const random = prng.random();
    const a = random.intRangeAtMost(u8, 1, 6);
    const b = random.float(f64);
    var items = [_]u32{ 1, 2, 3, 4 };
    random.shuffle(u32, &items);
    std.debug.print("{d} {d} {any}\n", .{ a, b, items });
}
