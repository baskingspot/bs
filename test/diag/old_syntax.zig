pub fn main() void {
    const idx: usize = 3;
    const narrow = @intCast(u16, idx);
    _ = narrow;
}
fn sum(xs: []const u8) usize {
    var total: usize = 0;
    for (xs) |x, i| total += x * i;
    return total;
}

// error
// old_syntax.zig:3:20: error[arg-count]: expected 1 argument, found 2
//   | const narrow = @intCast(u16, idx);
//   hint: since 0.11, @intCast takes its type from the result type: `@as(T, @intCast(x))`, or give the destination a type (`const y: T = @intCast(x);`)
//   fix old_syntax.zig:3:20-3:38: "@as(u16, @intCast(idx))"
// old_syntax.zig:8:18: error[bad-capture]: extra capture in for loop
//   | for (xs) |x, i| total += x * i;
//   hint: since 0.11, a for loop's index is an input of its own: `for (items, 0..) |item, i|`
//   fix old_syntax.zig:8:12-8:12: ", 0.."
// 2 errors
