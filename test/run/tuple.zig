//! exit: 0
//! stdout: "309\n4\n3\n42\n8\n1\n0\n1\n"
const rt = @import("rt.zig");
pub const panic = rt.panic;
pub export fn _start() callconv(.naked) noreturn { asm volatile ("call %[main:P]" : : [main] "X" (&main)); }
const T = struct { u8, u16, comptime u32 = 7 };
const E = struct {};
fn take(t: struct { u32, bool }) u32 {
    return if (t[1]) t[0] else 0;
}
fn main() callconv(.c) noreturn {
    var t: T = .{ 1, 300 };
    t[0] += 1;
    rt.printInt(t[0] + t[1] + t[2]);
    rt.printInt(@sizeOf(T));
    rt.printInt(t.len);
    rt.printInt(take(.{ 41, true }) + 1);
    const a: struct { u8, u8 } = .{ 3, 4 };
    const b = a ++ .{5};
    rt.printInt(b[2] + b[0]);
    rt.printInt(@intFromBool(T == struct { u8, u16, comptime u32 = 7 }));
    rt.printInt(@sizeOf(E));
    // A tuple's length is a usize, as an array's (`10 * t.len * x` with
    // a u7 `x` must not overflow u7).
    const kvs = .{ .{ "a", 1 }, .{ "b", 2 } };
    var x: u7 = 7;
    _ = &x;
    rt.printInt(@intFromBool(@TypeOf(t.len) == usize and 10 * kvs.len * x == 140));
    rt.exit(0);
}
