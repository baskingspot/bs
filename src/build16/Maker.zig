//! bs's stand-in for upstream 0.17.1's lib/compiler/Maker.zig, beside the
//! package fetcher that build.zig copies from that lib directory
//! (`Maker/Fetch.zig`, `Maker/Package.zig` and what they import): the
//! one type the fetcher takes from Maker.zig, `CliModule`, and the package
//! code for bs's `bs build` of Zig 0.16 projects (src/Build16.zig), which
//! fetches with 0.17's fetcher as 0.16's compiler fetched with its own.
//!
//! `CliModule` is upstream's, under its MIT license:
//! Copyright (c) Zig contributors (see LICENSE-ZIG).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Package = @import("Maker/Package.zig");

/// The modules of the build runner's compilation, as `-M` flags.
pub const CliModule = struct {
    name: []const u8,
    root_path: []const u8,
    deps: Deps = .empty,

    pub const Deps = std.array_hash_map.String(*CliModule);

    /// Appends the module's `--dep` flags and its `-M` flag.
    pub fn lower(cm: *const CliModule, arena: Allocator, argv: *std.ArrayList([]const u8)) !void {
        try argv.ensureUnusedCapacity(arena, 2 * cm.deps.count() + 1);
        for (cm.deps.keys(), cm.deps.values()) |name, dep| {
            argv.appendAssumeCapacity("--dep");
            if (std.mem.eql(u8, name, dep.name)) {
                argv.appendAssumeCapacity(dep.name);
            } else {
                argv.appendAssumeCapacity(try arena.print("{s}={s}", .{ name, dep.name }));
            }
        }
        argv.appendAssumeCapacity(try arena.print("-M{s}={s}", .{ cm.name, cm.root_path }));
    }
};
