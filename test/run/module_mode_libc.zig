//! exit: 0
//! libc: true
//! flags: --dep dep -Mroot=test/run/module_mode_libc.zig -OReleaseSafe -Mdep=test/run/module_mode_libc/dep.zig
//! stdout: "root debug, dep safe\n"

// A module whose -O differs gets a builtin of its own, as upstream; with
// -lc only the root module's builtin brings bs's start code, or the
// program would export `_start` twice (zwasm's spec runners: a Debug
// root and a ReleaseSafe `zwasm` module).
const std = @import("std");
const dep = @import("dep");

pub fn main() void {
    _ = std.c.printf("root %s, dep %s\n", @tagName(@import("builtin").mode).ptr, dep.mode().ptr);
}
