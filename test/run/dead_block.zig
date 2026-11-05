//! exit: 0
//! stdout: "1\n2\n3\n9\n"
//! Blocks whose value nothing reads (docs/slop/architecture.md, "Proving
//! checks"): one whose body calls something keeps the call, and one whose
//! body's value is read after it keeps that value.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

var two: u32 = 2;
var flag = true;
var bumps: u64 = 0;

/// As std's sort wraps a comparator in Debug: prove decides the assert,
/// which leaves the `lt and gt` block unread, and so runs the pass here.
fn lessThan(a: u32, b: u32) bool {
    const lt = a < b;
    const gt = b < a;
    if (lt and gt) unreachable;
    return lt;
}

fn bump() bool {
    bumps += 1;
    return true;
}

fn main() callconv(.c) noreturn {
    _ = flag and bump();
    _ = flag and bump();
    const v = blk: {
        const t = two + 1;
        break :blk t;
    };
    rt.printInt(@intFromBool(lessThan(two, v)));
    rt.printInt(bumps);
    rt.printInt(v);
    rt.printInt(v * v);
    rt.exit(0);
}
