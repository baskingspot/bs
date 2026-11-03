//! exit: 0
//! stdout: "1\n1\n1\n0\n1\n97\n111\n1\n1\n1\n1\n"
//! C pointers compared with integers and in order, unwrapped like
//! optionals, and read in place of optional pointers; slices of allowzero
//! pointers; comptime pointer differences and equality by layout.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

const S = extern struct { a: u32, b: u32 };

fn main() callconv(.c) noreturn {
    var y: i32 = 40;
    _ = &y;
    var p1: [*c]u32 = 0;
    _ = &p1;
    const p2: [*c]u32 = y;
    rt.printInt(@intFromBool(p1 == 0 and p1 >= 0 and p2 == 40));
    rt.printInt(@intFromBool(p1 < p2 and p2 > p1 and p2 >= 40));
    var n: [*c]u32 = null;
    _ = &n;
    rt.printInt(@intFromBool(if (n) |_| false else true));
    rt.printInt(@intFromBool(if (p2) |_| false else true));

    var arr = [_]u32{ 5, 6 };
    var cp: [*c]u32 = &arr;
    _ = &cp;
    rt.printInt(@intFromBool(cp.* == 5));

    var slice: []const u8 = "aoeu";
    _ = &slice;
    const opt_many: ?[*]const u8 = slice.ptr;
    var ptr_opt_many = &opt_many;
    const c_ptr: [*c]const [*c]const u8 = ptr_opt_many;
    rt.printInt(c_ptr.*.*);
    ptr_opt_many = c_ptr;
    rt.printInt(ptr_opt_many.*.?[1]);

    var zero: [*]allowzero i32 = @ptrFromInt(0);
    _ = &zero;
    var i: usize = 0;
    _ = &i;
    const zs = zero[i..10];
    rt.printInt(@intFromBool(@TypeOf(zs) == []allowzero i32));

    comptime {
        var x: packed struct { a: u1, b: u1 } = undefined;
        if (&x.b - &x.a != 0) unreachable;
        var s: S = undefined;
        const bytes: *[8]u8 = @ptrCast(&s);
        if (@as(*u32, @ptrCast(@alignCast(&bytes[4]))) != &s.b) unreachable;
    }
    rt.printInt(1);
    rt.printInt(@intFromBool(&arr[1] != &arr[0]));
    rt.printInt(@intFromBool(@as([*c]u32, &arr) + 1 == @as([*c]u32, &arr[1])));
    rt.exit(0);
}
