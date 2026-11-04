//! exit: 0
//! stdout: "bs17\n2\n15\n65\n1\n253\n9\n42\n1\n6\n16\n1000\n1\n2\n7\n137\nbs7\n1\n2\nbb3\n"
//! `@import` of ZON files, with a result type (structs with defaults,
//! arrays, slices, tuples, unions, enums, optionals, integers, floats with
//! inf and nan) and without one (anonymous structs and tuples of comptime
//! fields).
const rt = @import("rt.zig");

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

const Mode = enum { fast, slow, debug };
const Kind = union(enum) { int: u32, none };
const Data = struct {
    name: []const u8,
    version: [3]u8,
    tags: []const Mode,
    ratio: f32,
    count: u8,
    opt: ?u16,
    nested: struct { a: i8, b: bool, c: u4 = 9 },
    kind: Kind,
    mode: Mode,
    bytes: [3:0]u8,
    big: u128,
    neg: f64,
    extra: u8 = 7,
};
const data: Data = @import("zon/data.zon");
const Op = enum { add, sub };
const list: []const struct { Op, []const u8, u16 } = @import("zon/list.zon");
const fl: [4]f32 = @import("zon/fl.zon");
const anon = @import("zon/data.zon");
const anon_list = @import("zon/list.zon");
pub fn main() void {
    rt.print(data.name);
    rt.printInt(data.version[1]);
    rt.printInt(@intFromEnum(data.tags[1]));
    rt.printInt(@intFromFloat(data.ratio * 10));
    rt.printInt(data.count);
    rt.printInt(@intFromBool(data.opt == null));
    rt.printInt(@as(u8, @bitCast(data.nested.a)));
    rt.printInt(data.nested.c);
    rt.printInt(data.kind.int);
    rt.printInt(@intFromEnum(data.mode));
    rt.printInt(data.bytes[2] + data.bytes.len);
    rt.printInt(@intCast(data.big >> 60));
    rt.printInt(@intFromFloat(-data.neg));
    rt.printInt(@intFromBool(fl[0] > 1e38 and fl[1] < -1e38 and fl[2] != fl[2]));
    rt.printInt(@intFromFloat(fl[3]));
    rt.printInt(data.extra);
    var total: u64 = 0;
    for (list) |e| total += @as(u64, @intFromEnum(e[0])) * 100 + e[1].len * 10 + e[2];
    rt.printInt(total);
    rt.print(anon.name);
    rt.printInt(anon.version[2] + anon.nested.a + 10);
    rt.printInt(@intFromBool(anon.tags[0] == .fast));
    rt.printInt(anon_list.len);
    rt.print(anon_list[1][1]);
    rt.printInt(@intFromFloat(anon.ratio * 2));
    rt.exit(0);
}
