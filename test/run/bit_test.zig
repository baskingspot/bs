//! exit: 0
//! stdout: "u true false | f 20 10 | n false true | e y n | g 1 2 3 | w 1 2 0 | m 7 0 | s true false | z true false | b false true | r true false\n"

// A one-bit field of a packed struct compared with a constant, and a mask
// compared with 0, read the bit in place (`test`, `Ssa.plan`'s bit
// tests): in a register and in memory, branched on and as a value, at
// the lowest and highest bit of a byte, past the first byte, and past bit
// 31, which is still computed. Each case has inputs where the bit is set
// and clear, with the other bits set the opposite way. A shift compared
// with a constant is not a bit test.
const std = @import("std");

const Meta = packed struct(u8) { fp: u7, used: u1 };
const Flags = packed struct(u16) { lo: bool, mid: u14, hi: bool };
const Wide = packed struct(u64) { a: u31, b: u1, c: u1, d: u31 };

noinline fn used(m: *const Meta) bool {
    return m.used == 1;
}

noinline fn free(m: *const Meta) u32 {
    if (m.used == 0) return 10;
    return 20;
}

noinline fn notUsed(m: Meta) bool {
    return m.used != 1;
}

noinline fn usedNe0(m: Meta) u8 {
    if (m.used != 0) return 'y';
    return 'n';
}

noinline fn flags(f: *const Flags) u8 {
    var r: u8 = 0;
    if (f.lo) r |= 1;
    if (f.hi) r |= 2;
    return r;
}

noinline fn boolVal(f: Flags) bool {
    return f.hi;
}

noinline fn wide(w: Wide) u8 {
    var r: u8 = 0;
    if (w.b == 1) r |= 1;
    if (w.c == 1) r |= 2;
    return r;
}

noinline fn masked(x: u32, y: *const u64) u8 {
    var r: u8 = 0;
    if (x & 0x40 != 0) r |= 1;
    if (x & 0x8000_0000 == 0) r |= 2;
    if (y.* & 0x100 != 0) r |= 4;
    return r;
}

noinline fn signedBit(x: i8) bool {
    return (x >> 7) & 1 == 1;
}

noinline fn shifted(x: u32) bool {
    return x >> 3 == 2;
}

noinline fn isZero(x: u64) bool {
    return x == 0;
}

pub fn main() void {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const set: Meta = .{ .fp = 0, .used = 1 };
    const clear: Meta = .{ .fp = 0x7f, .used = 0 };
    w.print("u {} {} | f {} {} | n {} {} | e {c} {c} | g {} {} {} | w {} {} {} | m {} {} | s {} {} | z {} {} | b {} {} | r {} {}\n", .{
        used(&set),
        used(&clear),
        free(&set),
        free(&clear),
        notUsed(set),
        notUsed(clear),
        usedNe0(set),
        usedNe0(clear),
        flags(&.{ .lo = true, .mid = 0, .hi = false }),
        flags(&.{ .lo = false, .mid = 0x3fff, .hi = true }),
        flags(&.{ .lo = true, .mid = 0, .hi = true }),
        wide(.{ .a = 0, .b = 1, .c = 0, .d = 0x7fff_ffff }),
        wide(.{ .a = 0x7fff_ffff, .b = 0, .c = 1, .d = 0 }),
        wide(.{ .a = 0, .b = 0, .c = 0, .d = 0 }),
        masked(0x40, &@as(u64, 0x100)),
        masked(0xffff_ffbf, &@as(u64, 0xffff_feff)),
        signedBit(-1),
        signedBit(127),
        isZero(0),
        isZero(1 << 40),
        boolVal(.{ .lo = true, .mid = 0x3fff, .hi = false }),
        boolVal(.{ .lo = false, .mid = 0, .hi = true }),
        shifted(0x10),
        shifted(0x3),
    }) catch unreachable;
    std.Io.File.stdout().writeStreamingAll(std.Options.debug_io, w.buffered()) catch {};
}
