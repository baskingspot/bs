//! exit: 0
//! stdout: "9045188764992586428 5\n"
//! targets: x86_64-linux aarch64-macos aarch64-linux
//! More values live across a call than callee-saved registers hold:
//! some take caller-saved ones, saved around each call they cross and
//! reloaded after it (`Ssa.planSplits`), and keep their values.
const std = @import("std");

noinline fn mix(x: u64) u64 {
    return x *% 0x9e3779b97f4a7c15 ^ (x >> 29);
}

noinline fn spin(seed: u64, n: u32) [2]u64 {
    var a: u64 = seed;
    var b: u64 = seed +% 1;
    var c: u64 = seed +% 2;
    var d: u64 = seed +% 3;
    var e: u64 = seed +% 4;
    var f: u64 = seed +% 5;
    var g: u64 = seed +% 6;
    var h: u64 = seed +% 7;
    var i: u64 = seed +% 8;
    var j: u64 = seed +% 9;
    var k: u64 = seed +% 10;
    var l: u64 = seed +% 11;
    var m: u64 = seed +% 12;
    var calls: u32 = 0;
    var r: u32 = 0;
    while (r < n) : (r += 1) {
        // Each value is read many times per call it crosses.
        var s: u32 = 0;
        while (s < 4) : (s += 1) {
            a +%= b ^ m;
            b +%= c ^ a;
            c +%= d ^ b;
            d +%= e ^ c;
            e +%= f ^ d;
            f +%= g ^ e;
            g +%= h ^ f;
            h +%= i ^ g;
            i +%= j ^ h;
            j +%= k ^ i;
            k +%= l ^ j;
            l +%= m ^ k;
            m +%= a ^ l;
        }
        if (r & 3 == 0) {
            a = mix(a);
            calls += 1;
        }
    }
    return .{ a ^ b ^ c ^ d ^ e ^ f ^ g ^ h ^ i ^ j ^ k ^ l ^ m, calls };
}

pub fn main(init: std.process.Init) !void {
    var buf: [64]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &buf);
    const w = &fw.interface;
    const r = spin(12345, 20);
    try w.print("{} {}\n", .{ r[0], r[1] });
    try w.flush();
}
