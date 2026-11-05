//! Storage for the on-disk cache of analysis results and Atoms (see "The
//! on-disk cache" in docs/slop/architecture.md). This is the storage layer only:
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
//!   <global cache>/bs/store/<32 hex>.zsp       Store packs
//!   <global cache>/bs/zig/<32 hex>             upstream zig's lib directory
//!                                               (`toolchain`)
//!   <local cache>/bs/c/<32 hex>/               one compilation (`compilationDir`)
//!       lock, manifest, manifest.log, pack
//!   <local cache>/bs/tc/<32 hex>               a translate-c record, whose
//!   <local cache>/o/<32 hex>/                   output is in `o/<same hex>`
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
    const sub_path = std.mem.print(&buf, "bs/c/{s}", .{&hex}) catch unreachable;
    return local_cache.createDirPathOpen(io, sub_path, .{ .open_options = .{ .iterate = true } });
}

/// Sets the timestamps of the file at `sub_path`, which may be in a cache
/// that another process trims: a file deleted meanwhile is
/// `error.FileNotFound`. (std's path-based `Dir.setTimestamps` takes
/// utimensat's ENOENT as unexpected, which a Debug build reports with a
/// stack trace.)
pub fn setTimestamps(io: Io, dir: Io.Dir, sub_path: []const u8, options: Io.File.SetTimestampsOptions) !void {
    const f = try dir.openFile(io, sub_path, .{});
    defer f.close(io);
    try f.setTimestamps(io, options);
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

/// The file in a global tool directory (`bs/o/<hash>`: the C++ runtime
/// libraries, glibc's libc_nonshared.a, the build runner, translate-c)
/// that marks it in use: a build holds a shared lock on it while it may
/// still read the tool, and its mtime is the tool's last use.
pub const tool_use_name = "used";

/// Marks the tool directory `dir_path` in use until the returned file is
/// closed: takes a shared lock on its `used` file, which
/// `maintainCompilations` must take exclusively to delete the directory,
/// and renews the file's mtime, by which maintenance ranks the tool. Fails
/// if the directory does not exist. A caller takes it before checking
/// that the tool is there, so that a tool it finds stays until it closes
/// the file.
pub fn useTool(io: Io, dir_path: []const u8) !Io.File {
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);
    const f = try dir.createFile(io, tool_use_name, .{ .truncate = false, .lock = .shared });
    f.setTimestampsNow(io) catch {};
    return f;
}

/// Entries in `bs/o` and translation records used this recently are not
/// deleted over the size limit: they hold no lock, and a build that just
/// found one may not have read it yet.
const in_use_grace_ns = 60 * std.time.ns_per_min;

/// Over the size limit, a tool goes after the compilations and programs
/// used up to this much later than it: rebuilding one (libc++ and
/// libc++abi, the build runner) takes tens of seconds.
const tool_bias_ns = 24 * std.time.ns_per_hour;

/// Compilation directories unused this long are deleted by
/// `maintainCompilations`. They hold hard links to store packs, which keep
/// those packs' disk space in use after the store trims them.
pub const max_unused_compilation_ns = 5 * std.time.ns_per_day;

/// The default size limit of the global cache (`globalShares`) and of a
/// project's local cache; `BS_CACHE_MAX_SIZE` overrides it.
pub const default_max_bytes: u64 = 4 << 30;

/// How the global cache's limit is shared: the store (packs, donors,
/// ZIR) gets three quarters, and the compilation directories, `bs run`'s
/// programs and the tools under `<global>/bs/o` a quarter, so that the
/// two together stay within it. A local cache that is not the global one
/// has the whole limit for its compilation directories.
pub fn globalShares(max_bytes: u64) struct { store: u64, compilations: u64 } {
    return .{ .store = max_bytes - max_bytes / 4, .compilations = max_bytes / 4 };
}

/// `maintainCompilations` scans at most this often.
const compilations_scan_ns = 60 * std.time.ns_per_s;

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

