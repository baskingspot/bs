//! signal: ABRT
//! stderr: "panic: index out of bounds: index 2, len 2\n"
//! Proving checks (docs/slop/architecture.md, "Proving checks"): a field
//! of a field of a `*const` alloc, also read through a `*const` method's
//! `self` (`limbsConst`), is the same value at each load, so `sum`'s
//! slices of `x` and `y` need no check in its loops. A by-value parameter
//! of an inlined function is a copy made at the call, so after the caller
//! writes its variable, `at` reads the new length, and its check fails.
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

    fn limbsConst(self: *const Uint) []const u64 {
        return self.buf[0..self.len];
    }
};

const Fe = struct {
    v: Uint,

    fn count(self: Fe) usize {
        return self.v.len;
    }

    fn at(self: Fe, i: usize) u64 {
        return self.v.limbsConst()[i];
    }
};

noinline fn sum(x: Fe, y: Fe, d: *Fe) u64 {
    if (x.count() != y.count()) return 0;
    const a = x.v.limbsConst();
    const b = y.v.limbsConst();
    var t: u64 = 0;
    for (0..x.count()) |i| {
        for (0..y.count()) |j| {
            d.v.buf[j & 7] = a[i] +% b[j];
            t +%= a[i] *% b[j];
        }
    }
    return t;
}

var gx: Fe = .{ .v = .{ .buf = .{ 1, 2, 3, 4, 5, 6, 7, 8 }, .len = 3 } };

fn main() callconv(.c) noreturn {
    var d: Fe = gx;
    // (1 + 2 + 3)² = 36.
    if (sum(gx, gx, &d) != 36) rt.exit(1);
    var x = gx;
    if (x.at(2) != 3) rt.exit(2);
    x.v.len = 2;
    rt.exit(@truncate(x.at(2)));
}
