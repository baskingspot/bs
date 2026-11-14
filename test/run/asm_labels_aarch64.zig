//! exit: 0
//! stderr: "5050 0 1 3 1 0\n0 0 4\n443b75582d7519c2 5a 5a5a\n1 1\n24 67 248 4 true\ntrue 2 7\n"
//! targets: aarch64-macos aarch64-linux
//! aarch64 inline assembly as hand-written kernels use it: named labels
//! (`.Lloop:`) that branches reach forward and backward, `bhi` for
//! `b.hi`, `tbz` and `tbnz`, alignment directives, loads and stores of
//! the SIMD and floating-point registers (`ldr q0`, `ldur`, `ldp`, `stp`,
//! an index register), `dup` from a general register, `dc zva` sized by
//! `dczid_el0`, and constant expressions. Each case prints what upstream
//! prints. Other targets print the same text without running the assembly.
//! Then two statements on a line, which the object formats separate
//! differently, and a system register read into xzr.
const std = @import("std");
const builtin = @import("builtin");

/// The prefix of an assembler-local label, the only kind a conditional
/// branch reaches on Mach-O, and of a label that is a symbol on ELF.
const l = if (builtin.os.tag == .macos) "L" else ".L";
const g = if (builtin.os.tag == .macos) "L" else "";

/// 1 + 2 + ... + n, by a backward branch to a named label; n == 0 leaves
/// through a forward one.
noinline fn sum(n: u64) u64 {
    var m = n;
    return asm (std.fmt.comptimePrint(
            \\    mov %[o], #0
            \\    cbz %[n], {[l]s}done
            \\{[l]s}loop:
            \\    add %[o], %[o], %[n]
            \\    subs %[n], %[n], #1
            \\    b.ne {[l]s}loop
            \\{[l]s}done:
        , .{ .l = l })
        : [o] "=&r" (-> u64),
          [n] "+r" (m),
        :
        : .{ .nzcv = true });
}

/// Whether `a` is above 5, by a conditional branch without the dot.
noinline fn above(a: u64) u64 {
    return asm (std.fmt.comptimePrint(
            \\    cmp %[a], #5
            \\    mov %[o], #1
            \\    bhi {[l]s}above
            \\    mov %[o], #0
            \\{[l]s}above:
        , .{ .l = l })
        : [o] "=&r" (-> u64),
        : [a] "r" (a),
        : .{ .nzcv = true });
}

/// 1 if bit 5 of `x` is set and 2 if bit 40 is; labels without the `.L`
/// prefix on ELF, one of them before an instruction on its line.
noinline fn bits(x: u64) u64 {
    return asm (std.fmt.comptimePrint(
            \\    mov %[o], #0
            \\    tbz %[x:w], #5, {[g]s}low_clear
            \\    add %[o], %[o], #1
            \\{[g]s}low_clear:
            \\    tbnz %[x], 40, {[g]s}high_set
            \\    b {[g]s}out
            \\{[g]s}high_set: add %[o], %[o], #2
            \\{[g]s}out:
        , .{ .g = g })
        : [o] "=&r" (-> u64),
        : [x] "r" (x),
    );
}

/// The addresses of labels after alignment directives, modulo the
/// alignment, in bytes 0 and 1 of the result, and in byte 2 how far the
/// code after the last directive, which must not pad, is from the label
/// before it.
fn aligned() callconv(.naked) void {
    asm volatile (std.fmt.comptimePrint(
            \\    b {[l]s}over
            \\    nop
            \\    .p2align 5
            \\{[l]s}a:
            \\    nop
            \\    .balign 16
            \\{[l]s}b:
            \\    nop
            \\    .p2align 4,,11
            \\{[l]s}over:
            \\    adr x0, {[l]s}a
            \\    and x0, x0, #31
            \\    adr x1, {[l]s}b
            \\    and x2, x1, #15
            \\    orr x0, x0, x2, lsl #8
            \\    adr x2, {[l]s}over
            \\    sub x2, x2, x1
            \\    orr x0, x0, x2, lsl #16
            \\    ret
        , .{ .l = l }));
}

