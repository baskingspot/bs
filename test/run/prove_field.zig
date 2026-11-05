//! signal: ABRT
//! stderr: "panic: attempt to use null value\n"
//! Proving checks (docs/slop/architecture.md, "Proving checks"): a field of
//! a `*const` alloc, such as a by-value parameter's, is the same value at
//! each load, so `cap`'s `s.y.?` after `s.y == null` returned is proven.
//! `s.x.b` is a field of a field, not `s.y`, whatever is known of `s.y`:
//! its check stays and fails.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

const Inner = struct { a: ?*const u32, b: ?*const u32 };

const S = struct {
    x: Inner,
    y: ?*const u32,

    fn cap(s: S) u32 {
        if (s.y == null) return 0;
        return s.y.?.*;
    }
};

noinline fn f(s: S) u32 {
    const c = s.cap();
    if (s.y == null) return c;
    return c + s.x.b.?.*;
}

var g: ?*const u32 = null;
const one: u32 = 1;

fn main() callconv(.c) noreturn {
    rt.exit(@truncate(f(.{ .x = .{ .a = g, .b = g }, .y = &one })));
}
