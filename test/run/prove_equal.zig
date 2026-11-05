//! signal: ABRT
//! stderr: "panic: index out of bounds: index 3, len 3\n"
//! Proving checks (docs/slop/architecture.md, "Proving checks"): a compare
//! is decided with an operand replaced by a value the facts make equal to
//! it. After `assert(a.len == n)` and `assert(b.len == a.len)`, `a[j]` and
//! `b[j]` in a loop to `n` are proven, `b` through two equalities, as in
//! std.crypto.ff's `montgomeryLoop`. Facts name values: once a store
//! changes `v.len`, the length loaded after it is another value, which
//! `v.len == n` does not name, so the last loop's check stays and fails.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

fn assert(ok: bool) void {
    if (!ok) unreachable;
}

const V = struct { buf: [8]u64, len: usize };

noinline fn sum(a: *V, b: *const V, n: usize) u64 {
    assert(a.len == n);
    assert(b.len == a.len);
    const as = a.buf[0..a.len];
    const bs = b.buf[0..b.len];
    var t: u64 = 0;
    for (1..n) |j| {
        as[j - 1] +%= bs[j];
        t +%= as[j];
    }
    return t;
}

noinline fn shrunk(v: *V, n: usize) u64 {
    assert(v.len == n);
    v.len = n - 1;
    const s = v.buf[0..v.len];
    var t: u64 = 0;
    for (0..n) |j| t +%= s[j];
    return t;
}

var ga: V = .{ .buf = .{ 1, 2, 3, 4, 5, 6, 7, 8 }, .len = 4 };
var gb: V = .{ .buf = .{ 10, 20, 30, 40, 50, 60, 70, 80 }, .len = 4 };

fn main() callconv(.c) noreturn {
    if (sum(&ga, &gb, 4) != 2 + 3 + 4) rt.exit(1);
    if (ga.buf[0] != 21 or ga.buf[2] != 43) rt.exit(2);
    rt.exit(@truncate(shrunk(&ga, 4)));
}
