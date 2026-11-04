//! signal: ABRT
//! stderr: "panic: index out of bounds: index 100, len 4\n"
//! Proving checks (docs/architecture.md, "Proving checks"): code after a
//! block sees only the stores before the `br` that left it. `blk` is left
//! only by `break :blk`, before `v = 3`, so `a[v]` keeps its check.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

var g: usize = 100;
var flag = true;

fn main() callconv(.c) noreturn {
    const a: [4]u8 = .{ 1, 2, 3, 4 };
    var v: usize = 0;
    outer: {
        blk: {
            v = g;
            if (flag) break :blk;
            v = 3;
            break :outer;
        }
        rt.exit(a[v]);
    }
    rt.exit(0);
}
