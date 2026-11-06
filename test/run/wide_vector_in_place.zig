//! exit: 0
//! stderr: "store 7022a65a 686b4930\ncall 777b645a 35d77100\nadd 83011dd2\nback a9208502\nrotate 9a5d3d1\nreverse 3e5bb3ea\nwiden 7be329b5\nwiden array 7be329b5\nsame 4d6247a\nregisters 7ef356f6\n"
//! targets: x86_64-linux aarch64-linux aarch64-macos

// Vectors of more than 16 bytes: a load whose users read it in place, and
// an operation that writes the memory of the store after it, keep their
// meaning when a store or call writes the loaded memory between, and when
// the destination overlaps the source one chunk further on.
const std = @import("std");

const V = @Vector(16, u32);
const Chunk = @Vector(4, u32);

fn fill(buf: []Chunk) void {
    for (buf, 0..) |*c, i| {
        const base: u32 = @intCast(i * 4);
        c.* = .{ base *% 0x9e3779b9 +% 1, (base + 1) *% 0x85ebca6b, (base + 2) *% 0xc2b2ae35 ^ 5, (base + 3) *% 0x27d4eb2f };
    }
}

fn hash(buf: []const Chunk) u32 {
    var h: u32 = 0;
    for (buf) |c| h = (h *% 31) ^ @reduce(.Add, c *% Chunk{ 3, 5, 7, 11 });
    return h;
}

noinline fn storeBetween(p: *align(16) V, q: *align(16) V) void {
    const a = p.*;
    p.* = @splat(7);
    q.* = a +% a;
}

noinline fn clobber(p: *align(16) V) void {
    p.* = @splat(9);
}

noinline fn callBetween(p: *align(16) V, q: *align(16) V) void {
    const a = p.*;
    clobber(p);
    q.* = a ^ @as(V, @splat(0x55));
}

noinline fn shiftedAdd(buf: *[5]Chunk) void {
    const src: *align(16) V = @ptrCast(&buf[0]);
    const dst: *align(16) V = @ptrCast(&buf[1]);
    dst.* = src.* +% @as(V, @splat(1));
}

noinline fn shiftedBack(buf: *[5]Chunk) void {
    const src: *align(16) V = @ptrCast(&buf[1]);
    const dst: *align(16) V = @ptrCast(&buf[0]);
    dst.* = src.* -% @as(V, @splat(3));
}

noinline fn shiftedRotate(buf: *[5]Chunk) void {
    const src: *align(16) V = @ptrCast(&buf[0]);
    const dst: *align(16) V = @ptrCast(&buf[1]);
    dst.* = std.math.rotl(V, src.*, 7);
}

noinline fn shiftedReverse(buf: *[5]Chunk) void {
    const src: *align(16) V = @ptrCast(&buf[0]);
    const dst: *align(16) V = @ptrCast(&buf[1]);
    dst.* = @shuffle(u32, src.*, undefined, [16]i32{ 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0 });
}

noinline fn shiftedWiden(buf: *[5]Chunk) void {
    const src: *align(16) @Vector(16, u8) = @ptrCast(&buf[1]);
    const dst: *align(16) V = @ptrCast(&buf[0]);
    dst.* = src.*;
}

noinline fn shiftedWidenArray(buf: *[5]Chunk) void {
    const src: *align(16) @Vector(16, u8) = @ptrCast(&buf[1]);
    const dst: *align(16) [16]u32 = @ptrCast(&buf[0]);
    const w: V = src.*;
    dst.* = w;
}

noinline fn sameMemory(p: *align(16) V) void {
    p.* = std.math.rotl(V, p.*, 16) +% p.*;
}

// Rotates of vectors in registers, where the result may take the
// operand's register.
noinline fn rotates(a: Chunk, n: usize) Chunk {
    var x = a;
    for (0..n) |_| x = std.math.rotl(Chunk, x, 7) +% std.math.rotr(Chunk, x, 16) +% std.math.rotl(Chunk, x, 8);
    const h: @Vector(8, u16) = @bitCast(x);
    const b: @Vector(16, u8) = @bitCast(std.math.rotl(@Vector(8, u16), h, 8) ^ std.math.rotl(@Vector(8, u16), h, 3));
    return @bitCast(b);
}

pub fn main() void {
    var x: [5]Chunk = undefined;
    var y: [4]Chunk = undefined;
    fill(&x);
    storeBetween(@ptrCast(&x[0]), @ptrCast(&y));
    std.debug.print("store {x} {x}\n", .{ hash(&x), hash(&y) });
    fill(&x);
    callBetween(@ptrCast(&x[0]), @ptrCast(&y));
    std.debug.print("call {x} {x}\n", .{ hash(&x), hash(&y) });
    fill(&x);
    shiftedAdd(&x);
    std.debug.print("add {x}\n", .{hash(&x)});
    fill(&x);
    shiftedBack(&x);
    std.debug.print("back {x}\n", .{hash(&x)});
    fill(&x);
    shiftedRotate(&x);
    std.debug.print("rotate {x}\n", .{hash(&x)});
    fill(&x);
    shiftedReverse(&x);
    std.debug.print("reverse {x}\n", .{hash(&x)});
    fill(&x);
    shiftedWiden(&x);
    std.debug.print("widen {x}\n", .{hash(&x)});
    fill(&x);
    shiftedWidenArray(&x);
    std.debug.print("widen array {x}\n", .{hash(&x)});
    fill(&x);
    sameMemory(@ptrCast(&x[0]));
    std.debug.print("same {x}\n", .{hash(&x)});
    const r = [1]Chunk{rotates(x[2], 5)};
    std.debug.print("registers {x}\n", .{hash(&r)});
}
