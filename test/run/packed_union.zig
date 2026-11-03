//! exit: 0
//! stdout: "2\n1\n65534\n-130814\n120\n-1\n4660\n-2147418248\n1\n120\n9\n1451\n171\n3\n17825793\n"
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

const PF = packed struct(u32) {
    X: bool = false,
    W: bool = false,
    R: bool = false,
    unused3: u17 = 0,
    OS: packed union {
        MASK: u8,
    } = .{ .MASK = 0 },
    PROC: packed union {
        MASK: u4,
    } = .{ .MASK = 0 },
};

const Flags = packed union(u32) {
    int: u32,
    split: packed struct(u32) { lo: u8, mid: i8, hi: u16 },
    signed: i32,
};

const Small = packed union {
    u: u3,
    i: i3,
    e: enum(u3) { a, b, c, d, e, f, g, h },
};

var g_flags: Flags = .{ .int = 0x1234_ff78 };

fn printSigned(v: i64) void {
    if (v < 0) {
        rt.print("-");
        rt.printInt(@intCast(-v));
    } else rt.printInt(@intCast(v));
}

fn main() callconv(.c) noreturn {
    // Comptime: reading another field reinterprets the bits.
    const cf: Flags = .{ .int = 0xfffe_0102 };
    rt.printInt(cf.split.lo);
    printSigned(cf.split.mid);
    rt.printInt(cf.split.hi);
    printSigned(cf.signed);
    comptime if (@as(Flags, .{ .int = 0xfffe_0102 }).split.mid != 1) unreachable;
    // Runtime.
    var f: Flags = .{ .int = 0x1234_ff78 };
    _ = &f;
    rt.printInt(f.split.lo);
    printSigned(f.split.mid);
    rt.printInt(f.split.hi);
    f.split.hi = 0x8000;
    printSigned(f.signed);
    rt.printInt(@intFromBool(f == Flags{ .signed = @bitCast(@as(u32, 0x8000_ff78)) }));
    rt.printInt(@as(u32, @bitCast(g_flags)) & 0xff);
    g_flags.split.lo = 9;
    rt.printInt(g_flags.int & 0xff);
    // Packed unions inside a packed struct.
    var pf: PF = .{ .R = true };
    pf.OS.MASK = 0xab;
    pf.PROC = .{ .MASK = 5 };
    rt.printInt(@as(u32, @bitCast(pf)) >> 20);
    rt.printInt(pf.OS.MASK);
    const p = &pf.PROC.MASK;
    p.* = 3;
    rt.printInt(@as(u32, @bitCast(pf)) >> 28);
    const cpf: PF = comptime blk: {
        var x: PF = .{ .X = true };
        x.OS.MASK = 0x11;
        break :blk x;
    };
    rt.printInt(@as(u32, @bitCast(cpf)));
    // Narrow fields with different signedness.
    // (Upstream's runtime reads of narrow fields keep stale high bits.)
    comptime if (@as(Small, .{ .i = -1 }).u != 7) unreachable;
    comptime if (@intFromEnum(@as(Small, .{ .i = -2 }).e) != 6) unreachable;
    comptime if (@as(Small, .{ .u = 5 }).i != -3) unreachable;
    comptime if (@as(Small, .{ .u = 5 }) != @as(Small, .{ .i = -3 })) unreachable;
    comptime if (@sizeOf(Flags) != 4) unreachable;
    rt.exit(0);
}
