//! Storage for the on-disk cache of analysis results and Atoms (see "The
//! on-disk cache" in docs/architecture.md). This is the storage layer only:
//! it knows keys, hashes, dependency edges, and Atoms, not Sema.
//!
//! - `Store`: the global store, immutable packs of entries with sorted key
//!   indexes, shared by all projects.
//! - `Manifest`: one compilation's units, result hashes, dependency graph,
//!   input stats, and error codes; one mapped, pointer-free file.
//! - `Pack`: the Atoms that compilation last linked, in one append-only file.
//!
//! Two parts know more than storage: `seeds` reads ZIR, and `results`
//! encodes units' results as InternPool items, both for edit builds.
//!
//! Layout:
//!
//!   <global cache>/zap/store/<32 hex>.zsp       Store packs
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
pub const seeds = @import("cache/seeds.zig");
pub const results = @import("cache/results.zig");

/// A 128-bit content or identity hash.
pub const Hash = u128;

/// The directory of one compilation's manifest and pack under the local
/// cache. `key` identifies the compilation: root source path, target,
/// options, and output name.
pub fn compilationDir(io: Io, local_cache: Io.Dir, key: Hash) !Io.Dir {
    const hex = std.fmt.hex(key);
    var buf: [64]u8 = undefined;
    const sub_path = std.fmt.bufPrint(&buf, "zap/c/{s}", .{&hex}) catch unreachable;
    return local_cache.createDirPathOpen(io, sub_path, .{ .open_options = .{ .iterate = true } });
}

/// Takes the compilation's lock, held until the returned file is closed.
/// Builds of one compilation take turns; the manifest and pack are only
/// changed under it. The global store needs no lock.
pub fn lock(io: Io, dir: Io.Dir) !Io.File {
    const f = try dir.createFile(io, "lock", .{ .truncate = false, .lock = .exclusive });
    // Records use for `maintainCompilations`.
    f.setTimestampsNow(io) catch {};
    return f;
}

/// Compilation directories unused this long are deleted by
/// `maintainCompilations`. They hold hard links to store packs, which keep
/// those packs' disk space in use after the store trims them.
pub const max_unused_compilation_ns = 5 * std.time.ns_per_day;

/// The default size limit of each of the local cache's compilation
/// directories and the global store; `ZAP_CACHE_MAX_SIZE` overrides it.
pub const default_max_bytes: u64 = 4 << 30;

/// `maintainCompilations` scans at most this often.
const compilations_scan_ns = std.time.ns_per_min;

/// Parses a size limit: bytes, or a number followed by K, M, G, or T
/// (binary multiples).
pub fn parseSize(text: []const u8) ?u64 {
    if (text.len == 0) return null;
    const shift: u6 = switch (std.ascii.toUpper(text[text.len - 1])) {
        'K' => 10,
        'M' => 20,
        'G' => 30,
        'T' => 40,
        else => 0,
    };
    const digits = if (shift == 0) text else text[0 .. text.len - 1];
    const n = std.fmt.parseInt(u64, digits, 10) catch return null;
    return std.math.shlExact(u64, n, shift) catch null;
}

