//! exit: 0
//! stdout: "2\n14\n5\n6\n0\n37877\n45001\n50595\n614525140331348000\n1\n8\n14\n"
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

const P = packed struct(u16) { foo: u5, bar: i7, baz: u3, qux: bool };

/// `@bitCast` sees arrays and vectors as their elements' bits in order,
/// without each element's padding in memory, at runtime and at comptime.
fn main() callconv(.c) noreturn {
    var v: @Vector(4, u5) = .{ 0b0_0010, 0b01_111, 0b110_01, 0b0000_0 };
    var p: P = .{ .foo = 0b01001, .bar = -2, .baz = 0b010, .qux = true };
    var b: [4][4]bool = .{
        .{ true, true, false, false },
        .{ false, true, false, true },
        .{ true, false, true, false },
        .{ false, false, true, true },
    };
    var n: [2][1][3][5]u4 = .{ .{.{ .{ 0x1, 0x5, 0xF, 0x0, 0x4 }, .{ 0xD, 0xE, 0xF, 0xE, 0x1 }, .{ 0xC, 0xA, 0x7, 0xE, 0x0 } }}, .{.{ .{ 0x0, 0x2, 0x0, 0x4, 0xF }, .{ 0xF, 0x6, 0xF, 0xB, 0x5 }, .{ 0xB, 0x3, 0x7, 0x8, 0x8 } }} };
    _ = .{ &v, &p, &b, &n };
    const a: [5]u4 = @bitCast(v);
    inline for (0..5) |i| rt.printInt(a[i]);
    const bits: [16]u1 = @bitCast(p);
    var acc: u64 = 0;
    inline for (0..16) |i| acc = acc * 2 + bits[i];
    rt.printInt(acc);
    const vb: @Vector(16, u1) = @bitCast(p);
    const back: P = @bitCast(vb);
    rt.printInt(@as(u16, @bitCast(back)));
    rt.printInt(@as(u16, @bitCast(b)));
    const s: i120 = @bitCast(n);
    rt.printInt(@as(u64, @truncate(@as(u120, @bitCast(s)) >> 60)));
    rt.printInt(@intFromBool(s < 0));
    const rn: [2][1][3][5]u4 = @bitCast(s);
    rt.printInt(rn[1][0][2][3]);
    const c: [5]u4 = comptime @bitCast(@as(@Vector(4, u5), .{ 0b0_0010, 0b01_111, 0b110_01, 0b0000_0 }));
    rt.printInt(c[1]);
    rt.exit(0);
}
