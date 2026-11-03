//! exit: 0
//! A tagged union with one possible field stores no tag, a union field
//! holding a function pointer is called, a tagged union and its tag type
//! are peers, `x and false` is comptime-known, a generic instance runs with
//! its caller's branch quota, a comptime block may compute runtime
//! values it drops, and an inner struct's field defaults may read the
//! enclosing union's layout.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

const Tag = enum(u32) { only = 33 };
const One = union(Tag) { only: u64 };
const E = enum(u8) { a, b, _ };
const U2 = union(E) { a: i32, b: u32 };
const F = union(enum) {
    a: u8,
    d: *const fn (x: u8) F,
    fn make(x: u8) F {
        return .{ .a = x };
    }
};
var calls: u32 = 0;
fn sideEffect() bool {
    calls += 1;
    return true;
}
fn loopNTimes(comptime n: usize) void {
    comptime var i = 0;
    inline while (i < n) : (i += 1) {}
}

fn main() callconv(.c) noreturn {
    if (@sizeOf(One) != 8) rt.exit(1);
    var one: One = .{ .only = 5 };
    _ = &one;
    const t: Tag = one;
    comptime if (t != .only) unreachable;

    var u: U2 = .{ .b = 2 };
    _ = &u;
    switch (u) {
        .a => rt.exit(2),
        .b => |v| if (v != 2) rt.exit(3),
    }

    var f: F = .{ .d = F.make };
    _ = &f;
    if (f.d(7).a != 7) rt.exit(4);

    const V = union(Tag) { only: void };
    var v: V = .only;
    _ = &v;
    const p = if (calls == 0) Tag.only else v;
    if (@TypeOf(p) != V) rt.exit(5);

    if (sideEffect() and false) @compileError("comptime-known false");
    if (calls != 1) rt.exit(6);

    @setEvalBranchQuota(1001);
    loopNTimes(1001);

    const arr: [2]u8 = .{ 1, 2 };
    var idx: usize = undefined;
    idx = 0;
    comptime {
        _ = arr[idx];
    }

    const inner_a: Outer = .{ .a = .{} };
    const inner_b: Outer = .{ .b = .{} };
    if (inner_a.a.x != 5 or inner_b.b.y != 10) rt.exit(7);
    rt.exit(0);
}

const Outer = union {
    a: struct { x: u32 = @alignOf(Outer) + 1 },
    b: struct { y: u16 = @sizeOf(Outer) + 2 },
};