/// Copies 80 bytes through the SIMD registers in every addressing form,
/// then fills with `dup`.
noinline fn simd(dst: *[96]u8, src: *const [96]u8, c: u8) void {
    var d: [*]u8 = dst;
    var s: [*]const u8 = src;
    var i: u64 = 3;
    asm volatile (
        \\    ldp q0, q1, [%[s]]
        \\    ldr q2, [%[s], #32]
        \\    ldur q3, [%[s], #47]
        \\    ldr q4, [%[s], %[i], lsl #4]
        \\    ldr d5, [%[s], 64]!
        \\    ldr s6, [%[s], #8]
        \\    ldr h7, [%[s], #12]
        \\    ldr b16, [%[s], #14]
        \\    stp q0, q1, [%[d]], #32
        \\    str q2, [%[d]]
        \\    stur q3, [%[d], #15]
        \\    str q4, [%[d], #16]
        \\    str d5, [%[d], #32]!
        \\    str s6, [%[d], #8]
        \\    str h7, [%[d], #12]
        \\    str b16, [%[d], #14]
        \\    dup v17.16b, %[c:w]
        \\    stur b17, [%[d], #15]
        \\    stp d17, d17, [%[d], #(2 * 8)]
        : [d] "+r" (d),
          [s] "+r" (s),
        : [i] "r" (i),
          [c] "r" (c),
        : .{ .v0 = true, .v1 = true, .v2 = true, .v3 = true, .v4 = true, .v5 = true, .v6 = true, .v7 = true, .v16 = true, .v17 = true, .memory = true });
    _ = .{ &d, &s, &i };
}

/// Zeroes one `dc zva` block inside `buf` and returns whether exactly
/// that block is zero, and whether the block size is a power of two the
/// buffer holds.
noinline fn zva(buf: *align(2048) [4096]u8) [2]u64 {
    const id = asm ("mrs %[o], dczid_el0"
        : [o] "=r" (-> u64),
    );
    const block = @as(usize, 4) << @intCast(id & 15);
    if (id & 16 != 0) {
        // `dc zva` is prohibited here: nothing to run.
        return .{ 1, 1 };
    }
    @memset(buf, 0xff);
    asm volatile ("dc zva, %[p]"
        :
        : [p] "r" (buf[2048..].ptr),
        : .{ .memory = true });
    var zeros: usize = 0;
    for (buf) |x| zeros += @intFromBool(x == 0);
    var inside: usize = 0;
    for (buf[2048..][0..block]) |x| inside += @intFromBool(x == 0);
    return .{ @intFromBool(zeros == block and inside == block), @intFromBool(block <= 2048) };
}

/// Constant expressions. The last one's value depends on the assembler's
/// operator precedence, which is GNU as's on ELF and LLVM's own on Mach-O.
noinline fn exprs() [5]u64 {
    var r: [5]u64 = undefined;
    r[0] = asm ("mov %[o], #(16 + 2 * 4)"
        : [o] "=r" (-> u64),
    );
    r[1] = asm ("mov %[o], #((1 << 6) | 3)"
        : [o] "=r" (-> u64),
    );
    r[2] = asm ("mov %[o], # ( -8 & 0xff )"
        : [o] "=r" (-> u64),
    );
    r[3] = asm ("mov %[o], #(7 / 2 + 7 % 3)"
        : [o] "=r" (-> u64),
    );
    r[4] = asm ("mov %[o], #(1 + 2 << 3)"
        : [o] "=r" (-> u64),
    );
    return r;
}

/// Two statements on a line: `;` separates them on ELF and starts a
/// comment on Mach-O, where `%%` separates, which a template writes
/// `%%%%`.
noinline fn separated() [2]u64 {
    var r: [2]u64 = undefined;
    r[0] = asm ("mov %[o], #1 ; mov %[o], #2"
        : [o] "=r" (-> u64),
    );
    r[1] = asm ("mov %[o], #1 " ++ (if (builtin.os.tag == .macos) "%%%%" else ";") ++ " mov %[o], #2"
        : [o] "=r" (-> u64),
    );
    return r;
}

/// `mrs` into xzr discards the value: x0 keeps its 7.
fn discarded() callconv(.naked) void {
    asm volatile (
        \\    mov x0, #7
        \\    mrs xzr, dczid_el0
        \\    ret
    );
}

pub fn main() void {
    if (builtin.cpu.arch != .aarch64) {
        std.debug.print("5050 0 1 3 1 0\n0 0 4\n443b75582d7519c2 5a 5a5a\n1 1\n24 67 248 4 true\ntrue 2 7\n", .{});
        return;
    }
    var n: u64 = 100;
    var x: u64 = 0x100_0000_0020;
    _ = .{ &n, &x };
    std.debug.print("{d} {d} {d} {d} {d} {d}\n", .{ sum(n), sum(n - 100), bits(x & 0xff), bits(x), above(n), above(n - 97) });

    const al = @as(*const fn () callconv(.c) u64, @ptrCast(&aligned))();
    std.debug.print("{d} {d} {d}\n", .{ al & 0xff, al >> 8 & 0xff, al >> 16 });

    var src: [96]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @truncate(i *% 37 +% 11);
    var dst: [96]u8 = @splat(0);
    simd(&dst, &src, 0x5a);
    var same = true;
    for (dst[0..79], src[0..79]) |d, s| same = same and d == s;
    std.debug.print("{x} {x} {x}\n", .{
        if (same) std.hash.Wyhash.hash(0, dst[0..79]) else 0,
        dst[79],
        std.mem.readInt(u16, dst[80..82], .little) & std.mem.readInt(u16, dst[94..96], .little),
    });

    var buf: [4096]u8 align(2048) = undefined;
    const z = zva(&buf);
    std.debug.print("{d} {d}\n", .{ z[0], z[1] });

    const e = exprs();
    const shifted: u64 = if (builtin.os.tag == .macos) 24 else 17;
    std.debug.print("{d} {d} {d} {d} {}\n", .{ e[0], e[1], e[2], e[3], e[4] == shifted });

    const sep = separated();
    const first: u64 = if (builtin.os.tag == .macos) 1 else 2;
    std.debug.print("{} {d} {d}\n", .{ sep[0] == first, sep[1], @as(*const fn () callconv(.c) u64, @ptrCast(&discarded))() });
}
