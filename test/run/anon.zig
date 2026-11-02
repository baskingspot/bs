//! exit: 0
//! stdout: "11\n3\n0\n23\n0\n"
const rt = @import("rt.zig");

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

const P = struct { x: u32, y: u32 = 5 };
// Anonymous struct and array literals without a result type.
fn sum(args: anytype) u64 {
    var total: u64 = 0;
    total += args.a + args.b + args.c;
    return total;
}
fn count(args: anytype) usize {
    return args.len;
}
fn takeP(p: P) u32 {
    return p.x * 10 + p.y;
}
fn main() callconv(.c) noreturn {
    var r: u32 = 3;
    _ = &r;
    rt.printInt(sum(.{ .a = 1, .b = r, .c = @as(u8, 7) }));
    rt.printInt(count(.{ 1, r, 3 }));
    rt.printInt(count(.{}));
    rt.printInt(takeP(.{ .x = 2, .y = r }));
    // Each literal is its own struct type.
    rt.printInt(@intFromBool(@TypeOf(.{ .q = 1, .w = r }) == @TypeOf(.{ .q = 1, .w = r })));
    rt.exit(0);
}
