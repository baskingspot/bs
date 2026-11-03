//! exit: 0
//! stdout: "1\n1\n6\n7\n24\n5\n21\n24\n15\n72\n100\n300\n1\nsema_misc.main.Local\nsema_misc.make(u8)\nfn (...) callconv(.c) void\nfn (usize, bool, ...) callconv(.c) usize\nfn (noalias []u8) void\n"
//! Comptime-known packed const locals, calls through a `*const type`,
//! @bitSizeOf, named tuple initialization, many-pointer peer types,
//! anonymous type names, and variadic and noalias function types.
const rt = @import("rt.zig");

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

const Foo = packed struct { a: u4, b: u4 };
const U = packed union { a: u4, b: i4 };
fn eq(x: Foo, y: Foo) bool {
    return x == y;
}

const A = struct {
    const k: u32 = 7;
    fn f(x: u32) u32 {
        return x + 1;
    }
};

const P = packed struct { a: u3, b: u20, c: bool };
const Q = packed union { a: u5, b: i5 };

fn make(comptime T: type) type {
    return struct { x: T };
}

const Variadic = fn (a: usize, b: bool, ...) callconv(.c) usize;

fn main() callconv(.c) noreturn {
    // Packed const locals initialized field by field stay comptime-known.
    const x: Foo = .{ .a = 1, .b = 2 };
    const y: Foo = .{ .b = 2, .a = 1 };
    const u: U = .{ .a = 3 };
    comptime {
        if (!eq(x, y) or u.a != 3) unreachable;
    }
    rt.printInt(@intFromBool(eq(x, y)));
    rt.printInt(@intFromBool(u.b == 3));

    const t = &A;
    var v: u32 = 4;
    v += 1;
    rt.printInt(t.f(v));
    rt.printInt(t.k);

    rt.printInt(@bitSizeOf(P));
    rt.printInt(@bitSizeOf(Q));
    rt.printInt(@bitSizeOf([3]u7));
    rt.printInt(@bitSizeOf([2:0]u8));
    rt.printInt(@bitSizeOf(@Vector(3, u5)));
    rt.printInt(@bitSizeOf([3]P));

    const Tuple = struct { u8, u16, u32 };
    const tu = Tuple{ .@"2" = 300, .@"0" = 100, .@"1" = 200 };
    rt.printInt(tu[0]);
    rt.printInt(tu[2]);

    const many: [*:0]const u8 = "xy";
    rt.printInt(@intFromBool(@TypeOf("", "a", many) == [*:0]const u8));

    const Local = struct {};
    rt.print(@typeName(Local) ++ "\n");
    rt.print(@typeName(make(u8)) ++ "\n");
    rt.print(@typeName(fn (...) callconv(.c) void) ++ "\n");
    rt.print(@typeName(Variadic) ++ "\n");
    rt.print(@typeName(fn (noalias []u8) void) ++ "\n");
    rt.exit(0);
}
