//! signal: ABRT
//! stdout: "42\n1\n42\n"
//! stderr: "panic: cast causes pointer to be null\n"
//! upstream-signal: SEGV
const rt = @import("rt.zig");
pub export fn _start() callconv(.naked) noreturn { asm volatile ("call %[main:P]" : : [main] "X" (&main)); }
const T = struct { x: u32 };
var t: T = .{ .x = 42 };
var np: ?*anyopaque = null;
fn get(userdata: ?*anyopaque) u32 {
    const p: *T = @ptrCast(@alignCast(userdata));
    return p.x;
}
fn main() callconv(.c) noreturn {
    rt.printInt(get(&t));
    const o: ?*T = @ptrCast(@alignCast(np));
    rt.printInt(@intFromBool(o == null));
    const back: ?*anyopaque = @ptrCast(&t);
    rt.printInt(get(back));
    comptime if (@as(?*const u8, @ptrCast(@as(?*const u32, null))) != null) unreachable;
    _ = get(np);
    rt.exit(0);
}
