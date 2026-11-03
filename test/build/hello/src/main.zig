const std = @import("std");
const greet = @import("greet");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    std.debug.print("{s} {d}\n", .{ greet.word, args.len - 1 });
}

fn add(a: u32, b: u32) u32 {
    return a + b;
}

test add {
    try std.testing.expectEqual(5, add(2, 3));
}

test "greet" {
    try std.testing.expectEqualStrings("hello", greet.word);
}
