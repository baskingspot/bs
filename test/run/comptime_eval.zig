//! exit: 0
//! stdout: "476\n6\n6765\n55\n258\n55\n18\n28739\n1228\n606\n179668\n88\n582\n708\n710\n"
// Comptime calls repeated often enough for zap's comptime evaluator to run
// them from lowered IR instead of the ZIR walker; the results must be the
// walker's (and upstream's).
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

const Class = enum(u8) { other, digit, lower, upper, space };

fn classify(c: u8) Class {
    return switch (c) {
        '0'...'9' => .digit,
        'a'...'z' => .lower,
        'A'...'Z' => .upper,
        ' ', '\t', '\n' => .space,
        else => .other,
    };
}

fn weight(c: u8) ?u16 {
    const class = classify(c);
    if (class == .other) return null;
    var w: u16 = @intFromEnum(class);
    var i: u8 = 0;
    while (i < c % 7) : (i += 1) w += i;
    return w;
}

const table = blk: {
    @setEvalBranchQuota(100000);
    var t: [256]u16 = undefined;
    for (&t, 0..) |*e, c| e.* = weight(@intCast(c)) orelse 0;
    break :blk t;
};

const Acc = struct { sum: u32, count: u8 };

/// Mutates its caller's memory through a pointer.
fn accumulate(acc: *Acc, v: u32) void {
    acc.sum += v;
    acc.count +%= 1;
}

const counted = blk: {
    var acc: Acc = .{ .sum = 0, .count = 0 };
    for (0..6) |k| accumulate(&acc, @intCast(k * k));
    break :blk acc;
};

fn fibIter(n: u32) u32 {
    var a: u32 = 0;
    var b: u32 = 1;
    var i: u32 = 0;
    outer: while (true) : (i += 1) {
        if (i == n) break :outer;
        const next = b;
        b +%= a;
        a = next;
    }
    return a;
}

fn checkedDiv(a: u32, b: u32) error{DivByZero}!u32 {
    if (b == 0) return error.DivByZero;
    return a / b;
}

fn sumQuotients(n: u32) u32 {
    var s: u32 = 0;
    for (0..n) |d| s += checkedDiv(100, @intCast(d)) catch 0;
    return s;
}

fn addTen(count: *u32) void {
    count.* += 10;
}

/// Bumps a counter in caller memory, then calls through a function
/// pointer: an evaluator that gives up after the first write must undo it
/// before the walker runs the call again.
fn bump(count: *u32, k: u8, f: *const fn (*u32) void) void {
    count.* += 1;
    if (k == 6) f(count);
}

const bumped = blk: {
    var count: u32 = 0;
    for (0..8) |k| bump(&count, @intCast(k), &addTen);
    break :blk count;
};

fn sumOf(comptime T: type, xs: []const T) T {
    var s: T = 0;
    for (xs) |x| s +%= x;
    return s;
}

fn eqlOf(comptime T: type, a: []const T, b: []const T) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

fn addOf(comptime T: type, a: T, b: T) T {
    return a +% b;
}

fn twice(x: anytype) @TypeOf(x) {
    return x *% 2;
}

fn bitsOf(T: type, n: u16) u16 {
    return @bitSizeOf(T) * n;
}

/// Generic functions run per specialization: the comptime arguments'
/// values and the other arguments' types.
const generic = blk: {
    @setEvalBranchQuota(10000);
    var t: u64 = 0;
    const words = [_][]const u8{ "alpha", "beta", "gamma", "beta", "delta", "epsilon", "zeta", "eta", "theta", "beta", "iota", "kappa" };
    for (words, 0..) |w, i| {
        t += sumOf(u8, w);
        if (eqlOf(u8, w, "beta")) t += 1000;
        t += addOf(u16, 7, @intCast(w.len * i));
        t += addOf(u8, 250, @intCast(i));
        t += twice(@as(u32, @intCast(w.len + i)));
        t += twice(@as(u8, 120 + @as(u8, @intCast(i))));
        t += bitsOf(u32, @intCast(i)) + bitsOf([3]u8, 1);
    }
    for (0..6) |k| t += sumOf(u16, &.{ @intCast(k), 1000, 2000 });
    break :blk t;
};

/// The walker types an `if` by the branch it takes; runtime analysis
/// would give it the peer type of both.
fn branchSize(c: bool, k: u32) u32 {
    const x = if (c) @as(u8, 255) else @as(u16, 300);
    return @sizeOf(@TypeOf(x)) * 100 + k;
}

const peer = blk: {
    var t: u32 = 0;
    for (0..8) |k| t += branchSize(k % 2 == 0, @intCast(k));
    break :blk t;
};

/// Loops long enough for the evaluator to take them over from the walker
/// midway (on-stack replacement): reading the walker's variables, the
/// elements of a comptime_int slice, a narrowing that only a known value
/// allows, and leaving the loop by a break with a value.
const osr_table = blk: {
    @setEvalBranchQuota(100000);
    const vals: []const comptime_int = &.{ 3, 1, 4, 1, 5, 9, 2, 6, 5, 3, 5, 8, 9, 7, 9 };
    var t: [600]u16 = undefined;
    var acc: Acc = .{ .sum = 0, .count = 0 };
    for (&t, 0..) |*e, i| {
        var x: u16 = i;
        const v: u8 = @intCast(vals[i % vals.len]);
        x ^= v;
        accumulate(&acc, x);
        e.* = x;
    }
    var k: usize = 0;
    const found = while (k < t.len) : (k += 1) {
        if (t[k] > 590) break k;
    } else 0;
    break :blk .{ t[599], acc.sum, acc.count, found };
};

/// A return from inside a long loop of a function called once.
fn firstAbove(limit: u32) u32 {
    var i: u32 = 0;
    while (true) : (i += 1) {
        if (i *% i > limit) return i;
    }
}

/// The evaluator gives up on comparing floats after the loop has written
/// the walker's memory many times; the walker must run the loop on from
/// where the evaluator took it over.
const osr_abort = blk: {
    @setEvalBranchQuota(100000);
    var count: u32 = 0;
    var f: f32 = 0.5;
    for (0..700) |k| {
        count += 1;
        if (k == 500 and f < 1.0) {
            count += 10;
            f = 2.0;
        }
    }
    break :blk count;
};

fn main() callconv(.c) noreturn {
    var s: u32 = 0;
    for (table) |w| s += w;
    rt.printInt(s);
    rt.printInt(counted.count);
    rt.printInt(comptime fibIter(20));
    rt.printInt(comptime blk: {
        var t: u32 = 0;
        for (0..11) |n| t = fibIter(@intCast(n));
        break :blk t;
    });
    rt.printInt(comptime sumQuotients(8));
    rt.printInt(counted.sum);
    rt.printInt(bumped);
    rt.printInt(generic);
    rt.printInt(peer);
    rt.printInt(osr_table[0]);
    rt.printInt(osr_table[1]);
    rt.printInt(osr_table[2]);
    rt.printInt(osr_table[3]);
    rt.printInt(comptime firstAbove(500000));
    rt.printInt(osr_abort);
    rt.exit(0);
}
