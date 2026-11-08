//! exit: 0
//! stderr: "f8091a2b3c4d5e6f ff258bf258bf258b 123456789abcdee 123456589abce03 123456709abcdea 89abce3f 123456789bdfdef 2468acf13579be0 \n22442288224422 123456789abcdef 76543210 20446088a8cce 89abcdef89abcdef 0 123456789ab00ef ffff0123456789ab \n0 0 1 0 \n1 0 1 1 \n"
//! targets: aarch64-macos aarch64-linux
//! aarch64 inline assembly with shifted-register operands (`lsl`, `lsr`,
//! `asr`, and `ror` on the logical instructions), extended registers
//! (`uxtw`, `sxtw`, `uxtb`, with a left shift), an immediate shifted by
//! `lsl #12`, and the aliases built on them (cmp, cmn, tst, neg, mvn, and
//! bic or orn with an immediate). Each case prints what upstream prints.
//! Other targets print the same text without running the assembly.
const std = @import("std");
const builtin = @import("builtin");

noinline fn arith(a: u64, b: u64, w: u32) [8]u64 {
    var r: [8]u64 = undefined;
    r[0] = asm ("add %[o], %[a], %[b], lsl #3"
        : [o] "=r" (-> u64),
        : [a] "r" (a),
          [b] "r" (b),
    );
    r[1] = asm ("sub %[o], %[a], %[b], LSR 7"
        : [o] "=r" (-> u64),
        : [a] "r" (a),
          [b] "r" (b),
    );
    r[2] = asm ("adds %[o], %[a], %[b], asr #63"
        : [o] "=r" (-> u64),
        : [a] "r" (a),
          [b] "r" (b),
        : .{ .nzcv = true });
    r[3] = asm ("add %[o], %[a], %[w:w], sxtw #2"
        : [o] "=r" (-> u64),
        : [a] "r" (a),
          [w] "r" (w),
    );
    r[4] = asm ("sub %[o], %[a], %[w:w], uxtw"
        : [o] "=r" (-> u64),
        : [a] "r" (a),
          [w] "r" (w),
    );
    r[5] = asm ("add %[o:w], %[a:w], %[w:w], uxtb #4"
        : [o] "=r" (-> u64),
        : [a] "r" (a),
          [w] "r" (w),
    );
    r[6] = asm ("add %[o], %[a], #0x123, lsl #12"
        : [o] "=r" (-> u64),
        : [a] "r" (a),
    );
    r[7] = asm ("neg %[o], %[b], lsl #1"
        : [o] "=r" (-> u64),
        : [b] "r" (b),
    );
    return r;
}

noinline fn logic(a: u64, b: u64, w: u32) [8]u64 {
    var r: [8]u64 = undefined;
    r[0] = asm ("and %[o], %[a], %[b], ror #8"
        : [o] "=r" (-> u64),
        : [a] "r" (a),
          [b] "r" (b),
    );
    r[1] = asm ("orr %[o], %[a], %[b], lsl #60"
        : [o] "=r" (-> u64),
        : [a] "r" (a),
          [b] "r" (b),
    );
    r[2] = asm ("eor %[o:w], %[a:w], %[w:w], asr #31"
        : [o] "=r" (-> u64),
        : [a] "r" (a),
          [w] "r" (w),
    );
    r[3] = asm ("bic %[o], %[a], %[b], lsr #4"
        : [o] "=r" (-> u64),
        : [a] "r" (a),
          [b] "r" (b),
    );
    r[4] = asm ("orn %[o], %[a], %[b], ror #32"
        : [o] "=r" (-> u64),
        : [a] "r" (a),
          [b] "r" (b),
    );
    r[5] = asm ("eon %[o], %[a], %[b]"
        : [o] "=r" (-> u64),
        : [a] "r" (a),
          [b] "r" (b),
    );
    r[6] = asm ("bic %[o], %[a], #0xff00"
        : [o] "=r" (-> u64),
        : [a] "r" (a),
    );
    r[7] = asm ("mvn %[o], %[b], lsr #16"
        : [o] "=r" (-> u64),
        : [b] "r" (b),
    );
    return r;
}

/// The flags of the comparisons, as a conditional branch reads them.
noinline fn compare(a: u64, b: u64, w: u32) [4]u64 {
    var r: [4]u64 = undefined;
    r[0] = asm (
        \\cmp %[a], %[b], lsl #1
        \\mov %[o], #1
        \\b.hi 1f
        \\mov %[o], #0
        \\1:
        : [o] "=r" (-> u64),
        : [a] "r" (a),
          [b] "r" (b),
        : .{ .nzcv = true });
    r[1] = asm (
        \\cmn %[a], %[w:w], sxtw
        \\mov %[o], #1
        \\b.eq 1f
        \\mov %[o], #0
        \\1:
        : [o] "=r" (-> u64),
        : [a] "r" (a),
          [w] "r" (w),
        : .{ .nzcv = true });
    r[2] = asm (
        \\tst %[a], %[b], ror #4
        \\mov %[o], #1
        \\b.ne 1f
        \\mov %[o], #0
        \\1:
        : [o] "=r" (-> u64),
        : [a] "r" (a),
          [b] "r" (b),
        : .{ .nzcv = true });
    r[3] = asm (
        \\negs %[o], %[b], asr #1
        \\mov %[o], #1
        \\b.mi 1f
        \\mov %[o], #0
        \\1:
        : [o] "=r" (-> u64),
        : [b] "r" (b),
        : .{ .nzcv = true });
    return r;
}

pub fn main() void {
    if (builtin.cpu.arch != .aarch64) {
        std.debug.print("f8091a2b3c4d5e6f ff258bf258bf258b 123456789abcdee 123456589abce03 123456709abcdea 89abce3f 123456789bdfdef 2468acf13579be0 \n22442288224422 123456789abcdef 76543210 20446088a8cce 89abcdef89abcdef 0 123456789ab00ef ffff0123456789ab \n0 0 1 0 \n1 0 1 1 \n", .{});
        return;
    }
    var a: u64 = 0x0123_4567_89ab_cdef;
    var b: u64 = 0xfedc_ba98_7654_3210;
    var w: u32 = 0x8000_0005;
    _ = .{ &a, &b, &w };
    for (arith(a, b, w)) |x| std.debug.print("{x} ", .{x});
    std.debug.print("\n", .{});
    for (logic(a, b, w)) |x| std.debug.print("{x} ", .{x});
    std.debug.print("\n", .{});
    for (compare(a, b, w)) |x| std.debug.print("{x} ", .{x});
    std.debug.print("\n", .{});
    for (compare(b, a, @truncate(a))) |x| std.debug.print("{x} ", .{x});
    std.debug.print("\n", .{});
}
