//! exit: 0
//! stderr: "ALU 1587d3047363e6\nSHIFT 65d46875232a1b82\nDIV e969d7611e2a8b89\nMEM 1e08e156015da3be\nATOMIC be3f08145d626641\nCALL 7ac80198cabd226a\nELEM 9e3b09f85d594b11\n"
//! rcx, rdx and r10 hold values whose intervals contain no lowering that
//! may write them (`scratchUse`). Each function keeps more values live
//! than the other registers can hold, across one kind of lowering that
//! writes some of them (shifts by a variable count, division, string
//! copies, atomics, calls) or reads spilled operands at narrow widths,
//! through spilled pointers, and with scaled indices; the sums are
//! upstream's.
const std = @import("std");

var src: [64]u64 = undefined;

fn v(i: usize) u64 {
    return @as(*volatile u64, &src[i]).*;
}

noinline fn alu() u64 {
    var a: u32 = @truncate(v(0));
    var b: u16 = @truncate(v(1));
    var c: u8 = @truncate(v(2));
    var d: i32 = @bitCast(@as(u32, @truncate(v(3))));
    var e: u64 = v(4);
    var f: i16 = @bitCast(@as(u16, @truncate(v(5))));
    var g: u32 = @truncate(v(6));
    var h: u7 = @truncate(v(7));
    var i: i8 = @bitCast(@as(u8, @truncate(v(8))));
    var j: u64 = v(9);
    var k: u32 = @truncate(v(10));
    var l: u16 = @truncate(v(11));
    var m: u64 = v(12);
    var n: i64 = @bitCast(v(13));
    var o: u32 = @truncate(v(14));
    var acc: u64 = 0;
    for (0..40) |t| {
        a +%= g ^ k;
        b -%= l | @as(u16, c);
        c *%= @as(u8, @truncate(t)) | 1;
        d = d *% @as(i32, @bitCast(o)) -% d;
        e ^= j +% m;
        f +%= @as(i16, i) -% f;
        g = (g & a) | (o ^ k);
        h +%= @truncate(t);
        i -%= @as(i8, @truncate(f));
        j = j *% 3 +% @as(u64, a);
        k ^= @as(u32, b) *% 7;
        l = l *% b +% 1;
        m = m -% @as(u64, @bitCast(n));
        n = n *% -3 +% d;
        o = o *% g +% @as(u32, h);
        if (a < k or b == l or c > 7 or d < -5 or i > 3 or h == 3) acc +%= 1;
        acc = acc *% 31 +% a +% b +% c +% @as(u32, @bitCast(d)) +% e +% @as(u16, @bitCast(f)) +% g +% h +% @as(u8, @bitCast(i)) +% j +% k +% l +% m +% @as(u64, @bitCast(n)) +% o;
    }
    return acc;
}

noinline fn shifts() u64 {
    var x: [12]u64 = undefined;
    for (&x, 0..) |*p, i| p.* = v(i + 16);
    var s: u6 = @truncate(v(30));
    var acc: u64 = 0;
    for (0..30) |t| {
        const a = x[0] << s;
        const b = x[1] >> s;
        const c: i64 = @as(i64, @bitCast(x[2])) >> s;
        s +%= @truncate(t);
        x[t % 12] +%= a ^ b ^ @as(u64, @bitCast(c)) ^ x[(t + 5) % 12];
        acc = acc *% 17 +% x[0] +% x[1] +% x[2] +% x[3] +% x[4] +% x[5] +% x[6] +% x[7] +% x[8] +% x[9] +% x[10] +% x[11] +% s;
    }
    return acc;
}

noinline fn divs() u64 {
    var a = v(31) | 1;
    var b = v(32) | 3;
    var c: u32 = @truncate(v(33) | 5);
    var d: i64 = @bitCast(v(34) | 7);
    var e = v(35);
    var f = v(36);
    var g = v(37);
    var h = v(38);
    var i = v(39);
    var j = v(40);
    var k = v(41);
    var acc: u64 = 0;
    for (1..30) |t| {
        a = a / (t | 1) +% e;
        b = b % (a | 1) +% f;
        c = c / @as(u32, @truncate(t | 2)) +% @as(u32, @truncate(g));
        d = @divTrunc(d, @as(i64, @intCast(t)) - 15 | 1) +% @as(i64, @bitCast(h));
        e ^= i *% j;
        f = f *% k;
        g +%= h;
        h ^= e;
        i +%= f;
        j +%= 1;
        k = k *% g;
        acc = acc *% 13 +% a +% b +% c +% @as(u64, @bitCast(d)) +% e +% f +% g +% h +% i +% j +% k;
    }
    return acc;
}

const Big = struct { w: [40]u8 };

