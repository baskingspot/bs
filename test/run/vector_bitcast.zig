//! exit: 0
//! stdout: "10348616333177250801\n7015808298848\n18446744073709547739\n14410473\n18446744073708098800\n253\n1431862296556\n11142438507847241800\n12495129440118886728\n707365753767096700\n"
// Bitcasts between a vector in an XMM register and an integer or array of
// 1, 2, 4, or 8 bytes in a general-purpose register (movd/movq), and
// bitcasts of a vector to an array that a store writes straight to its
// destination (`vector.bitcastInPlace`). The narrow and signed results
// must be extended from their bits even when the lanes past the vector's
// length hold other bytes, and a store whose destination overlaps the
// vector's source must still see the whole source.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

noinline fn wide() @Vector(16, u8) {
    var a: [16]u8 = undefined;
    for (&a, 0..) |*x, i| x.* = @intCast(0xf0 - i * 7);
    return a;
}

noinline fn toU64(v: @Vector(8, u8)) u64 {
    return @bitCast(v +% @as(@Vector(8, u8), @splat(1)));
}

noinline fn fromU64(x: u64) @Vector(8, u8) {
    return @as(@Vector(8, u8), @bitCast(x)) +% @as(@Vector(8, u8), @splat(1));
}

noinline fn toI16(v: @Vector(16, u8)) i16 {
    // Lanes 2 and up of the shuffle are padding the bitcast ignores.
    const s: @Vector(2, u8) = @shuffle(u8, v, undefined, @Vector(2, i32){ 3, 0 });
    return @bitCast(s);
}

noinline fn toU24(v: @Vector(16, u8)) u24 {
    const s: @Vector(3, u8) = @shuffle(u8, v, undefined, @Vector(3, i32){ 1, 2, 3 });
    return @bitCast(s);
}

noinline fn toI24(v: @Vector(16, u8)) i24 {
    const s: @Vector(3, u8) = @shuffle(u8, v, undefined, @Vector(3, i32){ 0, 4, 1 });
    return @bitCast(s);
}

noinline fn fromI8(x: i8) @Vector(1, u8) {
    return @bitCast(x);
}

noinline fn store8(p: *[8]u8, v: @Vector(8, u16)) void {
    const t: @Vector(8, u8) = @truncate(v);
    p.* = t;
}

noinline fn store16(p: *[16]u8, v: @Vector(16, u8)) void {
    p.* = v ^ @as(@Vector(16, u8), @splat(0x5a));
}

noinline fn store64(p: *[16]u32, v: @Vector(16, u8)) void {
    const w: @Vector(16, u32) = v;
    p.* = w;
}

/// `p[0..16]` as u32 lanes plus one, stored to `p[1..17]`: the store's
/// destination overlaps the vector's source.
noinline fn shiftAdd(p: *[17]u32) void {
    const v: @Vector(16, u32) = p[0..16].*;
    p[1..17].* = v +% @as(@Vector(16, u32), @splat(1));
}

fn hash(bytes: []const u8) u64 {
    var h: u64 = 0;
    for (bytes) |b| h = h *% 31 +% b;
    return h;
}

fn put(x: u64) void {
    rt.printInt(x);
}

fn main() callconv(.c) noreturn {
    const v = wide();
    put(toU64(@shuffle(u8, v, undefined, @Vector(8, i32){ 0, 2, 4, 6, 8, 10, 12, 14 })));
    const f = fromU64(0x00ff_7f80_0102_fffe);
    put(hash(&@as([8]u8, f)));
    put(@as(u64, @bitCast(@as(i64, toI16(v)))));
    put(toU24(v));
    put(@as(u64, @bitCast(@as(i64, toI24(v)))));
    put(@as([1]u8, fromI8(-3))[0]);
    var a8: [8]u8 = undefined;
    store8(&a8, .{ 0x1234, 0xff01, 7, 0x80, 0x100, 0xfffe, 3, 0xab });
    put(hash(&a8));
    var a16: [16]u8 = undefined;
    store16(&a16, v);
    put(hash(&a16));
    var a64: [16]u32 = undefined;
    store64(&a64, v);
    put(hash(@ptrCast(&a64)));
    var s: [17]u32 = undefined;
    for (&s, 0..) |*x, i| x.* = @intCast(i * 1000);
    shiftAdd(&s);
    put(hash(@ptrCast(&s)));
    rt.exit(0);
}
