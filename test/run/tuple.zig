//! exit: 0
//! stdout: "309\n4\n3\n42\n8\n1\n0\n"
const rt = @import("rt.zig");
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
    rt.exit(0);
}
