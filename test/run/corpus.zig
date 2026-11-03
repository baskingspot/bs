//! exit: 0
//! stdout: "*corpus.S\n*const corpus.S\n*corpus.S\n5\n42\n9\n1\n1\n"
//! Reductions of bugs real projects hit (tools/corpus): each section names
//! the project it came from.
const rt = @import("rt.zig");

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

// zls (analyser/segmented_list.zig): a method call passes an `anytype`
// first parameter the object's address, not a copy.
const S = struct {
    items: [4]u32 = .{ 0, 0, 0, 0 },
    fn name(self: anytype) []const u8 {
        return @typeName(@TypeOf(self));
    }
    fn AtType(comptime Self: type) type {
        return if (@typeInfo(Self).pointer.attrs.@"const") *const u32 else *u32;
    }
    fn at(self: anytype, i: usize) AtType(@TypeOf(self)) {
        return &self.items[i];
    }
};
const Holder = struct { s: S = .{} };
fn atThroughPointer(h: *Holder) *u32 {
    return h.s.at(1);
}

// z2d (internal/util.zig): a generic function passed as a comptime
// function pointer is instantiated by the calls, never compiled on its own.
fn runCases(cases: anytype, comptime f: *const fn (case: anytype) u32) u32 {
    var sum: u32 = 0;
    for (cases) |c| sum += f(c);
    return sum;
}
const Case = struct { expected: u32 };
fn expected(c: anytype) u32 {
    return c.expected;
}

// ghostty (lib/enum.zig): referring to a function with a comptime-only
// parameter or result (`std.testing.refAllDecls`) does not compile it.
fn Pair(n: []const u8) type {
    return [n.len]u8;
}

// zls (features/hover.zig): `len` is an ordinary field of an anonymous
// struct, also through the pointer a parameter is reached by.
fn lenField(args: anytype) usize {
    return args.len;
}

// ghostty (terminal/stream_terminal.zig): a struct literal stored into a
// global optional (or error union) is set at run time.
var global_opt: ?struct { x: u32, y: []const u8 } = null;
var global_eu: error{Bad}!struct { x: u32 } = error.Bad;

fn main() callconv(.c) noreturn {
    var s: S = .{};
    const c: S = .{};
    const p = &s;
    rt.print(s.name());
    rt.print("\n");
    rt.print(c.name());
    rt.print("\n");
    rt.print(p.name());
    rt.print("\n");
    var h: Holder = .{};
    atThroughPointer(&h).* = 5;
    rt.printInt(h.s.items[1]);

    rt.printInt(runCases([_]Case{ .{ .expected = 40 }, .{ .expected = 2 } }, expected));
    _ = &Pair;

    var len: u7 = 9;
    _ = &len;
    rt.printInt(lenField(.{ .len = len }));

    global_opt = .{ .x = 1, .y = "y" };
    global_eu = .{ .x = 1 };
    rt.printInt(global_opt.?.x);
    rt.printInt((global_eu catch unreachable).x);
    rt.exit(0);
}
