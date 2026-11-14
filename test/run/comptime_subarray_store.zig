//! exit: 0
//! stderr: "nop\\x0anop\\x0anop\\x0a 74882db9\nabXYZfgh abXYQRSh 12345678\n0 1 9 8 4 5 7 6 8 9 \naXcdeYZh ab12efgh\n..ab..cd ..abxycd\nheLLo, wORld 0\n-##-=== 6\n"
//! Stores of a subarray into a comptime array (`a[i..][0..k].* = v`):
//! from string literals, tuples and other arrays, overlapping, at the
//! end, through a view of a view, of arrays of arrays, into a struct's
//! field, through a pointer a comptime call got, with the array read as
//! a whole between stores, and of `undefined`. Each store writes its
//! elements in place; the first case is the one that was slow while a
//! store interned the whole array again.
const std = @import("std");

const filled = blk: {
    @setEvalBranchQuota(100_000);
    var s: [4096 * 4]u8 = undefined;
    for (0..4096) |i| s[i * 4 ..][0..4].* = "nop\n".*;
    const c = s;
    break :blk c;
};

const pieces = blk: {
    var s: [8]u8 = "abcdefgh".*;
    s[2..][0..3].* = .{ 'X', 'Y', 'Z' };
    const first = s;
    // Overlapping the store before, and up to the last but one element.
    s[4..][0..3].* = "QRS".*;
    s[2..4].* = first[0..2].*;
    s[2..][0..2].* = "XY".*;
    const second = s;
    // Every element at once, through a view that starts inside.
    const digits: [10]u8 = "0123456789".*;
    s[0..][0..8].* = digits[1..9].*;
    const c = .{ first, second, s };
    break :blk c;
};

const pairs = blk: {
    var s: [5][2]u8 = @splat(.{ 0, 0 });
    for (&s, 0..) |*p, i| p.* = .{ @intCast(i * 2), @intCast(i * 2 + 1) };
    const swapped: [2][2]u8 = .{ .{ 9, 8 }, .{ 4, 5 } };
    s[1..][0..2].* = swapped;
    s[3..5].* = .{ s[3], .{ 8, 9 } };
    s[3][0..2].* = .{ 7, 6 };
    const c = s;
    break :blk c;
};

const nested = blk: {
    var s: [8]u8 = "abcdefgh".*;
    // A view of a view: elements 5 and 6.
    const view: *[6]u8 = s[1..7];
    view[4..][0..2].* = "YZ".*;
    view[0..1].* = "X".*;
    const first = s;
    var t: [8:0]u8 = "abcdefgh".*;
    t[2..][0..2].* = "12".*;
    const c = .{ first, t };
    break :blk c;
};

fn put(p: *[8]u8, at: usize, v: [2]u8) void {
    p[at..][0..2].* = v;
}

const through_call = blk: {
    var s: [8]u8 = @splat('.');
    put(&s, 2, "ab".*);
    put(&s, 6, "cd".*);
    const first = s;
    put(&s, 4, "xy".*);
    const c = .{ first, s };
    break :blk c;
};

const Message = struct { len: u8, text: [12]u8 };

const in_field = blk: {
    var m: Message = .{ .len = 0, .text = "hello, world".* };
    m.text[2..][0..2].* = "LL".*;
    const p = &m.text;
    p[8..][0..2].* = .{ 'O', 'R' };
    // `undefined` leaves the general path to store it; then defined again.
    m.text[10..12].* = undefined;
    m.text[10..12].* = "ld".*;
    const c = m;
    break :blk c;
};

/// The same stores in a function with comptime parameters, where the
/// array is a `comptime var` and the stores run in an inline loop.
fn striped(comptime n: usize) [n]u8 {
    comptime var s: [n]u8 = @splat('-');
    comptime var i: usize = 1;
    inline while (i + 2 <= n) : (i += 3) {
        s[i..][0..2].* = "##".*;
    }
    s[n - 3 ..][0..3].* = @splat('=');
    const c = s;
    return c;
}

pub fn main() void {
    std.debug.print("{f} {x}\n", .{ std.ascii.hexEscape(filled[filled.len - 12 ..], .lower), std.hash.Crc32.hash(&filled) });
    std.debug.print("{s} {s} {s}\n", .{ pieces[0], pieces[1], pieces[2] });
    for (pairs) |p| std.debug.print("{d} {d} ", .{ p[0], p[1] });
    std.debug.print("\n{s} {s}\n", .{ nested[0], nested[1] });
    std.debug.print("{s} {s}\n", .{ through_call[0], through_call[1] });
    std.debug.print("{s} {d}\n", .{ in_field.text, in_field.len });
    const st = striped(7);
    var count: usize = 0;
    for (st) |c| count += @intFromBool(c != '#');
    std.debug.print("{s} {d}\n", .{ st, count + 1 });
}
