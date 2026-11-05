//! exit: 0
//! flags: -mcpu=x86_64_v2+aes+pclmul
//! targets: x86_64-linux
//! stdout: "aes128 69c4e0d86a7b0430d8cdb78070b4c55a\naes128-dec 00112233445566778899aabbccddeeff\naes256 8ea2b7ca516745bfeafc49904b496089\naes256-dec 00112233445566778899aabbccddeeff\nwide 289b377a1005f27742eb8f346b95c27d\ngcm-tag 87c9d28d435d38b46b42fd81af64b3ab\ngcm-open true\nasm fedcba9876543210 7f6e5d4c3b2a1908\nasm b7d12ed8c8a2e64 95644db6f13d7784\n"

// AES-NI and PCLMULQDQ in inline assembly with `x` operands, read and
// written through variables (`+x`), with the aes and pclmul features
// std's AES and AES-GCM see (they take their asm paths only with AVX,
// so here their software ones), checked on FIPS-197's vectors.
const std = @import("std");
const aes = std.crypto.core.aes;

fn hex(out: *std.Io.Writer, label: []const u8, bytes: []const u8) !void {
    try out.print("{s} {x}\n", .{ label, bytes });
}

const V = @Vector(2, u64);

noinline fn rounds(a: V, b: V) [2]V {
    var x = a;
    asm ("pclmulqdq $0x11, %[b], %[x]"
        : [x] "+x" (x),
        : [b] "x" (b),
    );
    var y = a;
    asm (
        \\ aesenc %[b], %[y]
        \\ aesdeclast %[b], %[y]
        : [y] "+x" (y),
        : [b] "x" (b),
    );
    return .{ x, y };
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    const out = &w.interface;
    // FIPS-197 appendix C.1 and C.3.
    const pt: [16]u8 = .{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff };
    var k128: [16]u8 = undefined;
    var k256: [32]u8 = undefined;
    for (&k128, 0..) |*b, i| b.* = @intCast(i);
    for (&k256, 0..) |*b, i| b.* = @intCast(i);
    var ct: [16]u8 = undefined;
    var back: [16]u8 = undefined;
    aes.Aes128.initEnc(k128).encrypt(&ct, &pt);
    try hex(out, "aes128", &ct);
    aes.Aes128.initDec(k128).decrypt(&back, &ct);
    try hex(out, "aes128-dec", &back);
    aes.Aes256.initEnc(k256).encrypt(&ct, &pt);
    try hex(out, "aes256", &ct);
    aes.Aes256.initDec(k256).decrypt(&back, &ct);
    try hex(out, "aes256-dec", &back);
    // Several blocks at once (`encryptWide`).
    var many: [16 * 8]u8 = undefined;
    var many_out: [16 * 8]u8 = undefined;
    for (&many, 0..) |*b, i| b.* = @truncate(i *% 37);
    aes.Aes128.initEnc(k128).encryptWide(8, &many_out, &many);
    try hex(out, "wide", many_out[112..]);
    const Gcm = std.crypto.aead.aes_gcm.Aes128Gcm;
    var msg: [100]u8 = undefined;
    for (&msg, 0..) |*b, i| b.* = @truncate(i);
    var sealed: [100]u8 = undefined;
    var tag: [16]u8 = undefined;
    Gcm.encrypt(&sealed, &tag, &msg, "ad", @splat(7), k128);
    try hex(out, "gcm-tag", &tag);
    var opened: [100]u8 = undefined;
    try Gcm.decrypt(&opened, &sealed, tag, "ad", @splat(7), k128);
    try out.print("gcm-open {}\n", .{std.mem.eql(u8, &opened, &msg)});
    const r = rounds(.{ 0x0123456789abcdef, 0xfedcba9876543210 }, .{ 0x1111, 0x8000000000000001 });
    for (r) |v| try out.print("asm {x} {x}\n", .{ v[0], v[1] });
    try out.flush();
}
