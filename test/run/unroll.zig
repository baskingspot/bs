//! exit: 0
//! stdout: "68 1 null 5 20 13 99 507 394\n"

// Tiny constant-trip `for` loops are unrolled (`codegen/unroll.zig`):
// each copy of the body has the counter as a constant. `continue`,
// `break`, `return` and labeled breaks out of a copy, nested loops, and a
// start other than 0 keep their meaning; a loop of more than 8 iterations
// stays a loop.
const std = @import("std");

const weights = [_]u32{ 3, 5, 7, 11 };
const names = [_][]const u8{ "a", "bb", "ccc" };

noinline fn weighted(x: []const u32) u32 {
    var sum: u32 = 0;
    for (weights, 0..) |w, i| {
        if (i == 1) continue;
        sum += w * x[i];
    }
    return sum;
}

noinline fn firstLong(min: usize) ?usize {
    for (names, 0..) |n, i| {
        if (n.len >= min) return i;
    }
    return null;
}

noinline fn countTo(stop: usize) usize {
    var n: usize = 0;
    for (2..7) |i| {
        if (i == stop) break;
        n += i;
    }
    return n;
}

noinline fn nested(x: u32) u32 {
    var acc: u32 = 0;
    outer: for (0..3) |i| {
        for (0..3) |j| {
            if (i * 3 + j == x) break :outer;
            acc += @intCast(i * 10 + j);
        }
    }
    return acc;
}

noinline fn long(x: u32) u32 {
    var acc: u32 = x;
    for (0..12) |i| acc +%= @intCast(i * i);
    return acc;
}

noinline fn indexes(x: []const u8) usize {
    var n: usize = 0;
    for (0..4) |i| n += x[i];
    return n;
}

pub fn main() void {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const x = [_]u32{ 1, 2, 3, 4 };
    w.print("{} {any} {any} {} {} {} {} {} {}\n", .{
        weighted(&x),
        firstLong(2),
        firstLong(4),
        countTo(4),
        countTo(9),
        nested(4),
        nested(20),
        long(1),
        indexes("abcd"),
    }) catch unreachable;
    std.Io.File.stdout().writeStreamingAll(std.Options.debug_io, w.buffered()) catch {};
}
