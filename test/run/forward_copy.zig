//! exit: 0
//! stdout: "1 2 3 4 5 6 7 8 9 10\n2 11 9 3 6 2 3 7 4 6 21 10\n"

// A `const` copy of an aggregate that is only read reads its source
// (`codegen/forward.zig`), unless the source may be written while the copy
// is in use. Each case writes the source after the copy and must read the
// value from before. The second line: a load reads the value a store or a
// load before it found, unless something in between may write the memory.
const std = @import("std");

const S = struct { a: u64, b: u64, c: [6]u64 };

noinline fn afterStore(p: *S) u64 {
    const x = p.*;
    p.b = 100;
    return x.b;
}

noinline fn clobber(p: *S) void {
    p.b = 200;
}

noinline fn afterCall(p: *S) u64 {
    const x = p.*;
    clobber(p);
    return x.b + 1;
}

noinline fn inLoop(p: *S) u64 {
    const x = p.*;
    var sum: u64 = 0;
    for (0..3) |_| {
        sum += x.b;
        p.b += 1;
    }
    return sum;
}

noinline fn local(v: u64) u64 {
    var s: S = .{ .a = v, .b = v, .c = @splat(v) };
    const x = s;
    s.b = 0;
    return x.b + s.b + 2;
}

fn takesSelf(self: S, q: *S) u64 {
    q.a = 300;
    return self.a;
}

noinline fn receiver(p: *S) u64 {
    return takesSelf(p.*, p) + 4;
}

noinline fn escapes(p: *S, out: **const S) u64 {
    const x = p.*;
    out.* = &x;
    p.b = 400;
    return out.*.b + 4;
}

noinline fn elemCopy(buf: []S, i: usize) u64 {
    const x = buf[i];
    buf[i].c[2] = 500;
    return x.c[2] + 6;
}

noinline fn readOnly(p: *const S) u64 {
    const x = p.*;
    return x.a + x.c[5];
}

noinline fn inlineArg(p: *S) u64 {
    return @call(.always_inline, takesSelf, .{ p.*, p }) + 8;
}

noinline fn viaArray(p: *const [4]S) u64 {
    const x = p[1];
    return x.c[0];
}

noinline fn aliasStore(p: *u64, q: *u64) u64 {
    p.* = 1;
    q.* = 2;
    return p.*;
}

const F = struct { a: u64, b: u64 };

noinline fn fieldAlias(s: *F, t: *F) u64 {
    s.a = 3;
    s.b = 4;
    t.a = 7;
    return s.a + s.b;
}

const U = extern union { a: u32, b: u32 };

noinline fn unionField(u: *U) u32 {
    u.a = 5;
    u.b = 9;
    return u.a;
}

const P = packed struct { x: u4, y: u4 };

noinline fn packedField(p: *P) u8 {
    p.x = 1;
    p.y = 2;
    return @as(u8, p.x) + p.y;
}

noinline fn bump(p: *u64) void {
    p.* += 1;
}

noinline fn afterBump(p: *u64) u64 {
    p.* = 5;
    bump(p);
    return p.*;
}

noinline fn inBranch(p: *u64, q: *u64, c: bool) u64 {
    p.* = 1;
    if (c) q.* = 2;
    return p.*;
}

noinline fn loopCarried(p: *u64) u64 {
    p.* = 0;
    var x: u64 = 0;
    for (0..3) |_| {
        x += p.*;
        p.* += 1;
    }
    return x;
}

noinline fn afterMemset(p: *[4]u8) u8 {
    p[0] = 1;
    @memset(p, 7);
    return p[0];
}

noinline fn set4(p: *u64) void {
    p.* = 4;
}

noinline fn escapedLocal() u64 {
    var x: u64 = 1;
    x = 3;
    set4(&x);
    return x;
}

noinline fn throughAlias(v: u64) u64 {
    var x: u64 = v;
    const p = &x;
    x = 5;
    p.* = 6;
    return x;
}

noinline fn wholeStore(v: u64, g: F) u64 {
    var f: F = .{ .a = v, .b = v };
    const x = f.a;
    f = g;
    return x + f.a;
}

noinline fn storeThenUse(p: *u64, a: u64, b: u64) u64 {
    p.* = a +% b;
    p.* +%= a;
    return p.*;
}

pub fn main() void {
    var s: S = .{ .a = 1, .b = 1, .c = @splat(1) };
    var buf = [_]S{ s, s };
    var arr: [4]S = @splat(s);
    arr[1].c[0] = 10;
    var sink: *const S = undefined;
    const r1 = afterStore(&s);
    s.b = 1;
    const r2 = afterCall(&s);
    s.b = 1;
    const r3 = inLoop(&s);
    const r4 = local(2);
    s.a = 1;
    const r5 = receiver(&s);
    s.b = 2;
    const r6 = escapes(&s, &sink);
    const r7 = elemCopy(&buf, 1);
    s.a = 3;
    s.c[5] = 5;
    const r8 = readOnly(&s);
    s.a = 1;
    const r9 = inlineArg(&s);
    const r10 = viaArray(&arr);
    var out: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    w.print("{} {} {} {} {} {} {} {} {} {}\n", .{ r1, r2, r3, r4, r5, r6, r7, r8, r9, r10 }) catch unreachable;
    var x: u64 = 0;
    var f: F = undefined;
    var u: U = undefined;
    var pk: P = .{ .x = 0, .y = 0 };
    var bytes: [4]u8 = @splat(0);
    w.print("{} {} {} {} {} {} {} {} {} {} {} {}\n", .{
        aliasStore(&x, &x), fieldAlias(&f, &f),     unionField(&u),                      packedField(&pk),
        afterBump(&x),      inBranch(&x, &x, true), loopCarried(&x),                     afterMemset(&bytes),
        escapedLocal(),     throughAlias(1),        wholeStore(1, .{ .a = 20, .b = 0 }), storeThenUse(&x, 3, 4),
    }) catch unreachable;
    std.Io.File.stdout().writeStreamingAll(std.Options.debug_io, w.buffered()) catch {};
}
