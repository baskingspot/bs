// A coercion of an arithmetic operand fails at that operand, as upstream.
fn lhs(y: u64) u64 {
    return (1 << 70) + y;
}
fn rhs(y: u8) u8 {
    return y + 3 * 100;
}
pub fn main() void {
    _ = lhs(1);
    _ = rhs(1);
}

// error
// arith_operand.zig:3:12: error[lossy-conversion]: type 'u64' cannot represent integer value '1180591620717411303424'
//   | return (1 << 70) + y;
//   note arith_operand.zig:3:12: 'u64' holds 0 to 18446744073709551615; the smallest integer type that holds 1180591620717411303424 is u71; @truncate keeps its low 64 bits
//   ref: main arith_operand.zig:9:12 (+3 std frames)
// arith_operand.zig:6:18: error[lossy-conversion]: type 'u8' cannot represent integer value '300'
//   | return y + 3 * 100;
//   note arith_operand.zig:6:18: 'u8' holds 0 to 255; the smallest integer type that holds 300 is u9; @truncate keeps its low 8 bits
//   ref: main arith_operand.zig:10:12 (+3 std frames)
// 2 errors
