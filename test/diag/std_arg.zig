const std = @import("std");
fn find(xs: []const i32) ?i32 {
    return if (xs.len > 0) xs[0] else null;
}
fn printAlloc(gpa: std.mem.Allocator) anyerror!void {
    const msg = std.fmt.allocPrint(gpa, "{d}", .{42});
    std.debug.print("{s}\n", .{msg});
}
fn printOptional() void {
    std.debug.print("{d} {d}\n", .{ 3, find(&.{ 1, 2 }) });
}
fn free(gpa: std.mem.Allocator) anyerror!void {
    const buf = gpa.alloc(u8, 4);
    gpa.free(buf);
}
pub fn main(init: std.process.Init) !void {
    try printAlloc(init.gpa);
    printOptional();
    try free(init.gpa);
}

// error
// std/Io/Writer.zig:1935:5: error[compile-error]: invalid format string 'd' for type '?i32'
//   | @compileError("invalid format string '" ++ fmt ++ "' for type '" ++ @typeName(@TypeOf(value)) ++ "'");
//   note std_arg.zig:10:44: this argument is an optional; consider using '.?' or 'orelse' here: std.debug.print("{d} {d}\n", .{ 3, find(&.{ 1, 2 }) });
//   fix? std_arg.zig:10:56-10:56: ".?"
//   ref: printOptional std_arg.zig:10:20 <- main std_arg.zig:18:18 (+6 std frames)
// std/Io/Writer.zig:1935:5: error[compile-error]: invalid format string 's' for type 'error{OutOfMemory}![]u8'
//   | @compileError("invalid format string '" ++ fmt ++ "' for type '" ++ @typeName(@TypeOf(value)) ++ "'");
//   note std_arg.zig:6:35: 'msg' holds the error union returned by 'std.fmt.allocPrint'; consider using 'try' or 'catch' here: const msg = std.fmt.allocPrint(gpa, "{d}", .{42});
//   fix? std_arg.zig:6:17-6:17: "try "
//   ref: printAlloc std_arg.zig:7:20 <- main std_arg.zig:17:19 (+6 std frames)
// std/mem/Allocator.zig:469:50: error[inactive-field]: access of union field 'pointer' while field 'error_union' is active
//   | const slice_info = @typeInfo(@TypeOf(memory)).pointer;
//   note std_arg.zig:13:26: 'buf' holds the error union returned by 'gpa.alloc'; consider using 'try' or 'catch' here: const buf = gpa.alloc(u8, 4);
//   fix? std_arg.zig:13:17-13:17: "try "
//   ref: free std_arg.zig:14:13 <- main std_arg.zig:19:13 (+3 std frames)
// 3 errors
