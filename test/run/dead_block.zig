//! exit: 0
//! stdout: "1\n1\n0\n1\n1\n2\n3\n9\n"
//! Blocks whose value nothing reads (docs/slop/architecture.md, "Proving
//! checks"): one whose body calls something keeps the call, and one whose
//! body's value is read after it keeps that value. A `not` of a compare
//! becomes the inverted compare only off floats: `!(nan < 1)` is true.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

var nan: f64 = 0;
var one: f64 = 1;
var two: u32 = 2;
var three: u32 = 3;
var flag = true;
var bumps: u64 = 0;

fn lessF(a: f64, b: f64) bool {
    return a < b;
}

fn lessU(a: u32, b: u32) bool {
    return a < b;
}

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
    nan = (one - one) / (one - one);
    const a: u64 = @intFromBool(!lessF(nan, one));
    const b: u64 = @intFromBool(!lessF(one, nan));
    const c: u64 = @intFromBool(!lessU(two, three));
    const d: u64 = @intFromBool(!lessU(three, two));
    for ([_]u64{ a, b, c, d }) |x| rt.printInt(x);
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
