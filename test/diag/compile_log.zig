fn show(comptime T: type) void {
    const x: T = undefined;
    @compileLog(x +% 1, @as(T, 3) | x);
}

pub fn main() void {
    show(u8);
    show(u16);
}

// error
// compile_log.zig:3:5: error[compile-log]: found compile log statement
//   | @compileLog(x +% 1, @as(T, 3) | x);
//   note compile_log.zig:3:5: also here
//   ref: main compile_log.zig:7:9 (+3 std frames)
// Compile Log Output:
// @as(u8, undefined), @as(u8, 171)
// @as(u16, undefined), @as(u16, 43691)
// 1 error
