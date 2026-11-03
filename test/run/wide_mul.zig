//! signal: ABRT
//! stdout: "13178340824485560635\n13178340824485560635\n0\n6801460894288669408\n16385958038431229100\n16385958038431229100\n1\n6801460894288669408\n9203344593800792743\n9203344593800792743\n0\n7378205022900086462\n7295805019269565629\n7295805019269565629\n0\n7378205022900086462\n913916446521649328\n913916446521649328\n1\n15998993745615295489\n13178340824485560635\n"
//! stderr: "panic: integer overflow\n"
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
        1025 => u1025,
        520 => u520,
        320 => u320,
        else => unreachable,
    };
    const u: U = @bitCast(x);
    var h: u64 = 0;
    comptime var i = 0;
    inline while (i < @bitSizeOf(U)) : (i += 64) h = (h ^ @as(u64, @truncate(u >> i))) *% 0x100000001b3;
    rt.printInt(h);
}

/// Multiplies past four limbs, which x86_64 lowers as a loop.
fn run(comptime T: type, a: T, b: T) void {
    p(a *% b);
    const o = @mulWithOverflow(a, b);
    p(o[0]);
    rt.printInt(o[1]);
    p(a *% 0x1234_5678_9abc_def0_1234_5678_9abc);
}

fn main() callconv(.c) noreturn {
    var a: u1025 = (1 << 1000) + 0xdead_beef_cafe_babe_1234_5678;
    var b: u1025 = (1 << 24) + 977;
    _ = .{ &a, &b };
    run(u1025, a, b);
    run(u1025, a, a);
    var c: i520 = -(1 << 400) - 12345;
    var d: i520 = (1 << 100) - 1;
    _ = .{ &c, &d };
    run(i520, c, d);
    run(i520, c, -d);
    var e: u320 = 0xffff_ffff_ffff_ffff_ffff_ffff_ffff_ffff_ffff_ffff_ffff_ffff;
    _ = &e;
    run(u320, e, e);
    p(a * b);
    p(a * a);
    rt.exit(0);
}
