//! exit: 0
//! stderr: "sum 11 22 29 44 keep 1 2 3 4 twice 0 low 11 22 f 7.5 2.5 loop 11 44\n"
//! targets: aarch64-macos aarch64-linux
//! A SIMD asm input whose value lives in a register of its own is read
//! there rather than copied. The value must survive the statement when it
//! is used again, may be two inputs at once, and is still copied when the
//! constraint (`x`, v0-v15) excludes its register; an f64 that lives in
//! d8-d15 across a call is read in place too. Elsewhere the same values
//! come from plain operators.
const std = @import("std");
const builtin = @import("builtin");

const a64 = builtin.cpu.arch == .aarch64;

const V = @Vector(4, u32);

inline fn eor(a: V, b: V) V {
    if (!a64) return a ^ b;
    return asm ("eor %[out].16b, %[a].16b, %[b].16b"
        : [out] "=w" (-> V),
        : [a] "w" (a),
          [b] "w" (b),
    );
}

inline fn orrLow(a: V, b: V) V {
    if (!a64) return a | b;
    return asm ("orr %[out].16b, %[a].16b, %[b].16b"
        : [out] "=x" (-> V),
        : [a] "x" (a),
          [b] "x" (b),
    );
}

inline fn orrF(a: f64, b: f64) f64 {
    if (!a64) return @bitCast(@as(u64, @bitCast(a)) | @as(u64, @bitCast(b)));
    return asm ("orr %[out].16b, %[a].16b, %[b].16b"
        : [out] "=w" (-> f64),
        : [a] "w" (a),
          [b] "w" (b),
    );
}

noinline fn opaqueV(x: u32) V {
    return .{ x, 2 * x, 3 * x, 4 * x };
}

noinline fn opaqueF(x: f64) f64 {
    return x;
}

pub fn main() void {
    const a = opaqueV(1);
    const b = opaqueV(10);
    const s = eor(a, b);
    // `a` and `b` are read again after the statement.
    const t = eor(a, a);
    const u = orrLow(s, a);
    const x = opaqueF(5.0);
    const y = opaqueF(2.5);
    // Both live across this call, in d8-d15.
    const z = opaqueF(0);
    const f = orrF(x, x) + orrF(y, z);
    var acc = a;
    var i: u32 = 0;
    while (i < 18) : (i += 1) acc = eor(acc, a) | b;
    std.debug.print("sum {} {} {} {} keep {} {} {} {} twice {} low {} {} f {d} {d} loop {} {}\n", .{
        s[0], s[1], s[2], s[3], a[0], a[1], a[2], a[3], t[3], u[0], u[1], f, y, acc[0], acc[3],
    });
}
