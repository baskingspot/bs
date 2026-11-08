//! ziglint's semantic-mode tests of the rules Sema answers with types
//! (Z010, Z027, Z029, Z034), and where bs's answer differs from ziglint's
//! (test/lint/README.md).

const std = @import("std");

const Point = struct {
    x: u32 = 0,

    fn move(self: *Point, by: Point) void {
        self.x += by.x;
    }

    fn origin(p: Point) bool {
        return p.x == 0;
    }
};

const Color = enum { red, green };

const Error = error{Bad};

pub const E = error{Oops} || error{};

const Defaults = struct {
    const point: Point = .{ .x = 0 };
};

// Z010 in returns: the type is what the function returns, through
// optionals and error unions.
fn makePoint() Point {
    return Point{ .x = 1 };
}

fn maybePoint(ok: bool) !?Point {
    if (!ok) return error.Bad;
    return Point{};
}

fn red() Color {
    return Color.red;
}

// ziglint flags these; bs does not. An error set's member stays as written
// (`Z010: allow merged error set members in return`), and `.point` would
// name `Point.point`, not `Defaults.point`.
fn fail() Error!void {
    return Error.Bad;
}

fn oops() E!void {
    return E.Oops;
}

fn defaultPoint() Point {
    return Defaults.point;
}

fn takesPoint(p: Point) u32 {
    return p.x;
}

fn takesU32(v: u32) u32 {
    return v;
}

fn takesOptional(v: ?u8) bool {
    return v != null;
}

fn takesU64(v: u64) u64 {
    return v;
}

// Nothing in a generic function: its types depend on `T`, and the `@as`
// is redundant only where `T` is 64 bits.
fn widen(comptime T: type, v: T) u64 {
    return takesU64(@as(@Int(.unsigned, @bitSizeOf(T)), @bitCast(v)));
}

const MyType = struct {
    value: u32,
    // ziglint-ignore: Z020
    pub fn setValue(self: *@This(), v: u32) void {
        self.value = v;
    }
};

// Z027's tests that compile in Zig 0.17.1: an instance has no declarations
// but its methods (`instance.bar` and `instance.staticFn()` are compile
// errors), so bs has nothing to report.
const Foo = struct {
    // ziglint-ignore: Z019
    const Self = @This();
    field: u32,
    const bar = 42;
    // ziglint-ignore: Z020
    fn getField(self: *@This()) u32 {
        return self.field;
    }
    fn getFieldSelf(self: *Self) u32 {
        return self.field;
    }
    fn getFieldNamed(self: *Foo) u32 {
        return self.field;
    }
};

fn arguments(w: *std.Io.Writer, gpa: std.mem.Allocator) !void {
    var p: Point = .{ .x = 0 };
    // Z010 in arguments, through a local receiver, which ziglint cannot
    // type, and after no receiver for `Point.origin`.
    _ = takesPoint(Point{ .x = 2 });
    p.move(Point{ .x = 3 });
    _ = Point.origin(Point{ .x = 0 });
    // Z029: `@as` to the parameter's type, but not to its payload.
    _ = takesU32(@as(u32, 4));
    _ = takesOptional(@as(u8, 5));
    var instance: MyType = .{ .value = 0 };
    instance.setValue(@as(u32, 42));
    var foo: Foo = .{ .field = 0 };
    _ = foo.getField() + foo.getFieldSelf() + foo.getFieldNamed() + foo.field + Foo.bar;
    // Z034, through a parameter and a field ziglint cannot type, but not
    // with a placeholder.
    try w.print("hello\n", .{});
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try aw.writer.print("hello", .{});
    try w.print("{d}\n", .{p.x});
}

// Not referenced: Sema reports nothing here.
fn unreferenced() Point {
    return Point{ .x = 9 };
}

fn run() !void {
    _ = makePoint();
    _ = try maybePoint(true);
    _ = red();
    fail() catch |err| std.debug.assert(err == error.Bad);
    oops() catch |err| std.debug.assert(err == error.Oops);
    _ = defaultPoint();
    _ = widen(u64, 1) + widen(u32, 1);
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try arguments(&w, std.heap.page_allocator);
}

export fn entry() void {
    run() catch @panic("run");
}

test {
    entry();
}

// error
// main.zig:32:12: error[style, Z010]: prefer `.{ .x = 1 }` over `Point{ .x = 1 }`
//   | return Point{ .x = 1 };
// main.zig:37:12: error[style, Z010]: prefer `.{}` over `Point{}`
//   | return Point{};
// main.zig:41:12: error[style, Z010]: prefer `.red` over `Color.red`
//   | return Color.red;
// main.zig:113:20: error[style, Z010]: prefer `.{ .x = 2 }` over `Point{ .x = 2 }`
//   | _ = takesPoint(Point{ .x = 2 });
// main.zig:114:12: error[style, Z010]: prefer `.{ .x = 3 }` over `Point{ .x = 3 }`
//   | p.move(Point{ .x = 3 });
// main.zig:115:22: error[style, Z010]: prefer `.{ .x = 0 }` over `Point{ .x = 0 }`
//   | _ = Point.origin(Point{ .x = 0 });
// main.zig:117:18: error[style, Z029]: redundant @as(u32, ...): type u32 already known from context
//   | _ = takesU32(@as(u32, 4));
// main.zig:120:23: error[style, Z029]: redundant @as(u32, ...): type u32 already known from context
//   | instance.setValue(@as(u32, 42));
// main.zig:125:11: error[style, Z034]: print() has no format placeholders and empty args; use writeAll() instead
//   | try w.print("hello\n", .{});
// main.zig:128:19: error[style, Z034]: print() has no format placeholders and empty args; use writeAll() instead
//   | try aw.writer.print("hello", .{});
// 10 errors
