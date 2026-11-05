//! exit: 0
//! stdout: "f16\nf64\n97\n1\n1\n1\n1\n1\n0\n1\n1\n1\n1\n1\n1\n1\n1\n1\n1\n1\n1\n1\n1\n1\n1\n1\n1\n1\n1\n1\n1\n1\n1\n1\nerror{Foo}!?[*:0]const u8\nerror{Foo}!?[*:0]const u8\n?[*:0]const u8\n[*c]c_int\n[*c]c_int\n[*c]const u8\n[*c]const u8\n[3]*const u8\n[*:0]align(2) const volatile u8\n[3]i32\n[]const u8\n[]const u8\nstruct { u32, i16 }\n*align(4) u32\n?*align(4) u32\n*align(1) anyopaque\n232\n232\n12502050\n1\n1\n1\n1\n1\n2\n"
const rt = @import("rt.zig");
pub const panic = rt.panic;
pub export fn _start() callconv(.naked) noreturn { asm volatile ("call %[main:P]" : : [main] "X" (&main)); }
fn ok(b: bool) void { rt.printInt(@intFromBool(b)); }
fn pt(comptime T: type) void {
    rt.print(@typeName(T));
    rt.print("\n");
}

// c2.zig
fn retu() u32 { return 7; }
fn casts() void {
    // 382
    const r1 = @as(f16, @floatCast(1234));
    ok(r1 == 1234);
    const r2 = @as(f32, @floatCast(1234.5));
    ok(r2 == 1234.5);
    // 1411
    const a = @as(comptime_float, @floatFromInt(1));
    ok(a == 1 and @TypeOf(a) == comptime_float);
    const b = @as(comptime_int, @intFromFloat(2));
    ok(b == 2 and @TypeOf(b) == comptime_int);
    // 1840
    var f1: f80 = 12.34;
    const f2: *c_longdouble = &f1;
    f2.* += 1;
    ok(f1 == @as(f80, 12.34) + 1);
    ok(c_longdouble == f80);
    // 1870
    const T = fn () u32;
    const fa: T = retu;
    const fb: *const T = &retu;
    ok(@TypeOf(fa, fb) == *const fn () u32);
    ok(@TypeOf(fb, fa) == *const fn () u32);
    // 757
    const window_name = [1][*]const u8{"window name"};
    const x: [*]const ?[*]const u8 = &window_name;
    ok(x[0].?[1] == 'i');
    // 1915
    const na: ?[]const u32 = null;
    const nb: [*]allowzero const u8 = @ptrCast(na);
    ok(@intFromPtr(nb) == 0);
    var arr = [_]u32{ 1, 2 };
    var ns: ?[]const u32 = &arr;
    _ = &ns;
    const nc: [*]allowzero const u8 = @ptrCast(ns);
    ok(@intFromPtr(nc) == @intFromPtr(&arr));
    // 2197
    var v: u8 = 3;
    const ea: error{Foo}!*u8 = &v;
    const eb: error{Foo}!?*u8 = null;
    var t = true;
    _ = &t;
    const e1 = if (t) ea else eb;
    const e2 = if (t) eb else ea;
    ok(@TypeOf(e1) == error{Foo}!?*u8);
    ok((e1 catch unreachable).?.* == 3);
    ok((e2 catch unreachable) == null);
    // 580
    comptime castIntToErr(error.ItBroke) catch unreachable;
    castIntToErr(error.ItBroke) catch unreachable;
}
fn castIntToErr(err: anyerror) !void {
    const x = @intFromError(err);
    const y = @errorFromInt(x);
    if (error.ItBroke != y) return error.Bad;
}

