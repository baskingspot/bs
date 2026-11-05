fn f(_: u8) void {}
pub fn main() void {
    var p: *const fn (u8) void = &f;
    _ = &p;
    p(1, 2);
}

// error
// arg_count_indirect.zig:5:5: error[arg-count]: expected 1 argument(s), found 2
//   | p(1, 2);
// 1 error
