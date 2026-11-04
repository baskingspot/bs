//! exit: 0
//! stderr: "13\nOops 1\n11 7 3\n4 4\n"
//! Results of a few hundred kilobytes returned through an error union
//! take no frame copies (docs/slop/architecture.md, "Copy elision"):
//! the callee builds its result in the caller's memory, even though an
//! error-return-trace check reads it before the `ret` (`rvo_alloc`), and
//! `var x = f() catch unreachable` shares that memory with the call's
//! result (`payload_region`). `run` needs both to fit its 640 KiB stack.
//! An error writes only its code. In a loop, a failed call must leave
//! the variable it would have set as it was.
const std = @import("std");
const Inner = struct { head: [65536]u16, chain: [32768]u16, pos: u16 };
const Big = struct { a: u32, lookup: Inner, b: u32 };
noinline fn init(fail: bool) error{Oops}!Big {
    if (fail) return error.Oops;
    return .{ .a = 1, .lookup = .{ .head = @splat(7), .chain = undefined, .pos = 3 }, .b = 2 };
}
fn run(out: *u32) void {
    var x = init(false) catch unreachable;
    _ = &x;
    out.* = x.a + x.lookup.head[5] + x.lookup.pos + x.b;
}
const Small = struct { a: u64, b: u64, c: u64, pad: [6]u64 };
noinline fn small(i: u32) error{Stop}!Small {
    if (i == 2) return error.Stop;
    return .{ .a = i + 3, .b = i + 1, .c = 7, .pad = @splat(i) };
}
noinline fn twice() [2]u64 {
    var p = small(0) catch unreachable;
    var q = small(1) catch unreachable;
    p.a += 6;
    q.b *= 2;
    return .{ p.a + p.c - q.c, q.b };
}
pub fn main() !void {
    var r: u32 = 0;
    const t = try std.Thread.spawn(.{ .stack_size = 640 * 1024 }, run, .{&r});
    t.join();
    std.debug.print("{d}\n", .{r});
    if (init(true)) |v| {
        std.debug.print("{d}\n", .{v.a});
    } else |e| std.debug.print("{t} {d}\n", .{ e, @intFromBool(e == error.Oops) });
    var y: Small = .{ .a = 0, .b = 0, .c = 0, .pad = @splat(9) };
    var i: u32 = 0;
    while (i < 5) : (i += 1) y = small(i) catch break;
    const tw = twice();
    std.debug.print("{d} {d} {d}\n", .{ y.a + y.b + y.c - 3 + y.pad[5], y.c, i + 1 });
    std.debug.print("{d} {d}\n", .{ tw[0] - 5, tw[1] });
}
