//! exit: 1
//! stdout: "start 0\ncatch 0\nkept 2\nif-else 2\narg 0\nlabeled 0\ninline 2\ncfn 2\nafter-cfn 2\n"
//! stderr-contains: "error: TooBig\n"
//! stderr-contains: "error_trace.zig:20:16: 0x"
//! stderr-contains: " in fail (error_trace.zig)\n    if (x > 3) return error.TooBig;\n               ^\n"
//! stderr-contains: " in twice (error_trace.zig)\n    return try fail(x) * 2;\n           ^\n"
//! stderr-contains: "error_trace.zig:27:5: 0x"
//! stderr-contains: " in inl (error_trace.zig)\n"
//! stderr-contains: "error_trace.zig:76:9: 0x"
//! stderr-contains: " in main (error_trace.zig)\n    _ = try inl(10);\n        ^\n"
//! targets: x86_64-linux aarch64-macos aarch64-linux

// Error return traces, as upstream: each `.auto` function shares its
// caller's trace, returning an error pushes the return address, and handling
// an error pops what was pushed since. A `callconv(.c)` function that calls
// `.auto` functions makes its own trace.
const std = @import("std");

fn fail(x: u32) !u32 {
    if (x > 3) return error.TooBig;
    return x;
}
fn twice(x: u32) !u32 {
    return try fail(x) * 2;
}
inline fn inl(x: u32) !u32 {
    return twice(x);
}
fn takes(e: anyerror!u32) u32 {
    return e catch 1;
}
fn index() usize {
    return @errorReturnTrace().?.index;
}
fn reset() void {
    @errorReturnTrace().?.index = 0;
}
fn cfn() callconv(.c) usize {
    _ = twice(9) catch 0;
    const kept = twice(9);
    _ = &kept;
    return @errorReturnTrace().?.index;
}
fn labeled(x: u32) u32 {
    return blk: {
        const v = twice(x) catch break :blk 0;
        break :blk v;
    };
}
fn print(name: []const u8, i: usize) void {
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{s} {d}\n", .{ name, i }) catch unreachable;
    std.Io.File.stdout().writeStreamingAll(std.Options.debug_io, s) catch {};
}

pub fn main() !void {
    print("start", index());
    _ = fail(9) catch 0;
    print("catch", index());
    const kept = twice(9);
    _ = &kept;
    print("kept", index());
    reset();
    if (twice(9)) |_| {} else |_| {}
    print("if-else", index());
    reset();
    _ = takes(twice(9));
    print("arg", index());
    reset();
    _ = labeled(9);
    print("labeled", index());
    _ = inl(9) catch 0;
    print("inline", index());
    print("cfn", cfn());
    print("after-cfn", index());
    _ = try inl(10);
}
