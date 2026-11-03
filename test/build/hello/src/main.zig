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

test "unwind tables" {
    try std.testing.expectEqual(.sync, @import("builtin").unwind_tables);
}

// `zap build test --fuzz` finds the planted crash (check.sh).
test "fuzz" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [8]u8 = undefined;
            const n = smith.slice(&buf);
            if (n >= 3 and buf[0] == 'z' and buf[1] == 'a' and buf[2] == 'p') @panic("planted crash");
        }
    }.testOne, .{});
}
