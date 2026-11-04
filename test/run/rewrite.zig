//! exit: 0
//! stdout: "4\n18446744073709551612\n60\n18446744073709551614\n18446744073709551613\n18446744073709551615\n2\n52\n18446744073709551615\n1\n0\n1\n1\n0\n2\n300\n1\n0\n5\n1\n9\n34\n6\n"
//! The rewrite rules (docs/slop/architecture.md, "Rewrite rules") fold what
//! inlining makes constant: each helper below is inlined into `main` with
//! constant arguments, and the folded results must be what the operations
//! compute at run time. The values are chosen where a plausible wrong fold
//! differs: signed against unsigned shifts and division, the signs of
//! `rem` and `mod`, wrapping, casts, and overflow bits.
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

fn outI(v: i64) void {
    out(@bitCast(v));
}

fn add8(a: u8, b: u8) u8 {
    return a +% b;
}
fn shr(a: i8, n: u3) i8 {
    return a >> n;
}
fn shrU(a: u8, n: u3) u8 {
    return a >> n;
}
fn divT(a: i8, b: i8) i8 {
    return @divTrunc(a, b);
}
fn divF(a: i8, b: i8) i8 {
    return @divFloor(a, b);
}
fn rem(a: i8, b: i8) i8 {
    return @rem(a, b);
}
fn mod(a: i8, b: i8) i8 {
    return @mod(a, b);
}
fn low(a: u16) u8 {
    return @truncate(a);
}
fn widen(a: i8) i16 {
    return a;
}
fn ovf(a: u8, b: u8) u1 {
    return @addWithOverflow(a, b)[1];
}
fn lessSigned(a: i8, b: i8) bool {
    return a < b;
}
fn lessUnsigned(a: u8, b: u8) bool {
    return a < b;
}

var runtime: u64 = 7;

fn same(x: u64) u64 {
    return (x - x) + @intFromBool(x == x) + @intFromBool(x >= 0);
}

const Point = struct { x: u32, y: u32 };
fn sum(p: Point) u32 {
    return p.x + p.y;
}
fn orZero(o: ?u32) u32 {
    return o orelse 0;
}
fn at(a: [4]u8, i: usize) u8 {
    return a[i];
}
var flag: bool = false;

/// A constant initialized differently on each path, and a block exited
/// with different constants: neither folds to the first one seen.
fn choose(c: bool) u32 {
    const p: Point = if (c) .{ .x = 1, .y = 2 } else .{ .x = 3, .y = 4 };
    return p.x * 10 + p.y;
}
fn sel(c: bool) u32 {
    if (c) return 5;
    return 6;
}
fn checked(a: u32, b: u32) u32 {
    // Overflow checks on constants: the panic is never reached.
    return a - b + a * b;
}

pub fn main() void {
    out(add8(250, 10));
    outI(shr(-16, 2));
    out(shrU(0xf0, 2));
    outI(divT(-7, 3));
    outI(divF(-7, 3));
    outI(rem(-7, 3));
    outI(mod(-7, 3));
    out(low(0x1234));
    outI(widen(-1));
    out(ovf(200, 100));
    out(ovf(100, 100));
    out(@intFromBool(lessSigned(-1, 0)));
    out(@intFromBool(!lessUnsigned(255, 0)));
    out(@intFromBool(lessUnsigned(255, 0)));
    out(same(runtime));
    out(sum(.{ .x = 100, .y = 200 }));
    out(orZero(1));
    out(orZero(null));
    out(at(.{ 2, 3, 5, 7 }, 2));
    out(@intFromBool(at("abcd".*, 0) == 'a'));
    out(checked(3, 2) + 2);
    out(choose(flag));
    out(sel(flag));
    rt.exit(0);
}
