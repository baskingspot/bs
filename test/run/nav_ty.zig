//! exit: 0
//! stdout: "1\n1\n2\n1\n1\n1\n"
//! rebuild-replace: ".n = 2" ".n = 1"
//! Taking a declaration's address needs only its stated type, as
//! upstream's `nav_ty`: `x` and `y` take each other's address, and `main`
//! reaches `y` first, so `&x` must not need `x`'s value. The edit changes
//! only `x`'s value: `y` is loaded, and must not bring back the cycle.
//! A function type tells whether a parameter is comptime-only from its
//! type's fields, resolved on their own, so `F`, made before `T` is used,
//! is the same type as `fn (T) void` made after. Reading them may lead
//! back to the declaration being resolved (`P.FnPtr`), which upstream,
//! not asking, accepts: that function type takes `P` as it is.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

const S = struct { p: *const anyopaque, n: u32 };
var x: S = .{ .p = @ptrCast(&y), .n = 2 };
var y = &x;

const T = struct { t: type };
const F = fn (T) void;
const U = struct { f: *const fn (U) void, t: type };
const P = struct {
    const FnPtr = ?*const fn (@This()) void;
    fn_ptr: FnPtr,
};

fn main() callconv(.c) noreturn {
    rt.printInt(@intFromBool(@intFromPtr(y) == @intFromPtr(&x)));
    rt.printInt(@intFromBool(@intFromPtr(x.p) == @intFromPtr(&y)));
    rt.printInt(x.n);
    const f_first = F;
    const t: T = .{ .t = u8 };
    _ = t;
    rt.printInt(@intFromBool(f_first == fn (T) void));
    rt.printInt(@intFromBool(@typeInfo(@typeInfo(@FieldType(U, "f")).pointer.child).@"fn".is_generic));
    const p_ptr: P.FnPtr = @ptrFromInt(0x100000);
    const p: P = .{ .fn_ptr = p_ptr };
    rt.printInt(@intFromBool(@TypeOf(p.fn_ptr.?) == *const fn (P) void));
    rt.exit(0);
}
