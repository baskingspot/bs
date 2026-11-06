//! exit: 0
//! stdout: "1111111122222222 3333333344444444\n2222222244444444 6666666688888888\n1111111122222222 3333333344444444 88888888aaaaaaaa\n5555555566666666 5555555566666666\n"
//! targets: x86_64-linux aarch64-linux aarch64-macos

// 128-bit integers bitcast to and from `@Vector(2, u64)`, as GHASH does
// around its carry-less multiplies: on aarch64 an integer in a register
// pair moves to a vector register and back without the frame, a vector
// stored as an integer is stored from its register, and an inline
// callee's asm takes and returns the vector. The halves differ, so a
// swapped pair shows.
const std = @import("std");
const builtin = @import("builtin");

const V = @Vector(2, u64);

noinline fn roundTrip(x: u128) u128 {
    const v: V = @bitCast(x);
    return @bitCast(v +% v);
}

const Three = struct { a: u128, b: u128, c: u128 };

noinline fn fields(x: u128, y: u128) Three {
    const v: V = @bitCast(x);
    const w: V = @bitCast(y);
    return .{ .a = @bitCast(v), .b = @bitCast(w), .c = @bitCast(v +% w) };
}

inline fn swapHalves(x: u128) u128 {
    const v: V = @bitCast(x);
    const r: V = switch (builtin.cpu.arch) {
        .aarch64 => asm ("ext %[o].16b, %[i].16b, %[i].16b, #8"
            : [o] "=w" (-> V),
            : [i] "w" (v),
        ),
        .x86_64 => asm ("pshufd $0x4e, %[i], %[o]"
            : [o] "=x" (-> V),
            : [i] "x" (v),
        ),
        else => unreachable,
    };
    return @bitCast(r);
}

noinline fn viaAsm(x: u128, out: *Three) void {
    out.a = swapHalves(x);
    out.b = swapHalves(out.a) >> 64;
}

pub fn main() void {
    var a: u128 = 0x3333333344444444_1111111122222222;
    var b: u128 = 0x5555555566666666_4444444411111111;
    std.mem.doNotOptimizeAway(&a);
    std.mem.doNotOptimizeAway(&b);
    var out: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    const r = roundTrip(a);
    w.print("{x} {x}\n", .{ @as(u64, @truncate(a)), @as(u64, @truncate(a >> 64)) }) catch unreachable;
    w.print("{x} {x}\n", .{ @as(u64, @truncate(r)), @as(u64, @truncate(r >> 64)) }) catch unreachable;
    const f = fields(a, b);
    w.print("{x} {x} {x}\n", .{ @as(u64, @truncate(f.a)), @as(u64, @truncate(f.a >> 64)), @as(u64, @truncate(f.c >> 64)) }) catch unreachable;
    var t: Three = undefined;
    viaAsm(b, &t);
    w.print("{x} {x}\n", .{ @as(u64, @truncate(t.a)), @as(u64, @truncate(t.b)) }) catch unreachable;
    std.Io.File.stdout().writeStreamingAll(std.Options.debug_io, w.buffered()) catch {};
}
