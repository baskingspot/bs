//! exit: 0
//! stderr: "2105351464 2396440025\n"
//! Branches on `and`/`or` conditions go to the condition's parts
//! directly, and a labeled switch `continue` with a constant goes to its
//! case: short-circuit order, a condition that is also a value, nested and
//! negated conditions, and continues into items, ranges and else.
//! Chains of `and` and `or`, and bool results of inlined calls passed on
//! through enclosing calls, one `return` or several, also read as values.
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
    for (0..10) |x| for (0..10) |y| for (0..16) |m| {
        const p: [4]bool = .{ m & 1 != 0, m & 2 != 0, m & 4 != 0, m & 8 != 0 };
        h = h *% 16777619 ^ chains(@intCast(x), @intCast(y), &p);
    };
    for (0..10) |x| for (0..10) |y| {
        var items = [_]u32{ 1, @intCast(x), 4, @intCast(y), 0 };
        h = h *% 16777619 ^ inlined(&items, @intCast(x), @intCast(y));
        for (items) |e| h = h *% 16777619 ^ e;
    };
    h = h *% 16777619 ^ machine(250);
    std.debug.print("{d} {d}\n", .{ h, calls });
}
