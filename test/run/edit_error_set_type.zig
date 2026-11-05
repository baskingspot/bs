//! exit: 0
//! stdout: "5\n"
//! rebuild-replace: "error{ Bad, Empty, Zz }" "error{ Bad, Empty }"
//! An edit build after an error set gains a name. `check`'s body reads
//! nothing the edit changed, but its type does, so its function is
//! another item: loading the old body kept its inline result, whose hash
//! names the old error set's values, where a full build hashes the new.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

fn main() callconv(.c) noreturn {
    var n: u32 = 4;
    _ = &n;
    rt.printInt(check(n) catch 0);
    rt.exit(0);
}

const Error = error{ Bad, Empty, Zz };

fn check(n: u32) Error!u32 {
    if (n == 0) return error.Empty;
    if (n > 1000) return error.Bad;
    return n + 1;
}