/// The output directories (`o/<digest>`, `Incremental.outputDigests`) of
/// the compilation whose directory is `bs/c/<name>`, or null if `name`
/// is not a key's hex digits.
fn outputDirs(name: []const u8) ?[2][34]u8 {
    var bytes: [16]u8 = undefined;
    if (name.len != 32) return null;
    _ = std.fmt.hexToBytes(&bytes, name) catch return null;
    var dirs: [2][34]u8 = undefined;
    for (&dirs, @import("Incremental.zig").outputDigests(std.mem.readInt(Hash, &bytes, .little))) |*d, digest| {
        d[0..2].* = "o/".*;
        d[2..].* = std.fmt.bytesToHex(digest, .lower);
    }
    return dirs;
}

/// Deletes compilation directories under `local_cache`, skipping those a
/// build holds: those whose lock file (touched by `lock`) is older than
/// `max_unused_compilation_ns`, then the least recently used while the
/// directories total more than `max_bytes`, down to three quarters of it.
/// A file hard-linked into several directories counts once, against the
/// most recently used. `bs run`'s program directories (`bs/o`) count
/// and go the same way, by the program's mtime, which every run renews by
/// relinking it or, when nothing changed, by touching it
/// (`Incremental.renew_output`). Tools in `bs/o` (`useTool`) go by their
/// `used` file's mtime, ranked `tool_bias_ns` later, and only while no
/// build holds them. `bs translate-c`'s records (`bs/tc/<key>`) count
/// with their outputs (`o/<key>/`) and go the same way, by the record's
/// mtime, which every hit renews; the record goes first, so a half-deleted
/// translation is a miss. Programs and records, which have no lock, are
/// kept over the limit while used within `in_use_grace_ns`. A
/// compilation's output directories (`o/<digest>`, both of
/// `Incremental.outputDigests`) count with it and go after it. Test binaries in `bs/tmp` that a killed build left
/// go after a day. Runs at most once a minute, so that it costs a build
/// a few stats, and with `force`, which `Incremental` passes for a build
/// that started a directory. `Incremental` runs it once the build's new
/// pack is written, so that it counts. Returns null if it did not run.
pub fn maintainCompilations(gpa: std.mem.Allocator, io: Io, local_cache: Io.Dir, max_bytes: u64, force: bool) !?MaintainResult {
    const now = Io.Clock.real.now(io);
    // Made if missing: a global cache whose only entries are tools in
    // `bs/o` keeps its stamp here too.
    var c = try local_cache.createDirPathOpen(io, "bs/c", .{ .open_options = .{ .iterate = true } });
    defer c.close(io);
    if (c.statFile(io, "trim", .{})) |stat| {
        if (!force and stat.mtime.durationTo(now).toNanoseconds() < compilations_scan_ns) return null;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    }
    try c.writeFile(io, .{ .sub_path = "trim", .data = "" });
    // `bs run`'s programs, one directory per compilation.
    var o: ?Io.Dir = local_cache.openDir(io, "bs/o", .{ .iterate = true }) catch null;
    defer if (o) |*d| d.close(io);
    // `bs translate-c`'s records.
    var tc: ?Io.Dir = local_cache.openDir(io, "bs/tc", .{ .iterate = true }) catch null;
    defer if (tc) |*d| d.close(io);
    trimTemporary(io, local_cache, now);

    const File = struct { inode: u64, size: u64 };
    const Kind = enum { compilation, run, tool, translation };
    const Entry = struct {
        /// `bs/c/<name>`, `bs/o/<name>` (a program or a tool), or
        /// `bs/tc/<name>`.
        name_buf: [32]u8,
        name_len: u8,
        kind: Kind,
        /// A compilation's lock file's mtime (null without one: it is
        /// being created), a program's mtime (null without one), or a
        /// translation record's.
        used: ?Io.Timestamp = null,
        files: std.ArrayList(File) = .empty,
        bytes: u64 = 0,

        const Self = @This();
        fn name(e: *const Self) []const u8 {
            return e.name_buf[0..e.name_len];
        }

        /// When it was used, for ranking: a tool as if later.
        fn rank(e: *const Self) Io.Timestamp {
            return if (e.kind == .tool) e.used.?.addDuration(.fromNanoseconds(tool_bias_ns)) else e.used.?;
        }
    };
    var entries: std.ArrayList(Entry) = .empty;
    defer {
        for (entries.items) |*e| e.files.deinit(gpa);
        entries.deinit(gpa);
    }
    for ([_]?Io.Dir{ c, o, tc }, [_]Kind{ .compilation, .run, .translation }) |maybe_dir, kind| {
        const dir = maybe_dir orelse continue;
        var it = dir.iterate();
        while (try it.next(io)) |e| {
            if (e.kind != (if (kind == .translation) Io.File.Kind.file else .directory) or e.name.len > 32 or (kind != .run and e.name.len != 32)) continue;
            var entry: Entry = .{ .name_buf = undefined, .name_len = @intCast(e.name.len), .kind = kind };
            @memcpy(entry.name_buf[0..e.name.len], e.name);
            try entries.append(gpa, entry);
        }
    }
    // Each directory's files, stat'ed on several threads: hundreds of
    // directories take milliseconds on one.
    const Worker = struct {
        fn run(gpa_: std.mem.Allocator, io_: Io, local: Io.Dir, c_: Io.Dir, o_: ?Io.Dir, tc_: ?Io.Dir, entries_: []Entry, first: usize, stride: usize) void {
            var i = first;
            while (i < entries_.len) : (i += stride) {
                const entry = &entries_[i];
                var path_buf: [64]u8 = undefined;
                if (entry.kind == .translation) {
                    const stat = tc_.?.statFile(io_, entry.name(), .{}) catch continue;
                    entry.files.append(gpa_, .{ .inode = @intCast(stat.inode), .size = stat.size }) catch return;
                    entry.used = stat.mtime;
                }
                var d = switch (entry.kind) {
                    .compilation => c_.openDir(io_, entry.name(), .{ .iterate = true }),
                    .run, .tool => o_.?.openDir(io_, entry.name(), .{ .iterate = true }),
                    .translation => local.openDir(io_, std.mem.print(&path_buf, "o/{s}", .{entry.name()}) catch unreachable, .{ .iterate = true }),
                } catch continue;
                defer d.close(io_);
                var files = d.iterate();
                while (files.next(io_) catch null) |e| {
                    if (e.kind != .file) continue;
                    const stat = d.statFile(io_, e.name, .{}) catch continue;
                    switch (entry.kind) {
                        // A run that reuses the program renews its
                        // mtime; a tool's use renews its `used` file's,
                        // which alone counts once it has one.
                        .run => if (std.mem.eql(u8, e.name, tool_use_name)) {
                            entry.kind = .tool;
                            entry.used = stat.mtime;
                        } else if (entry.used == null or stat.mtime.compare(.gt, entry.used.?)) {
                            entry.used = stat.mtime;
                        },
                        .tool => if (std.mem.eql(u8, e.name, tool_use_name)) {
                            entry.used = stat.mtime;
                        },
                        .compilation => if (std.mem.eql(u8, e.name, "lock")) {
                            entry.used = stat.mtime;
                        },
                        .translation => {},
                    }
                    entry.files.append(gpa_, .{ .inode = @intCast(stat.inode), .size = stat.size }) catch return;
                }
                // A compilation's outputs, in its two directories.
                if (entry.kind == .compilation) for (outputDirs(entry.name()) orelse continue) |out| {
                    var od = local.openDir(io_, &out, .{ .iterate = true }) catch continue;
                    defer od.close(io_);
                    var outs = od.iterate();
                    while (outs.next(io_) catch null) |e| {
                        if (e.kind != .file) continue;
                        const stat = od.statFile(io_, e.name, .{}) catch continue;
                        entry.files.append(gpa_, .{ .inode = @intCast(stat.inode), .size = stat.size }) catch return;
                    }
                };
            }
        }
    };
    const n_threads = @max(1, @min(16, std.Thread.getCpuCount() catch 1, entries.items.len / 32));
    var group: Io.Group = .init;
    for (1..n_threads) |t| group.async(io, Worker.run, .{ gpa, io, local_cache, c, o, tc, entries.items, t, n_threads });
    Worker.run(gpa, io, local_cache, c, o, tc, entries.items, 0, n_threads);
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
            return a.rank().compare(.gt, b.rank());
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
        const age = e.used.?.durationTo(now).toNanoseconds();
        const old = age > max_unused_compilation_ns;
        if (!old and (!over or total <= target)) break;
        if (!old and age < in_use_grace_ns and (e.kind == .run or e.kind == .translation)) continue;
        var buf: [64]u8 = undefined;
        switch (e.kind) {
            .run => o.?.deleteTree(io, e.name()) catch continue,
            .tool => {
                const use_path = std.mem.print(&buf, "{s}/" ++ tool_use_name, .{e.name()}) catch unreachable;
                const f = o.?.openFile(io, use_path, .{ .mode = .read_write }) catch continue;
                defer f.close(io);
                if (!(f.tryLock(io, .exclusive) catch false)) continue;
                o.?.deleteTree(io, e.name()) catch continue;
            },
            .compilation => {
                const lock_path = std.mem.print(&buf, "{s}/lock", .{e.name()}) catch unreachable;
                const f = c.openFile(io, lock_path, .{ .mode = .read_write }) catch continue;
                defer f.close(io);
                if (!(f.tryLock(io, .exclusive) catch false)) continue;
                c.deleteTree(io, e.name()) catch continue;
                if (outputDirs(e.name())) |outs| for (outs) |out| local_cache.deleteTree(io, &out) catch {};
            },
            .translation => {
                tc.?.deleteFile(io, e.name()) catch continue;
                local_cache.deleteTree(io, std.mem.print(&buf, "o/{s}", .{e.name()}) catch unreachable) catch {};
            },
        }
        total -= e.bytes;
        result.deleted += 1;
    }
    result.bytes_after = total;
    return result;
}

