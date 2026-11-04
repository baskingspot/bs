//! exit: 1
//! flags: -OReleaseSafe -ferror-tracing
//! stdout: "mode safe, error tracing true, valgrind false\n"
//! stderr-contains: "error: TooBig\n"
//! stderr-contains: " in fail (release_safe_trace.zig)\n    if (x > 3) return error.TooBig;\n               ^\n"
//! stderr-contains: " in main (release_safe_trace.zig)\n    _ = try twice(10);\n        ^\n"

// -OReleaseSafe with -ferror-tracing keeps error return traces, as
// upstream's.
const std = @import("std");
const builtin = @import("builtin");

fn fail(x: u32) !u32 {
    if (x > 3) return error.TooBig;
    return x;
}
fn twice(x: u32) !u32 {
    return try fail(x) * 2;
}

pub fn main() !void {
    var buf: [128]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "mode {t}, error tracing {}, valgrind {}\n", .{ builtin.mode, builtin.have_error_return_tracing, builtin.valgrind_support }) catch unreachable;
    std.Io.File.stdout().writeStreamingAll(std.Options.debug_io, s) catch {};
    _ = try twice(10);
}