noinline fn mem(dst: *Big, s: *const Big) u64 {
    var a = v(42);
    var b = v(43);
    var c = v(44);
    var d = v(45);
    var e = v(46);
    var f = v(47);
    var g = v(48);
    var h = v(49);
    var i = v(50);
    var j = v(51);
    var k = v(52);
    var acc: u64 = 0;
    for (0..20) |t| {
        dst.* = s.*;
        @memset(dst.w[t % 8 ..][0..20], @truncate(a));
        a +%= dst.w[t % 40];
        b ^= a;
        c +%= b;
        d ^= c;
        e +%= d;
        f ^= e;
        g +%= f;
        h ^= g;
        i +%= h;
        j ^= i;
        k +%= j;
        acc = acc *% 7 +% a +% b +% c +% d +% e +% f +% g +% h +% i +% j +% k;
    }
    return acc;
}

noinline fn atomics() u64 {
    var cell: u64 = v(53);
    var a = v(54);
    var b = v(55);
    var c = v(56);
    var d = v(57);
    var e = v(58);
    var f = v(59);
    var g = v(60);
    var h = v(61);
    var i = v(62);
    var j = v(63);
    var k = v(0);
    var acc: u64 = 0;
    for (0..20) |t| {
        const old = @atomicRmw(u64, &cell, .Add, a, .seq_cst);
        _ = @cmpxchgStrong(u64, &cell, old +% a, b, .seq_cst, .seq_cst);
        const x = @atomicRmw(u64, &cell, .Xchg, c +% t, .seq_cst);
        a +%= x;
        b ^= old;
        c +%= b;
        d ^= c;
        e +%= d;
        f ^= e;
        g +%= f;
        h ^= g;
        i +%= h;
        j ^= i;
        k +%= j;
        acc = acc *% 7 +% a +% b +% c +% d +% e +% f +% g +% h +% i +% j +% k +% @atomicLoad(u64, &cell, .seq_cst);
    }
    return acc;
}

noinline fn mix(a: u64, b: u64, c: u64, d: u64, e: u64, f: u64, g: u64) u64 {
    return a ^ (b *% 3) ^ (c *% 5) ^ (d *% 7) ^ (e *% 11) ^ (f *% 13) ^ (g *% 17);
}

noinline fn calls() u64 {
    var a = v(1);
    var b = v(2);
    var c = v(3);
    var d = v(4);
    var e = v(5);
    var f = v(6);
    var g = v(7);
    var h = v(8);
    var acc: u64 = 0;
    for (0..20) |t| {
        const x = mix(a, b, c, d +% t, e, f, g);
        a = b +% x;
        b = c ^ x;
        c = d +% a;
        d = e ^ b;
        e = f +% c;
        f = g ^ d;
        g = h +% e;
        h ^= f;
        acc = acc *% 7 +% a +% b +% c +% d +% e +% f +% g +% h;
    }
    return acc;
}

const S12 = struct { a: u32, b: u32, c: u32 };
const S24 = struct { a: u64, b: u64, c: u64 };

noinline fn elems(xs: []S12, ys: []S24, ps: []*u64) u64 {
    var i: usize = @truncate(v(5) % 7);
    var j: usize = @truncate(v(6) % 5);
    var a = v(7);
    var b = v(8);
    var c = v(9);
    var d = v(10);
    var e = v(11);
    var f = v(12);
    var g = v(13);
    var h = v(14);
    var k = v(15);
    var acc: u64 = 0;
    for (0..40) |t| {
        xs[i].b +%= @truncate(a);
        ys[j].c ^= b;
        ps[t % ps.len].* +%= c;
        a +%= xs[(i + 1) % xs.len].a;
        b ^= ys[(j + 2) % ys.len].b;
        c +%= ps[(t + 1) % ps.len].*;
        d ^= a;
        e +%= b;
        f ^= c;
        g +%= d;
        h ^= e;
        k +%= f;
        i = (i + 3) % xs.len;
        j = (j + 2) % ys.len;
        acc = acc *% 7 +% a +% b +% c +% d +% e +% f +% g +% h +% k +% i +% j;
    }
    return acc;
}

pub fn main() void {
    for (&src, 0..) |*p, i| p.* = (i *% 0x9E3779B97F4A7C15) ^ (i << 7) ^ 0x1234567;
    var big_s: Big = undefined;
    for (&big_s.w, 0..) |*p, i| p.* = @truncate(i *% 37);
    var big_d: Big = undefined;
    var xs: [7]S12 = undefined;
    for (&xs, 0..) |*p, i| p.* = .{ .a = @truncate(i * 3), .b = @truncate(i * 5), .c = 1 };
    var ys: [5]S24 = undefined;
    for (&ys, 0..) |*p, i| p.* = .{ .a = i, .b = i * 9, .c = 2 };
    var cells: [3]u64 = .{ 1, 2, 3 };
    var ps = [_]*u64{ &cells[0], &cells[1], &cells[2], &cells[1] };
    const results = [_]u64{ alu(), shifts(), divs(), mem(&big_d, &big_s), atomics(), calls(), elems(&xs, &ys, &ps) };
    const names = [_][]const u8{ "ALU", "SHIFT", "DIV", "MEM", "ATOMIC", "CALL", "ELEM" };
    for (results, names) |r, n| std.debug.print("{s} {x}\n", .{ n, r });
}
