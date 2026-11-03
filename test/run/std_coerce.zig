//! exit: 0
//! stdout: "1\n3\n1\n9\n4\n99\n2\n7\n1\n7\n17\n2\n3\n9\n0\n0\n18\n89\n7\n5\n9\n7\n5\n1\n1\n"
//! Coercions and builtins that std's own tests need: pointer alignment
//! against a natural alignment (zero-bit and not yet laid out types),
//! `@typeInfo` field alignment, errors from `switch` prongs of inline and
//! comptime calls, destructuring a `switch`, an error union as the payload
//! of another, a calling convention held in a typed constant, and the
//! `cpuid` and `xgetbv` instructions.
const std = @import("std");
const builtin = @import("builtin");
const rt = @import("rt.zig");
pub const panic = rt.panic;

const E = enum(u8) { a, b };
const R = extern struct { x: u32 align(4096) };
fn zeroBit(p: *align(1) u0) error{OutOfMemory}!*u0 {
    return p;
}
fn voids(p: []align(1) void) error{OutOfMemory}![]void {
    return p;
}

// Laid out only when its pointer is first coerced.
const Ring = extern struct { a: u64, b: u32, c: u16, tail: u16 };
fn getRing(mem: *align(4096) [64]u8, fail: bool) !*align(4096) Ring {
    if (fail) return error.Bad;
    const br: *align(4096) Ring = @ptrCast(mem);
    return br;
}
fn initRing(s: *Ring) void {
    s.tail = 9;
}
fn ring() !u16 {
    var mem: [64]u8 align(4096) = undefined;
    const p = try getRing(&mem, false);
    initRing(p);
    return p.tail;
}

const A = extern struct {
    f0: u32,
    f1: extern struct { f0: u64 } align(4),
    f2: u32,
};

fn utf8Len(first_byte: u8) !u3 {
    return switch (first_byte) {
        0b0000_0000...0b0111_1111 => 1,
        0b1100_0000...0b1101_1111 => 2,
        else => error.Bad,
    };
}
inline fn inlineLen(first_byte: u8) !u3 {
    return switch (first_byte) {
        0b0000_0000...0b0111_1111 => 1,
        else => error.Bad,
    };
}

fn destructure(n: u32, b: u8) void {
    const code, const extra, const xsize = switch (n) {
        0 => unreachable,
        1...2 => .{ b, 0, 0 },
        3...10 => .{ @as(u8, 16) + @intFromBool(b == 0), n - 3, @as(u8, 2) + @intFromBool(b == 0) },
        else => .{ 18, n - 11, 7 },
    };
    rt.printInt(code);
    rt.printInt(extra);
    rt.printInt(xsize);
}

const Elem = error{ A, B }!u32;
fn nested(x: u32) error{Closed}!Elem {
    var buf: [1]Elem = undefined;
    buf[0] = if (x == 0) error.A else x;
    return buf[0];
}

const bloaty: std.builtin.CallingConvention = switch (builtin.mode) {
    .ReleaseSafe, .ReleaseFast => .@"inline",
    .Debug, .ReleaseSmall => .auto,
};
const plain: std.builtin.CallingConvention = .auto;
fn ccSwitch(a: u32) callconv(bloaty) u32 {
    return a + 1;
}
fn ccPlain(a: u32) callconv(plain) u32 {
    return a + 2;
}

fn cpuidMaxLeaf() u32 {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [_] "={eax}" (eax),
          [_] "={ebx}" (ebx),
          [_] "={ecx}" (ecx),
          [_] "={edx}" (edx),
        : [_] "{eax}" (0),
          [_] "{ecx}" (0),
    );
    return eax;
}
fn getXCR0() u32 {
    return asm volatile (
        \\ xor %%ecx, %%ecx
        \\ xgetbv
        : [_] "={eax}" (-> u32),
        :
        : .{ .edx = true, .ecx = true });
}

pub fn main() void {
    var e: E = .b;
    const pe: *align(1) E = &e;
    const q: *const E = pe;
    rt.printInt(@intFromEnum(q.*));
    var x: u0 = 0;
    _ = zeroBit(&x) catch unreachable;
    var v: [3]void = undefined;
    rt.printInt((voids(&v) catch unreachable).len);
    var r: R = undefined;
    const pr: *align(4096) R = &r;
    const pr2: *R = pr;
    rt.printInt(@intFromBool(pr2 == &r));
    rt.printInt(ring() catch 0);

    const attrs = @typeInfo(A).@"struct".field_attrs;
    rt.printInt(attrs[1].@"align" orelse 99);
    rt.printInt(attrs[0].@"align" orelse 99);

    var b: u8 = 0xc5;
    _ = &b;
    rt.printInt(utf8Len(b) catch 7);
    b = 0xff;
    rt.printInt(utf8Len(b) catch 7);
    rt.printInt(comptime (utf8Len(3) catch 7));
    b = 200;
    rt.printInt(inlineLen(b) catch 7);

    var n: u32 = 5;
    _ = &n;
    destructure(n, 0);
    destructure(2, 9);
    destructure(100, 1);

    rt.printInt((nested(5) catch unreachable) catch 0);
    rt.printInt((nested(0) catch unreachable) catch 9);
    rt.printInt(comptime (nested(7) catch unreachable) catch 1);

    rt.printInt(ccSwitch(1) + ccPlain(1));

    rt.printInt(@intFromBool(cpuidMaxLeaf() >= 1));
    // x87 state is always enabled.
    rt.printInt(getXCR0() & 1);
}
