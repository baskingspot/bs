//! exit: 0
//! stdout: "4\nabcd\n7\n9\n0\nB\n3\n10\n3\n6\n8\n"
const rt = @import("rt.zig");

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

const E = enum { A, B };
const S = struct { data: [4]u8, f: *const fn () u32 };

fn seven() u32 {
    return 7;
}

fn first(p: *align(1) const u32) u32 {
    return p.*;
}

fn name(comptime e: E) [*:0]const u8 {
    return @tagName(e);
}

fn main() callconv(.c) noreturn {
    var byte: u8 = 4;
    // `*T` to `*[1]T`, and `[N:0]T` to `[N]T`.
    const one: *[1]u8 = &byte;
    rt.printInt(one[0]);
    var s: S = .{ .data = "abcd".*, .f = seven };
    _ = &s;
    rt.print(&s.data);
    rt.print("\n");
    // A function body to a function pointer, optional too.
    const opt: ?*const fn () u32 = seven;
    rt.printInt(s.f() + opt.?() - 7);
    // A pointer whose alignment decreases.
    var x: u32 = 9;
    rt.printInt(first(&x));
    // `&.{}` to a mutable slice and a sentinel many-pointer.
    const empty: []u8 = &.{};
    const z: [*:0]const u8 = &.{};
    rt.printInt(empty.len + z[0]);
    rt.print(name(.B)[0..1]);
    rt.print("\n");
    var c: [*c]const u8 = null;
    c = "abc";
    rt.printInt(@as(u64, @intFromBool(c != null)) + 2);
    // A comptime block's return ends a runtime inline call; arrays coerce
    // between element types of the same representation; tuples coerce
    // field by field, widening optional error sets.
    var unit: u8 = 1;
    _ = &unit;
    const t = table(4);
    rt.printInt(t[3] + unit);
    const names: [2][:0]const u8 = .{ "ab", "cde" };
    var plain: [2][]const u8 = names;
    _ = &plain;
    rt.printInt(plain[1].len);
    const p = widen(true);
    rt.printInt(@intFromBool(p[0] != null) + p[1]);
    // Assembler comments.
    const r = asm volatile (
        \\ movl $7, %%eax # a comment
        \\ addl $1, %%eax // another
        : [ret] "={eax}" (-> u32),
    );
    rt.printInt(r);
    rt.exit(0);
}

inline fn table(comptime n: usize) [n]u8 {
    comptime {
        var out: [n]u8 = undefined;
        for (&out, 0..) |*o, i| o.* = @intCast(i * 3);
        return out;
    }
}
fn widen(fail: bool) struct { ?error{ A, B }, u64 } {
    const narrow: struct { ?error{A}, usize } = .{ if (fail) error.A else null, 5 };
    return narrow;
}
