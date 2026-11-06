//! signal: ABRT
//! stderr: "panic: attempt to use null value\n"
//! Proving checks (docs/slop/architecture.md, "Proving checks"): an
//! integer block exited with a constant on one path keeps what held at
//! its other exits, for a later fact that excludes the constant. Past
//! `cap() - 1`'s overflow check, or `c != 0`, `cap` did not return 0, so
//! `s.meta` is not null and `s.meta.?` is proven. `c != 5` excludes
//! neither exit, so `second`'s `s.meta.?` keeps its check, which fails.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

const S = struct {
    meta: ?*const u32,

    fn cap(s: S) u32 {
        if (s.meta == null) return 0;
        return s.meta.?.*;
    }
};

noinline fn first(s: S) u32 {
    const c = s.cap();
    if (c == 0) return 7;
    return c + s.meta.?.*;
}

noinline fn mask(s: S) u32 {
    const m = s.cap() - 1;
    return m + s.meta.?.*;
}

noinline fn second(s: S) u32 {
    const c = s.cap();
    if (c == 5) return 7;
    return s.meta.?.*;
}

const one: u32 = 1;

fn main() callconv(.c) noreturn {
    if (first(.{ .meta = &one }) != 2) rt.exit(1);
    if (first(.{ .meta = null }) != 7) rt.exit(2);
    if (mask(.{ .meta = &one }) != 1) rt.exit(3);
    rt.exit(@truncate(second(.{ .meta = null })));
}
