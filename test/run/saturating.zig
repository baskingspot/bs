//! signal: ABRT
//! stdout: "14874824514990236704\n14874824514990236704\n7078674556814143519\n7078674556814143519\n9223372036854775808\n18446744073709551615\n18446744073709551615\n32767\n18446744073709518848\n10\n28\n3\n16\n"
//! stderr: "panic: shift amount is greater than the type size\n"
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

fn pi(x: anytype) void {
    rt.printInt(@bitCast(@as(i64, x)));
}

/// Saturating arithmetic and shifts, `@shlWithOverflow`, and exact shifts
/// on every pair of boundary values, folded into one checksum per type
/// (runtime and comptime must agree); a shift amount past a non-power-of-two
/// width traps.
fn mix(h: *u64, x: anytype) void {
    h.* = h.* *% 1000003 +% @as(u64, @bitCast(@as(i64, x)));
}

fn sum(comptime T: type, comptime vals: []const T) u64 {
    @setEvalBranchQuota(100000);
    const shifts = [_]u8{ 0, 1, 3, 7, 8, 200 };
    var h: u64 = 0;
    inline for (vals) |ca| inline for (vals) |cb| {
        var a: T = ca;
        var b: T = cb;
        _ = .{ &a, &b };
        mix(&h, a +| b);
        mix(&h, a -| b);
        mix(&h, a *| b);
        inline for (shifts) |cs| {
            var s: u8 = cs;
            _ = &s;
            mix(&h, a <<| s);
            const o = @shlWithOverflow(a, @as(u3, @truncate(s)));
            mix(&h, o[0]);
            mix(&h, o[1]);
        }
    };
    return h;
}

fn main() callconv(.c) noreturn {
    const u = [_]u8{ 0, 1, 100, 200, 255 };
    const i = [_]i8{ -128, -100, -1, 0, 1, 100, 127 };
    rt.printInt(sum(u8, &u));
    rt.printInt(comptime sum(u8, &u));
    rt.printInt(sum(i8, &i));
    rt.printInt(comptime sum(i8, &i));

    var w: i128 = -(1 << 120);
    var w2: u128 = 1 << 127;
    _ = .{ &w, &w2 };
    pi(@as(i64, @truncate((w *| 1000) >> 64)));
    rt.printInt(@truncate((w2 +| w2) >> 64));
    rt.printInt(@truncate((w2 <<| @as(u8, 1)) >> 64));
    var va: @Vector(3, i16) = .{ 32000, -32000, 5 };
    _ = &va;
    const vs = va +| va;
    pi(vs[0]);
    pi(vs[1]);
    pi(vs[2]);

    var x: u5 = 7;
    var sh: u3 = 2;
    _ = .{ &x, &sh };
    pi(@shlExact(x, sh));
    pi(@shrExact(@as(u5, 12), sh));
    sh = 4;
    pi(x << sh);
    sh = 5;
    pi(x << sh); // shift amount is greater than the type size
    rt.exit(0);
}
