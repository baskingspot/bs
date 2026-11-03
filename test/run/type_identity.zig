//! exit: 0
//! stdout: "1\n1\n1\n1\n1\n1\n1\n"
//! Container type identity follows upstream: the same ZIR instruction with
//! equal captures is the same type, whatever made it.
const rt = @import("rt.zig");
pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}
fn Wrap(comptime I: type) type {
    const bits = @typeInfo(I).int.bits;
    return struct {
        x: @Int(.unsigned, bits),
        const Inner = struct { y: @Int(.signed, bits) };
    };
}
fn Plain(comptime n: u32) type {
    _ = n;
    return struct {};
}
fn main() callconv(.c) noreturn {
    rt.printInt(@intFromBool(Wrap(u8) == Wrap(i8)));
    rt.printInt(@intFromBool(Wrap(u8) != Wrap(u16)));
    rt.printInt(@intFromBool(Wrap(u8).Inner == Wrap(i8).Inner));
    rt.printInt(@intFromBool(Wrap(u8).Inner != Wrap(u16).Inner));
    rt.printInt(@intFromBool(Plain(1) == Plain(2)));
    rt.printInt(@intFromBool(struct {} != struct {}));
    comptime var types: [2]type = undefined;
    inline for (0..2) |i| types[i] = struct {};
    rt.printInt(@intFromBool(types[0] == types[1]));
    rt.exit(0);
}
