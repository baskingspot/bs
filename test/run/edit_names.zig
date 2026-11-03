//! exit: 0
//! stdout: "one\n"
//! rebuild-without: "    rt.print(\"one\");\n"
//! An edit above a `comptime` block whose anonymous type has a function:
//! the function is loaded, not analyzed, so the type's name, which its
//! symbol carries, must not depend on instructions above the block.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

fn main() callconv(.c) noreturn {
    rt.print("one");
    rt.print("\n");
    rt.exit(0);
}

comptime {
    _ = &struct {
        fn check(e: error{A}) anyerror {
            return e;
        }
    }.check;
}
