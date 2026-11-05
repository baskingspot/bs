//! exit: 0
//! stderr: "edit_ns_decl 7\n"
//! rebuild-lib-without: "std/debug.zig" "pub const Coverage = @import(\"debug/Coverage.zig\");\n"
//! An edit that only adds a public declaration to an imported file, which
//! no unit uses: the lazy edit build analyzes nothing in it, but the
//! file's namespace lists its names, so the build makes it again and
//! records its new names, as a full build does, instead of leaving it
//! undecided.
const std = @import("std");

pub fn main() void {
    std.debug.print("edit_ns_decl {d}\n", .{7});
}