/// Deletes compilation directories under `local_cache`, skipping those a
/// build holds: those whose lock file (touched by `lock`) is older than
/// `max_unused_compilation_ns`, then the least recently used while the
/// directories total more than `max_bytes`, down to three quarters of it.
/// A file hard-linked into several directories counts once, against the
/// most recently used. `zap run`'s program directories (`zap/o`) count
/// and go the same way, by the program's mtime, which every run renews by
/// relinking it or, when nothing changed, by touching it
/// (`Incremental.renew_output`); one is not locked, so a run that relinks the least
/// recently used program at the moment it goes fails, and the next run
/// builds it again. Test binaries in `zap/tmp` that a killed build left
/// go after a day. Runs at most once a minute, so that it costs a build
/// a few stats, and with `force`, which `Incremental` passes for a build
/// that started a directory. `Incremental` runs it once the build's new
/// pack is written, so that it counts. Returns null if it did not run.
pub fn maintainCompilations(gpa: std.mem.Allocator, io: Io, local_cache: Io.Dir, max_bytes: u64, force: bool) !?MaintainResult {
    const now = Io.Clock.real.now(io);
    var c = local_cache.openDir(io, "zap/c", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    defer c.close(io);
    if (c.statFile(io, "trim", .{})) |stat| {
        if (!force and stat.mtime.durationTo(now).toNanoseconds() < compilations_scan_ns) return null;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    }
    try c.writeFile(io, .{ .sub_path = "trim", .data = "" });
    // `zap run`'s programs, one directory per compilation.
    var o: ?Io.Dir = local_cache.openDir(io, "zap/o", .{ .iterate = true }) catch null;
    defer if (o) |*d| d.close(io);
    trimTemporary(io, local_cache, now);

    const File = struct { inode: u64, size: u64 };
    const Entry = struct {
        /// `zap/c/<name>` or `zap/o/<name>`.
        name_buf: [32]u8,
        name_len: u8,
        run: bool,
        /// A compilation's lock file's mtime (null without one: it is
        /// being created), or a program's mtime (null without one).
        used: ?Io.Timestamp = null,
        files: std.ArrayList(File) = .empty,
        bytes: u64 = 0,

        fn name(e: *const @This()) []const u8 {
            return e.name_buf[0..e.name_len];
        }
    };
    var entries: std.ArrayList(Entry) = .empty;
    defer {
        for (entries.items) |*e| e.files.deinit(gpa);
        entries.deinit(gpa);
    }
    for ([_]?Io.Dir{ c, o }, [_]bool{ false, true }) |maybe_dir, run| {
        const dir = maybe_dir orelse continue;
        var it = dir.iterate();
        while (try it.next(io)) |e| {
            if (e.kind != .directory or e.name.len > 32 or (!run and e.name.len != 32)) continue;
            var entry: Entry = .{ .name_buf = undefined, .name_len = @intCast(e.name.len), .run = run };
            @memcpy(entry.name_buf[0..e.name.len], e.name);
            try entries.append(gpa, entry);
        }
    }
    // Each directory's files, stat'ed on several threads: hundreds of
    // directories take milliseconds on one.
    const Worker = struct {
        fn run(gpa_: std.mem.Allocator, io_: Io, c_: Io.Dir, o_: ?Io.Dir, entries_: []Entry, first: usize, stride: usize) void {
            var i = first;
            while (i < entries_.len) : (i += stride) {
                const entry = &entries_[i];
                const parent = if (entry.run) o_.? else c_;
                var d = parent.openDir(io_, entry.name(), .{ .iterate = true }) catch continue;
                defer d.close(io_);
                var files = d.iterate();
                while (files.next(io_) catch null) |e| {
                    if (e.kind != .file) continue;
                    const stat = d.statFile(io_, e.name, .{}) catch continue;
                    if (entry.run) {
                        // A run that reuses the program renews its
                        // mtime.
                        if (entry.used == null or stat.mtime.compare(.gt, entry.used.?)) entry.used = stat.mtime;
                    } else if (std.mem.eql(u8, e.name, "lock")) entry.used = stat.mtime;
                    entry.files.append(gpa_, .{ .inode = @intCast(stat.inode), .size = stat.size }) catch return;
                }
            }
        }
    };
    const n_threads = @max(1, @min(16, std.Thread.getCpuCount() catch 1, entries.items.len / 32));
    var group: Io.Group = .init;
    for (1..n_threads) |t| group.async(io, Worker.run, .{ gpa, io, c, o, entries.items, t, n_threads });
    Worker.run(gpa, io, c, o, entries.items, 0, n_threads);
    try group.await(io);
    var n_entries: usize = 0;
    for (entries.items) |*e| {
        if (e.used == null) {
            e.files.deinit(gpa);
            continue;
        }
        entries.items[n_entries] = e.*;
        n_entries += 1;
    }
    entries.shrinkRetainingCapacity(n_entries);
    // Most recently used first.
    std.mem.sortUnstable(Entry, entries.items, {}, struct {
        fn newer(_: void, a: Entry, b: Entry) bool {
            return a.used.?.compare(.gt, b.used.?);
        }
    }.newer);
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(gpa);
    var total: u64 = 0;
    for (entries.items) |*e| {
        for (e.files.items) |f| {
            if ((try seen.getOrPut(gpa, f.inode)).found_existing) continue;
            e.bytes += f.size;
        }
        total += e.bytes;
    }
    var result: MaintainResult = .{ .scanned = @intCast(entries.items.len), .bytes = total };
    const over = total > max_bytes;
    const target = max_bytes - max_bytes / 4;
    // Least recently used first.
    var i = entries.items.len;
    while (i > 0) {
        i -= 1;
        const e = &entries.items[i];
        const old = e.used.?.durationTo(now).toNanoseconds() > max_unused_compilation_ns;
        if (!old and (!over or total <= target)) break;
        if (e.run) {
            o.?.deleteTree(io, e.name()) catch continue;
        } else {
            var buf: [64]u8 = undefined;
            const lock_path = std.fmt.bufPrint(&buf, "{s}/lock", .{e.name()}) catch unreachable;
            const f = c.openFile(io, lock_path, .{ .mode = .read_write }) catch continue;
            defer f.close(io);
            if (!(f.tryLock(io, .exclusive) catch false)) continue;
            c.deleteTree(io, e.name()) catch continue;
        }
        total -= e.bytes;
        result.deleted += 1;
    }
    result.bytes_after = total;
    return result;
}

/// Temporary files in `zap/tmp` (test binaries, deleted once they ran)
/// older than this were left by a build that was killed.
const max_temporary_ns = std.time.ns_per_day;

fn trimTemporary(io: Io, local_cache: Io.Dir, now: Io.Timestamp) void {
    var tmp = local_cache.openDir(io, "zap/tmp", .{ .iterate = true }) catch return;
    defer tmp.close(io);
    var it = tmp.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .file) continue;
        const stat = tmp.statFile(io, e.name, .{}) catch continue;
        if (stat.mtime.durationTo(now).toNanoseconds() > max_temporary_ns) tmp.deleteFile(io, e.name) catch {};
    }
}

