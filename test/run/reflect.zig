//! exit: 0
//! stdout: "reflect.S\n*const reflect.S\n[]const u8\n?*anyopaque\nreflect.G.Box(u8)\nreflect.E\nIo.Writer\nstruct { u8, bool }\nerror{A,B}!u32\nfn (u8) callconv(.c) void\n[3:0]u16\n@Vector(4, f32)\nfn () callconv(.c) noreturn\nanyerror\nreflect.G.Args(.y,(function 'main'),\"hi\"[0..2],.{ .a = 1, .b = &.{ ... } })\n9084\n16\nFoo\n4\n99\n117637633\n2\nreflect.H__struct_\nreflect.localName__func_.Inner\nreflect.main__struct_\nreflect.C.comptime__struct_\nreflect.C.comptime__struct_\nreflect.C.comptime__struct_\nreflect.C.comptime__struct_\n4\n"
//! @typeName, @offsetOf, @bitOffsetOf, @FieldType, @intFromError, and @errorFromInt.
const std = @import("std");
const rt = @import("rt.zig");
pub const panic = rt.panic;
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
    fn Args(comptime e: E, comptime f: fn () callconv(.c) noreturn, comptime s: []const u8, comptime v: anytype) type {
        return struct {
            const x = .{ e, f, s, v };
        };
    }
};
// Anonymous types are named after the container whose fields they type,
// and after a generic function instance including its `__func_` suffix.
const H = struct { f: struct { a: u8 } };
fn localName(comptime T: type) []const u8 {
    _ = T;
    const Inner = struct {};
    return @typeName(Inner);
}
// Anonymous types made in different `comptime` blocks of one namespace
// are named after `<namespace>.comptime` and have distinct names. Each
// block exports its names, which `main` compares.
const C = struct {
    comptime {
        @export(@typeName(struct { x: u8 }), .{ .name = "reflect_c0_decl" });
        @export(@typeName(@TypeOf(.{ .a = 1 })), .{ .name = "reflect_c0_lit" });
    }
    comptime {
        @export(@typeName(struct { y: u8 }), .{ .name = "reflect_c1_decl" });
        @export(@typeName(@TypeOf(.{ .b = 2 })), .{ .name = "reflect_c1_lit" });
    }
};
comptime {
    _ = C;
}
extern const reflect_c0_decl: u8;
extern const reflect_c0_lit: u8;
extern const reflect_c1_decl: u8;
extern const reflect_c1_lit: u8;
fn printComptimeNames() void {
    const names = [_][]const u8{
        std.mem.span(@as([*:0]const u8, @ptrCast(&reflect_c0_decl))),
        std.mem.span(@as([*:0]const u8, @ptrCast(&reflect_c0_lit))),
        std.mem.span(@as([*:0]const u8, @ptrCast(&reflect_c1_decl))),
        std.mem.span(@as([*:0]const u8, @ptrCast(&reflect_c1_lit))),
    };
    var distinct: u64 = 0;
    for (names, 0..) |n, i| {
        printWithoutNumbers(n);
        for (names[0..i]) |m| {
            if (std.mem.eql(u8, n, m)) break;
        } else distinct += 1;
    }
    rt.printInt(distinct);
}
fn printWithoutNumbers(n: []const u8) void {
    var i: usize = 0;
    while (i < n.len) : (i += 1) {
        rt.print(n[i..][0..1]);
        if ((n[i] == '_' and i + 1 < n.len and std.ascii.isDigit(n[i + 1])) or std.mem.endsWith(u8, n[0 .. i + 1], "__func_")) {
            while (i + 1 < n.len and std.ascii.isHex(n[i + 1])) i += 1;
        }
    }
    rt.print("\n");
}
const E = enum { x, y };
fn main() callconv(.c) noreturn {
    const names = [_][]const u8{
        @typeName(S),                         @typeName(*const S),            @typeName([]const u8),
        @typeName(?*anyopaque),               @typeName(G.Box(u8)),           @typeName(E),
        @typeName(std.Io.Writer),             @typeName(struct { u8, bool }), @typeName(error{ A, B }!u32),
        @typeName(fn (u8) callconv(.c) void), @typeName([3:0]u16),            @typeName(@Vector(4, f32)),
        @typeName(@TypeOf(main)),             @typeName(anyerror),
        @typeName(G.Args(.y, main, "hi", .{ .a = 1, .b = &S{ .a = 1, .b = 2, .c = 3 } })),
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
    // @typeInfo field names ([:0]const u8 elements) read as []const u8,
    // as @Struct's arguments are.
    rt.printInt(@sizeOf(@FieldType(FieldsOf(E, u16), "y")));
    printWithoutNumbers(@typeName(@FieldType(H, "f")));
    printWithoutNumbers(localName(u8));
    printWithoutNumbers(@typeName(@TypeOf(.{ .a = 1 })));
    printComptimeNames();
    rt.exit(0);
}

fn FieldsOf(comptime T: type, comptime Data: type) type {
    const field_names = @typeInfo(T).@"enum".field_names;
    return @Struct(.auto, null, field_names, &@splat(Data), &@splat(.{}));
}
