//! exit: 0
//! stdout: "3876\n386\n4271\n120\n35\n30\n945\n4208\n30\n"
//! More values cross calls than registers survive them: some live in
//! registers that do not, stored before each call and reloaded after it.
//! Arguments whose last use is the call they are passed to may sit in the
//! registers that pass them, in any order, so the moves into those
//! registers may form cycles. The values are chosen so that an argument
//! read after another one overwrote its register, or a value not
//! reloaded after a call that clobbered it, changes the output.
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

var calls: u64 = 0;

/// Writes every register a call may clobber with values of its own.
noinline fn clobber(x: u64) u64 {
    calls += 1;
    var acc: u64 = x;
    for (0..4) |i| acc = acc *% 31 +% i;
    return acc & 0xff;
}

/// Ten values live across the calls in the loop, more than the five
/// registers that survive calls.
noinline fn many(n: u64) u64 {
    const a = n + 1;
    const b = n * 3;
    const c = n ^ 0x55;
    const d = n + 7;
    const e = n * 5 + 1;
    const f = n | 0x100;
    const g = n -% 2;
    const h = n << 2;
    var i: u64 = 0;
    var sum: u64 = 0;
    while (i < 4) : (i += 1) {
        sum +%= clobber(i) & 1;
        sum +%= a + b + c + d + e + f + g + h + i;
    }
    return sum;
}

noinline fn sub3(x: u64, y: u64, z: u64) u64 {
    return x * 100 + y * 10 - z;
}

/// The arguments arrive in rdi, rsi, and rdx and are passed on rotated:
/// the moves form a cycle.
noinline fn rotate(x: u64, y: u64, z: u64) u64 {
    return sub3(y, z, x);
}

noinline fn swapped(x: u64, y: u64) u64 {
    return sub3(y, x, 0);
}

/// The same value passed twice, and one passed in another argument's
/// register.
noinline fn twice(x: u64, y: u64) u64 {
    return sub3(y +% 1, x, x);
}

noinline fn crossesTwo(x: u64) u64 {
    const k = x * 7;
    _ = clobber(k);
    _ = clobber(k + 1);
    return k;
}

noinline fn floats(x: f64) u64 {
    const a = x * 2.5;
    const b = x + 0.25;
    _ = clobber(3);
    return @intFromFloat(a + b);
}

const Big = struct { a: [24]u64 };

/// Pointers that live across calls in a loop, with more values than
/// surviving registers, read by a large copy (`rep movsb` in rsi, rdi,
/// and rcx) and by a call that passes them in registers.
noinline fn copies(dst: []Big, src: *const Big, n: u64) u64 {
    const x = n * 3;
    const y = n + 11;
    const z = n ^ 6;
    const w = n * 7 + 2;
    var acc: u64 = 0;
    for (dst, 0..) |*d, i| {
        d.* = src.*;
        d.a[i] +%= x + y;
        acc +%= clobber(d.a[i]) + z + w;
        acc +%= sub3(d.a[0], d.a[i], z);
    }
    return acc +% x +% y;
}

var bigs: [3]Big = undefined;
const big_src: Big = .{ .a = .{ 1, 2, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } };

pub fn main() void {
    out(many(37));
    out(rotate(4, 3, 9));
    out(rotate(9, 42, 8));
    out(swapped(2, 1));
    out(crossesTwo(5));
    out(floats(8.7));
    out(twice(5, 8));
    out(copies(&bigs, &big_src, 4));
    out(bigs[2].a[2]);
    rt.exit(0);
}
