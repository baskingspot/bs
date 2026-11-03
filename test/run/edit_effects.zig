//! exit: 0
//! stdout: "5\n"
//! rebuild-without: "    _ = early;\n"
//! Edit builds in which a function that is not analyzed again reuses a
//! memoized comptime call that made a type with a `comptime` block (an
//! export): `useB` hits the memo entry, and the comptime evaluator folds
//! the call into its lowering of `g`, which `useU` runs. When `early` no
//! longer makes the types first, loading either function must still
//! bring up its type's effects, as a full build does.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

fn Make(comptime n: u8) type {
    return struct {
        comptime {
            @export(&v, .{ .name = "edit_effects_made" ++ [_]u8{'0' + n} });
        }
        var v: u32 = n;
    };
}

fn g(x: u32) u32 {
    _ = Make(2);
    return x + 1;
}

// Makes both types first, and runs `g` in the walker until the evaluator
// lowers it.
const early = blk: {
    _ = Make(1);
    _ = g(0) + g(1) + g(2) + g(3);
    break :blk 0;
};

fn useB() u32 {
    _ = Make(1);
    return 0;
}

fn useU() u32 {
    return comptime g(4);
}

fn main() callconv(.c) noreturn {
    _ = early;
    rt.printInt(useB() + useU());
    rt.exit(0);
}
