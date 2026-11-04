//! The module `inline_trace.zig` imports, built with -fno-error-tracing.

pub inline fn fail() error{Bad}!void {
    return error.Bad;
}

/// A function of this module that inlines one of the root module's.
pub fn viaRoot() error{Bad}!void {
    try @import("root").rootFail();
}

/// Handles an error without restoring the trace, inlined.
pub inline fn swallow() void {
    @import("root").noinlineFail() catch {};
}

/// Whether the trace reads as present here, inlined.
pub inline fn hasTrace() bool {
    return @errorReturnTrace() != null;
}
