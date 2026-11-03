//! exit: 0
//! stdout: "42\n7\n18446744073709551615\n3\n2\n4294967294\n3\n-3 -> 3\n200\n5\n18446744073709551613\n7\n1\n0\n1\n"
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

fn neg(x: i32) i32 {
    return -x;
}

fn abs(x: i64) u64 {
    return if (x < 0) @intCast(-x) else @intCast(x);
}

fn main() callconv(.c) noreturn {
    var a: u32 = 6;
    var b: u32 = 7;
    _ = &a;
    _ = &b;
    rt.printInt(a * b);
    rt.printInt(@divTrunc(a * b - 7, 5));
    var z: u64 = 0;
    _ = &z;
    rt.printInt(z -% 1);
    const m: i32 = -7;
    rt.printInt(@intCast(@mod(m, 5)));
    rt.printInt(@intCast(-@rem(m, 5)));
    var w: u32 = 0xffff_ffff;
    w +%= 0xffff_ffff;
    rt.printInt(w);
    var s: u8 = 0b1000_0001;
    s = (s << 1) | (s >> 7);
    rt.printInt(s & 0x0f);
    rt.print("-3 -> ");
    rt.printInt(abs(neg(3)));
    var c: u8 = 100;
    c = c * 2;
    rt.printInt(c);
    const big: u64 = 1 << 40;
    rt.printInt(big >> 38 | @as(u64, @intFromBool(a < b)));
    // Comptime-known signed `/` truncates; `%` is allowed when it is zero.
    const sn: i32 = -7;
    const sd: i32 = 2;
    rt.printInt(@bitCast(@as(i64, sn / sd)));
    rt.printInt(@as(u32, @bitCast(@as(i32, -8 % 4))) + @as(u32, 7 / -2 + 10));
    // A comptime_int zero from a negative operand is the zero switch item.
    rt.printInt(switch (@mod(-2, 2)) {
        0 => 1,
        else => 2,
    });
    // `u0` shifts by zero.
    var z0: u0 = 0;
    _ = &z0;
    rt.printInt(@as(u8, z0 << 0) + @shlWithOverflow(z0, 0)[1]);
    // `undefined == x` is an undefined bool.
    var ub = undefined == 1;
    ub = true;
    rt.printInt(@intFromBool(ub));
    rt.exit(if (a ^ b == 1 and !(a > b) and (a != b or false)) 0 else 1);
}
