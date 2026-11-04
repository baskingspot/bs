//! exit: 0
//! stdout: "41\n4003\n"
//! Arguments that trade registers at a call: a by-reference parameter's
//! address passed where another argument arrived, while that argument
//! goes where the parameter's pointer is. Each case prints what
//! upstream's ReleaseSafe build prints.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

const E = struct { a: u64, b: u64, c: u64, n: u64 };

noinline fn addN(self: *const E, w: *u64) void {
    w.* += self.n;
}

/// `value` arrives in rsi and `w` in rdi; the call wants `&value` in rdi
/// and `w` in rsi.
noinline fn swapped(w: *u64, value: E) void {
    const local = value;
    addN(&local, w);
}

noinline fn pair(lo: u64, hi: u64) u64 {
    return lo *% 1000 +% hi;
}

/// Two register arguments that trade places.
noinline fn trade(a: u64, b: u64) u64 {
    return pair(b, a);
}

fn main() callconv(.c) noreturn {
    var w: u64 = 1;
    var e: E = .{ .a = 1, .b = 2, .c = 3, .n = 40 };
    _ = &e;
    swapped(&w, e);
    rt.printInt(w);
    rt.printInt(trade(3, 4));
    rt.exit(0);
}
