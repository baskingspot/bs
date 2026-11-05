//! signal: ABRT
//! stderr: "panic: index out of bounds: index 2, len 2\n"
//! Proving checks (docs/slop/architecture.md, "Proving checks"): a
//! pointer cast only to `*const` is the same pointer, so `d.count()`,
//! which reads `d.*` through a `*const Fe`, and `d.v.limbs()`, through a
//! `*Uint`, load the same length, and after `d.count() == n` a loop to
//! `n` indexes `d.v.limbs()` without checks. A store through `d` in
//! between still makes the next load another value: `shrink`'s check
//! stays and fails.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

const Uint = struct {
    buf: [8]u64,
    len: usize,

    fn limbs(self: *Uint) []u64 {
        return self.buf[0..self.len];
    }
};

const Fe = struct {
    v: Uint,

    fn count(self: Fe) usize {
        return self.v.len;
    }
};

noinline fn fill(d: *Fe, n: usize) u64 {
    if (d.count() != n) return 0;
    const s = d.v.limbs();
    var t: u64 = 0;
    for (0..n) |i| {
        s[i] = i;
        t +%= s[0];
    }
    return t;
}

noinline fn shrink(d: *Fe, i: usize) u64 {
    if (i >= d.count()) return 0;
    d.v.len = 2;
    return d.v.limbs()[i];
}

var gd: Fe = .{ .v = .{ .buf = .{ 1, 2, 3, 4, 5, 6, 7, 8 }, .len = 3 } };

fn main() callconv(.c) noreturn {
    if (fill(&gd, 3) != 0) rt.exit(1);
    rt.exit(@truncate(shrink(&gd, 2)));
}
