//! exit: 0
//! stderr: "992897660 1041546328\n"
//! Branches on `and`/`or` conditions go to the condition's parts
//! directly, and a labeled switch `continue` with a constant goes to its
//! case: short-circuit order, a condition that is also a value, nested and
//! negated conditions, and continues into items, ranges and else.
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
    h = h *% 16777619 ^ machine(250);
    std.debug.print("{d} {d}\n", .{ h, calls });
}
