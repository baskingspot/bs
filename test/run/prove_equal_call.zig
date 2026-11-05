//! signal: ABRT
//! stderr: "panic: index out of bounds: index 2, len 2\n"
//! Proving checks (docs/slop/architecture.md, "Proving checks"): equal
//! values replace each other in a compare (`prove_equal.zig`), but only
//! values, not places. A call between `assert(v.len == n)` and the slice
//! may change `v.len`, so the length loaded after it is another value and
//! `s[j]` in a loop to `n` keeps its check, which fails. The lengths
//! compared on one side of an `if` are equal only there.
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

var g: *V = undefined;

noinline fn shrink() void {
    g.len -= 1;
}

noinline fn branch(v: *const V, n: usize, x: usize) u64 {
    var t: u64 = 0;
    if (v.len == n) {
        for (0..n) |j| t +%= v.buf[0..v.len][j];
    }
    // Not `v.len == n` here: the check of `j < v.len` stays and holds.
    for (0..@min(n, x)) |j| t +%= v.buf[0..v.len][j];
    return t;
}

noinline fn called(v: *V, n: usize) u64 {
    assert(v.len == n);
    shrink();
    const s = v.buf[0..v.len];
    var t: u64 = 0;
    for (0..n) |j| t +%= s[j];
    return t;
}

var gv: V = .{ .buf = .{ 1, 2, 3, 4, 5, 6, 7, 8 }, .len = 3 };

fn main() callconv(.c) noreturn {
    g = &gv;
    if (branch(&gv, 3, 3) != 12) rt.exit(1);
    if (branch(&gv, 5, 2) != 3) rt.exit(2);
    rt.exit(@truncate(called(&gv, 3)));
}
