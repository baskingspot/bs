//! exit: 0
//! stdout: "1\n2\n"
//! rebuild-without: "    rt.printInt(F(u16).S.f() + 1);\n"
//! An edit build that analyzes `main`, which makes `F(u16).S`, and loads
//! `F(u8).S`'s declaration. `S` captures nothing of `T`, so both name
//! one type, and it takes the least creator's name: the loaded
//! declaration's offer counts as if it had been analyzed, so `S.f`'s
//! symbol is the one a full build gives.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

fn F(comptime T: type) type {
    return struct {
        const S = struct {
            fn f() u32 {
                return 1;
            }
        };
        const t: T = 0;
    };
}

const one = F(u8).S.f;

fn main() callconv(.c) noreturn {
    rt.printInt(one());
    rt.printInt(F(u16).S.f() + 1);
    rt.exit(0);
}
