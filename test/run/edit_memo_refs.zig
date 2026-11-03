//! exit: 0
//! stdout: "f1\n"
//! rebuild-replace: "    a[0]();\n" "    b[1]();\n    a[0]();\n"
//! An edit build that loads a declaration whose comptime call hit the
//! memo entry another declaration's call made. The first build evaluates
//! `b` first, so `a` reuses `mk`'s result; `a` must still refer to `f1`
//! and `f2`, as in a full build, once `b` is gone and `a` is loaded.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

fn f1() void {
    rt.print("f1\n");
}

fn f2() void {
    rt.print("f2\n");
}

fn mk() [2]*const fn () void {
    return .{ f1, f2 };
}

const a = mk();
const b = mk();

fn main() callconv(.c) noreturn {
    a[0]();
    rt.exit(0);
}
