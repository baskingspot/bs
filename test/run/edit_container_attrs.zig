//! exit: 0
//! stdout: "12\n4\n0\n"
//! rebuild-replace: "extern struct" "struct"
//! rebuild-replace: "extern union" "union"
//! rebuild-without: ", _"
//! A container's attributes change its layout, but AstGen 0.17.1 leaves
//! them out of the fields hash that is its source hash: a struct's
//! `extern`, a union's kind, an enum's `_`. The edit build must see each
//! as an edit to the layout (`seeds.srcHash`; the edit hunter, seed 5202,
//! where removing an enum's `_` gave no error).
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

const S = extern struct { a: u8, b: u32, c: u8 };
const U = extern union { a: u8, b: u32 };
const E = enum(u8) { a, b, _ };

fn main() callconv(.c) noreturn {
    rt.printInt(@sizeOf(S));
    rt.printInt(@sizeOf(U));
    rt.printInt(@intFromBool(@typeInfo(E).@"enum".mode == .exhaustive));
    rt.exit(0);
}
