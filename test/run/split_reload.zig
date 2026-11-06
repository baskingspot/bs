//! exit: 0
//! stdout: "14444824252828335331 15693502238916226395\n"
//! targets: x86_64-linux aarch64-macos aarch64-linux
//! Values saved around the calls they cross (`Ssa.planSplits`) that
//! nothing reads before the next call, or that a store to a variable
//! overwrites first, are not reloaded in between, and their slots are not
//! stored again while they hold them; values another branch reads still
//! are. Each case reads every value afterwards.
const std = @import("std");

noinline fn mix(x: u64) u64 {
    return x *% 0x9e3779b97f4a7c15 ^ (x >> 31);
}

noinline fn chain(seed: u64, flag: bool) u64 {
    // More values live across the calls than x19-x28 hold.
    const a = seed +% 1;
    const b = seed *% 3;
    const c = seed ^ 0x55;
    const d = seed +% 7;
    const e = seed *% 11;
    const g = seed ^ 0xa0a0;
    const h = seed +% 13;
    const i = seed *% 17;
    const j = seed ^ 0x3c3c;
    const k = seed +% 19;
    const l = seed *% 23;
    const m = seed ^ 0x77;
    // A variable written between calls without being read.
    var v: u64 = undefined;
    var x = mix(seed);
    x = mix(x +% a);
    v = x ^ b;
    x = mix(x);
    // A checked addition: its failure is a block the others skip.
    x = mix((x & 0xffff) + c);
    v = v +% x;
    x = mix(x);
    if (flag) {
        x +%= d +% v;
    } else {
        x ^= e;
    }
    x = mix(x);
    x = mix((x & 0xffff) + g);
    return x ^ a ^ b ^ c ^ d ^ e ^ g ^ h ^ i ^ j ^ k ^ l ^ m ^ v;
}

pub fn main(init: std.process.Init) !void {
    var buf: [128]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &buf);
    const w = &fw.interface;
    try w.print("{} {}\n", .{ chain(12345, true), chain(999, false) });
    try w.flush();
}
