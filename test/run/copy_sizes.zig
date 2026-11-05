//! exit: 0
//! stdout: "171502800\n171501504\n171500041\n171498425\n171496670\n171494790\n171490711\n171488540\n171486300\n171472195\n171469864\n171467576\n171447899\n171447936\n171448240\n171250059\n171247920\n171246240\n167901867\n167843664\n167787072\n113415888\n104090474\n171502800\n171498633\n171493910\n171465875\n171460168\n171454689\n167787600\n167671049\n115046524\n168021015\n168021015\n167959632\n167959632\n167899832\n167899832\n166411234\n166411234\n165716784\n165716784\n115633500\n115633500\n114123159\n114123159\n113879760\n113879760\n113643320\n113643320\n104544594\n104544594\n167409040\n167409040\n167394896\n167394896\n167382611\n167382611\n166132590\n166132590\n165108080\n165108080\n114883396\n114883396\n111674896\n111674896\n111620816\n111620816\n111573971\n111573971\n102669310\n102669310\n92313832\n92313832\n92313832\n92313832\n92254528\n92376504\n92103368\n92057920\n92374352\n92255512\n92525832\n92570960\n92346272\n92317432\n92382792\n92444576\n92162934\n92359692\n92009728\n91709814\n"
//! Copies at the edges of the copy lowering's size classes: a runtime
//! length `@memcpy` of 0 to 1100 bytes (two overlapping moves up to 16, a
//! loop of 16-byte moves up to 256, `rep movsb` above), and copies of
//! known size around 256 and 1024 bytes (straight moves, a loop of
//! 64-byte blocks, `rep movsb`), from unaligned memory, onto themselves,
//! and between overlapping memory, which upstream copies as `memmove`.
//! Each case checks the bytes on both sides of the destination stay
//! untouched and prints a sum of the destination window.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

var src: [1200]u8 = undefined;
var dst: [1200]u8 = undefined;

fn reset() void {
    for (&src, 0..) |*b, i| b.* = @truncate(i *% 7 +% 1);
    @memset(&dst, 0xee);
}

/// The weighted sum of `dst`, which covers the guard bytes around each
/// copy.
fn sum() u64 {
    var t: u64 = 0;
    for (dst, 0..) |b, i| t +%= @as(u64, b) *% (i + 1);
    return t;
}

noinline fn copyBytes(d: []u8, s: []const u8) void {
    @memcpy(d, s);
}

noinline fn copyHalves(d: []u16, s: []const u16) void {
    @memcpy(d, s);
}

fn Blob(comptime n: usize) type {
    return struct { b: [n]u8 };
}

fn copyBlob(comptime n: usize, d: usize, s: usize) void {
    const p: *align(1) Blob(n) = @ptrCast(&dst[d]);
    const q: *align(1) const Blob(n) = @ptrCast(&src[s]);
    p.* = q.*;
}

fn copyArray(comptime n: usize, d: usize, s: usize) void {
    const p: *[n]u8 = dst[d..][0..n];
    @memcpy(p, src[s..][0..n]);
}

/// A copy within `dst`, overlapping when `d` and `s` are closer than `n`.
fn overlapBlob(comptime n: usize, d: usize, s: usize) void {
    const p: *align(1) Blob(n) = @ptrCast(&dst[d]);
    const q: *align(1) const Blob(n) = @ptrCast(&dst[s]);
    p.* = q.*;
}

noinline fn knownSizes(d: usize, s: usize) void {
    inline for (.{ 255, 256, 257, 300, 320, 1000, 1023, 1024, 1025, 1100 }) |n| {
        reset();
        copyBlob(n, d, s);
        rt.printInt(sum());
        reset();
        copyArray(n, d, s);
        rt.printInt(sum());
    }
}

noinline fn overlaps(d: usize, s: usize) void {
    inline for (.{ 257, 300, 1000, 1025 }) |n| {
        for (&dst, 0..) |*b, i| b.* = @truncate(i *% 13 +% 5);
        overlapBlob(n, d, s);
        rt.printInt(sum());
    }
}

fn main() callconv(.c) noreturn {
    const sizes = [_]usize{ 0, 1, 2, 3, 4, 5, 7, 8, 9, 15, 16, 17, 31, 32, 33, 63, 64, 65, 255, 256, 257, 1024, 1100 };
    for (sizes) |n| {
        reset();
        copyBytes(dst[5..][0..n], src[3..][0..n]);
        rt.printInt(sum());
    }
    for ([_]usize{ 0, 1, 2, 7, 8, 9, 128, 129, 500 }) |n| {
        reset();
        copyHalves(@as([*]u16, @ptrCast(@alignCast(&dst[8])))[0..n], @as([*]const u16, @ptrCast(@alignCast(&src[2])))[0..n]);
        rt.printInt(sum());
    }
    knownSizes(3, 1);
    knownSizes(16, 64);
    var d: usize = 0;
    _ = &d;
    // Onto itself, then forward and backward by less than 64 bytes and by
    // more.
    overlaps(d + 40, 40);
    overlaps(d + 40, 32);
    overlaps(d + 32, 40);
    overlaps(d + 40, 0);
    overlaps(d + 0, 70);
    rt.exit(0);
}
