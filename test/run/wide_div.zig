//! signal: ABRT
//! stdout: "2835555825556841598\n2835555825556841598\n8402461381695723421\n8402461381695723421\n2835555825556841598\n276990485389981512\n2967656013606361783\n16165792031897911036\n13785627696563677211\n925071226190522023\n925071226190522023\n16165792031897911036\n16165792031897911036\n276990485389981512\n2967656013606361783\n16789001819673238577\n11914087382028242320\n5229717891750355840\n5229717891750355840\n0\n0\n18445787498593197271\n18445787498593197271\n17822578810329497941\n17822578810329497941\n276990485389981512\n"
//! stderr: "panic: division by zero\n"
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

/// Folds the limbs of `x` into one number, so a wrong limb anywhere shows.
fn p(x: anytype) void {
    const U = switch (@bitSizeOf(@TypeOf(x))) {
        129 => u129,
        192 => u192,
        256 => u256,
        else => unreachable,
    };
    const u: U = @bitCast(x);
    var h: u64 = 0;
    comptime var i = 0;
    inline while (i < @bitSizeOf(U)) : (i += 64) h = (h ^ @as(u64, @truncate(u >> i))) *% 0x100000001b3;
    rt.printInt(h);
}

/// Division past 128 bits calls compiler_rt's __udivei4 and __umodei4,
/// or __divei4 and __modei4 for signed operands.
fn run(comptime T: type, a: T, b: T) void {
    p(@divTrunc(a, b));
    p(@divFloor(a, b));
    p(@rem(a, b));
    p(@mod(a, b));
}

fn main() callconv(.c) noreturn {
    var a: u256 = (1 << 200) + 12345678901234567890;
    var b: u256 = (1 << 70) + 3;
    _ = .{ &a, &b };
    run(u256, a, b);
    p(a / b);
    var c: i256 = -(1 << 199) - 987654321;
    var d: i256 = (1 << 65) + 17;
    _ = .{ &c, &d };
    run(i256, c, d);
    run(i256, c, -d);
    run(i256, -c, -d);
    var e: i129 = -(1 << 127) - 5;
    var f: i129 = -7;
    _ = .{ &e, &f };
    run(i129, e, f);
    var g: u192 = 0xffff_ffff_ffff_ffff_ffff_ffff_ffff_ffff_ffff_ffff_ffff_ffff;
    var h: u192 = 0x1_0000_0000_0000_0001;
    _ = .{ &g, &h };
    run(u192, g, h);
    p(@divCeil(c, d));
    var z: u256 = 0;
    _ = &z;
    p(a / z);
    rt.exit(0);
}
