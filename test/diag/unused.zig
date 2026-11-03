pub fn main() void {
    var x: u32 = 1;
    const y = 2;
    blk: {}
}

// error
// unused.zig:4:5: error[unused-label]: unused block label
//   | blk: {}
// unused.zig:3:11: error[unused]: unused local constant
//   | const y = 2;
// unused.zig:2:9: error[unused]: unused local variable
//   | var x: u32 = 1;
// 3 errors
