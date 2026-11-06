//! exit: 0
//! stdout: "68 1 null 5 20 13 99 507 394 8589934593 120 7442\n"

// Tiny constant-trip `for` loops are unrolled (`codegen/unroll.zig`):
// each copy of the body has the counter as a constant. `continue`,
// `break`, `return` and labeled breaks out of a copy, nested loops, and a
// start other than 0 keep their meaning; a loop of more than 8 iterations
// stays a loop. Line markers do not count toward the size budget, so
// `MultiArrayList.slice` of an 8-field struct is unrolled. A slice's
// constant length (`@ptrCast` of a `*T`, as in `std.mem.swap`) counts as
// a constant trip count.
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

noinline fn byteSum(v: *const u64) u32 {
    const bytes: []const u8 = @ptrCast(v);
    var s: u32 = 0;
    for (bytes, 0..) |b, i| s += b * @as(u32, @intCast(i + 1));
    return s;
}

const Eight = struct { a: u32, b: u64, c: u8, d: u16, e: u32, f: u64, g: u8, h: u32 };

noinline fn eight(list: *const std.MultiArrayList(Eight)) u64 {
    const s = list.slice();
    var sum: u64 = 0;
    for (s.items(.b), s.items(.d), s.items(.g), s.items(.h)) |b, d, g, h| sum += b * d + g + h;
    return sum;
}

pub fn main() void {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const x = [_]u32{ 1, 2, 3, 4 };
    const v: u64 = 0x0102030405060708;
    var mem: [256]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&mem);
    var list: std.MultiArrayList(Eight) = .empty;
    list.setCapacity(fba.allocator(), 3) catch unreachable;
    for (1..4) |k| list.appendAssumeCapacity(.{ .a = 1, .b = k * 100, .c = 2, .d = @intCast(k), .e = 3, .f = 4, .g = @intCast(k * 7), .h = @intCast(k * 1000) });
    w.print("{} {any} {any} {} {} {} {} {} {} {} {} {}\n", .{
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
        eight(&list),
    }) catch unreachable;
    std.Io.File.stdout().writeStreamingAll(std.Options.debug_io, w.buffered()) catch {};
}
