//! exit: 0
//! stdout: "4294967295\n4294967294\n5\n120\n18\n1069547520\n1\n43971\n2751\n9\n4294967296\n200\n0\n52\n3\n9\n131071\n1\n1\n2049\n95\n64\n"
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

/// Loads and stores through pointers cast at comptime see the memory of
/// the variable they point into, as laid out on the target.
const S1 = extern struct { a: u8, b: u16, c: u8 };
const S2 = extern struct { a: u32 align(2), c: u8 };
const Bytes = struct {
    bytes: [4]u8,
    fn init(v: u32) Bytes {
        var res: Bytes = undefined;
        @as(*align(1) u32, @ptrCast(&res.bytes)).* = v;
        return res;
    }
};
const P = packed struct(u16) { a: u4, b: u12 };
const T = extern struct { x: u32, y: f32, z: [2]void };
const S = packed struct(u16) { lo: u8, hi: u8 };
const VS = struct { x: u32 };
// A comptime call through a constant that points to a comptime variable
// mutates it each time; it is not memoized.
fn doublePtrTest() u32 {
    var a: u32 = 0;
    const ptr = &a;
    const double_ptr = &ptr;
    setDoublePtr(double_ptr, 1);
    setDoublePtr(double_ptr, 2);
    setDoublePtr(double_ptr, 1);
    return a;
}
fn setDoublePtr(ptr: *const *const u32, value: u32) void {
    const mut_ptr: *u32 = @constCast(ptr.*);
    mut_ptr.* = value;
}

fn main() callconv(.c) noreturn {
    const r = comptime blk: {
        var x: u32 = 0;
        const y = @as(*i32, @ptrCast(&x));
        y.* = -1;
        var out: [12]u64 = undefined;
        out[0] = x;
        var arr: [11]u32 = undefined;
        var m: [*]i32 = @ptrCast(&arr[10]);
        m -= 10;
        m[10] = -2;
        out[1] = arr[10];
        var s1 align(2) = S1{ .a = 0, .b = 0, .c = 5 };
        const s2: *const S2 = @ptrCast(&s1);
        out[2] = s2.c;
        const b = Bytes.init(0x12345678);
        out[3] = b.bytes[0];
        out[4] = b.bytes[3];
        const f: f32 = 1.5;
        out[5] = @as(*const u32, @ptrCast(&f)).*;
        var fl: [2]f32 = .{ 0, 0 };
        @as(*[8]u8, @ptrCast(&fl))[3] = 0x3f;
        @as(*[8]u8, @ptrCast(&fl))[2] = 0x80;
        out[6] = @intFromFloat(fl[0]);
        var p: P = .{ .a = 3, .b = 0xabc };
        out[7] = @as(*const u16, @ptrCast(&p)).*;
        @as(*[2]u8, @ptrCast(&p))[0] = 0xff;
        out[8] = p.b;
        const ext = extern struct { x: u32, y: u64 }{ .x = 7, .y = 9 };
        out[9] = @as(*const [16]u8, @ptrCast(&ext))[8];
        var wide: u64 = 0;
        @as(*[2]u32, @ptrCast(&wide))[1] = 1;
        out[10] = wide;
        const e: enum(u8) { a = 4, b = 200 } = .b;
        out[11] = @as(*const u8, @ptrCast(&e)).*;
        break :blk out;
    };
    for (r) |v| rt.printInt(v);
    const r2 = comptime blk: {
        var out: [5]u64 = undefined;
        var val: T = undefined;
        const bytes: *[@sizeOf(T)]u8 = @ptrCast(&val);
        @memset(bytes, 0);
        out[0] = val.x;
        const data: [2:0]u8 = .{ 0x12, 0x34 };
        const ptr: *align(1) const S = @ptrCast(&data);
        out[1] = ptr.hi;
        var arr: [4]VS = .{ .{ .x = 1 }, .{ .x = 2 }, .{ .x = 3 }, .{ .x = 4 } };
        const buf: [*]align(@alignOf(VS)) u8 = @ptrCast(&arr);
        const second: *VS = @ptrCast(buf + 2 * @sizeOf(VS));
        out[2] = second.x;
        second.x = 9;
        out[3] = arr[2].x;
        const p0: *void = undefined;
        _ = p0.*;
        const a: u32 = 0x1ffff;
        const b: *const packed struct { x: u17 } = @ptrCast(&a);
        out[4] = b.x;
        break :blk out;
    };
    for (r2) |v| rt.printInt(v);
    rt.printInt(comptime doublePtrTest());
    // A single-item pointer cast to a slice of its own type has length 1,
    // whatever the size.
    const one: []const void = @ptrCast(&{});
    rt.printInt(one.len);
    // A store through an element of a byte view of a `[2]u16`, cast to an
    // unaligned `u16`, writes the bytes it covers, not element 1.
    const unaligned = comptime blk: {
        var x: [2]u16 = .{ 1, 8 };
        const q: *[4]u8 = @ptrCast(&x);
        const w: *align(1) u16 = @ptrCast(&q[1]);
        w.* = 0x5f08;
        break :blk x;
    };
    rt.printInt(unaligned[0]);
    rt.printInt(unaligned[1]);
    // An f80's padding bytes read as zeros, as upstream's.
    const f80_bytes = comptime blk: {
        var x: f80 = 2.5;
        _ = &x;
        break :blk @as(*const [16]u8, @ptrCast(&x)).*;
    };
    var pad_sum: u64 = 0;
    for (f80_bytes[10..]) |b| pad_sum += b;
    rt.printInt(pad_sum + f80_bytes[9]);
    rt.exit(0);
}
