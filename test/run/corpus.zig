//! exit: 0
//! stdout: "*corpus.S\n*const corpus.S\n*corpus.S\n5\n"
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
    rt.exit(0);
}