// c3.zig
fn peerAttrs() void {
    var buf_a align(4) = "foo".*;
    var buf_b align(4) = "bar".*;
    var buf_c align(4) = "baz".*;
    var buf_d align(4) = "qux".*;
    const a: [*:0]align(4) const u8 = &buf_a;
    const b: *align(2) volatile [3:0]u8 = &buf_b;
    const c: [*:0]align(4) u8 = &buf_c;
    const d: [*:0]allowzero align(4) u8 = &buf_d;
    const T = [*:0]allowzero align(2) const volatile u8;
    ok(@TypeOf(a, b) == [*:0]align(2) const volatile u8);
    ok(@TypeOf(a, d) == [*:0]allowzero align(4) const u8);
    ok(@TypeOf(a, b, c, d) == T);
    ok(@TypeOf(a, b, d, c) == T);
    ok(@TypeOf(a, c, b, d) == T);
    ok(@TypeOf(a, c, d, b) == T);
    ok(@TypeOf(a, d, b, c) == T);
    ok(@TypeOf(a, d, c, b) == T);
    ok(@TypeOf(b, c, d, a) == T);
    var s: [:0]const u8 = "Hello";
    var e = &.{};
    var x = &.{ @as(u8, 'x'), @as(u8, 'y'), @as(u8, 'z') };
    var os: ?[:0]const u8 = null;
    _ = .{ &s, &e, &x, &os };
    ok(@TypeOf(s, e) == []const u8);
    ok(@TypeOf(x, s) == []const u8);
    ok(@TypeOf(x, os) == ?[]const u8);
    var t = true;
    _ = &t;
    const r1 = if (t) e else s;
    const r2 = if (t) x else s;
    const r3 = if (t) x else os;
    ok(r1.len == 0);
    ok(r2.len == 3 and r2[2] == 'z');
    ok(r3.?[1] == 'y');
    var p: ?*u32 = undefined;
    var q: ?*allowzero u32 = undefined;
    p = @as(*u32, @ptrFromInt(4));
    q = p;
    ok(@intFromPtr(q.?) == 4);
    foo(null);
}
fn foo(pixels: ?[]const u32) void {
    const data: [*]allowzero const u8 = @ptrCast(pixels);
    ok(@intFromPtr(data) == 0);
}

// pt.zig
fn peerTypes() void {
    const E = error{Foo};
    var a: E = error.Foo;
    var b: *const [5:0]u8 = @ptrFromInt(0x1000);
    var c: ?[*:0]u8 = null;
    var cp: [*c]c_int = 0x1000;
    var cu: [*c]u8 = null;
    var k: *const u8 = @ptrFromInt(0x1000);
    var ar: [3]i32 = .{ 1, 2, 3 };
    var pa: [3]*u8 = undefined;
    var pc: [3]*const u8 = undefined;
    var s: [:0]const u8 = "abc";
    var m: [*:0]align(4) const u8 = @ptrFromInt(0x1000);
    var v: *align(2) volatile [3:0]u8 = @ptrFromInt(0x1000);
    var pu: *u32 = @ptrFromInt(0x1000);
    var p8: *align(8) u32 = @ptrFromInt(0x1000);
    var op: ?*u32 = null;
    var op8: ?*align(8) u32 = null;
    var ao: *anyopaque = @ptrFromInt(0x1000);
    var ao8: *align(8) anyopaque = @ptrFromInt(0x1000);
    _ = .{ &a, &b, &c, &cp, &cu, &k, &ar, &pa, &pc, &s, &m, &v, &pu, &p8, &op, &op8, &ao, &ao8 };
    pt(@TypeOf(a, b, c));
    pt(@TypeOf(c, b, a));
    pt(@TypeOf(b, c));
    pt(@TypeOf(cp, null));
    pt(@TypeOf(null, cp));
    pt(@TypeOf(cu, k));
    pt(@TypeOf(k, cu));
    pt(@TypeOf(pa, pc));
    pt(@TypeOf(m, v));
    pt(@TypeOf(ar, .{ 4, 5, 6 }));
    pt(@TypeOf(s, &.{ @as(u8, 'x'), @as(u8, 'y') }));
    pt(@TypeOf(s, &.{}));
    pt(@TypeOf(.{ 1, 2 }, .{ @as(u32, 3), @as(i16, 4) }));
    // The merged alignment is explicit if either peer's is.
    pt(@TypeOf(pu, p8));
    pt(@TypeOf(op, op8));
    pt(@TypeOf(ao, ao8));
}