/// Temporary files in `bs/tmp` (test binaries, deleted once they ran)
/// older than this were left by a build that was killed.
const max_temporary_ns = 24 * std.time.ns_per_hour;

fn trimTemporary(io: Io, local_cache: Io.Dir, now: Io.Timestamp) void {
    var tmp = local_cache.openDir(io, "bs/tmp", .{ .iterate = true }) catch return;
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
    var c = try tmp.dir.openDir(io, "bs/c", .{});
    defer c.close(io);
    for (names, [_]bool{ false, true, false }) |key, kept| {
        const hex = std.fmt.hex(key);
        if (kept) _ = try c.statFile(io, &hex, .{}) else try t.expectError(error.FileNotFound, c.statFile(io, &hex, .{}));
    }
}

test "maintainCompilations counts a compilation's two output directories and evicts them with it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const t = std.testing;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const now = Io.Clock.real.now(io);
    // a, the least recently used, has 300 bytes in its directory and 200
    // in its second output directory; b has 300 and 100 in its first.
    const keys = [_]Hash{ 0xa, 0xb };
    const outs = [_]struct { usize, usize }{ .{ 1, 200 }, .{ 0, 100 } };
    var out_paths: [2][34]u8 = undefined;
    for (keys, outs, &out_paths, 0..) |key, out, *p, i| {
        var d = try compilationDir(io, tmp.dir, key);
        defer d.close(io);
        (try lock(io, d)).close(io);
        try d.writeFile(io, .{ .sub_path = "manifest", .data = &(@as([300]u8, @splat(0))) });
        const age: i64 = @intCast(2 - i);
        try d.setTimestamps(io, "lock", .{ .modify_timestamp = .{ .new = now.addDuration(.fromNanoseconds(-age * std.time.ns_per_hour)) } });
        p.* = outputDirs(&std.fmt.hex(key)).?[out[0]];
        var od = try tmp.dir.createDirPathOpen(io, &p.*, .{});
        defer od.close(io);
        const bytes = try gpa.alloc(u8, out[1]);
        @memset(bytes, 0);
        defer gpa.free(bytes);
        try od.writeFile(io, .{ .sub_path = "bin", .data = bytes });
    }
    // 900 bytes against 800 (600 without the outputs): a goes, with its
    // output, down to 400.
    const r = (try maintainCompilations(gpa, io, tmp.dir, 800, false)).?;
    try t.expectEqual(1, r.deleted);
    try t.expectEqual(900, r.bytes);
    try t.expectError(error.FileNotFound, tmp.dir.statFile(io, &out_paths[0], .{}));
    _ = try tmp.dir.statFile(io, &out_paths[1], .{});
}

