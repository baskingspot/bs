//! signal: ABRT
//! stdout: "4\n0\n17\n17\n"
//! stderr: "panic: incorrect alignment\n"
//! `@alignCast` checks the address of the pointer it casts, also when the
//! result is a slice (from a pointer to an array or another slice) or the
//! operand is one, as upstream's ptrCastFull; an empty slice may have any
//! address (langref's test_incorrect_pointer_alignment).
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

var array align(4) = [_]u32{ 0x11111111, 0x11111111 };

noinline fn slice(bytes: []u8, lo: usize, hi: usize) usize {
    const p: []align(4) u8 = @alignCast(bytes[lo..hi]);
    return p.len;
}

noinline fn many(bytes: []u8, lo: usize) u8 {
    const p: [*]align(4) u8 = @alignCast(bytes[lo..].ptr);
    return p[0];
}

noinline fn fromArray(bytes: []u8) u8 {
    const p: []align(4) u8 = @alignCast(bytes[1..5]);
    return p[0];
}

fn main() callconv(.c) noreturn {
    const b: []u8 = @ptrCast(array[0..]);
    rt.printInt(slice(b, 4, 8));
    rt.printInt(slice(b, 1, 1));
    rt.printInt(many(b, 4));
    rt.printInt(many(b, 0));
    _ = fromArray(b);
    rt.exit(0);
}
