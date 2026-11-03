const std = @import("std");

const Point = struct {
    x: i32,
    y: i32,

    fn norm(p: Point) i32 {
        return p.x * p.x + p.y * p.y;
    }
};

const Color = enum { red, green, blue };

fn field(p: Point) i32 {
    return p.z;
}

fn tag() Color {
    return Color.gren;
}

fn method(p: Point) i32 {
    return p.nrom();
}

fn decl() void {
    _ = std.mem.indexOfScaler(u8, "ab", 'a');
}

pub fn main() void {
    const p: Point = .{ .x = 1, .y = 2 };
    _ = field(p);
    _ = tag();
    _ = method(p);
    decl();
}

// error
// lookup.zig:15:14: error[no-field]: no field named 'z' in struct 'lookup.Point'
//   | return p.z;
//   note lookup.zig:3:15: struct declared here: const Point = struct {
//   candidates: x, y
//   ref: main lookup.zig:32:14 (+3 std frames)
// lookup.zig:19:18: error[no-member]: enum 'lookup.Color' has no member named 'gren'
//   | return Color.gren;
//   note lookup.zig:12:15: enum declared here: const Color = enum { red, green, blue };
//   candidates: green
//   ref: main lookup.zig:33:12 (+3 std frames)
// lookup.zig:23:13: error[no-field]: no field or member function named 'nrom' in 'lookup.Point'
//   | return p.nrom();
//   note lookup.zig:3:15: struct declared here: const Point = struct {
//   candidates: norm
//   ref: main lookup.zig:34:15 (+3 std frames)
// lookup.zig:27:16: error[no-member]: root source file struct 'mem' has no member named 'indexOfScaler'
//   | _ = std.mem.indexOfScaler(u8, "ab", 'a');
//   note std/mem.zig:1:1: struct declared here
//   candidates: indexOfScalar
//   ref: main lookup.zig:35:9 (+3 std frames)
// 4 errors
