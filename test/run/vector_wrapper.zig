//! exit: 0
//! stderr: "chain 0x7d2b3ac31527e28870a33993e7b9b735\nopt 7 err 9 arr 0x1e1d1c1b1a1918171615141312111010\nnested 0x50 zbit 0x60 small 0x9 write 0x30202 addr 0x1004\ncalls 0x2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a\nasm 0x7d0 many 0xbc7\n"
//! targets: x86_64-linux aarch64-linux aarch64-macos

// A struct whose one runtime field is a vector, as `crypto.aes` wraps its
// blocks, lives where its vector does (aarch64's vector registers) and is
// read through its field as Sema spills by-value parameters; and
// functions whose bodies hold inline assembly are inlined into loops,
// with the vector state live across the statement.
const std = @import("std");
const builtin = @import("builtin");

const V = @Vector(2, u64);
const Block = struct {
    repr: V,
    fn xor(a: Block, b: Block) Block {
        return .{ .repr = a.repr ^ b.repr };
    }
    fn mix(a: Block, k: Block) Block {
        const rot = @shuffle(u64, a.repr, undefined, [2]i32{ 1, 0 });
        return .{ .repr = (rot +% k.repr) ^ (a.repr >> @splat(7)) };
    }
    fn word(a: Block) u128 {
        return @bitCast(a.repr);
    }
};
const Nested = struct { b: Block };
const ZeroBit = struct { pad: void, v: @Vector(4, u32) };
const Small = struct { v: @Vector(2, u32) };

fn zeroBit(v: @Vector(4, u32)) ZeroBit {
    return .{ .pad = {}, .v = v +% @as(@Vector(4, u32), @splat(1)) };
}

noinline fn opaqueXor(a: Block, b: Block) Block {
    return a.xor(b);
}

fn maybe(b: Block, ok: bool) ?Block {
    return if (ok) b else null;
}

fn fallible(b: Block, ok: bool) error{Bad}!Block {
    return if (ok) b else error.Bad;
}

/// One round in inline assembly, as `armcrypto.Block.encrypt`: inlined
/// into the loop that calls it.
fn asmRound(b: Block, k: Block) Block {
    const out = switch (builtin.cpu.arch) {
        .aarch64 => asm ("eor %[o].16b, %[i].16b, %[k].16b"
            : [o] "=&x" (-> V),
            : [i] "x" (b.repr),
              [k] "x" (k.repr),
        ),
        else => asm ("pxor %[k], %[o]"
            : [o] "=x" (-> V),
            : [i] "0" (b.repr),
              [k] "x" (k.repr),
        ),
    };
    return .{ .repr = out +% @as(V, @splat(1)) };
}

/// More vector operands than aarch64's scratch registers, with a block
/// live in a vector register across the statement.
fn manyOperands(k: V, j: V, live: Block) u64 {
    const pre = live.mix(.{ .repr = k });
    var acc: V = @splat(0);
    switch (builtin.cpu.arch) {
        .aarch64 => acc = asm (
            \\ eor %[r].16b, %[a0].16b, %[a1].16b
            \\ eor %[r].16b, %[r].16b, %[a2].16b
            \\ eor %[r].16b, %[r].16b, %[a3].16b
            \\ eor %[r].16b, %[r].16b, %[a4].16b
            \\ eor %[r].16b, %[r].16b, %[a5].16b
            \\ eor %[r].16b, %[r].16b, %[a6].16b
            \\ eor %[r].16b, %[r].16b, %[a7].16b
            \\ eor %[r].16b, %[r].16b, %[a8].16b
            \\ eor %[r].16b, %[r].16b, %[a9].16b
            \\ eor %[r].16b, %[r].16b, %[a10].16b
            \\ eor %[r].16b, %[r].16b, %[a11].16b
            \\ eor %[r].16b, %[r].16b, %[a12].16b
            \\ eor %[r].16b, %[r].16b, %[a13].16b
            \\ eor %[r].16b, %[r].16b, %[a14].16b
            \\ eor %[r].16b, %[r].16b, %[a15].16b
            : [r] "=&w" (-> V),
            : [a0] "w" (k),
              [a1] "w" (j),
              [a2] "w" (k),
              [a3] "w" (j),
              [a4] "w" (k),
              [a5] "w" (j),
              [a6] "w" (k),
              [a7] "w" (j),
              [a8] "w" (k),
              [a9] "w" (j),
              [a10] "w" (k),
              [a11] "w" (j),
              [a12] "w" (k),
              [a13] "w" (j),
              [a14] "w" (k),
              [a15] "w" (j),
        ),
        else => for (0..8) |_| {
            acc ^= k ^ j;
        },
    }
    const post = pre.xor(.{ .repr = acc });
    return post.repr[0] +% post.repr[1];
}

