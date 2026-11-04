const std = @import("std");

fn Stack(comptime T: type) type {
    return struct {
        items: [16]T = undefined,
        len: usize = 0,

        const Self = @This();

        fn push(self: *Self, value: T) void {
            self.items[self.len] = value;
            self.len += 1;
        }

        fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            self.len -= 1;
            return self.items[self.len];
        }
    };
}

fn maxOf(comptime T: type, a: T, b: T) T {
    return if (a > b) a else b;
}

pub fn main() void {
    var stack: Stack(i32) = .{};
    stack.push(3);
    stack.push(maxOf(i32, 4, 7));
    const top = stack.pop().?;
    const next = stack.pop() orelse 0;
    std.debug.print("{d} {d}\n", .{ top, next });
}
