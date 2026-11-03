//! exit: 0
//! stdout: "hello, world\n6\n1\n9\n21\n1\n1\n7\n13\nabcxyz\n1\n3\n1\n42\n"
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

const greeting = "hello, " ++ "world\n";
const parts: []const u8 = "ab" ++ "c";

var g: [3]u8 = .{ 'x', 'y', 'z' };

fn sum(args: anytype) u64 {
    var s: u64 = 0;
    inline for (args) |a| s += a;
    return s;
}

fn main() callconv(.c) noreturn {
    rt.print(greeting);
    var a: [2]u32 = .{ 1, 2 };
    var b: [3]u32 = .{ 3, 4, 5 };
    _ = &a;
    _ = &b;
    const c = a ++ b;
    rt.printInt(c.len + 1);
    rt.printInt(@intFromBool(@TypeOf(c) == [5]u32));
    rt.printInt(c[0] + c[1] + c[2] + c[4] - 2);
    // Tuples concatenate to a tuple, with runtime and comptime fields.
    var x: u32 = 6;
    _ = &x;
    const t = .{ 1, 2 } ++ .{ x, 3 } ++ .{9};
    rt.printInt(sum(t));
    rt.printInt(@intFromBool(t.len == 5));
    // A tuple and an array give an array of the array's element type.
    const ta = .{ 1, 2 } ++ [_]u8{ 3, 4 };
    rt.printInt(@intFromBool(@TypeOf(ta) == [4]u8));
    rt.printInt(ta[0] + ta[3] + ta[1]);
    // Sentinels: kept when equal or alone, dropped when they differ.
    const s1 = "ab" ++ [_]u8{'c'};
    const s2 = [_:1]u8{ 2, 3 } ++ [_:2]u8{4};
    comptime if (@TypeOf(s1) != *const [3:0]u8) unreachable;
    comptime if (@TypeOf(s2) != [3]u8) unreachable;
    rt.printInt(s1.len + s2[0] + s2[1] + s2[2] + 3 - 3 + 1);
    // A pointer to runtime memory and a comptime slice.
    const r = parts ++ &g;
    rt.print(r ++ "\n");
    rt.printInt(@intFromBool(@TypeOf(r) == *const [6]u8));
    g[0] = 'q';
    rt.printInt(r.len / 2);
    rt.printInt(@intFromBool(r[3] == 'x'));
    const empty = .{} ++ .{42};
    rt.printInt(empty[0]);
    rt.exit(0);
}
