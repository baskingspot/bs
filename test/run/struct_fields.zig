//! exit: 0
//! stdout: "4\n16\n5\n8\n8\n14\n1\n1\n1\n1\n1\n1\n1\n1\n1\n1\n1\n462\n"
//! Comptime struct fields (stores into parts of them check the value),
//! comparing a function with a pointer to it, the alignment of field
//! pointers and aligned comptime variables, methods of enum tags named
//! through their type, and pointers to zero-bit declarations.
const rt = @import("rt.zig");

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

fn main() callconv(.c) noreturn {
    comptimeFields();
    comptimeFieldParts();
    if (Sym.line.width() != 2) unreachable;
    if (voidPtr() != voidPtr()) unreachable;
    fnPtrCompare();
    fieldAlignment();
    rt.exit(0);
}
const S = struct {
    a: u8,
    comptime b: u32 = 5,
    c: u16 = 9,
    comptime T: type = u64,
};
fn get(s: S) u32 {
    return s.b + s.a + s.c;
}
var gs: S = .{ .a = 3 };
fn comptimeFields() void {
    var s: S = .{ .a = 1, .b = 5 };
    s.a += 1;
    const p = &s.b;
    rt.printInt(@sizeOf(S));
    rt.printInt(get(s));
    rt.printInt(p.*);
    rt.printInt(@sizeOf(s.T));
    rt.printInt(gs.a + gs.b);
    comptime {
        if (s.b != 5) unreachable;
    }
    const arr = [_]S{ .{ .a = 7 }, .{ .a = 8, .c = 1 } };
    var i: usize = 1;
    i -= 0;
    rt.printInt(arr[i].a + arr[i].c + arr[i].b);
}
const A = struct {
    ptr: *const fn () A,
    fn f() A {
        return .{ .ptr = f };
    }
    fn g() A {
        return .{ .ptr = g };
    }
};
fn fnPtrCompare() void {
    var a = A.f();
    _ = &a;
    rt.printInt(@intFromBool(a.ptr == A.f));
    rt.printInt(@intFromBool(A.g != a.ptr));
}
fn doTheTest() void {
    var a: struct { x: u32 } = .{ .x = 123 };
    var b: struct { x: u32 } align(1) = .{ .x = 456 };
    var c: struct { x: u32 } align(64) = .{ .x = 789 };
    var d: extern struct { x: u32, y: u16, z: u8 } align(1) = .{ .x = 3, .y = 4, .z = 5 };
    var e: extern struct { x: u32, y: u16, z: u8 } = .{ .x = 3, .y = 4, .z = 5 };
    var f: struct { x: u8, y: u32 align(16) } = .{ .x = 1, .y = 2 };
    var g: extern union { x: u8, y: u32 } = .{ .y = 1 };
    rt.printInt(@intFromBool(@TypeOf(&a.x) == *u32));
    rt.printInt(@intFromBool(@TypeOf(&b.x) == *align(1) u32));
    rt.printInt(@intFromBool(@TypeOf(&c.x) == *u32));
    rt.printInt(@intFromBool(@TypeOf(&d.y) == *align(1) u16));
    rt.printInt(@intFromBool(@TypeOf(&e.y) == *align(4) u16));
    rt.printInt(@intFromBool(@TypeOf(&e.z) == *align(2) u8));
    rt.printInt(@intFromBool(@TypeOf(&e.x) == *u32));
    rt.printInt(@intFromBool(@TypeOf(&f.y) == *align(16) u32));
    rt.printInt(@intFromBool(@TypeOf(&g.x) == *align(4) u8));
    rt.printInt(b.x + d.y + f.y);
}
fn fieldAlignment() void {
    doTheTest();
    comptime doTheTest2();
}
fn doTheTest2() void {
    var b: struct { x: u32 } align(1) = .{ .x = 456 };
    var v align(8) = @as(u8, 1);
    if (@TypeOf(&b.x) != *align(1) u32) unreachable;
    if (@TypeOf(&v) != *align(8) u8) unreachable;
    b.x += v;
}

fn comptimeFieldParts() void {
    const Arr = struct { comptime a: [2]u32 = .{ 1, 2 } };
    var s: Arr = .{};
    s.a[0] = 1;
    const Pair = struct { a: u32, b: u32 };
    const Holder = struct { comptime t: Pair = .{ .a = 1, .b = 2 } };
    var u: Holder = .{};
    u.t.b = 2;
}

const Sym = enum {
    tee,
    line,
    fn width(s: Sym) u32 {
        return @as(u32, @intFromEnum(s)) + 1;
    }
};

const nothing = {};
fn voidPtr() *const void {
    return &nothing;
}
