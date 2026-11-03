//! exit: 0
//! stdout: "476\n6\n6765\n55\n258\n55\n18\n1228\n"
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
    rt.printInt(peer);
    rt.exit(0);
}
