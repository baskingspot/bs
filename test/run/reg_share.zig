//! exit: 0
//! stdout: "1759\n15\n3\n12028\n2031318423253052669\n3345946502662444644\n5147915565925777339\n9683907899874039036\n10\n54\n25882649289\n6641995093946453602\n12\n350\n1222241189124021026\n"
//! Values computed in the register of the variable they are stored to, or
//! of the block result they leave with, only when nothing on the way
//! reads the old value: a failing check that reads the variable, a store
//! in an arm the other arm skips, an operand of the store's own value
//! that is not its first, a copy of the old value kept past the store.
//! Also arguments kept in the registers they arrive in, narrowing casts,
//! division by constants, and identities (`x - 0`, `x / 1`).
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

var zero: u64 = 0;

noinline fn id(x: u64) u64 {
    return x ^ zero;
}

/// `x = f(x)`: the call reads its argument before writing the result.
noinline fn callInto(n: u64) u64 {
    var x: u64 = n;
    var k: u64 = 0;
    while (k < 5) : (k += 1) x = id(x) *% 3 +% k;
    return x;
}

/// The store happens in one arm only.
noinline fn armStore(a: u64, b: u64, c: bool) u64 {
    var v: u64 = a;
    const t = a *% b;
    if (c) v = t;
    return v;
}

/// The early return reads the variable's old value.
noinline fn coldReads(start: u64, step: u64, stop: u64) u64 {
    var i: u64 = start;
    var n: u64 = 0;
    while (n < 100) : (n += 1) {
        const t = i *% step +% 1;
        if (n == stop) return i;
        i = t;
    }
    return i;
}

noinline fn swaps(n: u64) u64 {
    var a: u64 = 1;
    var b: u64 = 2;
    var k: u64 = 0;
    while (k < n) : (k += 1) {
        const t = a;
        a = b;
        b = t +% a *% 7;
    }
    return a ^ b;
}

/// The variable as both operands, and as the second operand only.
noinline fn selfOps(x: u64, n: u64) u64 {
    var v: u64 = x;
    var k: u64 = 0;
    while (k < n) : (k += 1) {
        v = v +% v;
        v = (k *% 5) -% v;
        v = (v >> 3) ^ (v *% 0x9e3779b97f4a7c15);
    }
    return v;
}

noinline fn oldNew(x: u64, n: u64) u64 {
    var v: u64 = x;
    var acc: u64 = 0;
    var k: u64 = 0;
    while (k < n) : (k += 1) {
        const old = v;
        v = v *% 31 +% k;
        acc +%= old ^ v;
    }
    return acc;
}

/// A block's result computed in its register.
noinline fn blockResult(x: u64, y: u64) u64 {
    const r = blk: {
        if (x > y) break :blk id(x) -% y;
        break :blk id(y) *% 3;
    };
    return r +% id(r);
}

noinline fn narrow(x: u64) u64 {
    var a: u16 = @truncate(x);
    var b: i8 = @bitCast(@as(u8, @truncate(x >> 8)));
    var c: u32 = @truncate(x >> 16);
    var s: u64 = 0;
    var k: u8 = 0;
    while (k < 20) : (k += 1) {
        a = a *% 3 +% k;
        b = b -% @as(i8, @intCast(k));
        c = c *% 0x10001 +% a;
        s +%= @as(u64, a) +% @as(u64, @bitCast(@as(i64, b))) +% c;
        s +%= @as(u64, @as(u3, @truncate(s))) +% @as(u64, @bitCast(@as(i64, @as(i32, @bitCast(c)) >> 7)));
        s +%= @as(u64, @as(u5, @truncate(@as(u64, 0x1234))));
    }
    return s;
}

noinline fn divs(x: u64) u64 {
    var s: u64 = 0;
    var v: u64 = x;
    var k: u64 = 0;
    while (k < 30) : (k += 1) {
        const a: u16 = @truncate(v);
        const b: u32 = @truncate(v >> 13);
        s +%= @mod(a, 2047) +% (a / 7) +% @divFloor(b, 1000003) +% (b % 10) +% @divCeil(b, 77) +% (v / 1) +% (v - 0);
        v = v *% 6364136223846793005 +% 1442695040888963407;
    }
    return s;
}

noinline fn args6(a: u64, b: u64, c: u64, d: u64, e: u64, f: u64) u64 {
    return (a -% b) *% (c +% d) ^ (e -% f) ^ (b *% e);
}

noinline fn sliceArgs(s: []const u8, t: []const u8) u64 {
    var h: u64 = s.len *% 31 +% t.len;
    for (s) |c| h = h *% 131 +% c;
    for (t) |c| h = h *% 137 +% c;
    return h;
}

fn main() callconv(.c) noreturn {
    rt.printInt(callInto(7));
    rt.printInt(armStore(3, 5, true));
    rt.printInt(armStore(3, 5, false));
    rt.printInt(coldReads(5, 3, 7));
    rt.printInt(coldReads(5, 3, 1000));
    rt.printInt(swaps(50));
    rt.printInt(selfOps(12345, 40));
    rt.printInt(oldNew(99, 40));
    rt.printInt(blockResult(9, 4));
    rt.printInt(blockResult(4, 9));
    rt.printInt(narrow(0xfedcba9876543210));
    rt.printInt(divs(0x123456789));
    rt.printInt(args6(1, 2, 3, 4, 5, 6));
    rt.printInt(args6(60, 50, 40, 30, 20, 10));
    rt.printInt(sliceArgs("hello", "world!"));
    rt.exit(0);
}
