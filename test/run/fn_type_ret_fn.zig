//! exit: 0
//! stderr: "3 1 3 1 2 0 2 21\n"
//! targets: x86_64-linux aarch64-macos aarch64-linux

// A function type whose return type is another function type: each keeps
// its own parameters. AstGen puts the outer parameters before the return
// type's function type in one block, and the inner type must not take
// them (revo's translated `signal` reported "expected 0 argument(s)").
const std = @import("std");

const Outer = fn (c_int, c_int, c_int) *const fn (u8) void;
const OuterC = fn (c_int, ?*const fn (c_int) callconv(.c) void) callconv(.c) ?*const fn (c_int) callconv(.c) void;
const Nested = fn (u8, u8) *const fn () *const fn (u8) void;

// Defined below under the same name, so the test needs no libc.
extern fn bs_signal(c_int, ?*const fn (c_int) callconv(.c) void) ?*const fn (c_int) callconv(.c) void;

fn handler(_: c_int) callconv(.c) void {}

fn pick(a: u8, b: u8, c: u8) *const fn (u8) u8 {
    _ = .{ a, b, c };
    return &twice;
}

fn twice(x: u8) u8 {
    return x * 2 + 1;
}

fn paramCount(comptime F: type) usize {
    return @typeInfo(F).@"fn".param_types.len;
}

fn retFn(comptime F: type) type {
    return @typeInfo(@typeInfo(F).@"fn".return_type.?).pointer.child;
}

pub fn main() void {
    const ret_inner = @typeInfo(@typeInfo(OuterC).@"fn".return_type.?).optional.child;
    std.debug.print("{d} {d} {d} {d} {d} {d} {d} {d}\n", .{
        paramCount(Outer),
        paramCount(retFn(Outer)),
        paramCount(@TypeOf(pick)),
        paramCount(@typeInfo(ret_inner).pointer.child),
        paramCount(Nested),
        paramCount(retFn(Nested)),
        paramCount(@TypeOf(bs_signal)),
        pick(1, 2, 3)(10),
    });
    // The call the translated header makes: two arguments, not zero.
    _ = bs_signal(2, &handler);
}

fn signalImpl(_: c_int, h: ?*const fn (c_int) callconv(.c) void) callconv(.c) ?*const fn (c_int) callconv(.c) void {
    return h;
}

comptime {
    @export(&signalImpl, .{ .name = "bs_signal" });
}
