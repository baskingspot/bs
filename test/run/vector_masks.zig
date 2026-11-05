//! exit: 0
//! stderr: "u8 8f9b9567216b22f4\ni8 c4bfd699afa6fa3b\nu16 c65dcca39fddf2ba\ni16 f7fbbdf11c9e3d1c\nu32 23527a2f2b2642e4\ni32 21bcef67343f2d5b\nu64 2a1f21e5c3e2a374\ni64 9e8e9a1bbb2abb0e\nf32 c1ed20d5300a68db\nf64 2774cc002019a9b4\nu4 83cc8b4433fa1b81\ni5 fc818dff608c103a\n"
//! targets: x86_64-linux aarch64-macos aarch64-linux

// Bool vectors that compares compute and their users read, which aarch64
// keeps as lane masks in V registers when they fit one (16 bytes of
// lanes): for each lane type, lane counts on both sides of that limit and
// of the shorter register loads, read by reductions (in a branch and as
// values), selects at the same, wider (several 16-byte chunks) and
// narrower lanes, bitwise operations mixing masks of two widths, bits
// loaded from memory, and constants, bitcasts to integers, firstTrue and
// lastTrue, stores, and masks live across a call (which keep no register,
// so they are bits). Each line folds one lane type's results.
const std = @import("std");

var seed: u64 = 0x9e3779b97f4a7c15;

fn next() u64 {
    seed = seed *% 6364136223846793005 +% 1442695040888963407;
    return seed >> 11;
}

/// A runtime vector whose lanes often repeat, so compares go both ways.
noinline fn vec(comptime n: usize, comptime T: type) @Vector(n, T) {
    var a: [n]T = undefined;
    for (&a) |*x| {
        const r = next();
        x.* = switch (@typeInfo(T)) {
            .int => switch (r % 5) {
                0 => std.math.maxInt(T),
                1 => std.math.minInt(T),
                else => @intCast(r % 3),
            },
            .float => @floatFromInt(@as(i32, @intCast(r % 5)) - 2),
            .bool => r % 3 == 0,
            else => unreachable,
        };
    }
    return a;
}

var h: u64 = 0;

fn mix(x: anytype) void {
    const T = @TypeOf(x);
    switch (@typeInfo(T)) {
        .vector => |v| inline for (0..v.len) |i| mix(x[i]),
        .bool => mix(@as(u8, @intFromBool(x))),
        .float => mix(@as(@Int(.unsigned, @bitSizeOf(T)), @bitCast(x))),
        .int => h = (h ^ @as(u64, @truncate(@as(u128, @as(@Int(.unsigned, @bitSizeOf(T)), @bitCast(x)))))) *% 0x100000001b3,
        else => unreachable,
    }
}

fn line(name: []const u8) void {
    std.debug.print("{s} {x}\n", .{ name, h });
    h = 0;
}

noinline fn barrier() void {
    mix(@as(u8, 0x5a));
}

noinline fn masks(comptime n: usize, comptime T: type) void {
    const a = vec(n, T);
    const b = vec(n, T);
    const c = vec(n, T);
    const x8 = vec(n, u8);
    const y8 = vec(n, u8);
    const w64 = vec(n, u64);
    const z64 = vec(n, u64);
    var loaded = vec(n, bool);
    _ = &loaded;
    const lt = a < b;
    const eq = a == c;
    const ge = b >= c;
    const ne = a != b;
    const bytes_eq = x8 == y8;
    const Bits = @Int(.unsigned, n);
    const alternate: @Vector(n, bool) = comptime blk: {
        var v: [n]bool = undefined;
        for (&v, 0..) |*e, i| e.* = i % 2 == 0;
        break :blk v;
    };
    // Computed before any call, so that the masks may keep registers.
    const results = .{
        // Reductions, as values and read by a branch.
        @reduce(.Or, lt | eq),
        @reduce(.And, lt | !eq),
        @reduce(.Xor, lt ^ ge),
        @reduce(.And, ne),
        @as(u8, if (@reduce(.Or, eq & ge)) 1 else 2),
        @as(u8, if (@reduce(.And, lt | ge)) 3 else 4),
        @as(u8, if (!@reduce(.Or, ne)) 5 else 6),
        // Selects at the predicate's lane width, wider, and narrower.
        @select(T, lt & ge, a, b),
        @select(T, !ne, c, a),
        @select(u8, lt | eq, x8, @as(@Vector(n, u8), @splat(9))),
        @select(u64, eq ^ ge, w64, z64),
        // Masks of two widths, bits loaded from memory, and constants.
        @reduce(.Or, lt & bytes_eq),
        @select(u8, bytes_eq | ge, y8, x8),
        @select(T, (w64 > z64) & lt, a, c),
        @reduce(.Or, eq & loaded),
        @select(T, lt ^ loaded, b, c),
        @reduce(.And, ge | alternate),
        @reduce(.Or, ne & @as(@Vector(n, bool), @splat(true))),
        // Bits: bitcasts, firstTrue and lastTrue, counts.
        @as(Bits, @bitCast(lt)),
        @as(Bits, @bitCast(eq | ge)),
        @as(Bits, @bitCast(!ne & alternate)),
        if (std.simd.firstTrue(lt)) |i| @as(u32, i) else 99,
        if (std.simd.firstTrue(eq ^ ge)) |i| @as(u32, i) else 99,
        if (std.simd.lastTrue(ne)) |i| @as(u32, i) else 99,
        if (std.simd.lastTrue(bytes_eq & lt)) |i| @as(u32, i) else 99,
        std.simd.countTrues(lt | eq),
    };
    inline for (results) |r| mix(r);
    var stored = lt & ge;
    _ = &stored;
    mix(stored);
    // Live across a call: kept as bits.
    const across = eq | ne;
    barrier();
    mix(@reduce(.Or, across));
    mix(@select(T, across, a, b));
    // A mask the loop's branch reads each time round.
    var i: usize = 0;
    var found: usize = 99;
    while (i < 4) : (i += 1) {
        const m = add(a, splatOf(n, T, i)) == b;
        if (@reduce(.Or, m)) {
            found = i * 100 + (std.simd.firstTrue(m) orelse 0);
            break;
        }
    }
    mix(found);
}

