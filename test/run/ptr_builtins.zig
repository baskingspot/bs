//! exit: 0
//! stdout: "1\n7\n3\n1\n0\n1\n1\n1\n9\n1\n42\n4\n4\n44\n7\n4294967295\n42\n13\n4\n"
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
    // A single-item pointer cast to a slice covers its bytes; cast builtins
    // take their destination from a result type without the error union
    // (and, except @ptrCast, the optional).
    const word: u32 = 0x01020304;
    const word_bytes = bytesOf(&word);
    rt.printInt(word_bytes.len);
    rt.printInt(word_bytes[0]);
    rt.printInt(narrow(300) catch 0);
    var w: u32 = 7;
    rt.printInt(optCast(&w).?.*);
    rt.printInt(bitsOf(-1) catch 0);
    // Extern function declarations resolve to exports of their name.
    rt.printInt(api_add(4, 2));
    rt.printInt(zap_add(1, 3));
    // @ptrCast into an optional slice.
    const ws = wordsOf(&word_buf).?;
    rt.printInt(ws.len + ws[1]);
    rt.exit(0);
}

fn bytesOf(x: *const u32) []const u8 {
    return @ptrCast(x);
}
fn narrow(x: u64) error{Big}!u8 {
    if (x > 1000) return error.Big;
    return @intCast(x % 256);
}
fn optCast(p: *u32) ?*u8 {
    return @ptrCast(p);
}
fn bitsOf(x: i32) error{X}!u32 {
    return @bitCast(x);
}

// As std.os.linux.getauxval: an extern declaration that an export in the
// same program defines.
const api_add = struct {
    comptime {
        @export(&addImpl, .{ .name = "zap_add", .linkage = .weak });
    }
    extern fn zap_add(a: u32, b: u32) u32;
}.zap_add;
fn addImpl(a: u32, b: u32) callconv(.c) u32 {
    return a * 10 + b;
}
extern fn zap_add(a: u32, b: u32) u32;

var word_buf: [8]u8 align(4) = .{ 1, 0, 0, 0, 2, 0, 0, 0 };
fn wordsOf(b: []u8) ?[]u32 {
    return @ptrCast(@alignCast(b));
}
