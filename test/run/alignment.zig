//! exit: 0
//! stdout: "16\n16\n8\n8\n1\n1\n0\n1\n0\n"
//! Explicit alignment on zero-bit struct fields and on global
//! declarations.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

// A zero-bit field with align(n) aligns the struct but takes no space.
const B = struct {
    x: u8,
    _: void align(16) = {},
};
const C = struct {
    a: u8,
    _: void align(8) = {},
    b: u8,
};

var small: u8 align(16) = 1;
var pad: u8 = 2;
const table: [3]u32 align(64) = .{ 1, 2, 3 };

fn main() callconv(.c) noreturn {
    rt.printInt(@alignOf(B));
    rt.printInt(@sizeOf(B));
    rt.printInt(@alignOf(C));
    rt.printInt(@sizeOf(C));
    // The declaration's alignment is part of its pointer type...
    rt.printInt(@intFromBool(@TypeOf(&small) == *align(16) u8));
    rt.printInt(@intFromBool(@TypeOf(&table) == *align(64) const [3]u32));
    rt.printInt(@intFromBool(@TypeOf(&table) == *const [3]u32));
    // ...and of its address.
    pad += 1;
    rt.printInt(small);
    rt.printInt(@intFromPtr(&small) % 16 + @intFromPtr(&table) % 64);
    rt.exit(0);
}
