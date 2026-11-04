//! exit: 7
//! stdout: "55\n144\n25\n42\n9\n1099511627776\n2\n700\n20\n6\n5\n4\npow2\n13\n99\n48\n3\n7\n31\n1234\n7\n500\n1891\n11\n66\n0\n"
const std = @import("std");
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

fn fib(n: u32) u32 {
    if (n < 2) return n;
    return fib(n - 1) + fib(n - 2);
}

fn max(comptime T: type, a: T, b: T) T {
    return if (a > b) a else b;
}

fn Pair(comptime T: type) type {
    return struct {
        a: T,
        b: T,

        const Self = @This();

        fn sum(self: Self) T {
            return self.a + self.b;
        }
    };
}

fn table(comptime n: usize) [n]u32 {
    var t: [n]u32 = undefined;
    for (&t, 0..) |*x, i| x.* = @intCast(i * i);
    return t;
}

const fib10 = fib(10);

// Element and field stores into comptime memory, mixed with whole reads: a
// value read out must not see later stores, and stores through a slice or a
// many-pointer must land in the same memory as stores through the array.
const Cell = struct { tag: u8, v: [3]u16, o: ?u8 = null };
const cells = blk: {
    var a: [4]Cell = undefined;
    for (&a, 0..) |*c, i| {
        c.* = .{ .tag = @intCast(i), .v = .{ 0, 0, 0 } };
        c.v[1] = @intCast(i * 10);
        c.v[2] = c.v[1] + 1;
    }
    a[2].o = 7;
    const snap = a;
    a[0].tag = 99;
    a[1] = snap[3];
    a[1].v[0] = snap[0].tag + snap[2].o.?;
    const sl = a[3].v[1..];
    sl[1] = 500;
    const many: [*]u16 = &a[2].v;
    many[0] = 1234;
    var grid: [3][3]u8 = @splat(@splat(0));
    for (0..3) |i| for (0..3) |j| {
        grid[i][j] = @intCast(i * 3 + j);
    };
    const row = grid[1];
    grid[2] = row;
    grid[1][1] = 40;
    a[0].v[0] = grid[2][1] + grid[1][1] + row[1];
    break :blk a;
};

// Stores through subarray views (`buf[i..][0..n]`, as std.Io.Writer's
// @memcpy makes) land in the array they view, also through a view of a
// view, and a value read out before them does not see them.
const views = blk: {
    var buf: [8]u8 = @splat(0);
    const s: []u8 = &buf;
    @memcpy(s[2..][0..3], "abc");
    const before = buf;
    const v = s[1..][0..6];
    @memcpy(v[4..][0..2], "xy");
    v[0] = v[2] - 'a' + 'A';
    break :blk [2][8]u8{ buf, before };
};
const json_len = blk: {
    @setEvalBranchQuota(1_000_000);
    var buf: [8 * 1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    var jws: std.json.Stringify = .{ .writer = &writer };
    jws.beginArray() catch unreachable;
    for (0..500) |i| jws.write(i) catch unreachable;
    jws.endArray() catch unreachable;
    break :blk writer.end;
};

// A local type may name a runtime parameter's type (std.sort.upperBound).
fn addVia(context: anytype, x: u32) u32 {
    const S = struct {
        fn add(ctx: @TypeOf(context), y: u32) u32 {
            return ctx + y;
        }
    };
    return S.add(context, x);
}
const squares = table(6);
const answer: u8 = blk: {
    var x: u8 = 0;
    var i: u8 = 0;
    while (i < 7) : (i += 1) x += 6;
    break :blk x;
};

fn isPow2(comptime x: comptime_int) bool {
    return x != 0 and (x & (x - 1)) == 0;
}

fn main() callconv(.c) noreturn {
    rt.printInt(fib10);
    rt.printInt(comptime fib(12));
    rt.printInt(squares[5]);
    rt.printInt(answer);
    rt.printInt(max(u8, 3, 9));
    rt.printInt(max(u64, 1 << 40, 5));
    var v: i16 = -3;
    _ = &v;
    rt.printInt(@intCast(max(i16, v, 2)));
    const P = Pair(u16);
    const p: P = .{ .a = 300, .b = 400 };
    rt.printInt(p.sum());
    rt.printInt(@sizeOf(P) + @sizeOf(Pair(u64)));
    var s: u32 = 0;
    inline for (.{ 1, 2, 3 }) |k| s += k;
    rt.printInt(s);
    comptime var c = 1;
    c *= 5;
    rt.printInt(c);
    const t = .{ @as(u8, 4), true };
    rt.printInt(if (t[1]) t[0] else 0);
    if (comptime isPow2(64)) rt.print("pow2\n");
    var ten: u32 = 10;
    _ = &ten;
    rt.printInt(addVia(ten, 3));
    rt.printInt(cells[0].tag);
    rt.printInt(cells[0].v[0]);
    rt.printInt(cells[1].tag);
    rt.printInt(cells[1].v[0]);
    rt.printInt(cells[1].v[2]);
    rt.printInt(cells[2].v[0]);
    rt.printInt(cells[2].o.?);
    rt.printInt(cells[3].v[2]);
    rt.printInt(json_len);
    rt.printInt(@intFromBool(std.mem.eql(u8, &views[0], "\x00Babcxy\x00")) + 2 * @as(u64, @intFromBool(std.mem.eql(u8, &views[1], "\x00\x00abc\x00\x00\x00"))) + 8);
    rt.printInt(views[0][1]);
    rt.printInt(@intFromBool(@hasDecl(@typeInfo(Tagged).@"union".tag_type.?, "x")));
    rt.exit(@intCast(@bitSizeOf(u7)));
}

// As upstream, a comptime declaration may compute runtime values nothing
// needs, and a union's generated tag enum has no declarations.
var lazy_rt: u32 = 5;
comptime {
    _ = lazy_rt;
    _ = lazy_rt + 1;
}
const Tagged = union(enum) {
    a: u8,
    pub const x = 1;
};
