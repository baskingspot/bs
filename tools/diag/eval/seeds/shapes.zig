const std = @import("std");

const Shape = union(enum) {
    circle: f64,
    rect: struct { w: f64, h: f64 },

    fn area(self: Shape) f64 {
        return switch (self) {
            .circle => |r| std.math.pi * r * r,
            .rect => |r| r.w * r.h,
        };
    }
};

fn totalArea(shapes: []const Shape) f64 {
    var total: f64 = 0;
    for (shapes) |s| total += s.area();
    return total;
}

pub fn main() void {
    const shapes = [_]Shape{ .{ .circle = 1.0 }, .{ .rect = .{ .w = 2, .h = 3 } } };
    const t = totalArea(&shapes);
    std.debug.print("{d:.2} {d}\n", .{ t, @sqrt(t) });
}
