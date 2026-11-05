//! exit: 0
//! stderr: "2728338536 54238937\n"
//! Branches on `and`/`or` conditions go to the condition's parts
//! directly, and a labeled switch `continue` with a constant goes to its
//! case: short-circuit order, a condition that is also a value, nested and
//! negated conditions, and continues into items, ranges and else.
//! Chains of `and` and `or`, and bool results of inlined calls passed on
//! through enclosing calls, one `return` or several, also read as values.
//! Branches on bool `|` and `&` jump on each operand: compares, the same
//! compare twice, negations, floats, loaded bools and nested operators.
//! A branch on a bool in memory reads the memory unless something between
//! the load and the branch may write it.
const std = @import("std");

var calls: u32 = 0;
fn side(r: bool) bool {
    calls = calls *% 31 +% @intFromBool(r) +% 1;
    return r;
}

fn conds(x: u32, y: u32) u32 {
    var acc: u32 = 0;
    if (x < 5 and side(y > 2)) acc += 1;
    if (x > 7 or side(y == 4)) acc += 2;
    const c = x == 3 or y == 3;
    if (c) acc += 4;
    acc += @as(u32, @intFromBool(c)) * 8;
    if ((x < 2 and y < 2) or (x > 8 and side(y > 8))) acc += 16;
    if (!(x == 1 or y == 1)) acc += 32;
    while (x + acc < 200 and !(acc & 64 != 0 and side(y < 3))) acc += 64;
    return acc;
}

fn chains(x: u32, y: u32, p: *const [4]bool) u32 {
    var acc: u32 = 0;
    if (x < 9 and y > 1 and !p[0] and p[1] != p[2]) acc += 1;
    if ((!p[3] and x != y and side(x > 4) and y < 8) or p[0]) acc += 2;
    if (x == 2 or y == 2 or (p[1] and p[2]) or side(x + y == 9)) acc += 4;
    const v = x > 3 and y > 3 and p[2];
    if (v) acc += 8;
    if (v and x < 8) acc += @as(u32, @intFromBool(v)) * 16;
    return acc;
}

fn lt(a: u32, b: u32) bool {
    return a < b;
}

fn lt2(items: []const u32, i: usize, j: usize) bool {
    return lt(items[i], items[j]);
}

fn pick(a: u32, b: u32) bool {
    if (a == 0) return true;
    if (b > a + 5) return false;
    return lt2(&.{ a, b }, 1, 0);
}

fn inlined(items: []u32, x: u32, y: u32) u32 {
    var acc: u32 = 0;
    var j: usize = items.len - 1;
    while (j > 0 and lt2(items, j, j - 1)) : (j -= 1) {
        std.mem.swap(u32, &items[j], &items[j - 1]);
        acc += 1;
    }
    if (pick(x, y)) acc += 10;
    if (!pick(y, x) and lt(x, 6)) acc += 20;
    const r = pick(x, y + 1);
    if (r) acc += 40;
    acc += @as(u32, @intFromBool(r)) * 80;
    const c = x < y;
    const q = blk: {
        if (x == 3) break :blk c;
        break :blk false;
    };
    if (c) acc += 160;
    const q2 = blk: {
        if (y == 4) break :blk c;
        break :blk side(x > 6);
    };
    if (c) acc += 320;
    if (q2) acc += 640;
    if (x > 1 and !lt2(items, 0, 1)) acc += 1280;
    if (!(lt(y, 3) and lt2(items, 2, 3)) or x == 5) acc += 2560;
    return acc + @intFromBool(q);
}

fn bitops(x: u32, y: u32, p: *const [4]bool) u32 {
    var acc: u32 = 0;
    if ((x < 3) | (y > 7)) acc += 1;
    if ((x < 3) & (y > 7)) acc += 2;
    const c = x < 5;
    if (c | c) acc += 4;
    if (c & c) acc += 8;
    const d = y == 2;
    if ((x > 1) | d) acc += 16;
    acc += @as(u32, @intFromBool(d)) * 32;
    if (!(x == 4) & (y != 1)) acc += 64;
    if (p[0] | p[1]) acc += 128;
    if (p[2] & !p[3]) acc += 256;
    if ((@as(f32, @floatFromInt(x)) < 2.5) | (y == 0)) acc += 512;
    if (((x == 1) | (y == 1)) | p[0]) acc += 1024;
    if (((x != 6) & (y < 9)) & side(x + y > 4)) acc += 2048;
    var i: u32 = 0;
    while ((i < x) & (i < 6)) : (i += 1) acc += 4096;
    return acc;
}

