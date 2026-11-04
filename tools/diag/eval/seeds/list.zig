const std = @import("std");

fn squares(gpa: std.mem.Allocator, n: u32) ![]u32 {
    var list: std.ArrayList(u32) = .empty;
    errdefer list.deinit(gpa);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        try list.append(gpa, i * i);
    }
    try list.appendSlice(gpa, &.{ 1000, 2000 });
    return list.toOwnedSlice(gpa);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const values = try squares(gpa, 5);
    defer gpa.free(values);
    var sum: u32 = 0;
    for (values) |v| sum += v;
    std.debug.print("sum: {d}\n", .{sum});
}
