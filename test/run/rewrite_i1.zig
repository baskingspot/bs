//! exit: 0
//! stdout: "134\n134\n0\n18446744073709551614\n134\n1\n134\n134\n120\n134\n70\n134\n"
//! Constants read as values, not bits (found by tools/mchunt). An i1's
//! -1 has one bit set, and the rewrite rules' `x * 1` identity took it
//! for 1, dropping the overflow check of -1 * -1. Prove read a constant
//! from a widened compare in the narrow operand's bits: after
//! `@as(i16, x) < 130` with `x: i8` it took 130 as -126 and dropped the
//! check of `x + 60`. Each case runs in a child process; a check that
//! fires prints 134.
const std = @import("std");
const linux = std.os.linux;
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

var m1: i1 = -1;
var z1: i1 = 0;
var m2: i2 = -2;
var o1: u1 = 1;
var m7: i7 = -64;
var big8: i8 = 127;
var mid8: i8 = 60;
var big7: i7 = 63;

fn outI(v: i64) void {
    rt.printInt(@bitCast(v));
}

fn case(comptime f: fn () i64) void {
    const pid = linux.fork();
    if (pid == 0) {
        // The parent reports the panic; keep its message out of the log.
        _ = linux.close(2);
        outI(f());
        rt.exit(0);
    }
    var status: i32 = 0;
    _ = linux.wait4(@intCast(pid), &status, 0, null);
    const st: u32 = @bitCast(status);
    // A signal (rt.panic aborts) as the shell reports it, else the exit code.
    const code = if (st & 0x7f != 0) 128 + (st & 0x7f) else (st >> 8) & 0xff;
    if (code != 0) rt.printInt(code);
}

fn main() callconv(.c) noreturn {
    case(struct {
        fn f() i64 {
            return @as(i1, -1) * m1; // -1 * -1 overflows
        }
    }.f);
    case(struct {
        fn f() i64 {
            return m1 * @as(i1, -1);
        }
    }.f);
    case(struct {
        fn f() i64 {
            return @as(i1, -1) * z1;
        }
    }.f);
    case(struct {
        fn f() i64 {
            return @as(i2, 1) * m2;
        }
    }.f);
    case(struct {
        fn f() i64 {
            return @as(i2, -1) * m2; // 2 overflows an i2
        }
    }.f);
    case(struct {
        fn f() i64 {
            return @as(u1, 1) * o1;
        }
    }.f);
    case(struct {
        fn f() i64 {
            return @as(i7, -1) * m7; // 64 overflows an i7
        }
    }.f);
    case(struct {
        fn f() i64 {
            const x = big8;
            return if (@as(i16, x) < 130) x + 60 else 0; // 187 overflows
        }
    }.f);
    case(struct {
        fn f() i64 {
            const x = mid8;
            return if (@as(i16, x) < 130) x + 60 else 0;
        }
    }.f);
    case(struct {
        fn f() i64 {
            const x = big7;
            return if (@as(i16, x) < 70) x + 10 else 0; // 73 overflows an i7
        }
    }.f);
    case(struct {
        fn f() i64 {
            const x: u8 = @intCast(mid8);
            return if (@as(u16, x) < 300) x + 10 else 0;
        }
    }.f);
    case(struct {
        fn f() i64 {
            const x: u8 = @intCast(big8);
            return if (@as(u16, x) < 300) x *% 2 + (x + 129) else 0; // 256 overflows a u8
        }
    }.f);
    rt.exit(0);
}
