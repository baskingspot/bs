//! exit: 0
//! stdout: "1\n4\n1\n8\n11\n1\n1\n8\n8\n7\n1\n1\n123\n124\n3\n"
//! Tuple @fieldParentPtr and @offsetOf, comptime calls of generic functions
//! returning comptime-only types, generic function coercion, comptime
//! pointer equality, enum literal peers, @Struct field attributes, @Fn, and
//! the noreturn tag of an empty enum, and a struct in a generic return
//! type, which is the same type wherever a call instantiates it.
const rt = @import("rt.zig");
pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}
fn b(x: bool) void {
    rt.printInt(@intFromBool(x));
}
// A generic function whose instantiation returns a comptime-only type is
// called at comptime.
fn info(comptime T: type, comptime x: u8) switch (@typeInfo(T)) {
    .int => struct { a: u8, v: comptime_int },
    else => void,
} {
    return .{ .a = x, .v = 5 };
}
fn add(comptime T: type, x: T, y: T) error{Overflow}!T {
    return x + y;
}
fn doMath(comptime f: fn (comptime type, i32, i32) error{Overflow}!i32, x: i32, y: i32) i32 {
    return f(i32, x, y) catch unreachable;
}
fn generic(comptime T: type, p: *const T) anyerror!void {
    _ = p;
}
const Foo = struct { x: u32 };
const foo_array: [2]Foo = undefined;
fn Bar(foo_slice: []const Foo) type {
    return struct {
        const foo_ptr: [*]const Foo = foo_slice.ptr;
    };
}
fn same(x: anytype, y: anytype) bool {
    return @TypeOf(x, y) == @TypeOf(y);
}
fn foo(_: anytype, x: u32) u32 {
    return x;
}
fn foo2(_: anytype, x: anytype) u32 {
    return x;
}
fn foo3(_: anytype, _: void) void {}
fn higherOrder(x: anytype, f: fn (@TypeOf(x), void) void) void {
    _ = f(x, {});
}
const Air = struct {
    extra: []const u32,
    fn extraData(air: Air, comptime T: type, index: usize) struct { data: T, end: usize } {
        return .{ .data = @intCast(air.extra[index]), .end = index + 1 };
    }
};
const Legalize = struct {
    air: Air,
    fn extraData(l: *const Legalize, comptime T: type, index: usize) @TypeOf(Air.extraData(undefined, T, undefined)) {
        return l.air.extraData(T, index);
    }
};

fn main() callconv(.c) noreturn {
    var tuple: struct { u32, u32 } = .{ 1, 2 };
    b(&tuple == @as(@TypeOf(&tuple), @fieldParentPtr("1", &tuple[1])));
    var one: u32 = 1;
    _ = &one;
    const Anon = @TypeOf(.{ .foo = one, .bar = one });
    rt.printInt(@offsetOf(Anon, "bar"));
    comptime var cv: u8 = 0;
    const t = .{&cv};
    b(@TypeOf(t) == struct { *u8 });
    const r = info(u8, 3);
    rt.printInt(r.a + r.v);
    rt.printInt(@intCast(doMath(add, 5, 6)));
    const coerced: fn (comptime type, *u8) anyerror!void = generic;
    var x: u8 = 1;
    coerced(u8, &x) catch unreachable;
    const T = Bar(&foo_array);
    b(comptime T.foo_ptr == &foo_array);
    const E = enum { foo, bar };
    b(same(.foo, E.bar));
    const S = @Struct(.auto, null, &.{ "a", "b" }, &.{ u8, u32 }, &.{ .{ .@"align" = 8 }, .{ .@"comptime" = true, .default_value_ptr = &@as(u32, 7) } });
    rt.printInt(@alignOf(S));
    rt.printInt(@sizeOf(S));
    const s: S = .{ .a = 1 };
    rt.printInt(s.b);
    b(@Fn(&.{ c_int, *u8 }, &.{ .{}, .{ .@"noalias" = true } }, void, .{ .@"callconv" = .c }) == fn (c_int, noalias *u8) callconv(.c) void);
    b(@typeInfo(enum {}).@"enum".tag_type == noreturn);
    const c1: fn (anytype, anytype) u32 = foo;
    rt.printInt(c1({}, 123));
    const c2: fn (anytype, u32) u32 = foo2;
    rt.printInt(c2({}, 124));
    const l: Legalize = .{ .air = .{ .extra = &.{ 1, 2, 3 } } };
    rt.printInt(l.extraData(u16, 1).data + l.extraData(u8, 0).end);
    const bar: fn (anytype, anytype) void = foo3;
    higherOrder(1, bar);
    rt.exit(0);
}
