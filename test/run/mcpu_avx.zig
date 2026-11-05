//! exit: 0
//! flags: -mcpu=x86_64_v3+pclmul -fomit-frame-pointer
//! targets: x86_64-linux
//! stdout: "avx2 true vector 32\nindex 110\nwide 1072\nchacha afbff36bc7e442cc61339238f19ef0ecf4c8873942ca0ce43dcf217c701a64de\nclmul 4040c0c04040310 f1c\nadd 42\nrep 03101d2a375a5a5a5a5a 5a5a5a5a5a5a5a5a5a5a\n"

// A CPU past x86-64-v2, as the per-CPU kernel objects of
// baskingspot/fastmem ask for: `builtin.cpu` is the requested one, so std
// and the program take their AVX2 paths at comptime (256-bit vectors,
// ChaCha20's two-block lanes), while bs's own code stays SSE. The output
// is the same at x86_64_v2, where those paths are 128 bits wide.
// `-fomit-frame-pointer` is accepted; frame pointers stay. Inline
// assembly ties inputs to outputs ("0") in XMM and general registers,
// with an early clobber, and repeats string instructions.
const std = @import("std");
const builtin = @import("builtin");

const V = @Vector(2, u64);

noinline fn clmul(a: V, b: V) V {
    return asm ("pclmulqdq $0x01, %[b], %[a]"
        : [a] "=x" (-> V),
        : [_] "0" (a),
          [b] "x" (b),
    );
}

noinline fn addTied(a: u64, b: u64) u64 {
    return asm ("addq %[b], %[r]"
        : [r] "=&r" (-> u64),
        : [_] "0" (a),
          [b] "r" (b),
    );
}

noinline fn repMove(dst: [*]u8, src: [*]const u8, n: usize) void {
    var d = dst;
    var s = src;
    var count = n;
    asm volatile ("rep movsb"
        : [d] "={rdi}" (d),
          [s] "={rsi}" (s),
          [count] "={rcx}" (count),
        : [d_in] "{rdi}" (d),
          [s_in] "{rsi}" (s),
          [count_in] "{rcx}" (count),
        : .{ .memory = true });
}

noinline fn repSet(dst: [*]u8, value: u8, n: usize) void {
    var d = dst;
    var count = n;
    asm volatile ("rep stosb"
        : [d] "={rdi}" (d),
          [count] "={rcx}" (count),
        : [d_in] "{rdi}" (d),
          [count_in] "{rcx}" (count),
          [value] "{al}" (value),
        : .{ .memory = true });
    asm volatile ("sfence" ::: .{ .memory = true });
}

noinline fn wide(a: @Vector(32, u8), b: @Vector(32, u8)) u32 {
    const m = @max(a, b) -% @min(a, b);
    return @reduce(.Add, @as(@Vector(32, u32), m));
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    const out = &w.interface;
    try out.print("avx2 {} vector {d}\n", .{ builtin.cpu.has(.x86, .avx2), std.simd.suggestVectorLength(u8).? });

    var bytes: [300]u8 = undefined;
    for (&bytes, 0..) |*c, i| c.* = @truncate(i *% 13 +% 5);
    try out.print("index {?d}\n", .{std.mem.findScalar(u8, &bytes, 0x9b)});
    try out.print("wide {d}\n", .{wide(bytes[0..32].*, bytes[100..132].*)});

    var key: [32]u8 = undefined;
    for (&key, 0..) |*c, i| c.* = @intCast(i);
    var stream: [128]u8 = undefined;
    std.crypto.stream.chacha.ChaCha20IETF.stream(&stream, 1, key, @splat(9));
    try out.print("chacha {x}\n", .{stream[96..]});

    const c = clmul(.{ 0x0123456789abcdef, 0xfedcba9876543210 }, .{ 0x1111, 0x8000000000000001 });
    try out.print("clmul {x} {x}\n", .{ c[0], c[1] });
    try out.print("add {d}\n", .{addTied(40, 2)});

    var dst: [300]u8 = undefined;
    repSet(&dst, 0x5a, dst.len);
    repMove(&dst, &bytes, 123);
    try out.print("rep {x} {x}\n", .{ dst[118..128], dst[290..] });
    try out.flush();
}
