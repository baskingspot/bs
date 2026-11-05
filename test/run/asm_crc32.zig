//! exit: 0
//! stderr: "e3069283 cbf43926 e3069283 cbf43926 42\n"
//! targets: x86_64-linux aarch64-macos

// aarch64 inline assembly: the CRC32 instructions (apple_m1 has the crc
// feature), at every width, against the CRC-32C and CRC-32 check values
// of "123456789"; and operands pinned to a register (`{x9}`) named in the
// template, as ghostty's crc32c and zwasm's JIT entry use them. Elsewhere
// std computes the same values.
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
}
