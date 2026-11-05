//! exit: 0
//! stderr: "add 12 E sub 250 E mul 4200 E i 9 E\nw 340282366920938463463374607431768211455 E -3 E\nloop 1240 1360 call 90 sum 34 nest 324 dead 7 twice 7 4\n"
//! std.math.add's shape: an overflow operation's tuple goes to a `const`,
//! whose bit the branch tests and whose value is read after the error
//! return. The tuple's fields are written by the operation (`Ssa.plan`'s
//! pairs) and the bit is left in the flags for the branch, which tests a
//! load forwarded from it. The value is read inside a loop the operation
//! is outside of, after a call, in a loop around both, in an inner loop,
//! and in a block that does not continue; a bit read again later stays
//! a value.
const std = @import("std");

noinline fn add(comptime T: type, a: T, b: T) !T {
    const ov = @addWithOverflow(a, b);
    if (ov[1] != 0) return error.Overflow;
    return ov[0];
}
noinline fn sub(comptime T: type, a: T, b: T) !T {
    const ov = @subWithOverflow(a, b);
    if (ov[1] != 0) return error.Overflow;
    return ov[0];
}
noinline fn mul(comptime T: type, a: T, b: T) !T {
    const ov = @mulWithOverflow(a, b);
    if (ov[1] != 0) return error.Overflow;
    return ov[0];
}

fn show(w: anytype, r: anytype) void {
    if (r) |v| w.print(" {d}", .{v}) else |_| w.print(" E", .{});
}

var sink: u64 = 0;
noinline fn clobber(x: u64) u64 {
    sink +%= x;
    return x *% 3;
}

// Read inside a loop the operation is outside of, with calls in the loop.
noinline fn inLoop(a: u64, b: u64, n: u64) !u64 {
    const ov = @addWithOverflow(a, b);
    if (ov[1] != 0) return error.Overflow;
    var s: u64 = 0;
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        s += ov[0] + clobber(i) + i;
    }
    return s;
}

// Read after a call.
noinline fn afterCall(a: u32, b: u32) !u64 {
    const ov = @mulWithOverflow(a, b);
    if (ov[1] != 0) return error.Overflow;
    const c = clobber(a);
    return c + ov[0];
}

// The operation and its read in the same loop, iteration by iteration.
noinline fn sumChecked(xs: []const u8) !u8 {
    var s: u8 = 0;
    for (xs) |x| {
        const ov = @addWithOverflow(s, x);
        if (ov[1] != 0) return error.Overflow;
        _ = clobber(x);
        s = ov[0];
    }
    return s;
}

// Read in an inner loop the operation is outside of.
noinline fn nested(a: i32, b: i32) !i64 {
    const ov = @subWithOverflow(a, b);
    if (ov[1] != 0) return error.Overflow;
    var t: i64 = 0;
    for (0..3) |i| {
        for (0..4) |j| t += ov[0] * @as(i64, @intCast(i + j)) + @as(i64, @intCast(clobber(j)));
    }
    return t;
}

// Read in a block that does not continue.
noinline fn dead(a: u16, b: u16) u16 {
    const ov = @addWithOverflow(a, b);
    if (ov[1] != 0) {
        _ = clobber(a);
        std.debug.panic("overflow to {d}", .{ov[0]});
    }
    return ov[0];
}

// The bit read again after the branch.
noinline fn twice(a: u8, b: u8) u8 {
    const ov = @addWithOverflow(a, b);
    if (ov[1] != 0) {
        _ = clobber(a);
    }
    return @as(u8, ov[1]) + ov[0];
}

const W = struct {
    pub fn print(_: W, comptime f: []const u8, args: anytype) void {
        std.debug.print(f, args);
    }
};

pub fn main() void {
    const w: W = .{};
    w.print("add", .{});
    show(w, add(u8, 5, 7));
    show(w, add(u8, 250, 7));
    w.print(" sub", .{});
    show(w, sub(u8, 255, 5));
    show(w, sub(u8, 5, 7));
    w.print(" mul", .{});
    show(w, mul(u16, 60, 70));
    show(w, mul(u16, 600, 700));
    w.print(" i", .{});
    show(w, add(i32, -3, 12));
    show(w, add(i32, std.math.maxInt(i32), 1));
    w.print("\nw", .{});
    show(w, add(u128, std.math.maxInt(u128) - 5, 5));
    show(w, add(u128, std.math.maxInt(u128), 1));
    show(w, sub(i128, 4, 7));
    show(w, sub(i128, std.math.minInt(i128), 1));
    const l1 = inLoop(100, 6, 10) catch 0;
    const l2 = inLoop(110, 8, 10) catch 0;
    const c = afterCall(5, 15) catch 0;
    const s = sumChecked(&.{ 3, 4, 5, 22 }) catch 0;
    const n = nested(10, 1) catch 0;
    w.print("\nloop {d} {d} call {d} sum {d} nest {d} dead {d} twice {d} {d}\n", .{ l1, l2, c, s, n, dead(3, 4), twice(3, 4), twice(250, 9) });
}
