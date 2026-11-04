const std = @import("std");
fn mean(xs: []const f64) ?f64 {
    if (xs.len == 0) return null;
    var sum: f64 = 0;
    for (xs) |x| sum += x;
    return sum / @as(f64, @floatFromInt(xs.len));
}
fn rounded(xs: []const f64) f64 {
    const m = mean(xs);
    return std.math.round(m);
}
fn check(xs: []const f64) !void {
    try std.testing.expectApproxEqAbs(2.0, mean(xs), 0.01);
}
pub fn main() !void {
    _ = rounded(&.{ 1, 2 });
    try check(&.{ 1, 3 });
}

// error
// std/math.zig:1154:12: error[operand-type]: expected float or vector type, found '?f64'
//   | return @round(value);
//   note inline_arg.zig:9:19: 'm' holds the optional returned by 'mean'; consider using '.?' or 'orelse' here: const m = mean(xs);
//   fix? inline_arg.zig:9:23-9:23: ".?"
//   call: inline_arg.zig:10:26 inline
//   ref: main inline_arg.zig:16:16 (+3 std frames)
// std/testing.zig:272:17: error[compile-error]: Unable to compare non floating point values
//   | else => @compileError("Unable to compare non floating point values"),
//   note inline_arg.zig:13:48: this argument is an optional; consider using '.?' or 'orelse' here: try std.testing.expectApproxEqAbs(2.0, mean(xs), 0.01);
//   fix? inline_arg.zig:13:52-13:52: ".?"
//   call: inline_arg.zig:13:38 inline, +3 std
//   ref: main inline_arg.zig:17:14 (+4 std frames)
// 2 errors
