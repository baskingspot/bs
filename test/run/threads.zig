//! exit: 0
//! stderr: "main 8 2 5 255\nthread 17 12 21 255\natomics -99 999 60000 3 11 10 4294967295 -9 42 3.5 null 1 -99\nhalf 14.836 15 -1.5 14\nc 1061.75\n"
//! targets: x86_64-linux aarch64-linux

// Thread-locals of mixed alignments, initialized and zero, in the main
// thread and a spawned one; atomics of every width and operation (on
// aarch64-linux's ARMv8.0 baseline, exclusive load and store loops);
// f16 arithmetic (compiler_rt without FEAT_FP16); and a C call whose
// arguments go on the stack.
const std = @import("std");

threadlocal var tl: u32 = 7;
threadlocal var tl_arr: [3]u64 = .{ 1, 2, 3 };
threadlocal var tl_zero: u128 align(64) = 0;
threadlocal var tl_byte: u8 = 255;

const print = std.debug.print;

fn worker(n: u32) void {
    tl += n;
    tl_arr[1] += n;
    tl_zero += n + 11;
    print("thread {d} {d} {d} {d}\n", .{ tl, tl_arr[1], tl_zero, tl_byte });
}

fn atomics() void {
    var a: i8 = -5;
    var b: u16 = 1000;
    var c: u32 = 7;
    var d: i64 = -1;
    var f: f32 = 1.5;
    var p: ?*u8 = null;
    var z: u8 = 0;
    _ = @atomicRmw(i8, &a, .Max, -3, .seq_cst);
    _ = @atomicRmw(i8, &a, .Min, -100, .seq_cst);
    _ = @atomicRmw(i8, &a, .Add, 1, .seq_cst);
    _ = @atomicRmw(u16, &b, .Sub, 1, .seq_cst);
    const b_old = @atomicRmw(u16, &b, .Max, 60000, .seq_cst);
    _ = @atomicRmw(u32, &c, .And, 3, .seq_cst);
    const c_or = @atomicRmw(u32, &c, .Or, 8, .seq_cst);
    const c_xor = @atomicRmw(u32, &c, .Xor, 1, .seq_cst);
    const c_nand = @atomicRmw(u32, &c, .Nand, 1, .seq_cst);
    _ = @atomicRmw(i64, &d, .Min, -9, .seq_cst);
    const d_old = @atomicRmw(i64, &d, .Xchg, 42, .seq_cst);
    _ = @atomicRmw(f32, &f, .Add, 2, .seq_cst);
    const fail = @cmpxchgStrong(i8, &a, 1, 9, .seq_cst, .seq_cst);
    const ok = @cmpxchgStrong(?*u8, &p, null, &z, .seq_cst, .seq_cst);
    print("atomics {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {any} {d} {d}\n", .{ a, b_old, @atomicLoad(u16, &b, .seq_cst), c_or, c_xor, c_nand, c, d_old, d, f, ok, @intFromBool(p != null), fail.? });
}

fn half() void {
    var x: f16 = 1.5;
    var y: f16 = 0.1;
    _ = .{ &x, &y };
    const r = x * y + x / y - @sqrt(y);
    const i: i32 = @intFromFloat(x * 10);
    print("half {d} {d} {d} {d}\n", .{ r, i, -x, @floor(r) });
}

fn many(a: c_int, b: c_int, c: c_int, d: c_int, e: c_int, f: c_int, g: c_int, h: c_int, i: u8, j: f64, k: f32, l: u16, m: i64) callconv(.c) f64 {
    return @as(f64, @floatFromInt(a + b + c + d + e + f + g + h + i)) + j + k + @as(f64, @floatFromInt(l)) + @as(f64, @floatFromInt(m));
}

pub fn main() !void {
    tl += 1;
    tl_zero = 5;
    print("main {d} {d} {d} {d}\n", .{ tl, tl_arr[1], tl_zero, tl_byte });
    const t = try std.Thread.spawn(.{}, worker, .{10});
    t.join();
    atomics();
    half();
    var j: f64 = 0.5;
    _ = &j;
    print("c {d}\n", .{many(1, 2, 3, 4, 5, 6, 7, 8, 9, j, 0.25, 1000, 16)});
}