test "maintainCompilations counts translate-c records with their outputs and evicts them by the record's mtime" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const t = std.testing;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const now = Io.Clock.real.now(io);
    var d = try compilationDir(io, tmp.dir, 0xc);
    defer d.close(io);
    (try lock(io, d)).close(io);
    // The old translation's output is newer than its record, which alone
    // says when it was last used.
    const old = std.fmt.hex(@as(Hash, 0x01d));
    const new = std.fmt.hex(@as(Hash, 0x2e3));
    for ([_][]const u8{ &old, &new }, [_]i64{ 6 * std.time.ns_per_day, std.time.ns_per_hour }) |hex, age| {
        var buf: [64]u8 = undefined;
        const record = try std.mem.print(&buf, "bs/tc/{s}", .{hex});
        try tmp.dir.createDirPath(io, "bs/tc");
        try tmp.dir.writeFile(io, .{ .sub_path = record, .data = &(@as([10]u8, @splat(0))) });
        try tmp.dir.setTimestamps(io, record, .{ .modify_timestamp = .{ .new = now.addDuration(.fromNanoseconds(-age)) } });
        var buf2: [64]u8 = undefined;
        const out = try std.mem.print(&buf2, "o/{s}", .{hex});
        try tmp.dir.createDirPath(io, out);
        var od = try tmp.dir.openDir(io, out, .{});
        defer od.close(io);
        try od.writeFile(io, .{ .sub_path = "x.zig", .data = &(@as([100]u8, @splat(0))) });
    }

    const r = (try maintainCompilations(gpa, io, tmp.dir, 1 << 30, true)).?;
    try t.expectEqual(3, r.scanned);
    try t.expectEqual(1, r.deleted);
    try t.expectEqual(r.bytes - 110, r.bytes_after);
    var buf: [64]u8 = undefined;
    try t.expectError(error.FileNotFound, tmp.dir.statFile(io, try std.mem.print(&buf, "bs/tc/{s}", .{&old}), .{}));
    try t.expectError(error.FileNotFound, tmp.dir.statFile(io, try std.mem.print(&buf, "o/{s}", .{&old}), .{}));
    _ = try tmp.dir.statFile(io, try std.mem.print(&buf, "bs/tc/{s}", .{&new}), .{});
    _ = try tmp.dir.statFile(io, try std.mem.print(&buf, "o/{s}/x.zig", .{&new}), .{});
}

