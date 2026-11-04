//! exit: 0
//! stdout: "*corpus.S\n*const corpus.S\n*corpus.S\n5\n42\n9\n1\n1\n1\n1\n1\n300\n20\n3\n2\n42\n7\n1\n2\n"
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

// zig-clap (clap.zig): a field seen as a one-element array (`*T` to
// `*[1]T`) loads as the array at comptime.
const Names = struct {
    short: ?u8 = null,
    fn longest(n: *const Names) []const u8 {
        if (n.short) |*s| return @as(*const [1]u8, s);
        return "";
    }
};

// superhtml (css/Ast.zig): a function in an anonymous struct's field is
// called with method syntax.
fn twice(x: u32) u32 {
    return 2 * x;
}
const rules = .{.{ .name = "a", .func = twice }};

// zig-protobuf (protobuf.zig): a prong over several union fields captures
// the active one at comptime, coerced to their peer type if they differ.
const Repeated = union(enum) { scalar: u8, submessage: void };
const FieldType = union(enum) { repeated: Repeated, packed_repeated: Repeated, small: u8, wide: u16 };
fn isSubmessage(comptime t: FieldType) bool {
    return switch (t) {
        .repeated, .packed_repeated => |r| r == .submessage,
        else => false,
    };
}
fn width(comptime t: FieldType) u32 {
    return switch (t) {
        .small, .wide => |w| w,
        else => 0,
    };
}

// zig-protobuf (wire.zig): `if (runtime) comptime continue;` in an inline
// loop continues only when the condition holds.
fn pick(x: u32) u32 {
    var r: u32 = 0;
    inline for (.{ 1, 2, 3 }) |n| {
        if (n != x) comptime continue;
        r += n * 10;
    }
    return r;
}

// zig-minisign (wasm.zig): @enumFromInt takes an integer of any type.
const Result = enum(isize) { overflow = -12, _ };
const Small = enum(u8) { a, b, c };
fn resultFromLen(len: usize) Result {
    return @enumFromInt(len);
}
fn small(i: u32) Small {
    return @enumFromInt(i);
}

// ziggy (known-folders): a struct literal that leaves a comptime field to
// its default stores nothing for it, not the default over a runtime field.
const Config = struct { a: u32 = 7, b: bool = true };
const WithConfig = struct {
    comptime config: Config = .{},
    p: *const u64,
};

// zio (ev/backends/linux/epoll.zig): a function returning a smaller error
// set coerces to a function type returning `anyerror`.
const SockErr = error{ Refused, Reset };
fn sockErr(code: u32) SockErr {
    return if (code == 0) error.Refused else error.Reset;
}
fn handleErr(comptime toErr: fn (u32) anyerror, code: u32) anyerror {
    return toErr(code);
}

// libxev (watcher/stream.zig): a callback whose parameter takes more errors
// coerces to a callback type that passes fewer.
fn readCb(r: error{ Eof, Reset, Canceled }!u32) u32 {
    return r catch |e| switch (e) {
        error.Eof => 1,
        error.Reset => 2,
        error.Canceled => 3,
    };
}
fn readWith(comptime cb: *const fn (r: error{ Eof, Reset }!u32) u32, r: error{ Eof, Reset }!u32) u32 {
    return cb(r);
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

    rt.printInt(runCases([_]Case{ .{ .expected = 40 }, .{ .expected = 2 } }, expected));
    _ = &Pair;

    var len: u7 = 9;
    _ = &len;
    rt.printInt(lenField(.{ .len = len }));

    global_opt = .{ .x = 1, .y = "y" };
    global_eu = .{ .x = 1 };
    rt.printInt(global_opt.?.x);
    rt.printInt((global_eu catch unreachable).x);

    const arr = comptime blk: {
        const n: Names = .{ .short = 'a' };
        const l = n.longest();
        break :blk l[0..l.len].*;
    };
    rt.printInt(@intFromBool(@TypeOf(arr) == [1]u8 and arr[0] == 'a'));
    rt.printInt(@intFromBool(rules[0].func(21) == 42));

    rt.printInt(@intFromBool(comptime isSubmessage(.{ .packed_repeated = .submessage })));
    rt.printInt(comptime width(.{ .wide = 300 }));

    var two: u32 = 2;
    _ = &two;
    rt.printInt(pick(two));

    var three: u32 = 3;
    _ = &three;
    rt.printInt(@intCast(@intFromEnum(resultFromLen(three))));
    rt.printInt(@intFromEnum(small(three - 1)));

    const x: u64 = 42;
    var wc: WithConfig = .{ .p = &x };
    _ = &wc;
    rt.printInt(wc.p.*);
    rt.printInt(wc.config.a);

    rt.printInt(@intFromBool(handleErr(sockErr, 1) == error.Reset));
    var eof: error{ Eof, Reset }!u32 = error.Reset;
    _ = &eof;
    rt.printInt(readWith(readCb, eof));
    rt.exit(0);
}
