const std = @import("std");
const greet = @import("greet");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    std.debug.print("{s} {d}{s}\n", .{ greet.word, args.len - 1, mode });
}

/// greet's mode, which greet inherits from this module, unless Debug,
/// and whether a bare union lacks the safety tag (ReleaseFast and Small).
const mode = if (greet.mode == .debug) "" else " " ++ @tagName(greet.mode) ++ if (@sizeOf(Bare) == 8) " untagged" else "";
const Bare = union { a: u64, b: u8 };

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

// `bs build test --fuzz` finds the planted crash (check.sh).
test "fuzz" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [8]u8 = undefined;
            const n = smith.slice(&buf);
            _ = greet.pick(n);
            if (n >= 3 and buf[0] == 'z' and buf[1] == 'a' and buf[2] == 'p') @panic("planted crash");
        }
    }.testOne, .{});
}