test "setTimestamps takes a file another process deleted as not found" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectError(error.FileNotFound, setTimestamps(io, tmp.dir, "gone", .{ .modify_timestamp = .now }));
}

test {
    _ = atoms;
    _ = Store;
    _ = Manifest;
    _ = Pack;
}

test "maintainCompilations keeps tools in use and recent programs, and ranks tools after newer compilations" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const t = std.testing;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const now = Io.Clock.real.now(io);
    const ago = struct {
        fn ts(n: Io.Timestamp, ns: i64) Io.Timestamp {
            return n.addDuration(.fromNanoseconds(-ns));
        }
    }.ts;
    const hour = std.time.ns_per_hour;
    // A compilation used an hour ago (400 bytes), and in `bs/o` libc++,
    // held by a build, used four days ago, the build runner three days
    // ago, libunwind three hours ago, and a program just written (100
    // bytes each).
    var d = try compilationDir(io, tmp.dir, 0xc);
    defer d.close(io);
    (try lock(io, d)).close(io);
    try d.writeFile(io, .{ .sub_path = "manifest", .data = &(@as([400]u8, @splat(0))) });
    try d.setTimestamps(io, "lock", .{ .modify_timestamp = .{ .new = ago(now, hour) } });
    const Entry = struct { name: []const u8, file: []const u8, age: i64, tool: bool };
    const entries = [_]Entry{
        .{ .name = "aaaa", .file = "libc++.a", .age = 96 * hour, .tool = true },
        .{ .name = "bbbb", .file = "maker", .age = 72 * hour, .tool = true },
        .{ .name = "cccc", .file = "libunwind.a", .age = 3 * hour, .tool = true },
        .{ .name = "dddd", .file = "prog", .age = 0, .tool = false },
    };
    for (entries) |e| {
        var buf: [64]u8 = undefined;
        var od = try tmp.dir.createDirPathOpen(io, try std.mem.print(&buf, "bs/o/{s}", .{e.name}), .{});
        defer od.close(io);
        try od.writeFile(io, .{ .sub_path = e.file, .data = &(@as([100]u8, @splat(0))) });
        try od.setTimestamps(io, e.file, .{ .modify_timestamp = .{ .new = ago(now, e.age) } });
        if (e.tool) {
            try od.writeFile(io, .{ .sub_path = tool_use_name, .data = "" });
            try od.setTimestamps(io, tool_use_name, .{ .modify_timestamp = .{ .new = ago(now, e.age) } });
        }
    }
    var o = try tmp.dir.openDir(io, "bs/o", .{});
    defer o.close(io);
    const held = held: {
        const p = try o.realPathFileAlloc(io, "aaaa", gpa);
        defer gpa.free(p);
        break :held try useTool(io, p);
    };
    // As if the build had found libc++ four days ago and held it since.
    try held.setTimestamps(io, .{ .modify_timestamp = .{ .new = ago(now, 96 * hour) } });

    // 800 bytes against a limit of 400, down to 300: the build runner
    // goes, libc++ is held, and then the compilation goes before
    // libunwind, though libunwind was used before it.
    const r = (try maintainCompilations(gpa, io, tmp.dir, 400, true)).?;
    try t.expectEqual(5, r.scanned);
    try t.expectEqual(2, r.deleted);
    try t.expectError(error.FileNotFound, tmp.dir.statFile(io, "bs/c/" ++ std.fmt.hex(@as(Hash, 0xc)), .{}));
    for (entries, [_]bool{ true, false, true, true }) |e, kept| {
        if (kept) _ = try o.statFile(io, e.name, .{}) else try t.expectError(error.FileNotFound, o.statFile(io, e.name, .{}));
    }
    // Once the build is done, libc++ goes, and libunwind with it under a
    // smaller limit; the program, used within the grace period, stays.
    held.close(io);
    try t.expectEqual(2, (try maintainCompilations(gpa, io, tmp.dir, 100, true)).?.deleted);
    for (entries, [_]bool{ false, false, false, true }) |e, kept| {
        if (kept) _ = try o.statFile(io, e.name, .{}) else try t.expectError(error.FileNotFound, o.statFile(io, e.name, .{}));
    }
}
