//! exit: 0
//! stderr: "101 102 102\n"
//! A call through a callee computed just before it (an extern's address,
//! a loaded function pointer) whose result is stored to a variable read
//! by its argument: the callee is not computed in the variable's
//! register, which still holds the argument.
const std = @import("std");
export fn addOne(x: i32) callconv(.c) i32 {
    return x + 1;
}
var fp: *const fn (i32) callconv(.c) i32 = &addOne;
noinline fn f(x: i32) i32 {
    return x + 100;
}
noinline fn viaExtern() i32 {
    const add = @extern(*const fn (i32) callconv(.c) i32, .{ .name = "addOne" });
    var x: i32 = 0;
    x = f(x);
    x = add(x);
    return x;
}
noinline fn viaPointer() i32 {
    var x: i32 = 1;
    x = f(x);
    x = fp(x);
    return x;
}
noinline fn twice() i32 {
    var x: i32 = 0;
    x = f(x);
    x = fp(x);
    x = fp(x);
    return x;
}
pub fn main() void {
    std.debug.print("{d} {d} {d}\n", .{ viaExtern(), viaPointer(), twice() });
}
