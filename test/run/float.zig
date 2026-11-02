//! exit: 0
//! stdout: "010010\n32768\n64512\n0\n13653\n46421\n16110\n48128\n15360\n48128\n32768\n16384\n48128\n16896\n15360\n18446744073709551615\n010010\n2147483648\n4286578688\n0\n1051372203\n3198855851\n1071494103\n3212836864\n1065353216\n3212836864\n2147483648\n1073741824\n3212836864\n1077936128\n1065353216\n18446744073709551615\n010010\n9223372036854775808\n18442240474082181120\n0\n4599676419421066581\n13823048456275842389\n4610479282544200874\n13830554455654793216\n4607182418800017408\n13830554455654793216\n9223372036854775808\n4611686018427387904\n13830554455654793216\n4613937818241073152\n4607182418800017408\n18446744073709551615\n010010\n9223372036854775808\n18446603336221196288\n0\n4611029243481729706\n13834401280336505514\n4611648307931038309\n13834917317793808384\n4611545280939032576\n13834917317793808384\n9223372036854775808\n4611826755915743232\n13834917317793808384\n4611897124659920896\n4611545280939032576\n18446744073709551615\n010010\n9223372036854775808\n18446462598732840960\n0\n4610935418489492821\n13834307455344268629\n13834776580305453056\n4611404543450677248\n13834776580305453056\n9223372036854775808\n4611686018427387904\n13834776580305453056\n4611826755915743232\n4611404543450677248\n18446744073709551615\n1602224128\n4895412794951729152\n4845873199050653696\n14069245235905429504\n4643211215818981376\n4629418941960159231\n31744\n1065353216\n16896\n4607182418800017408\n4611545280939032576\n1065353216\n18446744063709551616\n9223372036854775808\n255\n18446744063709551615\n"
const rt = @import("rt.zig");

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

fn bits(x: anytype) u64 {
    const T = @TypeOf(x);
    const U = @Int(.unsigned, @bitSizeOf(T));
    const u: U = @bitCast(x);
    if (@bitSizeOf(T) <= 64) return u;
    return @truncate(u >> (@bitSizeOf(T) - 64));
}

fn flag(b: bool) void {
    rt.print(if (b) "1" else "0");
}

/// NaN compares unequal to everything; signed zeros compare equal but keep
/// their sign; rounding of arithmetic and conversions is to nearest even.
fn check(comptime T: type) void {
    var zero: T = 0;
    var one: T = 1;
    var three: T = 3;
    _ = &zero;
    _ = &one;
    _ = &three;
    const nan = zero / zero;
    const neg_zero = -zero;
    flag(nan == nan);
    flag(nan != nan);
    flag(nan < one);
    flag(nan >= one);
    flag(neg_zero == zero);
    flag(neg_zero < zero);
    rt.print("\n");
    rt.printInt(bits(neg_zero));
    rt.printInt(bits(one / neg_zero));
    rt.printInt(bits(neg_zero + zero));
    rt.printInt(bits(one / three));
    rt.printInt(bits(-one / three));
    // compiler_rt's sqrtq needs tuples.
    if (T != f128) rt.printInt(bits(@sqrt(three)));
    rt.printInt(bits(@rem(-three, one + one)));
    rt.printInt(bits(@mod(-three, one + one)));
    rt.printInt(bits(@floor(-one / three)));
    rt.printInt(bits(@ceil(-one / three)));
    rt.printInt(bits(@round(three / (one + one))));
    rt.printInt(bits(@trunc(-three / (one + one))));
    rt.printInt(bits(@min(nan, three)));
    rt.printInt(bits(@max(one, nan)));
    rt.printInt(@bitCast(@as(i64, @intFromFloat(-three / (one + one)))));
}

fn main() callconv(.c) noreturn {
    check(f16);
    check(f32);
    check(f64);
    check(f80);
    check(f128);

    // Integer to float conversions round to nearest even.
    var max_u64: u64 = 0xffff_ffff_ffff_ffff;
    var odd: i64 = (1 << 53) + 1;
    var big: u128 = (1 << 113) + 3;
    _ = &max_u64;
    _ = &odd;
    _ = &big;
    rt.printInt(bits(@as(f32, @floatFromInt(max_u64))));
    rt.printInt(bits(@as(f64, @floatFromInt(max_u64))));
    rt.printInt(bits(@as(f64, @floatFromInt(odd))));
    rt.printInt(bits(@as(f64, @floatFromInt(-odd))));
    rt.printInt(bits(@as(f128, @floatFromInt(big))));
    rt.printInt(bits(@as(f80, @floatFromInt(max_u64))));
    rt.printInt(bits(@as(f16, @floatFromInt(max_u64 >> 48))));

    // Narrowing float conversions round to nearest even.
    var tie: f64 = 1.0 + 0x1p-24;
    var x: f128 = 1.0 + 0x1p-60;
    _ = &tie;
    _ = &x;
    rt.printInt(bits(@as(f32, @floatCast(tie))));
    rt.printInt(bits(@as(f16, @floatCast(tie * 3))));
    rt.printInt(bits(@as(f64, @floatCast(x))));
    rt.printInt(bits(@as(f80, @floatCast(x))));
    rt.printInt(bits(@as(f32, @floatCast(@as(f80, @floatCast(x))))));

    // Float to integer conversions truncate toward zero.
    var f: f64 = -1e10 - 0.75;
    var g: f32 = 0x1p63;
    _ = &f;
    _ = &g;
    rt.printInt(@bitCast(@as(i64, @intFromFloat(f))));
    rt.printInt(@intFromFloat(g));
    rt.printInt(@as(u8, @intFromFloat(@as(f16, 255.9))));
    rt.printInt(@truncate(@as(u128, @intFromFloat(@as(f128, 0x1p100) + f))));
    rt.exit(0);
}
