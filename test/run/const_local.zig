//! exit: 0
//! stdout: "16\n10\n6\n3\n12\n"
const rt = @import("rt.zig");
pub const panic = rt.panic;
pub export fn _start() callconv(.naked) noreturn { asm volatile ("call %[main:P]" : : [main] "X" (&main)); }
const S = struct { a: u32, b: [2]u8 = .{ 7, 8 }, c: ?u16 = null };
const U = union(enum) { x: u32, y: void };
var rv: u32 = 9;
fn main() callconv(.c) noreturn {
    const a: [3]i32 = .{ 1, 2, 3 };
    comptime if (a[1] != 2) unreachable;
    const s: S = .{ .a = 5 };
    comptime if (s.b[1] != 8 or s.c != null or s.a != 5) unreachable;
    const o: ?S = .{ .a = 6, .c = 3 };
    comptime if (o.?.c.? != 3) unreachable;
    const u: U = .{ .y = {} };
    comptime if (u != .y) unreachable;
    const types: [2]type = .{ u8, u16 };
    comptime if (types[1] != u16) unreachable;
    const t = .{ u8, 3 };
    comptime if (t[0] != u8) unreachable;
    // Runtime-known parts keep the local runtime.
    const r: S = .{ .a = rv };
    rt.printInt(r.a + r.b[0]);
    const arr: [2]u32 = .{ rv, 1 };
    rt.printInt(arr[0] + arr[1]);
    var sum: i32 = 0;
    for (a) |x| sum += x;
    rt.printInt(@intCast(sum));
    const p = &a;
    rt.printInt(@intCast(p[2]));
    rt.printInt(s.a + s.b[0]);
    rt.exit(0);
}
