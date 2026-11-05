//! exit: 0
//! libc: true
//! targets: x86_64-linux aarch64-linux
//! stdout: "sum 15 len 5 sorted 1 2 4 8\n"
//! rebuild-replace: "sum %d len" "total %d len"
//! An edit build of a program linked against glibc: the cache relinks it
//! from the manifest, rebuilding the dynamic tables (imports, versions,
//! DT_NEEDED, the interpreter) as a full link builds them; with the
//! output deleted, the relink reads glibc's symbols from abilists, and
//! must give a full build's bytes (build.zig).
const std = @import("std");

extern "c" fn printf(fmt: [*:0]const u8, ...) c_int;
extern "c" fn strlen(s: [*:0]const u8) usize;
extern "c" fn qsort(base: *anyopaque, n: usize, size: usize, cmp: *const fn (?*const anyopaque, ?*const anyopaque) callconv(.c) c_int) void;

fn cmp(a: ?*const anyopaque, b: ?*const anyopaque) callconv(.c) c_int {
    const x: *const i32 = @ptrCast(@alignCast(a.?));
    const y: *const i32 = @ptrCast(@alignCast(b.?));
    return @as(c_int, @intFromBool(x.* > y.*)) - @intFromBool(x.* < y.*);
}

pub fn main() void {
    var v = [_]i32{ 8, 2, 4, 1 };
    qsort(&v, v.len, @sizeOf(i32), cmp);
    var sum: i32 = 0;
    for (v) |x| sum += x;
    _ = printf("sum %d len %d sorted %d %d %d %d\n", sum, @as(c_int, @intCast(strlen("hello"))), v[0], v[1], v[2], v[3]);
}