pub const MaintainResult = struct { scanned: u32, deleted: u32 = 0, bytes: u64, bytes_after: u64 = 0 };

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

test "maintainCompilations evicts the least recently used unlocked directories past the limit" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const t = std.testing;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try t.expectEqual(4 << 30, parseSize("4G"));
    try t.expectEqual(512 << 20, parseSize("512m"));
    try t.expectEqual(1000, parseSize("1000"));
    try t.expectEqual(null, parseSize("4X"));
    try t.expectEqual(null, parseSize(""));

    // a is the least recently used, then b (held by a build), then c. a
    // shares a file with c, which counts against c, the more recent.
    const now = Io.Clock.real.now(io);
    const names = [_]Hash{ 0xa, 0xb, 0xc };
    var dirs: [3]Io.Dir = undefined;
    for (names, &dirs, 0..) |key, *d, i| {
        d.* = try compilationDir(io, tmp.dir, key);
        const l = try lock(io, d.*);
        l.close(io);
        try d.writeFile(io, .{ .sub_path = "manifest", .data = &(@as([300]u8, @splat(0))) });
        const age: i64 = @intCast(3 - i);
        try d.setTimestamps(io, "lock", .{ .modify_timestamp = .{ .new = now.addDuration(.fromNanoseconds(-age * std.time.ns_per_hour)) } });
    }
    defer for (dirs) |d| d.close(io);
    try dirs[2].writeFile(io, .{ .sub_path = "shared.zsp", .data = &(@as([200]u8, @splat(0))) });
    try dirs[2].hardLink("shared.zsp", dirs[0], "shared.zsp", io, .{});
    const held = try dirs[1].openFile(io, "lock", .{ .mode = .read_write, .lock = .exclusive });
    defer held.close(io);

    // 1100 bytes against a limit of 900: down to 675 takes a (300) and,
    // skipping b, c (500).
    try t.expectEqual(2, (try maintainCompilations(gpa, io, tmp.dir, 900, false)).?.deleted);
    var c = try tmp.dir.openDir(io, "zap/c", .{});
    defer c.close(io);
    for (names, [_]bool{ false, true, false }) |key, kept| {
        const hex = std.fmt.hex(key);
        if (kept) _ = try c.statFile(io, &hex, .{}) else try t.expectError(error.FileNotFound, c.statFile(io, &hex, .{}));
    }
}

test {
    _ = atoms;
    _ = Store;
    _ = Manifest;
    _ = Pack;
}
