// Adapted from zul's src/sort.zig
// (https://github.com/karlseguin/zul), MIT License, Copyright (c) Karl Seguin.
const std = @import("std");

pub const Direction = enum {
    asc,
    desc,

    pub fn toOrder(self: Direction) std.math.Order {
        return switch (self) {
            .asc => .lt,
            .desc => .gt,
        };
    }
};

pub fn strings(values: [][]const u8, direction: Direction) void {
    std.mem.sortUnstable([]const u8, values, direction.toOrder(), struct {
        fn order(d: std.math.Order, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == d;
        }
    }.order);
}

pub fn asciiIgnoreCase(values: [][]const u8, direction: Direction) void {
    std.mem.sortUnstable([]const u8, values, direction.toOrder(), struct {
        fn order(d: std.math.Order, lhs: []const u8, rhs: []const u8) bool {
            return std.ascii.orderIgnoreCase(lhs, rhs) == d;
        }
    }.order);
}

pub fn numbers(comptime T: type, values: []T, direction: Direction) void {
    switch (direction) {
        .asc => std.mem.sortUnstable(T, values, {}, std.sort.asc(T)),
        .desc => std.mem.sortUnstable(T, values, {}, std.sort.desc(T)),
    }
}

const t = std.testing;
test "sort: string / ascii" {
    var values = [_][]const u8{ "ABC", "abc", "Dog", "Cat", "horse", "chicken" };
    strings(&values, .asc);
    try t.expectEqualStrings("ABC", values[0]);
    try t.expectEqualStrings("Cat", values[1]);
    try t.expectEqualStrings("horse", values[5]);

    asciiIgnoreCase(&values, .desc);
    try t.expectEqualStrings("Cat", values[3]);
    try t.expectEqualStrings("chicken", values[2]);
    try t.expectEqualStrings("horse", values[0]);
}

test "sort: numbers" {
    var values = [_]i32{ 10, -20, 33, 0, 2, 6 };
    numbers(i32, &values, .asc);
    try t.expectEqual(-20, values[0]);
    try t.expectEqual(33, values[5]);

    numbers(i32, &values, .desc);
    try t.expectEqual(-20, values[5]);
    try t.expectEqual(33, values[0]);
}
