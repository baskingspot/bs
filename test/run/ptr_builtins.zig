//! exit: 0
//! stdout: "1\n7\n3\n1\n0\n1\n1\n1\n9\n1\n42\n"
const rt = @import("rt.zig");
// For `std.lang.ExternOptions`; std.start sees `_start` and stays out.
const std = @import("std");

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

export var exported_value: u32 = 7;

const Kind = enum(u8) {
    a = 1,
    b = 2,
    _,
    pub const special: Kind = @fromBackingInt(@intCast(9));
};

fn kindName(k: Kind) u64 {
    return switch (k) {
        .a => 1,
        // A declaration of the operand type as a switch item.
        .special => 9,
        else => 0,
    };
}

const Pair = struct { x: u32, y: u64 };

fn parentOf(y: *u64) *Pair {
    return @fieldParentPtr("y", y);
}

fn retAddr() usize {
    return @returnAddress();
}

fn nakedFortyTwo() callconv(.naked) u64 {
    asm volatile (
        \\ movl $42, %%eax
        \\ ret
    );
}

fn main() callconv(.c) noreturn {
    // The address of an exported symbol.
    const found = @extern(*u32, .{ .name = "exported_value" });
    var found_rt = found;
    _ = &found_rt;
    rt.printInt(@intFromBool(found_rt == &exported_value));
    rt.printInt(found.*);
    // Pointer difference in elements.
    var arr: [8]u32 = undefined;
    const p0: [*]u32 = &arr;
    var off: usize = 3;
    _ = &off;
    rt.printInt(p0 + off - p0);
    // `@intFromPtr` of optional pointers.
    const none: ?*u32 = null;
    rt.printInt(@intFromBool(@intFromPtr(@as(?*u32, &arr[0])) == @intFromPtr(&arr[0])));
    rt.printInt(@intFromPtr(none));
    // Const-qualifying through a const pointer.
    var strs: [1]?[*:0]u8 = .{null};
    const view: []const ?[*:0]const u8 = &strs;
    rt.printInt(view.len);
    // `@ptrCast` from an optional pointer, with `@alignCast`.
    const opaque_ptr: ?*anyopaque = &arr[1];
    const back: *u32 = @ptrCast(@alignCast(opaque_ptr));
    rt.printInt(@intFromBool(back == &arr[1]));
    var pair: Pair = .{ .x = 1, .y = 2 };
    rt.printInt(@intFromBool(parentOf(&pair.y) == &pair));
    rt.printInt(kindName(Kind.special));
    rt.printInt(@intFromBool(retAddr() != 0));
    // Calling a naked function through a pointer cast to `.c`.
    const f: *const fn () callconv(.c) u64 = @ptrCast(&nakedFortyTwo);
    rt.printInt(f());
    rt.exit(0);
}
