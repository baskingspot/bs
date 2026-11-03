//! exit: 0
//! stderr: "sum=103658747345780558405425396738333792356 wide=-1180591620717411303424 div=-1180591620717411304\narea 6.75\narea 7\nf16: 2.5 2.5 -0\nf32: 1.5 -2.5 0\nf64: 1.25 1.25 -0\nf80: 1 -2 0\nf128: 1.5 1.5 -0\nf16 4.5 f128 3000000000000000000000000000000 true\nparse 123 Empty\nlist 1000 332833500 3b456bc8\n"
//! targets: x86_64-linux aarch64-macos

// std programs that run unchanged on every target: integers wider than a
// register, floats of every width (soft-float compiler_rt calls for f80 and
// f128 on aarch64-macos), error unions, containers, and formatting.
const std = @import("std");

fn fib(n: u64) u64 {
    return if (n < 2) n else fib(n - 1) + fib(n - 2);
}

const Shape = union(enum) {
    circle: f64,
    rect: struct { w: f32, h: f32 },

    fn area(s: Shape) f64 {
        return switch (s) {
            .circle => |r| 3.0 * r * r,
            .rect => |r| r.w * r.h,
        };
    }
};

fn parse(s: []const u8) error{Empty}!u32 {
    if (s.len == 0) return error.Empty;
    return std.fmt.parseInt(u32, s, 10) catch 0;
}

fn mods(comptime T: type, a: T, b: T) void {
    std.debug.print("{s}: {d} {d} {d}\n", .{ @typeName(T), @as(f64, @floatCast(@mod(a, b))), @as(f64, @floatCast(@rem(a, b))), @as(f64, @floatCast(@mod(-0.0 * a, b))) });
}

pub fn main() !void {
    var sum: u128 = 0;
    for (0..30) |i| sum = sum *% 1_000_000_007 +% fib(i);
    var wide: i96 = -1;
    wide <<= 70;
    std.debug.print("sum={d} wide={d} div={d}\n", .{ sum, wide, @divFloor(wide, 1000) });
    const shapes = [_]Shape{ .{ .circle = 1.5 }, .{ .rect = .{ .w = 2, .h = 3.5 } } };
    for (shapes) |s| std.debug.print("area {d}\n", .{s.area()});
    mods(f16, 6.5, 4);
    mods(f32, -6.5, 4);
    mods(f64, 7.25, 2);
    mods(f80, -5, 3);
    mods(f128, 5.5, 2);
    var h: f16 = 1.5;
    var q: f128 = 1e30;
    _ = .{ &h, &q };
    std.debug.print("f16 {d} f128 {d} {}\n", .{ @as(f64, h * 3), @as(f64, @floatCast(q * 3)), q > 2.5 });
    std.debug.print("parse {d} ", .{try parse("123")});
    std.debug.print("{t}\n", .{if (parse("")) |_| unreachable else |e| e});
    var list: std.ArrayList(u64) = .empty;
    defer list.deinit(std.heap.page_allocator);
    for (0..1000) |k| try list.append(std.heap.page_allocator, k * k);
    var total: u64 = 0;
    for (list.items) |v| total +%= v;
    std.debug.print("list {d} {d} {x}\n", .{ list.items.len, total, @bitReverse(@as(u32, @intCast(total & 0xffff_ffff))) });
}
