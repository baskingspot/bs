//! exit: 0
//! stderr: "14508513716039858685\n"
//! targets: x86_64-linux aarch64-macos
//! Switches lowered as jump tables, binary searches, and compares at the
//! leaves: dense and sparse cases, signed and unsigned operands of every
//! width, values that need 64 bits, neighbors that go to one prong, and
//! the values just outside each case and each table.
const std = @import("std");

const Dense = enum(u8) { a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p };
fn dense(t: Dense) u32 {
    return switch (t) {
        .a => 10,
        .b => 11,
        .c => 12,
        .d => 13,
        .e => 14,
        .f => 15,
        .g => 16,
        .h => 17,
        .i => 18,
        .j => 19,
        .k => 20,
        .l => 21,
        .m => 22,
        .n => 23,
        .o => 24,
        .p => 25,
    };
}

/// A table with holes, offset from zero, and items sharing prongs.
fn holes(x: u8) u32 {
    return switch (x) {
        40, 41, 42 => 1,
        44 => 2,
        45, 47 => 3,
        48 => 4,
        50, 51 => 5,
        53 => 6,
        else => 0,
    };
}

/// Too sparse for a table: a binary search.
fn sparse(x: u32) u32 {
    return switch (x) {
        3 => 1,
        100 => 2,
        1000 => 3,
        5000 => 4,
        70000 => 5,
        0x7fff_ffff => 6,
        0x8000_0000 => 7,
        0xffff_fff0 => 8,
        0xffff_ffff => 9,
        else => 0,
    };
}

/// A dense run among outliers: a search that reaches a table.
fn mixed(x: u64) u32 {
    return switch (x) {
        0 => 1,
        100, 101, 102, 103, 104, 105, 106, 107 => 2,
        108, 109 => 3,
        110, 112, 113 => 4,
        1 << 40 => 5,
        (1 << 63) + 5 => 6,
        0xffff_ffff_ffff_ffff => 7,
        else => 0,
    };
}

fn signed64(x: i64) u32 {
    return switch (x) {
        std.math.minInt(i64) => 1,
        -(1 << 40) => 2,
        -100 => 3,
        -2 => 4,
        -1 => 5,
        0 => 6,
        1 => 7,
        2 => 8,
        1 << 33 => 9,
        std.math.maxInt(i64) => 10,
        else => 0,
    };
}

/// A signed table that crosses zero.
fn signed8(x: i8) u32 {
    return switch (x) {
        -4 => 1,
        -3 => 2,
        -2 => 3,
        -1 => 4,
        0 => 5,
        1 => 6,
        2 => 7,
        3 => 8,
        -128 => 9,
        127 => 10,
        else => 0,
    };
}

fn narrow16(x: u16) u32 {
    return switch (x) {
        0xfff0, 0xfff1, 0xfff2, 0xfff3, 0xfff4 => 1,
        0xfff6 => 2,
        0xffff => 3,
        7 => 4,
        else => 0,
    };
}

const Neg = enum(i8) { x = -7, y = -6, z = -5, w = -3, v = 9, _ };
fn neg(t: Neg) u32 {
    return switch (t) {
        .x => 1,
        .y => 2,
        .z => 3,
        .w => 4,
        .v => 5,
        _ => 6,
    };
}

/// Range prongs: in a table, among items, and in a search.
fn ident(c: u8) u32 {
    return switch (c) {
        '0'...'9' => 1,
        'A'...'Z', '_' => 2,
        'a'...'f', 'x' => 3,
        'g'...'w', 'y', 'z' => 4,
        else => 0,
    };
}

/// Ranges at the ends of the type and crossing zero.
fn rangesSigned(x: i32) u32 {
    return switch (x) {
        std.math.minInt(i32)...-1_000_000 => 1,
        -10...-1 => 2,
        0 => 3,
        1...9, 11 => 4,
        1000...1_000_000 => 5,
        2_000_000_000...std.math.maxInt(i32) => 6,
        else => 0,
    };
}

/// Wide sparse ranges in a 64-bit search.
fn rangesWide(x: u64) u32 {
    return switch (x) {
        0...2 => 1,
        100...199 => 2,
        200 => 3,
        1 << 32...(1 << 33) - 1 => 4,
        (1 << 63)...std.math.maxInt(u64) => 5,
        else => 0,
    };
}

fn boolean(b: bool) u32 {
    return switch (b) {
        true => 3,
        false => 4,
    };
}

/// Every value in and around each case.
const probes_u64 = [_]u64{ 0, 1, 2, 3, 4, 199, 200, 201, (1 << 33) - 1, 1 << 33, (1 << 63) - 1, 1 << 63, 99, 100, 101, 107, 108, 109, 110, 111, 112, 113, 114, 999, 1000, 1001, 4999, 5000, 70000, 1 << 32, 1 << 40, (1 << 40) + 1, 0x7fff_ffff, 0x8000_0000, 0xffff_fff0, 0xffff_ffff, (1 << 63) + 4, (1 << 63) + 5, 0xffff_ffff_ffff_fffe, 0xffff_ffff_ffff_ffff };
const probes_i64 = [_]i64{ std.math.minInt(i64), std.math.minInt(i64) + 1, -(1 << 40) - 1, -(1 << 40), -101, -100, -99, -5, -4, -3, -2, -1, 0, 1, 2, 3, 4, (1 << 33) - 1, 1 << 33, std.math.maxInt(i64) - 1, std.math.maxInt(i64) };
const probes_i32 = [_]i32{ std.math.minInt(i32), -1_000_000, -999_999, -11, -10, -1, 0, 1, 9, 10, 11, 12, 999, 1000, 1_000_000, 1_000_001, 1_999_999_999, 2_000_000_000, std.math.maxInt(i32) };

pub fn main() void {
    var h: u64 = 0;
    const mix = struct {
        fn f(acc: *u64, v: u32) void {
            acc.* = (acc.* ^ v) *% 0x100000001b3;
        }
    }.f;
    for (0..16) |i| mix(&h, dense(@fromBackingInt(@intCast(i))));
    for (0..256) |i| {
        mix(&h, holes(@intCast(i)));
        mix(&h, ident(@intCast(i)));
        mix(&h, signed8(@bitCast(@as(u8, @intCast(i)))));
        mix(&h, neg(@fromBackingInt(@intCast(@as(i8, @bitCast(@as(u8, @intCast(i))))))));
    }
    for (0..0x10000) |i| mix(&h, narrow16(@intCast(i)));
    for (probes_u64) |p| {
        mix(&h, mixed(p));
        mix(&h, sparse(@truncate(p)));
        mix(&h, rangesWide(p));
    }
    for (probes_i64) |p| {
        mix(&h, signed64(p));
        mix(&h, rangesSigned(@truncate(p)));
    }
    for (probes_i32) |p| mix(&h, rangesSigned(p));
    mix(&h, boolean(true));
    mix(&h, boolean(false));
    std.debug.print("{d}\n", .{h});
}
