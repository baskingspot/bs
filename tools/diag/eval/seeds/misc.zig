const std = @import("std");

fn Unsigned(comptime bits: u16) type {
    return @Int(.unsigned, bits);
}

pub fn main(init: std.process.Init) !void {
    const x: i32 = -5;
    const magnitude = @abs(x);
    const page = std.heap.pageSize();
    const home = init.environ_map.get("HOME") orelse "/";
    const small: Unsigned(4) = 7;
    std.debug.print("{d} {d} {s} {d}\n", .{ magnitude, page, home, small });
}
