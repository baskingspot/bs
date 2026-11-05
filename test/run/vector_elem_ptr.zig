//! exit: 0
//! stderr: "{ 10, 25, 30, 99 } { false, false, false, false, false, true, true, false } .{ { 1, 2, 30, 4 }, { false, true, false, false }, 7 } { 4.5, 1.5, 1.5, 1.5 }\ntrue *align(1:0:3:1) const u8 false\n"
//! A pointer to a vector element has upstream's type for one: it holds
//! the vector's address, and its type names the element's index and the
//! vector's length (`*align(4:0:4:1) u32`), so it does not coerce to a
//! plain pointer. Loads and stores through it, at runtime and at
//! comptime, reach the element, also in a global bool vector.
const std = @import("std");

var g: @Vector(4, u32) = .{ 10, 20, 30, 40 };
var gb: @Vector(8, bool) = @splat(false);
const cv: @Vector(3, u8) = .{ 5, 6, 7 };

fn bump(p: @TypeOf(&g[1])) void {
    p.* += 5;
}

noinline fn store(pp: *@TypeOf(&g[3]), v: u32) void {
    pp.*.* = v;
}

pub fn main() void {
    bump(&g[1]);
    var holder = &g[3];
    store(&holder, 99);
    gb[5] = true;
    const pb = &gb[6];
    pb.* = !pb.*;
    const ct = comptime blk: {
        var v: @Vector(4, i16) = .{ 1, 2, 3, 4 };
        const q = &v[2];
        q.* *= 10;
        var b: @Vector(4, bool) = @splat(false);
        (&b[1]).* = true;
        break :blk .{ v, b, (&cv[2]).* };
    };
    var lv: @Vector(4, f32) = @splat(1.5);
    const lp = &lv[0];
    lp.* = lp.* * 3;
    std.debug.print("{} {} {any} {}\n", .{ g, gb, ct, lv });
    std.debug.print("{} {s} {}\n", .{ @intFromPtr(&g[2]) == @intFromPtr(&g), @typeName(@TypeOf(&cv[1])), @TypeOf(&g[0]) == @TypeOf(&g[1]) });
}
