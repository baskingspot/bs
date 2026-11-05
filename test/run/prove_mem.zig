//! signal: ABRT
//! stderr: "panic: index out of bounds: index 7, len 4\n"
//! Proving checks (docs/slop/architecture.md, "Proving checks"): two loads
//! of `p.i` read one value only if nothing wrote memory between them.
//! `q` points at `p.i`, so `a[p.i]` after `q.* = 7` keeps its check.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

const S = struct { i: usize };
var s: S = .{ .i = 1 };
var q: *usize = &s.i;

fn get(p: *S, a: []const u8) u8 {
    if (p.i < a.len) {
        q.* = 7;
        return a[p.i];
    }
    return 0;
}

fn main() callconv(.c) noreturn {
    const a: [4]u8 = .{ 1, 2, 3, 4 };
    rt.exit(get(&s, &a));
}
