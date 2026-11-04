//! signal: ABRT
//! stderr-contains: "panic: index out of bounds: index 6, len 3\n"
//! stderr-contains: "panic_inlined.zig:21:13: 0x"
//! stderr-contains: " in leaf ("
//! stderr-contains: "panic_inlined.zig:24:16: 0x"
//! stderr-contains: " in middle ("
//! stderr-contains: "panic_inlined.zig:30:17: 0x"
//! stderr-contains: " in top ("
//! stderr-contains: "panic_inlined.zig:35:35: 0x"
//! stderr-contains: " in main ("
//! stderr-contains: " in _start ("

// A panic in functions the backend inlines into `main` (`leaf`, `upper`,
// `top`), through Sema's inline call of `middle`: the stack trace has the
// frames of the uninlined calls, as upstream's, which `zig build test`
// also compares with bs's trace of the program built without inlining.
// Upstream folds `middle` into `upper`'s frame, which keeps `upper`'s
// call's line under `middle`'s name.
const std = @import("std");
fn leaf(s: []const u8, i: usize) u8 {
    return s[i];
}
inline fn middle(s: []const u8, i: usize) u8 {
    return leaf(s, i) +% 1;
}
fn upper(s: []const u8, i: usize) u8 {
    return middle(s, i + 1);
}
fn top(s: []const u8, i: usize) u8 {
    return upper(s, i) | 1;
}
pub fn main() void {
    var i: usize = 5;
    _ = &i;
    std.debug.print("{d}\n", .{top("abc", i)});
}
