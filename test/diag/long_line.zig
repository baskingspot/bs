const table = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 300, 61, 62 };

pub fn main() void {
    _ = table;
}

// error
// long_line.zig:1:253: error[lossy-conversion]: type 'u8' cannot represent integer value '300'
//   | 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 300, 61, 62 };
//   note long_line.zig:1:253: 'u8' holds 0 to 255; the smallest integer type that holds 300 is u9; @truncate keeps its low 8 bits
//   ref: main long_line.zig:4:9 (+3 std frames)
// 1 error
