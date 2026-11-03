//! exit: 0
//! stdout: "661\n661\n10\n10\n10\n10\n22\n"
//! Labeled switches with captures by reference, switches on packed structs
//! and unions, and tag captures known from a single-item prong.
const rt = @import("rt.zig");
pub const panic = rt.panic;
pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}
const U = union(enum) { a: u32, b: u32, c: u32 };
const P = packed struct { a: u7, b: u20 };
const PU = packed union { a: u7, b: i7 };
fn refLoop() u64 {
    var a: U = .{ .a = 100 };
    var b: U = .{ .b = 200 };
    var c: U = .{ .c = 300 };
    inc: switch (a) {
        .a => |*x| {
            x.* += 1;
            continue :inc b;
        },
        .b => |*x| {
            x.* += 10;
            continue :inc c;
        },
        .c => |*x| x.* += 50,
    }
    return a.a + b.b + c.c;
}
fn packedLoop(p: P) u32 {
    const r = s: switch (p) {
        .{ .a = 5, .b = 10 } => |x| x,
        else => |x| continue :s .{ .a = x.a, .b = x.b + 1 },
    };
    return r.b;
}
fn packedUnion(p: PU) i8 {
    const r = s: switch (p) {
        .{ .a = 10 } => |x| x,
        else => |x| continue :s .{ .b = @intCast(x.a + 1) },
    };
    return r.b;
}
fn tagOf(u: U) u32 {
    return switch (u) {
        .a => |v, t| blk: {
            comptime {
                if (t != .a) unreachable;
            }
            break :blk v;
        },
        .b, .c => |v, t| v + @backingInt(t),
    };
}
fn plain(x: u8) u32 {
    return switch (@as(P, .{ .a = @intCast(x), .b = 3 })) {
        .{ .a = 1, .b = 3 } => 11,
        .{ .a = 2, .b = 3 } => 22,
        else => 0,
    };
}
fn main() callconv(.c) noreturn {
    rt.printInt(refLoop());
    rt.printInt(comptime refLoop());
    rt.printInt(packedLoop(.{ .a = 5, .b = 0 }));
    rt.printInt(comptime packedLoop(.{ .a = 5, .b = 0 }));
    rt.printInt(@intCast(packedUnion(.{ .a = 3 })));
    rt.printInt(tagOf(.{ .a = 4 }) + tagOf(.{ .c = 4 }));
    var x: u8 = 2;
    _ = &x;
    rt.printInt(plain(x));
    rt.exit(0);
}
