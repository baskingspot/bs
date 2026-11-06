//! exit: 0
//! stderr: "r 171 171 0 248 | t 1 128 | z 0 0 | l 2 3 4 5 0 | s 99 7 | v 4 1 | m 9 7 7 9 | e 8 0 | u 5\n"
//! Results returned in memory, written where they go. A callee's
//! aggregate that its `ret` returns is built in the caller's result
//! memory, and a call that initializes a fresh `var` gets the var as its
//! result memory. Neither may apply where the result memory is already
//! visible: an assignment to memory the callee reads, or a destination
//! the callee is passed.
const std = @import("std");

const N = 1 << 16;
const Big = struct { a: [N]u8, b: u64, c: u64 };

// A repeated byte and a constant that is not one, both large.
noinline fn rep() [N]u8 {
    return @splat(0xab);
}
const table = blk: {
    @setEvalBranchQuota(10 * N);
    var t: [N]u8 = undefined;
    for (&t, 0..) |*x, i| x.* = @truncate(i *% 7 +% (i >> 8));
    break :blk t;
};
noinline fn tab() [N]u8 {
    return table;
}
// What std.mem.zeroes is: a splat of a value computed at run time.
inline fn zero(comptime T: type) T {
    return 0;
}
noinline fn zeroes() [N]u8 {
    return @splat(zero(u8));
}
noinline fn make(x: u8, b: u64, c: u64) Big {
    return .{ .a = @splat(x), .b = b, .c = c };
}

// Reads all of `p` while building its result: the result memory must not
// be `p`'s.
noinline fn swapped(p: *const Big) Big {
    var r: Big = undefined;
    for (&r.a, 0..) |*x, i| x.* = p.a[N - 1 - i];
    r.b = p.c;
    r.c = p.b;
    return r;
}
noinline fn swappedAgg(p: *const Big) Big {
    return .{ .a = p.a, .b = p.c, .c = p.b };
}
noinline fn viaChain(p: *const Big) Big {
    return swappedAgg(p);
}

const Holder = struct {
    big: Big,
    fn step(self: *Holder) void {
        self.big = swapped(&self.big);
    }
};

const U = union(enum) { big: Big, small: u8 };
noinline fn mkUnion(x: u8) U {
    return .{ .big = make(x, x, x) };
}

// Saved addresses of the previous iteration's `var`, which the callee
// does not read.
var last: ?*const [N]u8 = null;
var sink: u64 = 0;

noinline fn early(n: u8) Big {
    if (n == 0) return make(9, 9, 9);
    var r: Big = undefined;
    @memset(&r.a, n);
    if (n == 7) return r;
    r.b = n;
    r.c = n;
    return r;
}

pub fn main() void {
    const r = rep();
    var t = tab();
    t[1] +%= 0;
    var z = zeroes();
    z[0] = z[N - 1];
    std.debug.print("r {} {} {} {} | ", .{ r[0], r[N - 1], table[0], table[N - 1] });
    std.debug.print("t {} {} | ", .{ @as(u8, @intFromBool(std.mem.eql(u8, &t, &table))), t[N / 2] });
    std.debug.print("z {} {} | ", .{ z[0], z[N / 3] });

    var loops: [4]u8 = undefined;
    for (0..4) |i| {
        var x = make(@intCast(i + 2), i, i);
        if (last) |p| sink +%= p[0];
        loops[i] = x.a[N - 1];
        x.a[0] +%= 1;
        last = &x.a;
    }
    // std.mem.zeroes builds its result with `@splat` of a value of a call
    // it inlines, so not a constant.
    var zs: u64 = 0;
    for (0..3) |i| {
        var x = std.mem.zeroes([N]u8);
        var y = std.mem.zeroes(Big);
        zs += x[i] + x[N - 1] + y.a[N - 1] + y.c;
        x[i] = 1;
        y.c = 1;
        last = &x;
    }
    std.debug.print("l {} {} {} {} {} | ", .{ loops[0], loops[1], loops[2], loops[3], zs });

    var h: Holder = .{ .big = make(1, 7, 99) };
    h.big.a[N - 1] = 99;
    h.step();
    std.debug.print("s {} {} | ", .{ h.big.a[0], h.big.c });

    var v = make(3, 1, 4);
    v = swappedAgg(&v);
    std.debug.print("v {} {} | ", .{ v.b, v.c });

    var m = make(5, 7, 9);
    var m2 = viaChain(&m);
    m = viaChain(&m);
    std.debug.print("m {} {} {} {} | ", .{ m.b, m.c, m2.c, m2.b });
    m2.b = 0;

    var e = early(7);
    var e0 = early(0);
    std.debug.print("e {} {} | ", .{ e.a[3] + 1, e0.a[1] - 9 });
    e.b = 0;
    e0.b = 0;

    var u = mkUnion(5);
    u.big.b +%= 0;
    std.debug.print("u {}\n", .{u.big.a[N - 1]});
}
