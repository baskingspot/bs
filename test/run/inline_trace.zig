//! exit: 0
//! flags: --dep dep -Mroot=test/run/inline_trace.zig -fno-error-tracing -Mdep=test/run/inline_trace/dep.zig
//! stdout: "inline from dep: 2\ninline from root: 2\nswallowed in dep: 1\ntrace in dep: false\n"

// Error return traces across modules, as upstream: the module `dep` does
// not trace, this one does. Returns push in every module once any module
// traces, so each `try` and each `return error` adds a frame wherever it
// is inlined. Restoring the trace when an error is handled, and reading
// it, follow the module of the code, so in an inline call the callee's:
// dep's `swallow`, inlined here, leaves its frame on the trace, and dep's
// `@errorReturnTrace()` is null.
const std = @import("std");
const dep = @import("dep");

pub inline fn rootFail() error{Bad}!void {
    return error.Bad;
}

pub noinline fn noinlineFail() error{Bad}!void {
    return error.Bad;
}

fn viaDep() error{Bad}!void {
    try dep.fail();
}

fn print(name: []const u8, value: anytype) void {
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{s}: {}\n", .{ name, value }) catch unreachable;
    std.Io.File.stdout().writeStreamingAll(std.Options.debug_io, s) catch {};
}

fn index() usize {
    return @errorReturnTrace().?.index;
}

pub fn main() void {
    viaDep() catch print("inline from dep", index());
    dep.viaRoot() catch print("inline from root", index());
    @errorReturnTrace().?.index = 0;
    dep.swallow();
    print("swallowed in dep", index());
    print("trace in dep", dep.hasTrace());
}
