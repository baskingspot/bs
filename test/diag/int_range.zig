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
pub fn main() void {
    unsigned();
    signed();
    cast();
}

// error
// int_range.zig:3:23: error[lossy-conversion]: type 'u8' cannot represent integer value '300'
//   | const small: u8 = big;
//   note int_range.zig:3:23: 'u8' holds 0 to 255; the smallest integer type that holds 300 is u9; @truncate keeps its low 8 bits
//   ref: main int_range.zig:15:13 (+3 std frames)
// int_range.zig:7:19: error[lossy-conversion]: type 'i8' cannot represent integer value '-200'
//   | const n: i8 = -200;
//   note int_range.zig:7:19: 'i8' holds -128 to 127; the smallest integer type that holds -200 is i9; @truncate keeps its low 8 bits
//   ref: main int_range.zig:16:11 (+3 std frames)
// int_range.zig:11:29: error[lossy-conversion]: type 'u16' cannot represent integer value '70000'
//   | const x: u16 = @intCast(70000);
//   note int_range.zig:11:29: 'u16' holds 0 to 65535; the smallest integer type that holds 70000 is u17; @truncate keeps its low 16 bits
//   ref: main int_range.zig:17:9 (+3 std frames)
// 3 errors
