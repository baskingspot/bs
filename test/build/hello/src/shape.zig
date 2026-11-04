const c = @import("c");

pub fn main() void {
    const s: c.struct_shape = .{ .sides = c.SHAPE_SIDES, .name = "triangle" };
    _ = c.printf("%s %d %d\n", s.name, c.shape_sides(s), @as(c_int, c.SHAPE_AREA));
}
