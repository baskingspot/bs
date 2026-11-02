//! exit: 0
//! stdout: "18364758544493064720\n82267004193197554\n81985529216486895\n18365040019469775380\n3361427964874203099\n15085035884858534349\n65244\n13445626778676220249\n0\n248987462293988\n5247073869855161280\n0\n0\n286949352257704136\n18446744073709551615\n18303909909527703351\n1305912358234041273\n2646961371846576930\n1305912358234041273\n2646961371846576930\n18446744073709551615\n18446744073709551615\n18446744073709551615\n18446744073709551615\n0\n6\n9305357566071262703\n18364758544493064722\n9141386507638288912\n81985529216486895\n1\n0\n1\n79\n70\n64\n17279655951921914625\n1167088121787636990\n13835058055282196480\n0\n1\n0\n1\n1\n1\n1\n0\n16\n18446744073709551615\n18446744073709551613\n18446744073709551615\n18446744073709551600\n1\n0\n"
const rt = @import("rt.zig");

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

fn p(x: anytype) void {
    const U = @Int(.unsigned, @bitSizeOf(@TypeOf(x)));
    const u: U = @bitCast(x);
    rt.printInt(@truncate(u >> 64));
    rt.printInt(@truncate(u));
}

/// Wide integers: multi-limb arithmetic, division through compiler_rt, and
/// the overflow flags the safety checks use.
fn main() callconv(.c) noreturn {
    var a: u128 = 0xfedc_ba98_7654_3210_0123_4567_89ab_cdef;
    var b: u128 = 0x1_0000_0000_0003;
    var s: i128 = -0x7edc_ba98_7654_3210_0123_4567_89ab_cdef;
    var t: i128 = -7;
    var n: u7 = 70;
    _ = &a;
    _ = &b;
    _ = &s;
    _ = &t;
    _ = &n;
    p(a +% b);
    p(b -% a);
    p(a *% b);
    p(a / b);
    p(a % b);
    p(a << n);
    p(a >> n);
    p(s >> n);
    p(@divTrunc(s, t));
    p(@divFloor(s, t));
    p(@rem(s, t));
    p(@mod(s, t));
    p(@mod(s, -t));
    p(@divTrunc(s, t) * t);
    p(-s);
    rt.printInt(@intFromBool(s < t));
    rt.printInt(@intFromBool(a < b));
    rt.printInt(@intFromBool(@as(i128, @bitCast(a)) < @as(i128, @bitCast(b))));
    rt.printInt(@clz(b));
    rt.printInt(@ctz(b << 70));
    rt.printInt(@popCount(a));
    p(@byteSwap(a));
    p(@bitReverse(b));
    rt.printInt(@mulWithOverflow(a, b)[1]);
    rt.printInt(@mulWithOverflow(b, b)[1]);
    rt.printInt(@addWithOverflow(a, a)[1]);
    rt.printInt(@subWithOverflow(b, a)[1]);
    rt.printInt(@mulWithOverflow(s, t)[1]);
    rt.printInt(@mulWithOverflow(s, -t * 2)[1]);
    // Odd widths stay normalized: sign- or zero-extended in their limbs.
    var c: u100 = 0xf_ffff_ffff_ffff_ffff_ffff_fff0;
    var d: i100 = -1;
    _ = &c;
    _ = &d;
    p(c +% 0x20);
    p(@as(i128, d *% 3));
    p(@as(i128, @as(i100, @bitCast(c))));
    rt.printInt(@addWithOverflow(c, 0x10)[1]);
    rt.printInt(@addWithOverflow(c, 0xf)[1]);
    rt.exit(0);
}
