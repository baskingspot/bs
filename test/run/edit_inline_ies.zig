//! exit: 0
//! stdout: "7\n"
//! rebuild-replace: "return try f(n - 1) + 2;" "return try f(n - 1) + 1;"
//! An edit build that loads `f`, which inlines `g`, after an edit to `g`.
//! Deciding whether `f` still inlines `g` analyzes `g` while `f` is in
//! progress, and `g` reads `f`'s inferred error set: a dependency loop a
//! full build never meets, since it analyzes `g` after `f`. The edit
//! build must give up on loading `f` instead of reporting it.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

fn main() callconv(.c) noreturn {
    rt.printInt(f(3) catch 0);
    rt.exit(0);
}

fn f(n: u32) !u32 {
    if (n > 100) return error.Big;
    return (g(n) catch null) orelse 1;
}

fn g(n: u32) error{Big}!?u32 {
    if (n == 0) return null;
    return try f(n - 1) + 2;
}
