const U = union(enum) { a: u8, b: void };
fn mayFail() !u8 {
    return 1;
}
fn param(a: u8, b: u8) u8 {
    return b;
}
pub fn main() void {
    _ = param(1, 2);
    var u: U = .{ .a = 1 };
    _ = &u;
    switch (u) {
        .a => |v| {},
        .b => {},
    }
    switch (u) {
        inline else => |v, tag| {
            _ = v;
        },
    }
    const x = mayFail() catch |err| 0;
    if (mayFail()) |v| {
        _ = v;
    } else |err| {}
    for ([_]u8{ 1, 2 }, 0..) |item, i| {
        _ = item;
    }
    const k = 4;
    _ = k;
    _ = x + k;
    var n: u8 = 1;
    _ = n;
    outer: while (true) break;
}

// error
// fix_unused.zig:5:10: error[unused]: unused function parameter
//   | fn param(a: u8, b: u8) u8 {
//   fix fix_unused.zig:6:1-6:1: "    _ = a;\n"
// fix_unused.zig:13:16: error[unused]: unused capture
//   | .a => |v| {},
//   fix fix_unused.zig:13:15-13:19: ""
// fix_unused.zig:17:28: error[unused]: unused switch tag capture
//   | inline else => |v, tag| {
//   fix fix_unused.zig:17:26-17:31: ""
// fix_unused.zig:21:32: error[unused]: unused capture
//   | const x = mayFail() catch |err| 0;
//   fix fix_unused.zig:21:31-21:37: ""
// fix_unused.zig:24:13: error[unused]: unused capture
//   | } else |err| {}
//   fix fix_unused.zig:24:13-24:16: "_"
// fix_unused.zig:25:37: error[unused]: unused capture
//   | for ([_]u8{ 1, 2 }, 0..) |item, i| {
//   fix fix_unused.zig:25:23-25:28: ""
//   fix fix_unused.zig:25:35-25:38: ""
// fix_unused.zig:33:5: error[unused-label]: unused while loop label
//   | outer: while (true) break;
//   fix fix_unused.zig:33:5-33:12: ""
// fix_unused.zig:31:9: error[never-mutated]: local variable is never mutated
//   | var n: u8 = 1;
//   note fix_unused.zig:31:9: consider using 'const'
//   fix fix_unused.zig:31:5-31:8: "const"
// fix_unused.zig:29:9: error[pointless-discard]: pointless discard of local constant
//   | _ = k;
//   note fix_unused.zig:30:13: used here
//   fix fix_unused.zig:29:1-30:1: ""
// 9 errors
