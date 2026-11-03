//! exit: 0
//! stdout: "16\n16\n8\n8\n1\n1\n0\n1\n0\n0\n1\n0\n0\n842\n808\n404\n1616\n1\n1\n1\n1\n1\n1\n1\n1\n7\n9\n"
//! Explicit alignment on zero-bit struct fields, global declarations,
//! functions, local constants, union fields, and pointers to elements.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

// A zero-bit field with align(n) aligns the struct but takes no space.
const B = struct {
    x: u8,
    _: void align(16) = {},
};
const C = struct {
    a: u8,
    _: void align(8) = {},
    b: u8,
};

var small: u8 align(16) = 1;
var pad: u8 = 2;
const table: [3]u32 align(64) = .{ 1, 2, 3 };

// Zero-bit fields align the struct by their natural alignment too; in an
// extern struct they pad the next field.
const Z = struct { arr: [0]usize = .{} };
const E = extern struct { x: u8, a: [0]u16 = .{}, y: u8 };

const U = union { a: [3]u8 align(8), b: u8 };
const T = union(enum) { a: u8 align(4), b: u16 };
const X = extern union { a: u8 align(16), b: u32 };

fn align1() align(1) void {}
fn overaligned() align(0x1000) i32 {
    return 42;
}

fn main() callconv(.c) noreturn {
    rt.printInt(@alignOf(B));
    rt.printInt(@sizeOf(B));
    rt.printInt(@alignOf(C));
    rt.printInt(@sizeOf(C));
    // The declaration's alignment is part of its pointer type...
    rt.printInt(@intFromBool(@TypeOf(&small) == *align(16) u8));
    rt.printInt(@intFromBool(@TypeOf(&table) == *align(64) const [3]u32));
    rt.printInt(@intFromBool(@TypeOf(&table) == *const [3]u32));
    // ...and of its address.
    pad += 1;
    rt.printInt(small);
    rt.printInt(@intFromPtr(&small) % 16 + @intFromPtr(&table) % 64);

    // An explicit alignment makes a type of its own, even when natural.
    rt.printInt(@intFromBool(*u32 == *align(4) u32));
    rt.printInt(@intFromBool(@TypeOf(&align1) == *align(1) const fn () void));
    rt.printInt(@intFromPtr(&overaligned) % 0x1000);
    const local: f32 align(128) = 12.34;
    rt.printInt(@intFromPtr(&local) % 128);
    rt.printInt(@alignOf(Z) * 100 + @sizeOf(E) * 10 + @offsetOf(E, "y"));
    rt.printInt(@alignOf(U) * 100 + @sizeOf(U));
    rt.printInt(@alignOf(T) * 100 + @sizeOf(T));
    rt.printInt(@alignOf(X) * 100 + @sizeOf(X));
    var t: T = .{ .a = 5 };
    _ = &t;
    rt.printInt(@intFromBool(@TypeOf(&t.a) == *align(4) u8));

    // Element pointers keep as much of an explicit alignment as their
    // offset allows; a runtime index moves by whole elements.
    var array align(4) = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var i: usize = 3;
    _ = &i;
    rt.printInt(@intFromBool(@TypeOf(&array[0]) == *align(4) u8));
    rt.printInt(@intFromBool(@TypeOf(&array[2]) == *align(2) u8));
    rt.printInt(@intFromBool(@TypeOf(&array[i]) == *align(1) u8));
    rt.printInt(@intFromBool(@TypeOf(array[i..]) == []align(1) u8));
    var bigger align(2) = [_]u64{ 1, 2, 3, 4 };
    rt.printInt(@intFromBool(@TypeOf(&bigger[1]) == *align(2) u64));
    rt.printInt(@intFromBool(@TypeOf(bigger[i..]) == []align(2) u64));
    const undef_slice: []align(1024) const u8 = undefined;
    rt.printInt(@intFromBool(@TypeOf(&undef_slice[0]) == *align(1024) const u8));
    // Values of types aligned to more than 16 bytes, passed and returned.
    var line = makeLine(7);
    _ = &line;
    rt.printInt(line.a);
    rt.printInt(bump(line).a);
    rt.exit(0);
}

const Line = struct { a: u32, b: u8 align(64) = 1 };
fn makeLine(a: u32) Line {
    return .{ .a = a };
}
fn bump(l: Line) Line {
    var r = l;
    r.a += 2;
    return r;
}
