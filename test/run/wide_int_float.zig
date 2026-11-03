//! signal: ABRT
//! stdout: "68124640972325349\n33776997218641920\n56013520387581184\n17758005578773779075\n4368201368055649591\n6907031141261780983\n9223373872324149248\n926857297920\n9223373799343259648\n6125850968828600694\n18433741730235810227\n5656497698635776000\n7084162213853790208\n7340876188706934168\n14091763234042281984\n18446462598732729600\n18433741730235810227\n5656497698635776000\n9277634035218616869\n6431467925443410526\n9277524084055795769\n18446462598732729600\n18433741730235810227\n5656497698635776000\n10530823303675772928\n4205799102010621952\n6775383069540965965\n18446462598732729600\n611160721047681614\n1787538076859971336\n"
//! stderr: "panic: integer part of floating point value out of bounds\n"
//! upstream-signal: SEGV
const rt = @import("rt.zig");

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

/// Folds the bits of `x` into one number, so a wrong limb anywhere shows.
fn p(x: anytype) void {
    const U = @Int(.unsigned, @bitSizeOf(@TypeOf(x)));
    const u: U = @bitCast(x);
    var h: u64 = 0;
    comptime var i = 0;
    inline while (i < @bitSizeOf(U)) : (i += 64) h = (h ^ @as(u64, @truncate(u >> i))) *% 0x100000001b3;
    rt.printInt(h);
}

/// Conversions between floats and integers past 128 bits call compiler_rt's
/// __floateisf, __fixsfei, and their relatives, with rounding to nearest
/// even one way and truncation the other.
fn conv(comptime F: type, a: i256, b: u300, c: i129) void {
    p(@as(F, @floatFromInt(a)));
    p(@as(F, @floatFromInt(b)));
    p(@as(F, @floatFromInt(c)));
    const fa: F = @floatFromInt(a);
    p(@as(i256, @intFromFloat(fa)));
    const fc: F = @floatFromInt(c);
    p(@as(i129, @intFromFloat(fc)));
    p(@as(u200, @intFromFloat(@abs(fc))));
}

fn main() callconv(.c) noreturn {
    var a: i256 = -(1 << 200) - 0x123456789abcdef;
    var b: u300 = (1 << 299) + (1 << 250) + 1;
    var c: i129 = -(1 << 100) + 3;
    _ = .{ &a, &b, &c };
    conv(f16, -12345, 1 << 15, -7);
    conv(f32, -(1 << 120) - 0x123456789, (1 << 127) + (1 << 100) + 1, c);
    conv(f64, a, b, c);
    conv(f80, a, b, c);
    conv(f128, a, b, c);
    // 2^200 is past f32's range: infinity does not fit in an i256.
    const inf: f32 = @floatFromInt(a);
    p(@as(i256, @intFromFloat(inf)));
    rt.exit(0);
}
