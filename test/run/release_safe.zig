//! exit: 1
//! flags: -OReleaseSafe
//! stdout: "mode safe, error tracing false, valgrind false, safety true\ncatch: no trace\ncfn: no trace\n"
//! stderr: "error: TooBig\n"

// -OReleaseSafe, as upstream's: `builtin.mode == .safe` with safety on,
// and neither error return traces nor Valgrind client requests unless
// asked for, so an error returned from main prints no trace. A
// `callconv(.c)` function calling `.auto` ones sets up no trace when no
// module traces.
const std = @import("std");
const builtin = @import("builtin");

fn fail(x: u32) !u32 {
    if (x > 3) return error.TooBig;
    return x;
}
fn twice(x: u32) !u32 {
    return try fail(x) * 2;
}
fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [128]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch unreachable;
    std.Io.File.stdout().writeStreamingAll(std.Options.debug_io, s) catch {};
}
fn trace() []const u8 {
    return if (@errorReturnTrace()) |_| "trace" else "no trace";
}
fn cfn() callconv(.c) void {
    _ = twice(9) catch 0;
    print("cfn: {s}", .{trace()});
}

pub fn main() !void {
    print("mode {t}, error tracing {}, valgrind {}, safety {}", .{ builtin.mode, builtin.have_error_return_tracing, builtin.valgrind_support, std.debug.runtime_safety });
    _ = twice(9) catch 0;
    print("catch: {s}", .{trace()});
    cfn();
    _ = try twice(10);
}
