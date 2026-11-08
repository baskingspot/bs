//! exit: 0
//! stdout: "1\n99\n42\n1\n83\n22\n7\n0\n43\n"
//! Constructs from upstream's compiler source: a runtime index into a
//! `comptime var`, `@fieldParentPtr` with an optional pointer result type,
//! destructuring a `switch` on a comptime-known operand into a type,
//! `inline else` on a tagged union whose tag enum is non-exhaustive, and an
//! inline function whose return type uses a runtime `anytype` parameter.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

fn lookup(comptime set: []const u8, x: u8) ?u8 {
    comptime var map: [8]u8 = @splat(set.len);
    inline for (set, 0..) |e, i| map[e] = i;
    const v = map[x & 7];
    return if (v < set.len) v else null;
}

const Base = struct { tag: u8 };
const A = struct { x: u32, base: Base };
fn parent(b: *Base) ?*A {
    return if (b.tag == 1) @alignCast(@fieldParentPtr("base", b)) else null;
}

const Tag = enum { a, b };
fn size(comptime tag: Tag) usize {
    const T, const name = switch (tag) {
        .a => .{ u16, "aa" },
        .b => .{ u64, "bbb" },
    };
    return @sizeOf(T) * 10 + name.len;
}

const Class = enum(u8) { none = 0, @"32" = 1, @"64" = 2, _ };
const Slice = union(Class) { none: void, @"32": []const u32, @"64": []const u64 };
fn first(s: Slice) u64 {
    return switch (s) {
        inline else => |v, t| if (t == .none) 0 else v[0],
    };
}

const S = struct {
    v: u32,
    inline fn temps(s: *const S, refs: anytype) [refs.len]u32 {
        var out: [refs.len]u32 = undefined;
        for (&out, &refs) |*o, r| o.* = r + s.v;
        return out;
    }
};

pub fn main() void {
    var x: u8 = 5;
    _ = &x;
    rt.printInt(lookup(&.{ 1, 5, 3 }, x) orelse 99);
    x = 2;
    rt.printInt(lookup(&.{ 1, 5, 3 }, x) orelse 99);

    var a: A = .{ .x = 42, .base = .{ .tag = 1 } };
    rt.printInt(parent(&a.base).?.x);
    a.base.tag = 2;
    rt.printInt(@intFromBool(parent(&a.base) == null));

    var t: Tag = .b;
    _ = &t;
    switch (t) {
        inline else => |tag| rt.printInt(size(tag)),
    }
    rt.printInt(size(.a));

    var s: Slice = .{ .@"64" = &.{ 7, 8 } };
    _ = &s;
    rt.printInt(first(s));
    s = .none;
    rt.printInt(first(s));

    const st: S = .{ .v = 10 };
    var n: u32 = 1;
    _ = &n;
    const r = st.temps([_]u32{ n, n + 1, 7 });
    rt.printInt(r[0] + r[1] + r[2] + r.len);
    rt.exit(0);
}
