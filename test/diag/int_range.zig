fn unsigned() void {
    const big: u64 = 300;
    const small: u8 = big;
    _ = small;
}
fn signed() void {
    const n: i8 = -200;
    _ = n;
}
fn cast() void {
    const x: u16 = @intCast(70000);
    _ = x;
}
fn shiftLeft(x: u8) u8 {
    return x << 8;
}
fn shiftRight(x: i32) i32 {
    var y = x;
    y >>= 40;
    return y;
}
pub fn main() void {
    unsigned();
    signed();
    cast();
    _ = shiftLeft(1);
    _ = shiftRight(1);
}

// error
// int_range.zig:3:23: error[lossy-conversion]: type 'u8' cannot represent integer value '300'
//   | const small: u8 = big;
//   note int_range.zig:3:23: 'u8' holds 0 to 255; the smallest integer type that holds 300 is u9; @truncate keeps its low 8 bits
//   ref: main int_range.zig:23:13 (+3 std frames)
// int_range.zig:7:19: error[lossy-conversion]: type 'i8' cannot represent integer value '-200'
//   | const n: i8 = -200;
//   note int_range.zig:7:19: 'i8' holds -128 to 127; the smallest integer type that holds -200 is i9; @truncate keeps its low 8 bits
//   ref: main int_range.zig:24:11 (+3 std frames)
// int_range.zig:11:29: error[lossy-conversion]: type 'u16' cannot represent integer value '70000'
//   | const x: u16 = @intCast(70000);
//   note int_range.zig:11:29: 'u16' holds 0 to 65535; the smallest integer type that holds 70000 is u17; @truncate keeps its low 16 bits
//   ref: main int_range.zig:25:9 (+3 std frames)
// int_range.zig:15:17: error[lossy-conversion]: type 'u3' cannot represent integer value '8'
//   | return x << 8;
//   note int_range.zig:15:17: shifting 'u8' by 8 or more is not allowed; 'u3' holds 0 to 7
//   note int_range.zig:15:17: to keep the shifted-out bits, widen the operand: `@as(u16, x) << 8`; for a result of 0, use `std.math.shl(u8, x, 8)`, which allows shifting by 8 or more
//   ref: main int_range.zig:26:18 (+3 std frames)
// int_range.zig:19:11: error[lossy-conversion]: type 'u5' cannot represent integer value '40'
//   | y >>= 40;
//   note int_range.zig:19:11: shifting 'i32' by 32 or more is not allowed; 'u5' holds 0 to 31
//   note int_range.zig:19:11: use `std.math.shr(i32, y, 40)`, which allows shifting by 32 or more
//   ref: main int_range.zig:27:19 (+3 std frames)
// 5 errors
