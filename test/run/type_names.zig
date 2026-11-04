//! exit: 0
//! stdout: "same\n"
//! A type that two creators name differently (it captures nothing that
//! tells them apart) is named after the least creator by key, not the
//! first, so that the name does not depend on analysis order. Its name is
//! read before the second creator makes it (`F(u8).S` has the lesser key,
//! so the name changes after the read): the build is redone with the
//! final names pinned, and both reads see the same name, as upstream's,
//! which are its first creator's.
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
        const S = struct {};
        const t: T = 0;
    };
}

const early = @typeName(F(u16).S);
const late = blk: {
    _ = F(u8);
    break :blk @typeName(F(u8).S);
};

fn main() callconv(.c) noreturn {
    rt.print(if (eql(early, late)) "same\n" else "different\n");
    rt.exit(0);
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}
