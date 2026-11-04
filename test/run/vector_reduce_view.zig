//! exit: 0
//! stdout: "1\n0\n42\n3\n16\n"
// `@reduce` of a vector bitcast from a load, which the reduce reads in
// place (`Home.view`), as ghostty's bitset `@reduce(.Or, masks)` does;
// bs took it for a fused `firstTrue` select and crashed. The last two
// lines are the fused select itself.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

const S = struct { masks: [4]u64 };

noinline fn any(s: *const S) bool {
    return @reduce(.Or, @as(@Vector(4, u64), @bitCast(s.masks))) != 0;
}

noinline fn sum(p: *const [16]u8) u32 {
    return @reduce(.Add, @as(@Vector(4, u32), @bitCast(p.*)));
}

noinline fn first(v: @Vector(16, u8), x: u8) u32 {
    const iota: @Vector(16, u4) = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    const none: @Vector(16, u4) = @splat(15);
    const m = v == @as(@Vector(16, u8), @splat(x));
    if (!@reduce(.Or, m)) return 16;
    return @reduce(.Min, @select(u4, m, iota, none));
}

fn main() callconv(.c) noreturn {
    var s: S = .{ .masks = .{ 0, 0, 1 << 40, 0 } };
    rt.printInt(@intFromBool(any(&s)));
    s.masks[2] = 0;
    rt.printInt(@intFromBool(any(&s)));
    var b: [16]u8 = @splat(0);
    b[0] = 40;
    b[8] = 2;
    rt.printInt(sum(&b));
    const v: @Vector(16, u8) = .{ 9, 9, 9, 7, 9, 9, 9, 7, 9, 9, 9, 9, 9, 9, 9, 9 };
    rt.printInt(first(v, 7));
    rt.printInt(first(v, 1));
    rt.exit(0);
}
