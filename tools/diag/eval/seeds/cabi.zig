const std = @import("std");

const Pair = extern struct { a: c_int, b: c_int };

export fn addPair(p: *const Pair) callconv(.c) c_int {
    return p.a + p.b;
}

fn cold() void {
    @branchHint(.cold);
    std.debug.print("cold path\n", .{});
}

pub fn main() void {
    const p: Pair = .{ .a = 2, .b = 3 };
    if (addPair(&p) != 5) cold();
    std.debug.print("{d}\n", .{addPair(&p)});
}
