//! exit: 0
//! stdout: "hello\n2\n3\n2\none\n"
const rt = @import("rt.zig");
pub export fn _start() callconv(.naked) noreturn { asm volatile ("call %[main:P]" : : [main] "X" (&main)); }
var c: bool = true;
var arr = [_]u8{ 1, 2, 3 };
var arr2 = [_]u8{ 4, 5 };
fn name(x: u8) []const u8 {
    return switch (x) {
        0 => "zero",
        1 => "one",
        else => "many",
    };
}
fn main() callconv(.c) noreturn {
    const s = if (c) "hello" else "hell";
    comptime if (@TypeOf(s) != [:0]const u8) unreachable;
    rt.print(s);
    rt.print("\n");
    const t = if (!c) &arr else &arr2;
    comptime if (@TypeOf(t) != []u8) unreachable;
    rt.printInt(t.len);
    const u = if (c) &arr else "ab";
    comptime if (@TypeOf(u) != []const u8) unreachable;
    rt.printInt(u.len);
    const m: [*]const u8 = &arr;
    const v = if (c) m else "xyz";
    comptime if (@TypeOf(v) != [*]const u8) unreachable;
    rt.printInt(v[1]);
    rt.print(name(1));
    rt.print("\n");
    rt.exit(0);
}
