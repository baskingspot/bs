//! exit: 7
//! stdout: "1\n16\n5\nBad\n"
//! Types with no possible value, as upstream classifies them: a struct
//! with a `noreturn` field, `enum(noreturn) {}`. `?S` is always null and
//! takes no space, `E!S` and a union with such fields lay out as upstream,
//! and a call returning one does not return.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

const S = struct { x: u64, n: noreturn };
const E = enum(noreturn) {};
const U = union(enum) { a: S, b: u8, c: E };

fn never() S {
    rt.exit(7);
}

fn pick(fail: bool) error{Bad}!S {
    if (fail) return error.Bad;
    return never();
}

fn main() callconv(.c) noreturn {
    var o: ?S = null;
    _ = &o;
    rt.printInt(@intFromBool(o == null));
    rt.printInt(@sizeOf(?S) + @sizeOf(error{Bad}!S) + @sizeOf(U));
    var u: U = .{ .b = 5 };
    _ = &u;
    switch (u) {
        .a => unreachable,
        .b => |b| rt.printInt(b),
        .c => unreachable,
    }
    if (pick(true)) |_| unreachable else |err| rt.print(@errorName(err));
    rt.print("\n");
    _ = never();
}
