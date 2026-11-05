//! exit: 1
//! stderr-contains: "error: Overflow\n"
//! stderr-contains: "error_inlined.zig:17:17: 0x"
//! stderr-contains: " in add (error_inlined.zig)\n    if (o != 0) return error.Overflow;\n                ^\n"
//! stderr-contains: "error_inlined.zig:22:15: 0x"
//! stderr-contains: " in grow (error_inlined.zig)\n    const m = try add(len, extra);\n              ^\n"
//! stderr-contains: " in main (error_inlined.zig)\n    _ = try grow(std.math.maxInt(u64), len);\n        ^\n"

// Error-returning helpers with explicit error sets inline (their only kept
// call is the error return trace's push), and the trace still names them:
// each pushed address maps to the inlined callee's line and name, as in the
// program built without inlining.
const std = @import("std");

fn add(a: u64, b: u64) error{Overflow}!u64 {
    const r, const o = @addWithOverflow(a, b);
    if (o != 0) return error.Overflow;
    return r;
}

noinline fn grow(len: u64, extra: u64) error{Overflow}!u64 {
    const m = try add(len, extra);
    return m * 2;
}

pub fn main() !void {
    var len: u64 = 5;
    _ = &len;
    const ok = try grow(len, 7);
    if (ok != 24) unreachable;
    _ = try grow(std.math.maxInt(u64), len);
}
