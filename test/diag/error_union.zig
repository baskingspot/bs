// try, catch and orelse on the wrong kind of value, and a function that
// returns errors without a `!`.
const std = @import("std");

const max = try std.math.maxInt(u8);

fn firstChar(s: []const u8) u8 {
    if (s.len == 0) return error.Empty;
    return s[0];
}

fn digit(s: []const u8) ?u8 {
    if (s.len == 0) return null;
    return std.fmt.charToDigit(s[0], 10) catch null;
}

fn parse(s: []const u8) !u8 {
    return std.fmt.parseInt(u8, s, 10);
}

fn catchOptional() u8 {
    return digit("7") catch 0;
}

fn catchCapture() u8 {
    return digit("8") catch |err| switch (err) {};
}

fn orelseError() u8 {
    return parse("9") orelse 0;
}

fn unwrapError() u8 {
    return parse("10").?;
}

fn tryBool() bool {
    return try std.mem.eql(u8, "a", "b");
}

pub fn main() !void {
    _ = .{ catchOptional(), catchCapture(), orelseError(), unwrapError(), tryBool() };
    _ = try firstChar("zig");
}

// error
// error_union.zig:5:13: error[outside-function]: 'try' outside function scope
//   | const max = try std.math.maxInt(u8);
//   hint: no function here can return the error: remove 'try', or handle the error with 'catch'
//   fix? error_union.zig:5:13-5:17: ""
// error_union.zig:8:34: error[type-mismatch]: expected type 'u8', found 'error{Empty}'
//   | if (s.len == 0) return error.Empty;
//   note error_union.zig:7:29: function cannot return an error: fn firstChar(s: []const u8) u8 {
//   hint: return type '!u8' lets the function return errors
//   fix? error_union.zig:7:29-7:29: "!"
//   ref: main error_union.zig:43:22 (+3 std frames)
// error_union.zig:22:23: error[operand-type]: expected error union type, found '?u8'
//   | return digit("7") catch 0;
//   hint: 'catch' unwraps an error union; 'orelse' unwraps an optional
//   fix? error_union.zig:22:23-22:28: "orelse"
//   ref: main error_union.zig:42:25 (+3 std frames)
// error_union.zig:26:23: error[operand-type]: expected error union type, found '?u8'
//   | return digit("8") catch |err| switch (err) {};
//   ref: main error_union.zig:42:41 (+3 std frames)
// error_union.zig:30:23: error[operand-type]: expected optional type, found '@typeInfo(@typeInfo(@TypeOf(error_union.parse)).@"fn".return_type.?).error_union.error_set!u8'
//   | return parse("9") orelse 0;
//   note error_union.zig:30:23: consider using 'try', 'catch', or 'if'
//   fix? error_union.zig:30:23-30:29: "catch"
//   ref: main error_union.zig:42:56 (+3 std frames)
// error_union.zig:34:23: error[operand-type]: expected optional type, found '@typeInfo(@typeInfo(@TypeOf(error_union.parse)).@"fn".return_type.?).error_union.error_set!u8'
//   | return parse("10").?;
//   note error_union.zig:34:23: consider using 'try', 'catch', or 'if'
//   ref: main error_union.zig:42:71 (+3 std frames)
// error_union.zig:38:27: error[operand-type]: expected error union type, found 'bool'
//   | return try std.mem.eql(u8, "a", "b");
//   note error_union.zig:38:27: consider omitting 'try'
//   fix? error_union.zig:38:12-38:16: ""
//   ref: main error_union.zig:42:82 (+3 std frames)
// error_union.zig:43:22: error[operand-type]: expected error union type, found 'u8'
//   | _ = try firstChar("zig");
//   note error_union.zig:43:22: consider omitting 'try'
// 8 errors
