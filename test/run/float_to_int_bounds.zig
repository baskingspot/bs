//! signal: ABRT
//! stdout: "9223372036854775808\n9223372036854775808\n32768\n9223372036854775808\n9223372036854775808\n"
//! stderr: "panic: integer part of floating point value out of bounds\n"
//! upstream-signal: SEGV
const rt = @import("rt.zig");

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

/// The minimum of a signed integer is in range whether or not the float
/// type represents the integer below it.
fn minimums() void {
    var a: f32 = -0x1p127;
    var b: f64 = -0x1p63;
    var c: f16 = -0x1p15;
    var d: f80 = -0x1p63;
    var e: f128 = -0x1p127;
    _ = .{ &a, &b, &c, &d, &e };
    rt.printInt(@as(u64, @truncate(@as(u128, @bitCast(@as(i128, @intFromFloat(a)))) >> 64)));
    rt.printInt(@bitCast(@as(i64, @intFromFloat(b))));
    rt.printInt(@as(u16, @bitCast(@as(i16, @intFromFloat(c)))));
    rt.printInt(@bitCast(@as(i64, @intFromFloat(d))));
    rt.printInt(@as(u64, @truncate(@as(u128, @bitCast(@as(i128, @intFromFloat(e)))) >> 64)));
}

fn main() callconv(.c) noreturn {
    minimums();
    var f: f32 = 256.0;
    _ = &f;
    const x: u8 = @intFromFloat(f);
    rt.exit(x);
}
