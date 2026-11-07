//! One finding of each syntax rule that needs no other file.

const std = @import("std");
const builtin = @import("builtin");
const again = @import("std");
const mem = std.mem;

const Point = struct {
    x: i32,
    y: i32,

    const Alias = @This();

    fn len(p: @This()) i32 {
        return p.x + p.y;
    }
};

const Bad_Errors = error{Oops};
const MyValue = 3;

fn Make_thing() void {}

fn bad(comptime T: type, n: usize) type {
    _ = n;
    return T;
}

fn _hidden() void {}

fn parseXML() void {}

pub fn run(a: std.mem.Allocator, value: anyerror!u32) !u32 {
    _ = a;
    const origin = Point{ .x = 0, .y = 0 };
    const _unused = origin.len();
    std.debug.assert(_unused == 0 and mem.eql(u8, "a", "a"));
    _ = std.mem.eql(u8, "b", "b");
    _ = value catch {};
    const v = value catch |err| return err;
    _ = v;
    const anon = struct {
        const Me = @This();
    };
    _ = anon;
    return try value;
}

const Hidden = struct {};

pub fn expose() Hidden {
    return Hidden{};
}

fn order(a: std.mem.Allocator, comptime T: type) T {
    _ = a;
    const max: u32 = @as(u32, 1);
    const list = [_]u32{@as(u32, 2)};
    _ = list;
    _ = @import("std").math.maxInt(u8);
    return max;
}

fn hello(w: *std.Io.Writer) !void {
    try w.print("hello\n", .{});
}

const unused_import = @import("builtin");

const Thing = struct {
    buf: []u8,

    fn deinit(t: *Thing, gpa: std.mem.Allocator) void {
        gpa.free(t.buf);
    }
};

test {
    _ = builtin;
    _ = again;
    _ = &Make_thing;
    _ = &bad;
    _ = &_hidden;
    _ = &parseXML;
    _ = &run;
    _ = Bad_Errors;
    _ = MyValue;
    _ = Thing;
    _ = &expose;
    _ = &order;
    _ = &hello;
    _ = @import("std").math;
}

// error
// rules.zig:5:7: error[style, Z007]: duplicate import '"std"'
//   | const again = @import("std");
// rules.zig:12:19: error[style, Z019]: @This() used in named struct; use 'Point' instead
//   | const Alias = @This();
// rules.zig:14:15: error[style, Z020]: inline @This() in named struct; use 'Point' instead
//   | fn len(p: @This()) i32 {
// rules.zig:19:7: error[style, Z014]: error set 'Bad_Errors' should be PascalCase
//   | const Bad_Errors = error{Oops};
// rules.zig:20:7: error[style, Z006]: variable 'MyValue' should be snake_case
//   | const MyValue = 3;
// rules.zig:22:4: error[style, Z001]: function 'Make_thing' should be camelCase
//   | fn Make_thing() void {}
// rules.zig:24:4: error[style, Z005]: type function 'bad' should be PascalCase
//   | fn bad(comptime T: type, n: usize) type {
// rules.zig:29:4: error[style, Z031]: identifier '_hidden' has underscore prefix; avoid _like_this naming
//   | fn _hidden() void {}
// rules.zig:31:4: error[style, Z032]: acronym in 'parseXML' should use standard casing: 'parseXml'
//   | fn parseXML() void {}
// rules.zig:33:15: error[style, Z035]: use alias 'mem' instead of 'std.mem'
//   | pub fn run(a: std.mem.Allocator, value: anyerror!u32) !u32 {
// rules.zig:35:5: error[style, Z004]: prefer type annotation 'Point' with an anonymous initializer for 'origin'; preserve the declaration kind, modifiers, and fields
//   | const origin = Point{ .x = 0, .y = 0 };
// rules.zig:36:11: error[style, Z002]: initialized variable '_unused' uses a named discard; rename it if used or write `_ = expression;` to discard the value
//   | const _unused = origin.len();
// rules.zig:36:11: error[style, Z031]: identifier '_unused' has underscore prefix; avoid _like_this naming
//   | const _unused = origin.len();
// rules.zig:37:21: error[style, Z016]: split compound assert: `assert(a and b)` -> `assert(a); assert(b);`
//   | std.debug.assert(_unused == 0 and mem.eql(u8, "a", "a"));
// rules.zig:38:9: error[style, Z035]: use alias 'mem' instead of 'std.mem'
//   | _ = std.mem.eql(u8, "b", "b");
// rules.zig:39:15: error[style, Z026]: empty catch block suppresses errors: `catch {}`
//   | _ = value catch {};
// rules.zig:40:21: error[style, Z025]: redundant catch: `catch |err| return err` -> use try
//   | const v = value catch |err| return err;
// rules.zig:43:20: error[style, Z022]: @This() alias 'Me' should be 'Self'
//   | const Me = @This();
// rules.zig:46:5: error[style, Z017]: avoid try in return; hoist it to preserve payload coercion: `const value = try value; return value;`
//   | return try value;
// rules.zig:51:8: error[style, Z012]: public function exposes private type 'Hidden'
//   | pub fn expose() Hidden {
// rules.zig:52:12: error[style, Z010]: prefer `.{}` over `Hidden{}`
//   | return Hidden{};
// rules.zig:55:13: error[style, Z035]: use alias 'mem' instead of 'std.mem'
//   | fn order(a: std.mem.Allocator, comptime T: type) T {
// rules.zig:55:41: error[style, Z023]: 'type' parameter should come before 'Allocator'
//   | fn order(a: std.mem.Allocator, comptime T: type) T {
// rules.zig:57:22: error[style, Z018]: redundant @as(u32, ...): type u32 already known from context
//   | const max: u32 = @as(u32, 1);
// rules.zig:58:25: error[style, Z029]: redundant @as(u32, ...): type u32 already known from context
//   | const list = [_]u32{@as(u32, 2)};
// rules.zig:60:9: error[style, Z028]: inline @import; assign to a top-level const
//   | _ = @import("std").math.maxInt(u8);
// rules.zig:65:11: error[style, Z034]: print() has no format placeholders and empty args; use writeAll() instead
//   | try w.print("hello\n", .{});
// rules.zig:68:7: error[style, Z007]: duplicate import '"builtin"'
//   | const unused_import = @import("builtin");
// rules.zig:68:7: error[style, Z013]: unused import 'unused_import'
//   | const unused_import = @import("builtin");
// rules.zig:73:8: error[style, Z030]: deinit should set t.* = undefined
//   | fn deinit(t: *Thing, gpa: std.mem.Allocator) void {
// rules.zig:73:31: error[style, Z035]: use alias 'mem' instead of 'std.mem'
//   | fn deinit(t: *Thing, gpa: std.mem.Allocator) void {
// 31 errors
