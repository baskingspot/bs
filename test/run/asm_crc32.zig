//! exit: 0
//! stderr: "e3069283 cbf43926 e3069283 cbf43926 42\nfa745634 5555 3f7e 4000 ff 2772 3fc fc 7a2f\n"
//! targets: x86_64-linux aarch64-macos

// aarch64 inline assembly: the CRC32 instructions (apple_m1 has the crc
// feature), at every width, against the CRC-32C and CRC-32 check values
// of "123456789"; and operands pinned to a register (`{x9}`) named in the
// template, as ghostty's crc32c and zwasm's JIT entry use them. Then a
// CRC from wzr and `pmull` on bytes (apple_m1 has the aes feature).
// Elsewhere std or plain Zig computes the same values.
const std = @import("std");
const builtin = @import("builtin");

fn crc(comptime c: bool, data: []const u8) u32 {
    if (builtin.cpu.arch != .aarch64) return if (c) std.hash.crc.@"CRC-32/ISCSI".hash(data) else std.hash.Crc32.hash(data);
    var r: u32 = 0xffffffff;
    var i: usize = 0;
    while (data.len - i >= 8) : (i += 8) {
        const v = std.mem.readInt(u64, data[i..][0..8], .little);
        r = if (c) asm ("crc32cx %[out:w], %[crc:w], %[v:x]"
            : [out] "=r" (-> u32),
            : [crc] "r" (r),
              [v] "r" (v),
        ) else asm ("crc32x %[out:w], %[crc:w], %[v:x]"
            : [out] "=r" (-> u32),
            : [crc] "r" (r),
              [v] "r" (v),
        );
    }
    if (data.len - i >= 4) {
        const v = std.mem.readInt(u32, data[i..][0..4], .little);
        r = if (c) asm ("crc32cw %[out:w], %[crc:w], %[v:w]"
            : [out] "=r" (-> u32),
            : [crc] "r" (r),
              [v] "r" (v),
        ) else asm ("crc32w %[out:w], %[crc:w], %[v:w]"
            : [out] "=r" (-> u32),
            : [crc] "r" (r),
              [v] "r" (v),
        );
        i += 4;
    }
    if (data.len - i >= 2) {
        const v = std.mem.readInt(u16, data[i..][0..2], .little);
        r = if (c) asm ("crc32ch %[out:w], %[crc:w], %[v:w]"
            : [out] "=r" (-> u32),
            : [crc] "r" (r),
              [v] "r" (v),
        ) else asm ("crc32h %[out:w], %[crc:w], %[v:w]"
            : [out] "=r" (-> u32),
            : [crc] "r" (r),
              [v] "r" (v),
        );
        i += 2;
    }
    for (data[i..]) |b| {
        r = if (c) asm ("crc32cb %[out:w], %[crc:w], %[v:w]"
            : [out] "=r" (-> u32),
            : [crc] "r" (r),
              [v] "r" (b),
        ) else asm ("crc32b %[out:w], %[crc:w], %[v:w]"
            : [out] "=r" (-> u32),
            : [crc] "r" (r),
              [v] "r" (b),
        );
    }
    return ~r;
}

/// One CRC-32C step over a word from a zero CRC, the CRC named as wzr:
/// register 31 in the encoding, not w0.
noinline fn crcFromZero(v: u32) u32 {
    if (builtin.cpu.arch != .aarch64) {
        var r = v;
        for (0..32) |_| r = (r >> 1) ^ (0x82F63B78 & -%(r & 1));
        return r;
    }
    return asm ("crc32cw %[out:w], wzr, %[v:w]"
        : [out] "=r" (-> u32),
        : [v] "r" (v),
    );
}

/// The carry-less products of the low eight bytes of `a` and `b`: `pmull`
/// on bytes (`.8h`), where std's GHASH uses it on doublewords (`.1q`).
noinline fn polyMul(a: @Vector(16, u8), b: @Vector(16, u8)) @Vector(8, u16) {
    if (builtin.cpu.arch != .aarch64) {
        const x: [16]u8 = a;
        const y: [16]u8 = b;
        var out: [8]u16 = undefined;
        for (&out, x[0..8], y[0..8]) |*o, xi, yi| {
            o.* = 0;
            for (0..8) |bit| {
                if (yi >> @intCast(bit) & 1 != 0) o.* ^= @as(u16, xi) << @intCast(bit);
            }
        }
        return out;
    }
    return asm ("pmull %[o].8h, %[a].8b, %[b].8b"
        : [o] "=w" (-> @Vector(8, u16)),
        : [a] "w" (a),
          [b] "w" (b),
    );
}

fn add1(x: u64) callconv(.c) u64 {
    return x + 1;
}

pub fn main() void {
    var check: []const u8 = "123456789";
    _ = &check;
    // 9 bytes take the x and b forms; 7 the w, h and b forms.
    const crc_c9 = crc(true, check);
    const crc_9 = crc(false, check);
    var crc_c7 = crc(true, check[0..7]);
    var crc_7 = crc(false, check[0..7]);
    crc_c7 = if (crc_c7 == std.hash.crc.@"CRC-32/ISCSI".hash(check[0..7])) crc_c9 else 0;
    crc_7 = if (crc_7 == std.hash.Crc32.hash(check[0..7])) crc_9 else 0;
    var f: *const fn (u64) callconv(.c) u64 = &add1;
    _ = &f;
    var out: u64 = if (builtin.cpu.arch == .aarch64) 0 else f(41);
    if (builtin.cpu.arch == .aarch64) asm volatile (
        \\ mov x0, #41
        \\ blr %[callee]
        \\ mov %[res], x0
        : [res] "={x11}" (out),
        : [callee] "{x9}" (f),
        : .{ .x0 = true, .x1 = true, .x2 = true, .x3 = true, .x4 = true, .x5 = true, .x6 = true, .x7 = true, .x8 = true, .x10 = true, .x12 = true, .x13 = true, .x14 = true, .x15 = true, .x16 = true, .x17 = true, .x30 = true, .memory = true });
    std.debug.print("{x} {x} {x} {x} {d}\n", .{ crc_c9, crc_9, crc_c7, crc_7, out });
    var word: u32 = 0x12345678;
    _ = &word;
    var a: @Vector(16, u8) = .{ 0xff, 0x53, 0x80, 0x01, 0xa5, 0x3c, 0x7e, 0x99, 1, 2, 3, 4, 5, 6, 7, 8 };
    var b: @Vector(16, u8) = .{ 0xff, 0xca, 0x80, 0xff, 0x5a, 0x11, 0x02, 0xe7, 8, 7, 6, 5, 4, 3, 2, 1 };
    _ = .{ &a, &b };
    const products: [8]u16 = polyMul(a, b);
    std.debug.print("{x}", .{crcFromZero(word)});
    for (products) |product| std.debug.print(" {x}", .{product});
    std.debug.print("\n", .{});
}
