//! exit: 0
//! stdout: "76846\n4137703\n74243\n2999\n18446598959453085560\n266792\n16194944260024680548\n"
//! A packed field read of an inline call's by-value argument loads the
//! whole backing integer through a pointer cast of the `const` local
//! holding the argument; forward.zig reads it from the stored value
//! instead. Each case could print something else if the value read were
//! not the one stored there: a field at a bit offset, a packed union, a
//! local written through a field pointer, an argument whose address
//! escapes, a `const` local built field by field, a local stored again
//! on each loop iteration, and backing integers of 64 and 63 bits with
//! signed fields (a `u63` is read as a `u64` and left alone). Each prints
//! what upstream's ReleaseSafe build prints.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

fn out(v: u64) void {
    rt.printInt(v);
}

const Wide = enum(u2) { narrow, wide, spacer_tail, spacer_head };

const Cell = packed struct(u64) {
    tag: u2 = 0,
    content: u24 = 0,
    style: u16 = 0,
    wide: Wide = .narrow,
    hyperlink: bool = false,
    top: i19 = 0,

    inline fn isTag(self: Cell, t: u2) bool {
        return self.tag == t;
    }
    inline fn styleOf(self: Cell) u16 {
        return self.style;
    }
    inline fn signed(self: Cell) i64 {
        return self.top;
    }
};

var cells: [6]Cell = .{
    .{ .tag = 1, .content = 0x123456, .style = 7, .wide = .wide, .top = -5 },
    .{ .tag = 0, .content = 1, .style = 0, .hyperlink = true, .top = 262143 },
    .{ .tag = 3, .content = 0xffffff, .style = 0xffff, .wide = .spacer_head, .top = -262144 },
    .{ .tag = 1, .style = 300, .wide = .spacer_tail, .top = 1 },
    .{ .tag = 2, .content = 77, .style = 1 },
    .{ .tag = 1, .content = 5, .style = 9, .hyperlink = true, .top = -1 },
};

fn sink(p: *const u64) u64 {
    return p.* ^ 0x5a5a;
}

/// Fields at bit offsets 0 and 26, and a signed field ending at bit 63.
fn byValue() u64 {
    var n: u64 = 0;
    for (&cells, 0..) |*cell, i| {
        if (cell.isTag(1)) n += 1000 * (i + 1);
        n += cell.styleOf();
        n +%= @bitCast(cell.signed());
    }
    return n;
}

const U = packed union {
    whole: u32,
    halves: packed struct(u32) { lo: u16, hi: u16 },

    inline fn hi(self: U) u16 {
        return self.halves.hi;
    }
    inline fn low(self: U) u16 {
        return self.halves.lo;
    }
};

var words = [_]u32{ 0x12345678, 0xffff0001, 0x0000ffff };

fn packedUnion() u64 {
    var n: u64 = 0;
    for (words) |w| {
        const u: U = .{ .whole = w };
        n = n * 7 + u.hi() + 3 * @as(u64, u.low());
    }
    return n;
}

/// A local written through a pointer to one of its fields between two
/// reads: the second read sees the write.
fn fieldWrite() u64 {
    var c = cells[0];
    const before = c.style;
    const p = &c.style;
    p.* = 4242;
    asm volatile ("" ::: .{ .memory = true });
    return @as(u64, before) * 10000 + c.style + @as(u64, @backingInt(c.wide));
}

/// A `const` local built field by field through field pointers into its
/// backing integer, then read.
noinline fn fieldInit(a: u2, b: u16) u64 {
    const c: Cell = .{ .tag = a, .style = b, .top = -2 };
    return @as(u64, c.style) * 10 + c.tag +% @as(u64, @bitCast(c.signed()));
}

/// The argument's address escapes to a call; the field still reads the
/// argument's value.
inline fn escapes(self: Cell) u64 {
    const p: *const u64 = @ptrCast(&self);
    const s = sink(p);
    return s +% self.style +% @as(u64, self.tag) * 100;
}

fn escaped() u64 {
    var n: u64 = 0;
    for (cells) |c| n +%= escapes(c);
    return n;
}

/// The local is stored again on every iteration, and the read must see
/// this iteration's value, not the last one's.
fn perIteration() u64 {
    var n: u64 = 0;
    var i: usize = 0;
    var prev: u16 = 0;
    while (i < cells.len) : (i += 1) {
        if (i == 2) {
            prev = 1;
            continue;
        }
        const c: Cell = cells[(i * 5) % cells.len];
        n = n * 3 + c.styleOf() + prev;
        prev = c.style;
        if (c.isTag(1)) continue;
        n += 11;
    }
    return n;
}

const P63 = packed struct(u63) {
    low: u55,
    top: i8,

    inline fn sx(self: P63) i64 {
        return self.top;
    }
    inline fn zx(self: P63) u64 {
        return self.low;
    }
};

var p63s = [_]P63{
    .{ .low = (1 << 55) - 1, .top = -1 },
    .{ .low = 12345, .top = -128 },
    .{ .low = 1 << 54, .top = 127 },
};

fn narrow() u64 {
    var n: u64 = 0;
    for (&p63s) |*p| {
        n = n *% 31 +% @as(u64, @bitCast(p.sx())) +% p.zx();
    }
    return n;
}

fn main() callconv(.c) noreturn {
    out(byValue());
    out(packedUnion());
    out(fieldWrite());
    out(fieldInit(@truncate(@as(u64, @bitCast(cells[0]))), cells[3].style));
    out(escaped());
    out(perIteration());
    out(narrow());
    rt.exit(0);
}
