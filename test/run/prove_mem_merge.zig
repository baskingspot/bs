//! signal: ABRT
//! stderr: "panic: index out of bounds: index 11, len 4\n"
//! Proving checks (docs/slop/architecture.md, "Proving checks"): a call may
//! write memory, and where paths merge after one of them wrote it, a load
//! reads what either left. `bump` runs on one side, so `a[p.i]` after
//! the branch keeps its check.
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
var flag = true;

noinline fn bump(p: *S) void {
    p.i += 10;
}

fn get(p: *S, a: []const u8) u8 {
    if (p.i < a.len) {
        if (flag) bump(p);
        return a[p.i];
    }
    return 0;
}

fn main() callconv(.c) noreturn {
    const a: [4]u8 = .{ 1, 2, 3, 4 };
    rt.exit(get(&s, &a));
}