// ps.zig
fn elem() u64 {
    var cases: [2][2]i32 = [_][2]i32{ [_]i32{ 0, 1 }, [_]i32{ 2, 3 } };
    const elem_ptr = &cases[0];
    const many = @as([*][2]i32, @ptrCast(elem_ptr));
    const many_elem = @as(*[2]i32, @ptrCast(&many[1]));
    const items: []i32 = many_elem;
    return items.len * 100 + @as(u64, @intCast(items[1])) * 10 + @as(u64, @intCast(items[0]));
}
fn sub() u64 {
    var r: u64 = 0;
    {
        const a: *u8 = @ptrFromInt(100);
        const b: *u8 = @ptrFromInt(50);
        r += a - b;
    }
    {
        var ptr: [*]const u8 = "abc";
        _ = &ptr;
        r += (&ptr[2] - &ptr[0]) * 1000;
    }
    {
        const a: *[100]u16 = @ptrFromInt(100);
        const b: *[100]u16 = @ptrFromInt(50);
        r += (a - b) * 100000;
    }
    {
        var x: struct { a: u32, b: u32 } = undefined;
        const a = &x.a;
        const b = &x.b;
        r += (b - a) * 10000000;
    }
    return r;
}
fn ptrArith() void {
    rt.printInt(elem());
    rt.printInt(comptime elem());
    rt.printInt(sub());
    comptime {
        var x: extern struct { a: u32, b: u32 } = undefined;
        const a = &x.a;
        const b = &x.b;
        if (b - a != 1) unreachable;
        var y: packed struct { a: u1, b: u1 } = undefined;
        if (&y.b - &y.a != 0) unreachable;
    }
    var p: [*]align(8) [3]u8 = undefined;
    var xx: usize = 1;
    _ = .{ &p, &xx };
    rt.printInt(@intFromBool(@TypeOf(p + 17) == [*]align(1) [3]u8));
    rt.printInt(@intFromBool(@TypeOf(p + 8) == [*]align(8) [3]u8));
    rt.printInt(@intFromBool(@TypeOf(p + 4) == [*]align(4) [3]u8));
    rt.printInt(@intFromBool(@TypeOf(p + xx) == [*]align(1) [3]u8));
}

// eu.zig
const EU = enum(u1) { foo, bar };
const U = union(EU) { foo, bar };
const E2 = enum { a, b, c };
const U2 = union(E2) { a, b: void, c: u0 };
fn enumToUnion() void {
    var runtime: EU = undefined;
    runtime = .bar;
    var result: U = undefined;
    result = runtime;
    rt.printInt(@intFromBool(result == .bar));
    var r2: E2 = .c;
    _ = &r2;
    const uu: U2 = r2;
    rt.printInt(@intFromEnum(@as(E2, uu)));
}

fn cfn(q: [*c]const u8) callconv(.c) u8 {
    return if (q == null) 0 else q[0];
}
fn fnCoerce() void {
    const g: ?*const fn (?[*:0]const u8) callconv(.c) u8 = &cfn;
    rt.printInt(g.?("a"));
}
// Numbers next to a fixed-width float peer as that float in any order,
// as upstream: a comptime_float before an integer does not fail.
var peer_bit: i1 = -1;
fn floatPeers() void {
    pt(@TypeOf(@as(comptime_float, 0.5), peer_bit, @as(f16, 3)));
    pt(@TypeOf(@as(i1, -1), 0.5, @as(u8, 200), @as(f32, 3), @as(f64, 1)));
}

fn main() callconv(.c) noreturn {
    floatPeers();
    fnCoerce();
    casts();
    peerAttrs();
    peerTypes();
    ptrArith();
    enumToUnion();
    rt.exit(0);
}
