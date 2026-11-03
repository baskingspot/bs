fn narrow(n: usize) void {
    const a: u8 = n + 1;
    _ = a;
}
fn float(x: f64) f32 {
    return x;
}
fn toFloat(i: i32) f32 {
    return i;
}
fn toInt(x: f64) void {
    takes(x);
}
fn takes(a: u16) void {
    _ = a;
}
pub fn main() void {
    narrow(1);
    _ = float(1);
    _ = toFloat(1);
    toInt(1);
}

// error
// fix_cast.zig:2:21: error[type-mismatch]: expected type 'u8', found 'usize'
//   | const a: u8 = n + 1;
//   note fix_cast.zig:2:21: unsigned 8-bit int cannot represent all possible unsigned 64-bit values
//   fix? fix_cast.zig:2:19-2:24: "@intCast(n + 1)"
//   ref: main fix_cast.zig:18:11 (+3 std frames)
// fix_cast.zig:6:12: error[type-mismatch]: expected type 'f32', found 'f64'
//   | return x;
//   note fix_cast.zig:5:18: function return type declared here: fn float(x: f64) f32 {
//   fix? fix_cast.zig:6:12-6:13: "@floatCast(x)"
//   ref: main fix_cast.zig:19:14 (+3 std frames)
// fix_cast.zig:9:12: error[type-mismatch]: expected type 'f32', found 'i32'
//   | return i;
//   note fix_cast.zig:8:20: function return type declared here: fn toFloat(i: i32) f32 {
//   fix? fix_cast.zig:9:12-9:13: "@floatFromInt(i)"
//   ref: main fix_cast.zig:20:16 (+3 std frames)
// fix_cast.zig:12:11: error[type-mismatch]: expected type 'u16', found 'f64'
//   | takes(x);
//   note fix_cast.zig:14:13: parameter type declared here: fn takes(a: u16) void {
//   fix? fix_cast.zig:12:11-12:12: "@intFromFloat(x)"
//   ref: main fix_cast.zig:21:10 (+3 std frames)
// 4 errors
