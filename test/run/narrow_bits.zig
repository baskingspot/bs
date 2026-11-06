//! exit: 0
//! stderr: "garbage 103020201 607030303\nfp 7f 70787d7e fp 0 0 fp 40 40004000 \nm true 7a m true 7f m true 0 m false 7f \nunchecked 13 checked 13\nshifts 1f50a3ffff1fffc0 ffffe02468a8d140\ncarries 3 2 0\n"
//! upstream-llvm: true
//! targets: x86_64-linux aarch64-macos aarch64-linux

// An unsigned narrow integer is normalized only when its value may have
// bits above its type, and with one `and` when narrower than 32 bits. A
// shift right, a truncation of a value already within the type, or a cast
// past its safety check needs none. A load still extends from its own
// width, since memory written through another type (a `@ptrCast` pointer)
// may hold any bits above it, and a cast without its check (runtime
// safety off) bounds nothing. (A value out of range there is illegal
// behavior, on which upstream's backends disagree, so `unchecked` gets
// one in range.) Upstream checks it with LLVM: its x86_64 backend trusts
// the bits a load finds.
const std = @import("std");

const M = packed struct(u8) { fp: u7, used: u1 };

var bytes: [4]u8 = .{ 0xfa, 0xff, 0x80, 0x7f };
var hashes: [3]u64 = .{ 0xfedc_ba98_7654_3210, 0x0123_4567_89ab_cdef, 0x8000_0000_0000_0001 };
var wide: u64 = 0x1f3;
var x21: u21 = 0x1f_ffff;
var x7: u7 = 0x55;
var n: u5 = 3;

noinline fn loadU3(p: *const u8) u3 {
    const q: *const u3 = @ptrCast(p);
    return q.*;
}

noinline fn garbage(p: *const u8) u64 {
    const x = loadU3(p);
    const half = x >> 1;
    const low: u2 = @truncate(x);
    const back: u2 = @intCast(x & 3);
    return @as(u64, half) | @as(u64, low) << 8 | @as(u64, back) << 16 | @as(u64, x | 1) << 24 | @as(u64, x +% 7) << 32;
}

noinline fn takeFingerprint(h: u64) u7 {
    return @truncate(h >> 57);
}

noinline fn mixed(h: u64) u64 {
    const f: u7 = @truncate(h >> 57);
    return @as(u64, f +% f) | @as(u64, f *% 3) << 8 | @as(u64, (f >> 2) << 3) << 16 | @as(u64, (f >> 4) << 4) << 24;
}

noinline fn used(p: [*]const M, i: usize) bool {
    return p[i].used == 1;
}

noinline fn fingerprint(p: [*]const M, i: usize) u7 {
    return p[i].fp;
}

noinline fn unchecked(x: u64) u64 {
    @setRuntimeSafety(false);
    const y: u4 = @intCast(x);
    return @as(u64, y) * 3 + @as(u64, y +% 1);
}

noinline fn checked(x: u64) u64 {
    const y: u4 = @intCast(x & 0xf);
    return @as(u64, y) * 3 + @as(u64, y +% 1);
}

noinline fn shifts(a: u21, b: u7, k: u5) u64 {
    const s1 = a << 6;
    const s2 = a << @intCast(k);
    const s3 = b << 3;
    const s4 = b << @intCast(k);
    const s5 = @as(u21, 0xff) >> @intCast(k);
    return @as(u64, s1) ^ @as(u64, s2) << 21 ^ @as(u64, s3) << 42 ^ @as(u64, s4) << 49 ^ @as(u64, s5) << 56;
}

noinline fn carries(a: u64, b: u64) u64 {
    const r = @addWithOverflow(a, b);
    const s = @subWithOverflow(a, b);
    const c: u1 = r[1] +% s[1];
    return @as(u64, c) << 1 | r[1];
}

pub fn main() void {
    const m: [*]const M = @ptrCast(&bytes);
    std.debug.print("garbage {x} {x}\n", .{ garbage(&bytes[0]), garbage(&bytes[1]) });
    for (hashes) |h| std.debug.print("fp {x} {x} ", .{ takeFingerprint(h), mixed(h) });
    std.debug.print("\n", .{});
    for (0..4) |i| std.debug.print("m {} {x} ", .{ used(m, i), fingerprint(m, i) });
    std.debug.print("\n", .{});
    std.debug.print("unchecked {} checked {}\n", .{ unchecked(wide & 0xf), checked(wide) });
    std.debug.print("shifts {x} {x}\n", .{ shifts(x21, x7, n), shifts(0x12345, 0x7f, 0) });
    std.debug.print("carries {} {} {}\n", .{ carries(~@as(u64, 0), 1), carries(1, 2), carries(5, 5) });
}
