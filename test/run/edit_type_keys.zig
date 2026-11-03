//! exit: 0
//! stdout: "8\n12\n"
//! rebuild-replace: "    rt.printInt(F(u8).size);\n" "    rt.printInt(F(u16).size + @sizeOf(F(u16).E));\n    rt.printInt(F(u8).size);\n"
//! An edit build that loads a declaration of one instance of a generic
//! type, which reads a type it shares with the other instances (`D` and
//! `E` capture nothing of `T`). The first build makes them for `F(u16)`;
//! their keys, and so the loaded declaration's dependencies, must be the
//! ones a full build gives when only `F(u8)` makes them.
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
        const zero: T = 0;
        const size = blk: {
            const D = struct { x: u32, y: u8 };
            break :blk @sizeOf(D) + zero;
        };
        const E = struct { a: u64, b: u32 };
    };
}

fn eSize() u64 {
    return @sizeOf(F(u8).E) - 4;
}

fn main() callconv(.c) noreturn {
    rt.printInt(F(u8).size);
    rt.printInt(eSize());
    rt.exit(0);
}
