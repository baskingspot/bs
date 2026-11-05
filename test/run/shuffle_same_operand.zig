//! exit: 0
//! flags: -mcpu=x86_64_v2
//! targets: x86_64-linux
//! stderr: "{ 11, 22, 33, 22 }\n{ 11, 33, 33, 11, 44 }\n{ 44, 11, 11, 44, 33, 22, 22, 33 }\n{ 11, 11, 22, 22, 33, 33, 44, 44, 44, 44, 33, 33, 22, 22, 11, 11 }\n{ 11, 22, 33, 22 }\n{ 11, 44, 33, 22 }\n{ 44, 11, 11, 44, 33 }\n{ 11, 22, 22, 11, 44, 44, 33, 33 }\n{ 127, 75, 75, 127 }\n{ 127, -58, -58, -58, 75 }\n{ 127, 7, 7, 127, 0, 75, 75, 0 }\n{ 127, 7, 7, 127, 2, 4, 75, 0, 6, 0, 0, 6, 0, 75, 4, 2 }\n{ 10, 40, 90, 160 }\n{ 10, 22, 33, 160 }\n"

// `@shuffle` and `@select` of one runtime vector with itself, at a CPU
// with SSSE3 (pshufb). A shuffle taking lanes from both operands reads
// them all from the one vector, not from the half-built result in its
// register, and a select of a value with itself is that value.
const std = @import("std");

var ga: @Vector(4, u32) = .{ 1, 2, 3, 4 };
var gb: @Vector(4, u32) = .{ 10, 20, 30, 40 };
var gc: @Vector(16, i8) = .{ 0, 0, 0, -2, -1, 3, 1, 2, 0, 0, 0, 0, 0, 0, 0, 0 };
var gd: @Vector(16, i8) = .{ 127, -58, 75, 35, -1, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, -1 };
var gp: @Vector(4, bool) = .{ true, false, false, true };

fn bytes(comptime n: usize) void {
    const c: @Vector(n, i8) = @as([16]i8, gc)[0..n].*;
    const d: @Vector(n, i8) = @as([16]i8, gd)[0..n].*;
    const s = d -| c;
    const m = comptime blk: {
        var m: [n]i32 = undefined;
        for (&m, 0..) |*x, i| x.* = if (i % 2 == 0) @intCast((i * 3) % n) else ~@as(i32, @intCast((i * 5 + 1) % n));
        break :blk m;
    };
    std.debug.print("{any}\n", .{@shuffle(i8, s, s, m)});
}

fn words(comptime m: anytype) void {
    const r = gb +% ga;
    std.debug.print("{any}\n", .{@shuffle(u32, r, r, m)});
}

pub fn main() void {
    words(@Vector(4, i32){ 0, -2, -3, 1 });
    words(@Vector(5, i32){ -1, 2, -3, 0, -4 });
    words(@Vector(8, i32){ 3, -1, 0, -4, 2, -2, 1, -3 });
    words(@Vector(16, i32){ 0, -1, 1, -2, 2, -3, 3, -4, -4, 3, -3, 2, -2, 1, -1, 0 });
    const r = gb +% ga;
    std.debug.print("{any}\n", .{@shuffle(u32, r, r, @Vector(4, i32){ 0, -2, -3, 1 })});
    std.debug.print("{any}\n", .{@shuffle(u32, r, r, @Vector(4, i32){ -1, -4, -3, -2 })});
    std.debug.print("{any}\n", .{@shuffle(u32, r, r, @Vector(5, i32){ 3, -1, 0, -4, 2 })});
    std.debug.print("{any}\n", .{@shuffle(u32, r, r, @Vector(8, i32){ 0, -2, 1, -1, 3, -4, 2, -3 })});
    bytes(4);
    bytes(5);
    bytes(8);
    bytes(16);
    const q = gb *% ga;
    std.debug.print("{any}\n", .{@select(u32, gp, q, q)});
    std.debug.print("{any}\n", .{@select(u32, gp, q, r)});
}
