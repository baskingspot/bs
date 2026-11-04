//! exit: 0
//! stdout: "77\n7\n80\n15\n1\n"
//! A pointer at a constant offset from another (a field's, an element's
//! at a constant index) is folded into its users' addressing when its
//! base can stay in a register as long as the users read it: through a
//! loop, but not across a large copy (`rep movsb` in rsi, rdi, rcx) or a
//! call.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

fn out(v: u64) void {
    rt.printInt(v);
}

const Big = struct { a: [40]u64, b: u64, c: u64 };

var calls: u64 = 0;

noinline fn bump() void {
    calls += 1;
}

noinline fn copyThenField(p: *Big, q: *const Big) u64 {
    const pb = &p.b;
    const pc = &p.c;
    p.* = q.*;
    pb.* += 1;
    bump();
    return pc.* * 10 + pb.*;
}

noinline fn loop(p: *Big, n: usize) u64 {
    var sum: u64 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        p.a[3] += i;
        sum += p.a[3] + p.c;
    }
    return sum;
}

pub fn main() void {
    var x: Big = .{ .a = @splat(1), .b = 2, .c = 3 };
    const y: Big = .{ .a = @splat(5), .b = 6, .c = 7 };
    out(copyThenField(&x, &y));
    out(x.b);
    out(loop(&x, 5));
    out(x.a[3]);
    out(calls);
    rt.exit(0);
}
