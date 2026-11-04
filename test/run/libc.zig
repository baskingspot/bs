//! exit: 3
//! libc: true
//! stdout: "fputs\nprintf 42 str 1.41\nsorted 1 3 5 9\nenviron set, tl 8, thread tl 27\n"
//! A program linked against glibc (`-lc`): functions, a variadic one, libm,
//! data imports (`environ`, `stdout`), a callback from libc, glibc's
//! allocator and threads, and an exit status through `main`'s return.
const std = @import("std");

extern "c" var environ: [*:null]?[*:0]u8;
extern "c" var stdout: *anyopaque;
extern "c" fn fputs(s: [*:0]const u8, f: *anyopaque) c_int;
extern "c" fn printf(fmt: [*:0]const u8, ...) c_int;
extern "c" fn sqrt(x: f64) f64;
extern "c" fn qsort(base: *anyopaque, n: usize, size: usize, cmp: *const fn (?*const anyopaque, ?*const anyopaque) callconv(.c) c_int) void;

threadlocal var tl: u32 = 7;

fn cmp(a: ?*const anyopaque, b: ?*const anyopaque) callconv(.c) c_int {
    const x: *const i32 = @ptrCast(@alignCast(a.?));
    const y: *const i32 = @ptrCast(@alignCast(b.?));
    return @intFromBool(x.* > y.*) - @as(c_int, @intFromBool(x.* < y.*));
}

fn bump() void {
    tl += 10;
}

pub fn main() !u8 {
    if (!@import("builtin").link_libc) return error.NotLinkedWithLibc;
    _ = fputs("fputs\n", stdout);
    _ = printf("printf %d %s %.2f\n", @as(c_int, 42), "str", sqrt(2.0));
    var arr = [_]i32{ 5, 3, 9, 1 };
    qsort(&arr, arr.len, @sizeOf(i32), &cmp);
    _ = printf("sorted %d %d %d %d\n", arr[0], arr[1], arr[2], arr[3]);

    const p: [*]u8 = @ptrCast(std.c.malloc(16) orelse return error.OutOfMemory);
    p[0] = 1;
    std.c.free(p);

    tl += 1;
    var thread_tl: u32 = 0;
    const t = try std.Thread.spawn(.{}, struct {
        fn f(out: *u32) void {
            bump();
            bump();
            out.* = tl;
        }
    }.f, .{&thread_tl});
    t.join();
    _ = printf("environ %s, tl %u, thread tl %u\n", @as([*:0]const u8, if (environ[0] != null) "set" else "empty"), tl, thread_tl);
    return 3;
}
