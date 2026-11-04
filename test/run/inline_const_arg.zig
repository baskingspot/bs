//! exit: 0
//! stdout: "126956\n231\n4\n34\n8160\n123161\n"
//! A small callee taking a constant over 16 bytes by value inlines, and
//! its parameter's copy is the constant's own memory (no copy per call).
//! The copy stays when the parameter's memory is written through
//! `@constCast`. A `const` local initialized with a constant (after the
//! rewrite rules fold `if (flag) table else table`) is the constant's
//! memory too, also when its address goes to a call: the call's `*const`
//! parameter is not written either. The constant's address held in a
//! slot instead of a register (inline assembly, register pressure) works
//! the same. Each case prints what upstream's ReleaseSafe build prints.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

const T = struct {
    data: [2205]u8,

    fn get(self: @This(), i: usize) u8 {
        return self.data[i];
    }

    /// Writes the parameter's copy through `@constCast`.
    fn bump(self: @This(), i: usize) u8 {
        const p = @constCast(&self);
        p.data[i] +%= 3;
        return self.data[i];
    }
};

noinline fn readAt(t: *const T, i: usize) u8 {
    return t.data[i];
}

/// With inline assembly no value gets a register.
noinline fn withAsm(i: usize) u32 {
    const table = comptime build();
    asm volatile ("" ::: .{ .memory = true });
    var s: u32 = 0;
    for (0..64) |k| s +%= table.get((i + k) % 2205);
    return s;
}

/// Enough values live across the loop that some are evicted.
noinline fn pressure(i: usize) u64 {
    const table = comptime build();
    var a: [14]u64 = undefined;
    inline for (&a, 0..) |*x, n| x.* = i *% (n + 3);
    var k: usize = 0;
    while (k < 64) : (k += 1) {
        inline for (&a, 0..) |*x, n| x.* +%= table.get((i + k + n) % 2205);
    }
    var s: u64 = 0;
    inline for (a) |x| s +%= x;
    return s;
}

fn build() T {
    @setEvalBranchQuota(10000);
    var t: T = undefined;
    for (&t.data, 0..) |*d, i| d.* = @truncate(i *% 7);
    return t;
}

var idx: usize = 5;
var flag: bool = true;

pub fn main() noreturn {
    const table = comptime build();
    var s: u32 = 0;
    for (0..1000) |k| s +%= table.get((idx + k) % 2205);
    rt.printInt(s);
    const t: T = if (flag) table else table;
    rt.printInt(readAt(&t, idx + 28));
    rt.printInt(table.bump(idx - 5) +% table.get(idx - 5) +% 1);
    rt.printInt(table.bump(2) +% table.bump(2));
    rt.printInt(withAsm(idx));
    rt.printInt(pressure(idx));
    rt.exit(0);
}
