//! signal: ABRT
//! stdout: "15289149009567803999\n15289149009567803999\n1011000101 0100111010\n2\n16\n16\n2139095040\n4290772992\n1266679808\n01\n9223372036854775808\n31744\n1\n16777216\n1069547520\n13834917317793808384\n4611826755915743232\n9223372036854775808\n536870912\n1\n18446744073709551552\n18446744073709551615\n0\n18446744073709551588\n11\n16339675983031644798\n18446744073709551615\n1\n"
//! stderr: "panic: integer overflow\n"
//! upstream-signal: SEGV
const rt = @import("rt.zig");

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

fn pi(x: i64) void {
    rt.printInt(@bitCast(x));
}

fn pb(b: bool) void {
    rt.print(if (b) "1" else "0");
}

fn bits32(x: f32) void {
    rt.printInt(@as(u32, @bitCast(x)));
}

/// Element-wise arithmetic, comparisons, casts, and the vector builtins,
/// at runtime and at comptime; bool vectors are bit-packed.
fn ints() i64 {
    var a: @Vector(4, i32) = .{ 1, -2, 3, 2147483647 };
    var b: @Vector(4, i32) = .{ 5, 6, -7, 1 };
    _ = &a;
    _ = &b;
    const s = a +% b;
    const d = a - @as(@Vector(4, i32), @splat(1));
    const lt = a < b;
    const sel = @select(i32, lt, a, b);
    const sh = @shuffle(i32, a, b, @Vector(5, i32){ 3, -1, 0, -4, 2 });
    const w: @Vector(4, i64) = a;
    const t: @Vector(4, i8) = @truncate(a);
    const n = -%a;
    const sl = b << @splat(3);
    const pc = @popCount(a);
    var acc: i64 = 0;
    inline for (0..4) |i| {
        acc = acc *% 31 +% s[i];
        acc = acc *% 31 +% d[i];
        acc = acc *% 31 +% @intFromBool(lt[i]);
        acc = acc *% 31 +% sel[i];
        acc = acc *% 31 +% w[i];
        acc = acc *% 31 +% t[i];
        acc = acc *% 31 +% n[i];
        acc = acc *% 31 +% sl[i];
        acc = acc *% 31 +% pc[i];
    }
    inline for (0..5) |i| acc = acc *% 31 +% sh[i];
    return acc;
}

fn bools() void {
    var x: @Vector(10, bool) = .{ true, false, true, true, false, false, false, true, false, true };
    _ = &x;
    const y = !x;
    comptime var i: usize = 0;
    inline while (i < 10) : (i += 1) pb(x[i]);
    rt.print(" ");
    i = 0;
    inline while (i < 10) : (i += 1) pb(y[i]);
    rt.print("\n");
    rt.printInt(@sizeOf(@Vector(10, bool)));
    rt.printInt(@sizeOf(@Vector(3, u8)));
    rt.printInt(@alignOf(@Vector(3, u8)));
}

fn floats() void {
    var f: @Vector(3, f32) = .{ 1.5, -0.0, 16777217.0 };
    var g: @Vector(3, f32) = .{ 0.0, 0.0, 1.0 };
    _ = &f;
    _ = &g;
    const q = f / g;
    bits32(q[0]);
    bits32(q[1]);
    bits32(q[2]);
    const ne = q != q;
    pb(ne[0]);
    pb(ne[1]);
    rt.print("\n");
    const h: @Vector(3, f64) = f;
    rt.printInt(@as(u64, @bitCast(h[1])));
    const r: @Vector(3, f16) = @floatCast(f);
    rt.printInt(@as(u16, @bitCast(r[2])));
    const k: @Vector(3, i32) = @intFromFloat(f);
    pi(k[0]);
    pi(k[2]);
    const sq = @sqrt(f * f);
    bits32(sq[0]);
}

/// `@bitCast` of vectors whose elements have padding bits works element
/// by element.
fn padded() void {
    var w: @Vector(4, f80) = .{ -1.0, 2.0, -0.0, 0x1p-16400 };
    var v: @Vector(5, u7) = .{ 1, 64, 127, 0, 100 };
    _ = .{ &w, &v };
    const wi: @Vector(4, i80) = @bitCast(w);
    inline for (0..4) |i| rt.printInt(@as(u64, @truncate(@as(u80, @bitCast(wi[i])) >> 16)));
    const vi: @Vector(5, i7) = @bitCast(v);
    inline for (0..5) |i| pi(vi[i]);
    const wb: @Vector(4, f80) = @bitCast(wi);
    pb(wb[2] == 0.0);
    pb(wi[2] < 0);
    rt.print("\n");
}

/// The overflow builtins on vectors give a vector of overflow bits.
fn overflow() void {
    var a: @Vector(5, i8) = .{ 127, -128, 5, -7, 64 };
    var b: @Vector(5, i8) = .{ 1, -1, 3, -128, 2 };
    var s: @Vector(5, u3) = .{ 0, 1, 7, 2, 1 };
    var c: @Vector(1, i1) = .{-1};
    _ = .{ &a, &b, &s, &c };
    const add = @addWithOverflow(a, b);
    const sub = @subWithOverflow(a, b);
    const mul = @mulWithOverflow(a, b);
    const shl = @shlWithOverflow(a, s);
    var acc: i64 = 0;
    inline for (0..5) |i| {
        acc = acc *% 31 +% add[0][i];
        acc = acc *% 31 +% add[1][i];
        acc = acc *% 31 +% sub[0][i];
        acc = acc *% 31 +% sub[1][i];
        acc = acc *% 31 +% mul[0][i];
        acc = acc *% 31 +% mul[1][i];
        acc = acc *% 31 +% shl[0][i];
        acc = acc *% 31 +% shl[1][i];
    }
    pi(acc);
    const m = @mulWithOverflow(c, c);
    pi(m[0][0]);
    rt.printInt(m[1][0]);
}

fn main() callconv(.c) noreturn {
    pi(ints());
    pi(comptime ints());
    bools();
    floats();
    padded();
    overflow();
    var a: @Vector(2, i8) = .{ 100, 1 };
    _ = &a;
    const b = a + a; // overflow traps in element 0
    pi(b[1]);
    rt.exit(0);
}
