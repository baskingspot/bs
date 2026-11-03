//! exit: 0
//! stdout: "reflect.S\n*const reflect.S\n[]const u8\n?*anyopaque\nreflect.G.Box(u8)\nreflect.E\nIo.Writer\nstruct { u8, bool }\nerror{A,B}!u32\nfn (u8) callconv(.c) void\n[3:0]u16\n@Vector(4, f32)\nfn () callconv(.c) noreturn\nanyerror\n9084\n16\nFoo\n4\n99\n117637633\n"
//! @typeName, @offsetOf, @bitOffsetOf, @FieldType, @intFromError, and @errorFromInt.
const std = @import("std");
const rt = @import("rt.zig");
pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}
const S = extern struct { a: u8, b: u32, c: u16 };
const P = packed struct { a: u3, b: u7, c: bool };
const G = struct {
    fn Box(comptime T: type) type {
        return struct { v: T };
    }
};
const E = enum { x, y };
fn main() callconv(.c) noreturn {
    const names = [_][]const u8{
        @typeName(S),                         @typeName(*const S),            @typeName([]const u8),
        @typeName(?*anyopaque),               @typeName(G.Box(u8)),           @typeName(E),
        @typeName(std.Io.Writer),             @typeName(struct { u8, bool }), @typeName(error{ A, B }!u32),
        @typeName(fn (u8) callconv(.c) void), @typeName([3:0]u16),            @typeName(@Vector(4, f32)),
        @typeName(@TypeOf(main)),             @typeName(anyerror),
    };
    for (names) |n| {
        rt.print(n);
        rt.print("\n");
    }
    rt.printInt(@offsetOf(S, "b") + @offsetOf(S, "c") * 10 + @bitOffsetOf(P, "c") * 100 + @offsetOf(struct { u8, u64 }, "1") * 1000);
    const T = @FieldType(S, "c");
    rt.printInt(@bitSizeOf(T));
    var e: anyerror = error.Foo;
    _ = &e;
    const i = @intFromError(e);
    const back = @errorFromInt(i);
    rt.print(@errorName(back));
    rt.print("\n");
    // Elements of a comptime slice of types, which have no size.
    const field_types = @typeInfo(struct { a: u8, b: u32 }).@"struct".field_types;
    rt.printInt(@sizeOf(field_types[1]));
    // A source array's sentinel is part of its bits.
    var sname: [3:0]u8 = .{ 'a', 'b', 'c' };
    _ = &sname;
    const name4: [4]u8 = @bitCast(sname);
    rt.printInt(name4[2] + name4[3]);
    const sc: [3:7]u8 = .{ 1, 2, 3 };
    rt.printInt(@as(u32, @bitCast(sc)));
    rt.exit(0);
}
