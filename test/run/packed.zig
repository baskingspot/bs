//! exit: 0
//! stdout: "5\n0\n1\n3\n-2\n21\n1\n0\n7\n45678\n2\n234\n1\n0\n1\n12345\n57\n20\n"
const rt = @import("rt.zig");

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

const Color = enum(u2) { red, green, blue };

const Inner = packed struct { lo: u3, hi: u2 };

const Flags = packed struct(u32) {
    a: u3,
    b: bool,
    c: Color,
    d: i4,
    inner: Inner,
    rest: u17,
};

// Crosses the 64-bit boundary.
const Wide = packed struct { x: u60, y: u16, z: u4 };

var global: Flags = .{ .a = 7, .b = true, .c = .blue, .d = -1, .inner = .{ .lo = 2, .hi = 1 }, .rest = 0x1ffff };

fn printSigned(v: i64) void {
    if (v < 0) {
        rt.print("-");
        rt.printInt(@intCast(-v));
    } else rt.printInt(@intCast(v));
}

fn setD(p: *align(4:6:4) i4, v: i4) void {
    p.* = v;
}

fn main() callconv(.c) noreturn {
    var five: u3 = 5;
    _ = &five;
    var f: Flags = .{ .a = five, .b = false, .c = .green, .d = 3, .inner = .{ .lo = 0, .hi = 0 }, .rest = 0 };
    rt.printInt(f.a);
    rt.printInt(@intFromBool(f.b));
    rt.printInt(@intFromEnum(f.c));
    printSigned(f.d);
    f.d = -2;
    printSigned(f.d);
    f.inner.lo = 6;
    f.inner.hi = 1;
    // a=5, b=0, c=1 (bits 4-5), d=-2 (0b1110, bits 6-9), inner.lo=6 (bits 10-12), inner.hi=1 (bit 13)
    const bits: u32 = @bitCast(f);
    rt.printInt(bits & 0x3f);
    rt.printInt(@intFromBool(f.a == 5 and f.c == .green));
    setD(&f.d, 0);
    printSigned(f.d);

    rt.printInt(global.a);
    global.rest = 45678;
    rt.printInt(global.rest);
    rt.printInt(@intFromEnum(global.c));
    rt.printInt(global.inner.lo | @as(u8, global.inner.hi) << 3 | @as(u8, global.a) << 5);

    var g = f;
    rt.printInt(@intFromBool(g == f));
    g.b = true;
    rt.printInt(@intFromBool(g == f));
    rt.printInt(@intFromBool(g.b));

    var w: Wide = .{ .x = 0, .y = 12345, .z = 9 };
    w.x = (1 << 59) | 48;
    rt.printInt(w.y);
    rt.printInt(@as(u64, w.z) + (w.x & 0xff));
    // Comptime @bitCast both ways.
    const ct: Flags = comptime @bitCast(@as(u32, 0b10_1101 | 1 << 10));
    comptime {
        if (@as(u32, @bitCast(ct)) != 0b10_1101 | 1 << 10) unreachable;
    }
    rt.printInt(@as(u8, ct.a) + @as(u8, @intFromEnum(ct.c)) * 2 + ct.inner.lo + @as(u8, @intFromBool(ct.b)) * 10);
    rt.exit(if (bits == (5 | 1 << 4 | 0b1110 << 6 | 6 << 10 | 1 << 13)) 0 else 1);
}
