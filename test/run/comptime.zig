const rt = @import("rt.zig");

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

fn fib(n: u32) u32 {
    if (n < 2) return n;
    return fib(n - 1) + fib(n - 2);
}

fn max(comptime T: type, a: T, b: T) T {
    return if (a > b) a else b;
}

fn Pair(comptime T: type) type {
    return struct {
        a: T,
        b: T,

        const Self = @This();

        fn sum(self: Self) T {
            return self.a + self.b;
        }
    };
}

fn table(comptime n: usize) [n]u32 {
    var t: [n]u32 = undefined;
    for (&t, 0..) |*x, i| x.* = @intCast(i * i);
    return t;
}

const fib10 = fib(10);
const squares = table(6);
const answer: u8 = blk: {
    var x: u8 = 0;
    var i: u8 = 0;
    while (i < 7) : (i += 1) x += 6;
    break :blk x;
};

fn isPow2(comptime x: comptime_int) bool {
    return x != 0 and (x & (x - 1)) == 0;
}

fn main() callconv(.c) noreturn {
    rt.printInt(fib10);
    rt.printInt(comptime fib(12));
    rt.printInt(squares[5]);
    rt.printInt(answer);
    rt.printInt(max(u8, 3, 9));
    rt.printInt(max(u64, 1 << 40, 5));
    var v: i16 = -3;
    _ = &v;
    rt.printInt(@intCast(max(i16, v, 2)));
    const P = Pair(u16);
    const p: P = .{ .a = 300, .b = 400 };
    rt.printInt(p.sum());
    rt.printInt(@sizeOf(P) + @sizeOf(Pair(u64)));
    var s: u32 = 0;
    inline for (.{ 1, 2, 3 }) |k| s += k;
    rt.printInt(s);
    comptime var c = 1;
    c *= 5;
    rt.printInt(c);
    const t = .{ @as(u8, 4), true };
    rt.printInt(if (t[1]) t[0] else 0);
    if (comptime isPow2(64)) rt.print("pow2\n");
    rt.exit(@intCast(@bitSizeOf(u7)));
}