pub fn main() void {
    var keys: [11]Block = undefined;
    for (&keys, 0..) |*k, i| k.* = .{ .repr = .{ 0x0123456789abcdef *% (i + 1), 0xfedcba9876543210 ^ i } };
    var t: Block = .{ .repr = .{ 0x1c2d3e4f50617283, 0x3b9f0a5a7b4d2a6e } };
    var n: usize = 0;
    while (n < 3) : (n += 1) {
        inline for (keys[0..10]) |k| t = t.mix(k);
        t = t.xor(keys[10]).xor(keys[10]);
    }
    std.debug.print("chain 0x{x}\n", .{t.word()});

    var opt_sum: u64 = 0;
    if (maybe(.{ .repr = .{ 3, 4 } }, true)) |b| opt_sum += b.repr[0] + b.repr[1];
    if (maybe(.{ .repr = .{ 5, 6 } }, false)) |b| opt_sum += b.repr[0];
    var err_sum: u64 = 0;
    if (fallible(.{ .repr = .{ 4, 5 } }, true)) |b| err_sum += b.repr[0] + b.repr[1] else |_| {}
    if (fallible(.{ .repr = .{ 1, 1 } }, false)) |b| err_sum += b.repr[0] else |_| {}
    var arr: [2]Block = undefined;
    const bytes: [16]u8 = .{ 0x10, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e };
    arr[1] = .{ .repr = @bitCast(bytes) };
    arr[0] = arr[1];
    std.debug.print("opt {d} err {d} arr 0x{x}\n", .{ opt_sum, err_sum, arr[0].word() });

    var nest: Nested = .{ .b = .{ .repr = .{ 0x20, 0x30 } } };
    nest.b = nest.b.xor(.{ .repr = .{ 0, 0 } });
    var z: ZeroBit = .{ .pad = {}, .v = .{ 0x10, 0x20, 0x30, 0 } };
    z = zeroBit(z.v -% @as(@Vector(4, u32), @splat(@intCast(n - 2))));
    var small: Small = .{ .v = .{ 4, 5 } };
    small = .{ .v = small.v };
    var w: Block = .{ .repr = .{ 1, 2 } };
    w.repr[1] = 0x30201;
    const p = &w.repr;
    p[0] += 0x1003;
    std.debug.print("nested 0x{x} zbit 0x{x} small 0x{x} write 0x{x} addr 0x{x}\n", .{ nest.b.repr[0] + nest.b.repr[1], @reduce(.Add, z.v), small.v[0] + small.v[1], w.repr[1] + 1, w.repr[0] });

    var c: Block = .{ .repr = @splat(0x2a2a2a2a2a2a2a2a) };
    var j: usize = 0;
    while (j < 4) : (j += 1) c = opaqueXor(opaqueXor(c, keys[j]), keys[j]);
    std.debug.print("calls 0x{x}\n", .{c.word()});

    var s: Block = .{ .repr = @splat(0) };
    var i: u64 = 0;
    while (i < 1000) : (i += 1) s = asmRound(s, .{ .repr = @splat(0) });
    const live: Block = .{ .repr = .{ 8, s.repr[0] } };
    const total = manyOperands(s.repr, s.repr +% live.repr, live);
    std.debug.print("asm 0x{x} many 0x{x}\n", .{ s.repr[0] + s.repr[1], total });
}
