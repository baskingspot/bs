//! musl's libc.a and crt1.o for bs's static `-lc` executables of a musl
//! target (`main.Options.musl`), as upstream's `src/libs/musl.zig` builds
//! them from the zig lib directory's sources: which sources (an
//! architecture's directory substitutes for the generic source of the
//! same name) and musl's own C flags. CSource.zig compiles them with
//! upstream's Clang into the global cache.
//! Copyright (c) Zig contributors. MIT licensed (see LICENSE-ZIG).

const std = @import("std");

/// The sources of libc.a for `arch` among a language's `src_files`
/// (`CSource.Recipe.musl_sources`), relative to the lib directory's
/// `libc/`, in upstream's order: `musl/src/<dir>/<arch>/<name>.{s,S,c}`
/// replaces `musl/src/<dir>/<name>.*`, and other architectures'
/// directories are left out. (x86_64 and aarch64 take no time32 compat
/// sources.)
pub fn sources(arena: std.mem.Allocator, arch: std.Target.Cpu.Arch, src_files: []const []const u8) ![]const []const u8 {
    const arch_name = archName(arch);
    var table: std.StringHashMapUnmanaged(void) = .empty;
    for (src_files) |f| try table.put(arena, f, {});
    var out: std.ArrayList([]const u8) = .empty;
    for (src_files) |f| {
        const dir = std.Io.Dir.path.dirname(f).?;
        const base = std.Io.Dir.path.basename(f);
        const stem = base[0 .. base.len - std.Io.Dir.path.extension(base).len];
        if (isArchName(std.Io.Dir.path.basename(dir))) {
            if (!std.mem.eql(u8, std.Io.Dir.path.basename(dir), arch_name)) continue;
        } else {
            const overridden = for ([_][]const u8{ ".s", ".S", ".c" }) |ext| {
                if (table.contains(try arena.print("{s}/{s}/{s}{s}", .{ dir, arch_name, stem, ext }))) break true;
            } else false;
            if (overridden) continue;
        }
        try out.append(arena, f);
    }
    return out.items;
}

/// musl's flags after the compilation's (`addCcArgs`), for a source of
/// libc.a or crt1.o: `-O3` for the string and internal C sources
/// (`wantsO3`), `-Os` for the others.
pub fn ccArgs(arena: std.mem.Allocator, lib: []const u8, arch: std.Target.Cpu.Arch, o3: bool) ![]const []const u8 {
    const join = std.Io.Dir.path.join;
    const arch_name = archName(arch);
    return arena.dupe([]const u8, &.{
        "-std=c99",
        "-ffreestanding",
        "-fexcess-precision=standard",
        "-frounding-math",
        "-ffp-contract=off",
        "-fno-strict-aliasing",
        "-Wa,--noexecstack",
        "-D_XOPEN_SOURCE=700",
        "-I",
        try join(arena, &.{ lib, "libc", "musl", "arch", arch_name }),
        "-I",
        try join(arena, &.{ lib, "libc", "musl", "arch", "generic" }),
        "-I",
        try join(arena, &.{ lib, "libc", "musl", "src", "include" }),
        "-I",
        try join(arena, &.{ lib, "libc", "musl", "src", "internal" }),
        "-I",
        try join(arena, &.{ lib, "libc", "musl", "include" }),
        "-I",
        try join(arena, &.{ lib, "libc", "include", if (arch == .aarch64) "aarch64-linux-musl" else "x86_64-linux-musl" }),
        "-I",
        try join(arena, &.{ lib, "libc", "include", "generic-musl" }),
        if (o3) "-O3" else "-Os",
        "-Qunused-arguments",
        "-w",
    });
}

/// Whether a source takes `-O3` (`addSrcFile`).
pub fn wantsO3(file: []const u8) bool {
    return std.mem.endsWith(u8, file, ".c") and
        (std.mem.startsWith(u8, file, "musl/src/string/") or std.mem.startsWith(u8, file, "musl/src/internal/"));
}

fn archName(arch: std.Target.Cpu.Arch) []const u8 {
    return std.zig.target.muslArchName(arch, .musl);
}

fn isArchName(name: []const u8) bool {
    const names = [_][]const u8{
        "aarch64",    "arm",     "generic", "hexagon", "i386", "loongarch64", "m68k",
        "microblaze", "mips",    "mips64",  "mipsn32", "or1k", "powerpc",     "powerpc64",
        "riscv32",    "riscv64", "s390x",   "sh",      "x32",  "x86_64",
    };
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}
