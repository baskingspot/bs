//! exit: 0
//! stdout: "7\n1\n255\n255\n1\n0\n0\n4096\n9\n11\n67305985\n0\n4\n2\n2\n7\n10\n"
//! Patterns std relies on: a generic namespace's declarations captured by
//! nested types (resolved lazily, so a type can capture itself), a runtime
//! block with one comptime-known result, @intFromPtr of optional pointers,
//! switch prongs of `noreturn` union fields, comptime evaluation of
//! arguments to comptime parameters, and comparisons that a runtime
//! operand's range decides, const locals stored from a labeled block, and
//! struct literals with an optional result type.
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
const page = 4096;
fn take(m: []align(page) const u8) usize {
    return m.len;
}
fn take2(p: ?[*]align(page) u8) usize {
    return @intFromBool(p != null);
}
fn unmap(memory: []align(page) u8) usize {
    return take(memory.ptr[0..memory.len]) + take2(memory.ptr);
}
var page_buf: [8192]u8 align(page) = undefined;
const Alignment = enum(u6) {
    @"1" = 0,
    @"8" = 3,
    _,
    pub fn toByteUnits(a: Alignment) usize {
        return @as(usize, 1) << @backingInt(a);
    }
    pub fn of(comptime T: type) Alignment {
        return @fromBackingInt(@intCast(@ctz(@as(usize, @alignOf(T)))));
    }
};
fn swapAligned(comptime S: type, comptime a: Alignment, ptr: *align(a.toByteUnits()) S) void {
    ptr.* = @byteSwap(ptr.*);
}
fn swap(comptime S: type, ptr: *S) void {
    swapAligned(S, .of(S), ptr);
}
fn H(comptime a: u4, comptime b: u4) type {
    return struct {
        linked: if (a == b) void else [4]u8 = undefined,
        fn gen(self: *@This(), lens: []const u8) u32 {
            var n: u32 = 0;
            for (a + 1..b + 1) |bits| {
                for (lens) |l| {
                    self.linked[l] = @intCast(bits);
                    n += 1;
                }
            }
            return n;
        }
    };
}
var gb: bool = true;
fn lebLike(comptime signed: bool) u8 {
    const a: u7, var fits: bool = switch (signed) {
        false => blk: {
            const ok = gb;
            break :blk .{ 0, ok };
        },
        true => .{ 1, false },
    };
    _ = &fits;
    if (!signed) comptime {
        if (a != 0) unreachable;
    };
    const b: u7, const c = .{ 3, gb };
    comptime {
        if (b != 3) unreachable;
    }
    return @as(u8, a) + @intFromBool(fits) + @intFromBool(c);
}
const OS = struct { x: u32, y: u8 = 2 };
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
    const pm: []u8 = page_buf[0..10];
    rt.printInt(unmap(@alignCast(pm)));
    var x: u32 = 0x01020304;
    swap(u32, &x);
    rt.printInt(x);
    var h: H(3, 3) = .{};
    var h2: H(1, 3) = .{};
    const lens = [_]u8{ 0, 1 };
    rt.printInt(h.gen(&lens));
    rt.printInt(h2.gen(&lens));
    rt.printInt(lebLike(false));
    rt.printInt(lebLike(true));
    var o: ?OS = .{ .x = 5 };
    _ = &o;
    rt.printInt(o.?.x + o.?.y);
    const oc: ?OS = comptime .{ .x = 9, .y = 1 };
    rt.printInt(oc.?.x + oc.?.y);
    rt.exit(0);
}
