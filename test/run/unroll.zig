//! exit: 0
//! stdout: "68 1 null 5 20 13 99 507 394 8589934593 120 231 345612 987 7\n"

// Tiny constant-trip `for` loops are unrolled (`codegen/unroll.zig`):
// each copy of the body has the counter as a constant. `continue`,
// `break`, `return` and labeled breaks out of a copy, nested loops, and a
// start other than 0 keep their meaning; a loop of more than 8 iterations
// stays a loop. A slice's constant length (`@ptrCast` of a `*T`, as in
// `std.mem.swap`) counts as a constant trip count, and `std.mem.swap`'s
// byte loop moves words instead: overlapping, coinciding and
// multi-word swaps keep the byte loop's meaning.
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

noinline fn swapped(a: u32, b: u32) u64 {
    var x = a;
    var y = b;
    std.mem.swap(u32, &x, &y);
    return @as(u64, x) << 32 | y;
}

noinline fn overlapped(base: u32) u32 {
    var arr: [3]u32 = .{ base, base + 1, base + 2 };
    std.mem.swap([2]u32, arr[0..2], arr[1..3]);
    return arr[0] * 100 + arr[1] * 10 + arr[2];
}

noinline fn overlappedWords(base: u64) u64 {
    var arr: [6]u64 = undefined;
    for (&arr, 0..) |*e, i| e.* = base + i;
    std.mem.swap([4]u64, arr[0..4], arr[2..6]);
    var n: u64 = 0;
    for (arr) |e| n = n * 10 + e;
    return n;
}

const S12 = struct { a: u32, b: u32, c: u32 };

noinline fn swapped12(x: u32) u32 {
    var s: S12 = .{ .a = x, .b = x + 1, .c = x + 2 };
    var t: S12 = .{ .a = 9, .b = 8, .c = 7 };
    std.mem.swap(S12, &s, &t);
    return s.a * 100 + s.b * 10 + s.c + t.a - x;
}

noinline fn swappedSelf(x: u16) u16 {
    var v = x;
    std.mem.swap(u16, &v, &v);
    return v;
}

noinline fn byteSum(v: *const u64) u32 {
    const bytes: []const u8 = @ptrCast(v);
    var s: u32 = 0;
    for (bytes, 0..) |b, i| s += b * @as(u32, @intCast(i + 1));
    return s;
}

pub fn main() void {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const x = [_]u32{ 1, 2, 3, 4 };
    const v: u64 = 0x0102030405060708;
    w.print("{} {any} {any} {} {} {} {} {} {} {} {} {} {} {} {}\n", .{
        weighted(&x),
        firstLong(2),
        firstLong(4),
        countTo(4),
        countTo(9),
        nested(4),
        nested(20),
        long(1),
        indexes("abcd"),
        swapped(1, 2),
        byteSum(&v),
        overlapped(1),
        overlappedWords(1),
        swapped12(1),
        swappedSelf(7),
    }) catch unreachable;
    std.Io.File.stdout().writeStreamingAll(std.Options.debug_io, w.buffered()) catch {};
}
