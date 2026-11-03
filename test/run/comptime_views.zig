//! exit: 0
//! stdout: "abc/abc/abc/x.txt\n01/01/b\n2\n4\n12\nellorl\n252\n1\n2\n3\n2\n1\n3\n15\n"
//! Comptime memory read through views of another shape: arrays of arrays
//! as bytes, slices that start inside an element, subarrays of comptime
//! arrays, `++` of such slices, and indexing a pointer to a tuple.
const rt = @import("rt.zig");

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

fn repeat(comptime n: usize, comptime s: []const u8) []const u8 {
    const buf: [n][s.len]u8 = @splat(s[0..s.len].*);
    return @ptrCast(&buf);
}

fn cat(comptime a: []const u8, comptime b: []const u8) []const u8 {
    return a ++ b;
}

const E = enum { none, a, bb, c };
const names = @typeInfo(E).@"enum".field_names;
const tail = names[1..];
const words = [_][:0]const u8{ "x", "yy", "zzz" };
const word_slice: []const [:0]const u8 = &words;
const nums = [_]u32{ 1, 2, 3, 4, 5 };
const tuple = .{ @as(u32, 7), @as(u8, 8) };

pub fn main() void {
    // Arrays of arrays read as one byte slice.
    const name = comptime blk: {
        const buf: [3][4]u8 = @splat("abc/".*);
        const dir: []const u8 = @ptrCast(&buf);
        break :blk dir ++ "x.txt";
    };
    rt.print(name);
    rt.print("\n");
    const r = comptime repeat(2, "01/") ++ "b";
    rt.print(r);
    rt.print("\n");
    // A byte slice that starts inside the first inner array.
    const bytes: []const u8 = comptime @ptrCast(&[2][2]u8{ .{ 1, 2 }, .{ 3, 4 } });
    const t = comptime bytes[1..];
    rt.printInt(comptime t[0]);
    const a3: *const [3]u8 = comptime t[0..3];
    rt.printInt(comptime a3.*[2]);
    const z = comptime bytes[1..] ++ bytes[0..1];
    rt.printInt(z[0] + z[3] * 10);
    // `++` of comptime slices that do not start at element 0.
    rt.print(comptime cat("hello"[1..], "world"[2..4]));
    rt.print("\n");
    const sum = comptime blk: {
        const sl: []const u32 = nums[1..];
        const y = sl ++ nums[0..2];
        break :blk y[0] + y[3] * 10 + y[5] * 100;
    };
    rt.printInt(sum);
    // Subarrays of comptime arrays.
    const all = comptime blk: {
        const field_names = @typeInfo(E).@"enum".field_names[1..];
        var array: [field_names.len]E = undefined;
        for (field_names, 0..) |field_name, i| array[i] = @field(E, field_name);
        break :blk array;
    };
    for (all) |e| rt.printInt(@intFromEnum(e));
    rt.printInt(comptime names[1..][1].len);
    rt.printInt(tail[2].len);
    rt.printInt(comptime word_slice[1..][1].len);
    // Indexing through a pointer to a tuple.
    const tp = &tuple;
    rt.printInt(tp[0] + tp[1]);
    rt.exit(0);
}
