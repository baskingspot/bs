//! exit: 0
//! stdout: "2931\n10\n7\n3\n4\n4\n2\n4\n18446744073709551611\n5\n1\n2\n104\n255\n"
//! Scalar replacement (docs/architecture.md, "Rewrite rules") splits the
//! local structs below into one local per field. The values are chosen
//! where a plausible wrong split differs: a copy that shares its fields'
//! locals with the original, a store of a struct to memory it was loaded
//! from, a struct carried around a loop, and fields of mixed sizes.
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

const P = struct { a: i64, b: i64 };
const T = struct { u8, u64, i32 };
const E = enum(u8) { x, y, z };
const M = struct { c: u8, ok: bool, e: E, n: i32, s: []const u8, p: *const u64 };

fn swap(p: P) P {
    return .{ .a = p.b, .b = p.a };
}

fn addp(x: P, y: P) P {
    var r: P = undefined;
    r.a = x.a + y.a;
    r.b = x.b - y.b;
    return r;
}

noinline fn loop(n: u32) i64 {
    var acc: P = .{ .a = 0, .b = 1 };
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        acc = addp(swap(acc), .{ .a = i, .b = 2 });
        if (acc.a > 1000) acc = .{ .a = acc.b, .b = 3 };
    }
    return acc.a * 7 + acc.b;
}

/// `u` is a copy: writing `t` after it must not change it.
noinline fn copy(n: u64) u64 {
    var t: T = .{ 1, n, -2 };
    t[1] += 3;
    const u = t;
    t[0] = 9;
    t[2] = 5;
    return u[1] + u[0] + @as(u64, @intCast(u[2] + 4)) + t[0] - t[0];
}

/// The swapped fields are read before either is written back.
noinline fn swapInPlace(p: *P) void {
    p.* = swap(p.*);
}

noinline fn pick(c: bool, a: P, b: P) P {
    var q = if (c) a else b;
    q.a += 1;
    return q;
}

noinline fn mixed(i: u8, s: []const u8, p: *const u64) M {
    var m: M = undefined;
    m.c = i +% 250;
    m.ok = i > 3;
    m.e = @enumFromInt(i % 3);
    m.n = -@as(i32, i);
    m.s = s[0 .. i % 4];
    m.p = p;
    return m;
}

pub fn main() void {
    out(@bitCast(loop(100)));
    out(copy(4));
    var p: P = .{ .a = 3, .b = 7 };
    swapInPlace(&p);
    out(@bitCast(p.a));
    out(@bitCast(p.b));
    const q = pick(true, .{ .a = 3, .b = 4 }, .{ .a = 5, .b = 6 });
    out(@bitCast(q.a));
    out(@bitCast(q.b));
    const r = pick(false, .{ .a = 1, .b = 2 }, .{ .a = 3, .b = 4 });
    out(@bitCast(r.a - 2));
    out(@bitCast(r.b));
    const v: u64 = 5;
    const m = mixed(5, "hello", &v);
    out(@bitCast(@as(i64, m.n)));
    out(m.p.*);
    out(@intFromBool(m.ok));
    out(@intFromEnum(m.e));
    out(m.s[0]);
    out(m.c);
    rt.exit(0);
}
