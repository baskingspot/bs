//! exit: 0
//! stdout: "7\n9\n"
//! rebuild-replace: "    const k = @as(u32, 7);\n" "    const k = 7;\n"
//! An edit build after an edit to a declaration of `S` that comes before
//! its fields in the ZIR and adds instructions there. `S`'s layout stays
//! green; the anonymous struct its field's type makes must keep the key a
//! full build gives it (numbered from the field's type body, not from
//! `S`'s instruction), and so must `Box`'s instance and its function.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

fn Box(comptime T: type) type {
    return struct {
        v: T,
        fn get(b: @This()) u32 {
            return b.v.a + b.v.b;
        }
    };
}

const S = struct {
    const k = @as(u32, 7);
    b: Box(struct { a: u32, b: u32 }) = .{ .v = .{ .a = 4, .b = 5 } },
};

fn main() callconv(.c) noreturn {
    const s: S = .{};
    rt.printInt(S.k);
    rt.printInt(s.b.get());
    rt.exit(0);
}
