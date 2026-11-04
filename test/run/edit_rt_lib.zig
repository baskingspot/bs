//! exit: 0
//! stderr: "1.5\n"
//! rebuild-lib-without: "compiler_rt/fmod.zig" "const arch = builtin.cpu.arch;\n"
//! An edit in a compiler_rt file that a lazy edit build does not load
//! until analysis requests its helper: `fmod`, which `@rem` on f64 calls,
//! moves up a line. The requester is kept, so the build requests the helper
//! again, maps the file's old instructions to its new ones once it loads,
//! and decides its namespace, as a full build does.
const std = @import("std");

pub fn main() void {
    var a: f64 = 7.5;
    var b: f64 = 2.0;
    _ = .{ &a, &b };
    std.debug.print("{d}\n", .{@rem(a, b)});
}
