//! exit: 0
//! stdout: "1\n1\n1\n1\n1\n"
//! Debug fills undefined memory with 0xaa, as upstream: small values with
//! stores, large ones (here, past 128 bytes) with `rep stosb`, both for
//! an undefined local and for `undefined` stored through a pointer.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

fn allAa(bytes: []const volatile u8) bool {
    for (bytes) |b| if (b != 0xaa) return false;
    return true;
}

fn local(comptime n: usize) bool {
    var buf: [n]u8 = undefined;
    return allAa(&buf);
}

const Odd = extern struct { a: [125]u8, b: u32 };

fn stored(p: *volatile [3000]u8) bool {
    @memset(p, 0);
    p.* = undefined;
    return allAa(p);
}

fn main() callconv(.c) noreturn {
    rt.printInt(@intFromBool(local(128)));
    rt.printInt(@intFromBool(local(129)));
    rt.printInt(@intFromBool(local(64 * 1024)));
    var odd: Odd = undefined;
    rt.printInt(@intFromBool(allAa(@as(*const volatile [@sizeOf(Odd)]u8, @ptrCast(&odd)))));
    var big: [3000]u8 = undefined;
    rt.printInt(@intFromBool(stored(&big)));
    rt.exit(0);
}
