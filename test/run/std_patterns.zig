//! exit: 0
//! stdout: "7\n1\n255\n255\n1\n0\n0\n4096\n9\n"
//! Patterns std relies on: a generic namespace's declarations captured by
//! nested types (resolved lazily, so a type can capture itself), a runtime
//! block with one comptime-known result, @intFromPtr of optional pointers,
//! and switch prongs of `noreturn` union fields.
const rt = @import("rt.zig");

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

fn SM(comptime T: type) type {
    return struct {
        const Self = @This();
        const Value = union(enum) {
            generic: T,
            reg: struct { a: T, b: u8 },
            pub fn get(self: Value) T {
                return switch (self) {
                    .generic => |v| v,
                    .reg => |r| r.a,
                };
            }
        };
        stack: [4]Value = undefined,
        len: usize = 0,
        pub const Slice = struct {
            ptrs: [2][*]u8,
            len: usize,
            pub fn toSM(s: Slice) Self {
                _ = s;
                return .{};
            }
        };
        pub fn slice(self: Self) Slice {
            return .{ .ptrs = undefined, .len = self.len };
        }
        fn push(self: *Self, v: Value) void {
            self.stack[self.len] = v;
            self.len += 1;
        }
    };
}
fn parse(s: []const u8) error{ Overflow, Bad }!u8 {
    if (s.len > 3) return error.Overflow;
    if (s.len == 0) return error.Bad;
    return @intCast(s.len);
}
var txt: []const u8 = "12345";
const Mode = union(enum) {
    a,
    b: u32,
    w: W,
    const W = if (true) noreturn else struct { x: u16 };
};
fn val(m: Mode) u32 {
    return switch (m) {
        .a => 1,
        .b => |v| v,
        .w => |w| w.x,
    };
}
var g: u32 = 5;
fn main() callconv(.c) noreturn {
    var s: SM(u32) = .{};
    s.push(.{ .reg = .{ .a = 7, .b = 1 } });
    rt.printInt(s.stack[0].get());
    rt.printInt(s.slice().len);
    var i: u8 = 0;
    while (i < 2) : (i += 1) {
        const value = parse(txt) catch |err| switch (err) {
            error.Overflow => 255,
            error.Bad => continue,
        };
        rt.printInt(value);
    }
    var p: ?*u32 = &g;
    var q: ?*const u32 = null;
    _ = .{ &p, &q };
    rt.printInt(@intFromBool(@intFromPtr(p) == @intFromPtr(&g)));
    rt.printInt(@intFromPtr(q));
    rt.printInt(comptime @intFromPtr(@as(?*u8, null)));
    rt.printInt(comptime @intFromPtr(@as(?*u8, @ptrFromInt(0x1000))));
    var m: Mode = .{ .b = 9 };
    _ = &m;
    rt.printInt(val(m));
    rt.exit(0);
}
