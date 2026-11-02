//! Storage for the on-disk cache of analysis results and Atoms (see "The
//! on-disk cache" in docs/architecture.md). This is the storage layer only:
//! it knows keys, hashes, dependency edges, and Atoms, not Sema.
//!
//! - `Store`: the global store, one file per entry, shared by all projects.
//! - `Manifest`: one compilation's units, result hashes, dependency graph,
//!   input stats, and error codes; one mapped, pointer-free file.
//! - `Pack`: the Atoms that compilation last linked, in one append-only file.
//!
//! Layout:
//!
//!   <global cache>/zap/units/<2 hex>/<32 hex>   Store entries
//!   <local cache>/zap/c/<32 hex>/               one compilation (`compilationDir`)
//!       lock, manifest, manifest.log, pack
//!
//! Files are written once to an unnamed temporary file and linked or
//! renamed into place, so readers never see a partial file. Their contents
//! are trusted: lengths are checked when a file is opened, but indices
//! inside it are not checked on every access.

const std = @import("std");
const Io = std.Io;

pub const Store = @import("cache/Store.zig");
pub const Manifest = @import("cache/Manifest.zig");
pub const Pack = @import("cache/Pack.zig");
pub const atoms = @import("cache/atoms.zig");

/// A 128-bit content or identity hash.
pub const Hash = u128;

/// The directory of one compilation's manifest and pack under the local
/// cache. `key` identifies the compilation: root source path, target,
/// options, and output name.
pub fn compilationDir(io: Io, local_cache: Io.Dir, key: Hash) !Io.Dir {
    const hex = std.fmt.hex(key);
    var buf: [64]u8 = undefined;
    const sub_path = std.fmt.bufPrint(&buf, "zap/c/{s}", .{&hex}) catch unreachable;
    return local_cache.createDirPathOpen(io, sub_path, .{});
}

/// Takes the compilation's lock, held until the returned file is closed.
/// Builds of one compilation take turns; the manifest and pack are only
/// changed under it. The global store needs no lock.
pub fn lock(io: Io, dir: Io.Dir) !Io.File {
    return dir.createFile(io, "lock", .{ .truncate = false, .lock = .exclusive });
}

/// Maps `sub_path` read-only, or returns null if it does not exist.
pub fn mapFile(io: Io, dir: Io.Dir, sub_path: []const u8) !?Io.File.MemoryMap {
    const f = dir.openFile(io, sub_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    defer f.close(io);
    return try mapOpenFile(io, f, try f.length(io), false);
}

/// Maps `len` bytes of `f` read-only. `populate` faults every page in up
/// front, which is faster than faulting them one by one when they will all
/// be read.
pub fn mapOpenFile(io: Io, f: Io.File, len: u64, populate: bool) !Io.File.MemoryMap {
    return .create(io, f, .{ .len = @intCast(len), .protection = .{ .read = true }, .populate = populate });
}

/// Writes `parts` to a new file that atomically replaces `sub_path`.
pub fn writeReplace(io: Io, dir: Io.Dir, sub_path: []const u8, parts: []const []const u8) !void {
    var af = try dir.createFileAtomic(io, sub_path, .{ .replace = true });
    defer af.deinit(io);
    try writeParts(io, af.file, parts);
    try af.replace(io);
}

/// Writes up to 16 `parts` to `f`.
pub fn writeParts(io: Io, f: Io.File, parts: []const []const u8) !void {
    // `writeVecAll` advances the slices it is given.
    var vecs: [16][]const u8 = undefined;
    @memcpy(vecs[0..parts.len], parts);
    var w = f.writerStreaming(io, &.{});
    w.interface.writeVecAll(vecs[0..parts.len]) catch return w.err.?;
    w.interface.flush() catch return w.err.?;
}

/// Two seeded Wyhash passes, as InternPool's stable hashes.
pub fn hash(seed: u64, bytes: []const u8) Hash {
    const lo = std.hash.Wyhash.hash(seed, bytes);
    const hi = std.hash.Wyhash.hash(seed ^ 0x9e3779b97f4a7c15, bytes);
    return @as(Hash, hi) << 64 | lo;
}

test {
    _ = atoms;
    _ = Store;
    _ = Manifest;
    _ = Pack;
}