/// Few live values, so that every mask keeps a register; and splat
/// constants of each shape aarch64 writes with movi or mvni.
noinline fn light(comptime n: usize, comptime T: type) void {
    const a = vec(n, T);
    const b = vec(n, T);
    const w = vec(n, u64);
    const V = @Vector(n, T);
    const r = .{
        @reduce(.Or, a < b),
        @reduce(.And, a <= b),
        @as(@Int(.unsigned, n), @bitCast(a == b)),
        if (std.simd.firstTrue(a != b)) |i| @as(u32, i) else 99,
        if (std.simd.lastTrue(a > b)) |i| @as(u32, i) else 99,
        // Lanes past the length may be true in a mask (equal padding, `!`).
        if (std.simd.lastTrue(a == b)) |i| @as(u32, i) else 99,
        if (std.simd.lastTrue(!(a < b))) |i| @as(u32, i) else 99,
        @as(u64, @as(@Int(.unsigned, n), @bitCast(!(a < b)))),
        @reduce(.And, !(a < b)),
        @reduce(.And, a < b),
        @select(u64, a > b, w, @as(@Vector(n, u64), @splat(5))),
        @select(u8, a == b, @as(@Vector(n, u8), @splat(1)), @as(@Vector(n, u8), @splat(2))),
        @select(T, a >= b, a, b),
    };
    inline for (r) |x| mix(x);
    // u8 constants stored as strings: a splat, and not.
    const x8 = vec(n, u8);
    const as: [n]u8 = comptime blk: {
        var v: [n]u8 = undefined;
        @memset(&v, 'A');
        break :blk v;
    };
    mix(x8 ^ @as(@Vector(n, u8), as));
    mix(x8 +% std.simd.iota(u8, n));
    if (@typeInfo(T) == .int) {
        inline for (.{
            0x5a5a5a5a5a5a5a5a, 0xff00ff00ff00ff00, 0x0000ff000000ff00,
            0xffff00ffffff00ff, 0x0001ffff0001ffff, 0x000001ff000001ff,
            0xfffffe00fffffe00, 0xfffe0000fffe0000, 0xff0000ffff00ff00,
            0x8000000080000000, 0xffffffffffffffff, 0x00000000000000a5,
        }) |k| {
            const U = @Int(.unsigned, @bitSizeOf(T));
            const s: V = @splat(@bitCast(@as(U, @truncate(@as(u64, k)))));
            mix(a ^ s);
            mix(@as(@Int(.unsigned, n), @bitCast(a < s)));
            mix(@reduce(.Or, a == s));
        }
    }
}

fn add(x: anytype, y: @TypeOf(x)) @TypeOf(x) {
    return if (@typeInfo(@typeInfo(@TypeOf(x)).vector.child) == .float) x + y else x +% y;
}

fn splatOf(comptime n: usize, comptime T: type, i: usize) @Vector(n, T) {
    return @splat(switch (@typeInfo(T)) {
        .int => @intCast(i),
        .float => @floatFromInt(i),
        else => unreachable,
    });
}

pub fn main() void {
    inline for (.{ u8, i8, u16, i16, u32, i32, u64, i64, f32, f64, u4, i5 }) |T| {
        const full = 16 / @sizeOf(T);
        inline for (.{ 1, 2, 3, full / 2 - 1, full / 2, full / 2 + 1, full - 1, full, full + 1 }) |n| {
            if (n >= 1) {
                masks(n, T);
                light(n, T);
            }
        }
        line(@typeName(T));
    }
}
