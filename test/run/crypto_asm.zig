//! exit: 0
//! stderr: "sha256 ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\naes128 69c4e0d86a7b0430d8cdb78070b4c55a\ngcm 0388dace60b6a392f328c2b971b2fe78 ab6e47d42cec13bdf53a67b21257bddf\n"
//! targets: x86_64-linux aarch64-macos

// std's crypto with published test vectors (FIPS 180-2, FIPS-197 C.1, GCM
// test case 2). On aarch64-macos (apple_m1 has the aes and sha2 features)
// SHA-256, AES and GHASH are std's NEON inline assembly: `w`/`x` operands,
// `%[x].16b` and Apple's `sha256h.4s` spelling, tied inputs, `pmull2`.
const std = @import("std");
const crypto = std.crypto;

pub fn main() void {
    var digest: [32]u8 = undefined;
    crypto.hash.sha2.Sha256.hash("abc", &digest, .{});
    std.debug.print("sha256 {x}\n", .{digest});

    var key: [16]u8 = undefined;
    for (&key, 0..) |*k, i| k.* = @intCast(i);
    var block: [16]u8 = undefined;
    for (&block, 0..) |*p, i| p.* = @intCast(i * 0x11);
    crypto.core.aes.Aes128.initEnc(key).encrypt(&block, &block);
    std.debug.print("aes128 {x}\n", .{block});

    const zero16: [16]u8 = @splat(0);
    var ct: [16]u8 = undefined;
    var tag: [16]u8 = undefined;
    crypto.aead.aes_gcm.Aes128Gcm.encrypt(&ct, &tag, &zero16, "", @splat(0), zero16);
    std.debug.print("gcm {x} {x}\n", .{ ct, tag });
}
