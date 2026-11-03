pub fn main() void {
    var x: u32 = 1;
    const y = 2;
    blk: {}
}

// error
// unused.zig:4:5: error[unused-label]: unused block label
//   | blk: {}
//   fix unused.zig:4:5-4:10: ""
// unused.zig:3:11: error[unused]: unused local constant
//   | const y = 2;
//   fix unused.zig:4:1-4:1: "    _ = y;\n"
// unused.zig:2:9: error[unused]: unused local variable
//   | var x: u32 = 1;
//   fix unused.zig:2:5-2:8: "const"
//   fix unused.zig:3:1-3:1: "    _ = x;\n"
// 3 errors
