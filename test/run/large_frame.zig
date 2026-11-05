//! exit: 0
//! stderr: "7 5 0 12\n24 -1.5 9 2400\n1001 16909060 9 16909060\n333 0 0 77\n"
//! targets: x86_64-linux aarch64-linux aarch64-macos

// A stack frame of 16 MiB or more, as raylib-zig's drop_files example
// has: aarch64 allocates it with the size in a register, since
// `sub sp, sp, #imm` reaches only 2^24 - 1 (on macOS, after probing the
// pages). It runs on a thread with a stack large enough for it. Its
// `@splat` of zeroes, and the splats in `splats`, write one run of
// elements, not one store per element. `saved` has such a frame and
// keeps integers and f64s live across calls, in x19-x28 and d8-d15,
// which the prologue saves before the frame and the epilogue restores.
const std = @import("std");

const len = 12 << 20;
var result: [4]u32 = undefined;

fn big(n: usize) void {
    // `std.mem.zeroes` builds its value in a second frame slot: 24 MiB.
    var a: [len]u8 = std.mem.zeroes([len]u8);
    a[n] = 7;
    a[len - 1 - n] = 5;
    result = .{ a[n], a[len - 1 - n], a[n + 1], @intCast(len >> 20) };
}

noinline fn twice(x: f64) f64 {
    return x * 2;
}

noinline fn add(x: u64) u64 {
    return x + 100;
}

var floats: [4]f64 = undefined;

fn saved(a: f64, b: f64, n: usize) void {
    var buf: [len]u8 = std.mem.zeroes([len]u8);
    buf[n] = 9;
    const c = a + b;
    const d = a - b;
    const e = a * b;
    const m = n * 400;
    const s = twice(c);
    const t = twice(d);
    const k = add(m);
    floats = .{ s + e + c, t + d, @floatFromInt(buf[n] + buf[n + 1]), @floatFromInt(k + m - 100) };
}

fn run(n: usize) void {
    big(n);
    saved(2.5, 3, n);
}

fn splats(x: u32) void {
    // A runtime element, four bytes, in an odd count: the copy's tail.
    var b: [1001]u32 = @splat(x);
    b[3] = 9;
    std.debug.print("{d} {d} {d} {d}\n", .{ b.len, b[0], b[3], b[1000] });
    // A 24-byte element, its run followed by other elements.
    const S = struct { a: u64, b: u64, c: u64 };
    var c: [333]S = @splat(.{ .a = 0, .b = 0, .c = 0 });
    c[332].c = 77;
    std.debug.print("{d} {d} {d} {d}\n", .{ c.len, c[0].a, c[200].b, c[332].c });
}

pub fn main() !void {
    const t = try std.Thread.spawn(.{ .stack_size = 64 << 20 }, run, .{3});
    t.join();
    std.debug.print("{d} {d} {d} {d}\n", .{ result[0], result[1], result[2], result[3] });
    std.debug.print("{d} {d} {d} {d}\n", .{ floats[0], floats[1], floats[2], floats[3] });
    splats(0x01020304);
}
