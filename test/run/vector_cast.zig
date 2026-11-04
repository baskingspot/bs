//! exit: 0
//! stdout: "6319276624752600098\n8823866333948789538\n8823866333948789538\n7042984655872\n18446720048716682209\n6319276624752600098\n8823866333948789538\n8823866333948789538\n7042984655872\n6319276624752600098\n8823866333948789538\n6319276624752600098\n18446744072903100400\n19184\n19184\n46351\n27640\n135\n120\n135\n143\n"
// Vector `@intCast` that widens and `@truncate`, lowered as SSE unpacks
// and packs, the same widenings as implicit coercions, and compares against a constant that splits the lanes at
// their sign bit, lowered as the sign bits (`signTest`). Each line is a
// lane-by-lane result folded into one number, so a lane out of place, a
// wrong extension, or a constant off by one changes it.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

fn fold(comptime T: type, comptime n: usize, v: @Vector(n, T)) u64 {
    const a: [n]T = v;
    var h: u64 = 0;
    for (a) |x| h = h *% 31 +% @as(u64, @bitCast(@as(i64, x)));
    return h;
}

fn bits(comptime n: usize, b: @Vector(n, bool)) u64 {
    return @as(@Int(.unsigned, n), @bitCast(b));
}

noinline fn bytes(comptime T: type, comptime n: usize) @Vector(n, T) {
    var a: [n]T = undefined;
    for (&a, 0..) |*x, i| x.* = @bitCast(@as(@Int(.unsigned, @bitSizeOf(T)), @truncate(i *% 0x9e3779b97f4a7c15 >> 7)));
    return a;
}

noinline fn id(comptime T: type, comptime n: usize, v: @Vector(n, T)) @Vector(n, T) {
    return v;
}

fn main() callconv(.c) noreturn {
    // Widening: zero- and sign-extension across one to three doublings,
    // with result chunks taken from the middle of a source chunk.
    rt.printInt(fold(u32, 16, @intCast(bytes(u8, 16))));
    rt.printInt(fold(i32, 16, @intCast(bytes(i8, 16))));
    rt.printInt(fold(i64, 16, @intCast(bytes(i8, 16))));
    rt.printInt(fold(i16, 9, @intCast(bytes(u8, 9))));
    rt.printInt(fold(i64, 8, @intCast(bytes(i16, 8))));
    // The same widenings as coercions of the argument.
    rt.printInt(fold(u32, 16, bytes(u8, 16)));
    rt.printInt(fold(i32, 16, bytes(i8, 16)));
    rt.printInt(fold(i64, 16, bytes(i8, 16)));
    rt.printInt(fold(i16, 9, bytes(u8, 9)));
    // Truncating: one to three halvings, an odd length, and more source
    // chunks than one result chunk holds.
    rt.printInt(fold(u8, 16, @truncate(bytes(u16, 16))));
    rt.printInt(fold(i8, 16, @truncate(bytes(i32, 16))));
    rt.printInt(fold(u8, 16, @truncate(bytes(u64, 16))));
    rt.printInt(fold(i16, 5, @truncate(bytes(i64, 5))));
    // Sign tests and their neighbours, which are not.
    const u = id(u8, 16, .{ 0, 1, 0x7e, 0x7f, 0x80, 0x81, 0xfe, 0xff, 0x7f, 0x80, 3, 0x90, 0x10, 0x7f, 0xc0, 0x40 });
    const s = id(i16, 8, .{ -32768, -2, -1, 0, 1, 2, 32767, -1 });
    rt.printInt(bits(16, u >= @as(@Vector(16, u8), @splat(0x80))));
    rt.printInt(bits(16, u > @as(@Vector(16, u8), @splat(0x7f))));
    rt.printInt(bits(16, @as(@Vector(16, u8), @splat(0x80)) > u));
    rt.printInt(bits(16, u >= @as(@Vector(16, u8), @splat(0x7f))));
    rt.printInt(bits(8, s < @as(@Vector(8, i16), @splat(0))));
    rt.printInt(bits(8, s >= @as(@Vector(8, i16), @splat(0))));
    rt.printInt(bits(8, s <= @as(@Vector(8, i16), @splat(-1))));
    rt.printInt(bits(8, s <= @as(@Vector(8, i16), @splat(0))));
    rt.exit(0);
}