const Flags = struct { a: bool, b: bool, done: bool, n: u32 };
var global_flag: bool = false;

noinline fn flip(f: *Flags) void {
    f.a = !f.a;
    f.n +%= 1;
    if (f.n % 3 == 0) f.done = true;
}

fn loads(f: *Flags, g: *Flags, v: *volatile bool) u32 {
    var acc: u32 = 0;
    if (f.a) acc += 1;
    if (!f.b) acc += 2;
    const a = f.a;
    f.a = !a;
    if (a) acc += 4;
    const b = g.b;
    flip(g);
    if (b) acc += 8;
    if (f.a | g.b) acc += 16;
    if (!g.a & f.b) acc += 32;
    if (global_flag) acc += 64;
    global_flag = !global_flag;
    if (v.*) acc += 128;
    var local = f.n > 2;
    if (g.done) local = !local;
    if (local) acc += 256;
    while (!g.done) {
        flip(g);
        acc += 512;
    }
    return acc;
}

fn machine(start: u8) u32 {
    var steps: u32 = 0;
    var n: u8 = 0;
    s: switch (start) {
        0 => {
            steps += 1;
            continue :s 5;
        },
        1...4 => {
            steps += n + 1;
            continue :s 10;
        },
        5...9 => {
            steps += 100;
            n += 1;
            if (n < 3) continue :s 2 else continue :s 200;
        },
        10 => {
            steps += 1000;
            if (n > 5) break :s;
            continue :s 7;
        },
        else => {
            steps += 7;
            if (n < 6) {
                n += 3;
                continue :s start;
            }
        },
    }
    return steps;
}

pub fn main() void {
    var h: u32 = 0;
    for (0..11) |x| for (0..11) |y| {
        h = h *% 16777619 ^ conds(@intCast(x), @intCast(y));
    };
    for (0..12) |s| h = h *% 16777619 ^ machine(@intCast(s));
    for (0..64) |m| {
        var f: Flags = .{ .a = m & 1 != 0, .b = m & 2 != 0, .done = m & 4 != 0, .n = @intCast(m >> 3) };
        var g: Flags = .{ .a = m & 8 != 0, .b = m & 16 != 0, .done = m & 32 != 0, .n = @intCast(m & 7) };
        var vb: bool = m & 5 == 5;
        h = h *% 16777619 ^ loads(&f, &g, &vb);
        h = h *% 16777619 ^ @as(u32, @bitCast([4]u8{ @intFromBool(f.a), @intFromBool(f.b), @intFromBool(g.a), @intFromBool(g.done) }));
    }
    for (0..10) |x| for (0..10) |y| for (0..16) |m| {
        const p: [4]bool = .{ m & 1 != 0, m & 2 != 0, m & 4 != 0, m & 8 != 0 };
        h = h *% 16777619 ^ chains(@intCast(x), @intCast(y), &p);
    };
    for (0..10) |x| for (0..10) |y| for (0..16) |m| {
        const p: [4]bool = .{ m & 1 != 0, m & 2 != 0, m & 4 != 0, m & 8 != 0 };
        h = h *% 16777619 ^ bitops(@intCast(x), @intCast(y), &p);
    };
    for (0..10) |x| for (0..10) |y| {
        var items = [_]u32{ 1, @intCast(x), 4, @intCast(y), 0 };
        h = h *% 16777619 ^ inlined(&items, @intCast(x), @intCast(y));
        for (items) |e| h = h *% 16777619 ^ e;
    };
    h = h *% 16777619 ^ machine(250);
    std.debug.print("{d} {d}\n", .{ h, calls });
}
