const std = @import("std");

fn stdout() void {
    const out = std.io.getStdOut().writer();
    _ = out;
}

fn list() void {
    var l = std.ArrayList(u8).init(std.heap.page_allocator);
    _ = &l;
}

fn cwd() void {
    _ = std.fs.cwd();
}

fn info() bool {
    return @typeInfo(u8).Int.signedness == .unsigned;
}

pub fn main() void {
    stdout();
    list();
    cwd();
    _ = info();
}

// error
// migration.zig:4:21: error[no-member]: root source file struct 'std' has no member named 'io'
//   | const out = std.io.getStdOut().writer();
//   note std/std.zig:1:1: struct declared here
//   candidates: Io
//   hint: std.io is now std.Io: take `init: std.process.Init` in main, then `var w = std.Io.File.stdout().writer(init.io, &buffer);`, print with `w.interface.print(...)` and `w.interface.flush()`; std.debug.print writes to stderr without io
//   ref: main migration.zig:22:11 (+3 std frames)
// migration.zig:9:30: error[no-member]: struct 'array_list.Aligned(u8,null)' has no member named 'init'
//   | var l = std.ArrayList(u8).init(std.heap.page_allocator);
//   note std/array_list.zig:638:12: struct declared here: return struct {
//   hint: std.ArrayList is unmanaged: `var list: std.ArrayList(T) = .empty;`, then pass the allocator to each call (`list.append(gpa, x)`, `list.deinit(gpa)`); std.array_list.Managed keeps the old API; to print into a byte buffer, use std.Io.Writer.Allocating
//   ref: main migration.zig:23:9 (+3 std frames)
// migration.zig:14:15: error[no-member]: root source file struct 'fs' has no member named 'cwd'
//   | _ = std.fs.cwd();
//   note std/fs.zig:1:1: struct declared here
//   hint: std.fs.cwd() is now std.Io.Dir.cwd(), and its methods take io: `std.Io.Dir.cwd().openFile(io, path, .{})`, with io from main's `init: std.process.Init` (`init.io`)
//   ref: main migration.zig:24:8 (+3 std frames)
// migration.zig:18:26: error[no-field]: no field named 'Int' in union 'lang.Type'
//   | return @typeInfo(u8).Int.signedness == .unsigned;
//   note std/lang.zig:640:18: union declared here: pub const Type = union(enum) {
//   candidates: int
//   hint: @typeInfo's fields are lowercase: .int, .pointer, .@"struct", .@"enum", .@"union", .@"fn"
//   ref: main migration.zig:25:13 (+3 std frames)
// 4 errors
