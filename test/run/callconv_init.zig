//! exit: 0
//! stderr: "4 5 6 7 true true\n"
//! `callconv` with a union initializer, as upstream's test/c_abi writes
//! it (`.{ .x86_64_sysv = .{} }`): the result type is
//! `std.lang.CallingConvention`, so the literal initializes the union. The
//! SysV convention is the target's C one, so the function types are the
//! same, and so they are through a typed constant and through `@Fn`.
const std = @import("std");

export fn sysv(x: i32) callconv(.{ .x86_64_sysv = .{} }) i32 {
    return x + 1;
}
fn auto(x: i32) callconv(.{ .auto = {} }) i32 {
    return x + 2;
}
const cc: std.lang.CallingConvention = .{ .x86_64_sysv = .{ .incoming_stack_alignment = null } };
fn typed(x: i32) callconv(cc) i32 {
    return x + 3;
}
const Reified = @Fn(&.{i32}, &@splat(.{}), i32, .{ .@"callconv" = .{ .x86_64_sysv = .{} } });

pub fn main() void {
    const p: *const fn (i32) callconv(.c) i32 = &sysv;
    const q: *const Reified = &typed;
    std.debug.print("{d} {d} {d} {d} {} {}\n", .{ p(3), auto(3), typed(3), q(4), @TypeOf(sysv) == fn (i32) callconv(.c) i32, Reified == @TypeOf(typed) });
}
