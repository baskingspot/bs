//! signal: ABRT
//! stderr: "panic: index out of bounds: index 4, len 4\n"
//! Proving checks (docs/slop/architecture.md, "Proving checks"): a store
//! later in a loop reaches its start, so `p.i` loaded there is not the
//! `p.i` compared before the loop, and `a[p.i]` keeps its check: the
//! second iteration (`p.i` 4) fails it.
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

fn sum(p: *S, a: []const u8) u8 {
    var t: u8 = 0;
    if (p.i < a.len) while (true) {
        t +%= a[p.i];
        p.i += 3;
        if (t > 100) break;
    };
    return t;
}

fn main() callconv(.c) noreturn {
    const a: [4]u8 = .{ 1, 2, 3, 4 };
    rt.exit(sum(&s, &a));
}
