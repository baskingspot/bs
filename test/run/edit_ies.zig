//! exit: 0
//! stdout: "seven\n"
//! rebuild-without: "fn bar() !u64 {\n    return try foo(7);\n}\n"
//! rebuild-without: "    if (bar()) |_| {} else |e| switch (e) {\n        error.Seven => rt.print(\"seven\\n\"),\n    }\n"
//! An edit build that adds the first reader of an inferred error set
//! whose function is loaded, not analyzed: the set must keep its names.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

pub fn foo(x: u64) !u64 {
    if (x == 7) return error.Seven;
    return x;
}

fn bar() !u64 {
    return try foo(7);
}

fn main() callconv(.c) noreturn {
    _ = &foo;
    if (bar()) |_| {} else |e| switch (e) {
        error.Seven => rt.print("seven\n"),
    }
    rt.exit(0);
}
