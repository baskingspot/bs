// An error in a generic function's parameter or return type names the
// call that instantiates it, in the caller's file, as upstream.
const std = @import("std");

fn returnType() void {
    _ = std.mem.span(5);
}
fn paramType() void {
    _ = std.meta.fieldInfo(u8, .x);
}

pub fn main() void {
    returnType();
    paramType();
}

// error
// std/mem.zig:945:5: error[compile-error]: invalid type given to std.mem.span: comptime_int
//   | @compileError("invalid type given to std.mem.span: " ++ @typeName(T));
//   call: generic_frames.zig:6:21 generic, +1 std
//   ref: main generic_frames.zig:13:15 (+3 std frames)
// std/meta.zig:315:26: error[reached-unreachable]: reached unreachable code
//   | else => comptime unreachable,
//   call: generic_frames.zig:9:27 generic, +2 std
//   ref: main generic_frames.zig:14:14 (+3 std frames)
// 2 errors
