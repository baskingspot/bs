//! The records of outputs zap makes with upstream's tools (translate-c's
//! Zig files, Clang's objects): `<local cache>/zap/tc/<key>` lists every
//! file the tool read (from its `-MD` depfile) with its stat and content
//! hash, and the output's hash; the output is `<local cache>/o/<key>/`.
//! The key covers the tool, its arguments and the source path, not the
//! files' contents, so the output keeps its path across header edits, and
//! a build whose files all stat as recorded runs nothing (docs/
//! architecture.md, "C interop"). The cache's trimming counts a record and
//! its output directory as one entry, by the record's mtime.

const std = @import("std");
const Io = std.Io;
const cache = @import("cache.zig");

/// A record: `Header`, `n` `Entry`s, then the paths.
const record_magic = "ZAPTC002".*;
const Header = extern struct {
    magic: [8]u8 = record_magic,
    output_hash: cache.Hash,
    n: u32,
    paths_len: u32,
};
const Entry = extern struct {
    inode: u64,
    size: u64,
    /// Nanoseconds, or `racy_mtime` when the file was too new to trust.
    mtime: i64,
    path_len: u32,
    _pad: u32 = 0,
    hash: cache.Hash,

    /// A file changed within the timestamp granularity of its last read
    /// could change again without changing its mtime, so it is recorded
    /// with this mtime and rehashed by the next build (Frontend's rule).
    const racy_mtime = std.math.minInt(i64);
    const racy_window_ns = 2 * std.time.ns_per_s;

    fn matches(e: Entry, st: Io.File.Stat) bool {
        return e.mtime != racy_mtime and e.inode == st.inode and e.size == st.size and e.mtime == st.mtime.toNanoseconds();
    }
};

fn entry(st: Io.File.Stat, hash: cache.Hash, path_len: usize, start_ns: i96) Entry {
    const mtime: i64 = @intCast(st.mtime.toNanoseconds());
    return .{
        .inode = @intCast(st.inode),
        .size = st.size,
        .mtime = if (mtime >= start_ns - Entry.racy_window_ns) Entry.racy_mtime else mtime,
        .path_len = @intCast(path_len),
        .hash = hash,
    };
}

/// A record's key: the tool that makes the output (`tool_id`: upstream
/// zig's identity for Clang, the binary's content hash for translate-c),
/// the working directory, the zig lib directory and the arguments, which
/// end with the source. Not zap's identity: zap only chooses the
/// arguments, and everything else the tool reads is a recorded file,
/// checked by content.
pub fn key(gpa: std.mem.Allocator, io: Io, kind: []const u8, tool_id: []const u8, lib: []const u8, args: []const []const u8) !cache.Hash {
    var id: std.ArrayList(u8) = .empty;
    defer id.deinit(gpa);
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    try id.print(gpa, "{s}\x00{s}\x00{s}\x00{s}\x00", .{ kind, tool_id, cwd, lib });
    for (args) |a| try id.print(gpa, "{s}\x00", .{a});
    return cache.hash(4, id.items);
}

pub const Check = union(enum) {
    /// The recorded files, zero-separated.
    hit: []const u8,
    /// The output's recorded hash.
    miss: cache.Hash,
};

/// The stats of files that `check` already read in this build, by path,
/// for records that share headers: SDL3's 473 sources read 190k headers,
/// a few thousand distinct.
pub const Stats = std.StringHashMapUnmanaged(Io.File.Stat);

/// Compares the record's files with the file system: a hit when every
/// file stats as recorded or, rehashed, has the recorded contents (the
/// record then takes the new stats). Null without a usable record.
/// `stats` keeps what it stats for later checks, in `stats_gpa`.
pub fn check(arena: std.mem.Allocator, io: Io, record_path: []const u8, out_path: []const u8, start_ns: i96, stats_gpa: std.mem.Allocator, stats: ?*Stats) !?Check {
    const cwd = Io.Dir.cwd();
    const rec = cwd.readFileAlloc(io, record_path, arena, .limited(64 << 20)) catch return null;
    if (rec.len < @sizeOf(Header)) return null;
    const header = std.mem.bytesToValue(Header, rec[0..@sizeOf(Header)]);
    const entries_end = @sizeOf(Header) + @as(usize, header.n) * @sizeOf(Entry);
    if (!std.mem.eql(u8, &header.magic, &record_magic) or rec.len != entries_end + header.paths_len) return null;
    const entries = try arena.alloc(Entry, header.n);
    @memcpy(std.mem.sliceAsBytes(entries), rec[@sizeOf(Header)..entries_end]);
    const paths = rec[entries_end..];
    _ = cwd.statFile(io, out_path, .{}) catch return .{ .miss = header.output_hash };
    var inputs: std.ArrayList(u8) = .empty;
    var changed = false;
    var at: usize = 0;
    for (entries) |*e| {
        const p = paths[at..][0..e.path_len];
        at += e.path_len;
        if (inputs.items.len != 0) try inputs.append(arena, 0);
        try inputs.appendSlice(arena, p);
        if (stats) |m| {
            const gop = try m.getOrPut(stats_gpa, p);
            if (!gop.found_existing) {
                gop.key_ptr.* = try stats_gpa.dupe(u8, p);
                gop.value_ptr.* = cwd.statFile(io, p, .{}) catch {
                    m.removeByPtr(gop.key_ptr);
                    return .{ .miss = header.output_hash };
                };
            }
            if (e.matches(gop.value_ptr.*)) continue;
        }
        const f = cwd.openFile(io, p, .{}) catch return .{ .miss = header.output_hash };
        defer f.close(io);
        const st = f.stat(io) catch return .{ .miss = header.output_hash };
        if (e.matches(st)) continue;
        const bytes = try arena.alloc(u8, st.size);
        _ = f.readPositionalAll(io, bytes, 0) catch return .{ .miss = header.output_hash };
        const h = cache.hash(0, bytes);
        if (h != e.hash) return .{ .miss = header.output_hash };
        e.* = entry(st, h, e.path_len, start_ns);
        changed = true;
    }
    if (changed) {
        cache.writeReplace(io, cwd, record_path, &.{ rec[0..@sizeOf(Header)], std.mem.sliceAsBytes(entries), paths }) catch {};
    } else {
        // The record's mtime is its last use, for trimming the cache.
        cache.setTimestamps(io, cwd, record_path, .{ .access_timestamp = .now, .modify_timestamp = .now }) catch {};
    }
    return .{ .hit = inputs.items };
}

pub const Commit = struct {
    record_path: []const u8,
    out_path: []const u8,
    /// Where the tool wrote the output and its depfile (empty if none).
    tmp_out: []const u8,
    dep_path: []const u8,
    /// The source's absolute path, recorded first.
    source: []const u8,
    /// The output's hash in the record `check` found, if any.
    old_output: ?cache.Hash,
    start_ns: i96,
};

/// Records a run of the tool: moves its output into place unless the bytes
/// did not change, then writes the record. Returns the files the tool read,
/// zero-separated.
pub fn commit(arena: std.mem.Allocator, io: Io, c: Commit) ![]const u8 {
    const cwd = Io.Dir.cwd();
    const cwd_path = try std.process.currentPathAlloc(io, arena);
    // Every file the tool read, from the depfile: the source, then
    // headers. Without one (`dep_path` empty), the source alone.
    const dep = if (c.dep_path.len == 0) "" else try cwd.readFileAlloc(io, c.dep_path, arena, .unlimited);
    var paths: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var it: std.Build.Cache.DepTokenizer = .{ .bytes = dep };
    while (it.next()) |tok| switch (tok) {
        .target, .target_must_resolve => {},
        .prereq, .prereq_must_resolve => {
            var buf: std.ArrayList(u8) = .empty;
            if (tok == .prereq_must_resolve) try tok.resolve(arena, &buf);
            const p = try std.fs.path.resolve(arena, &.{ cwd_path, if (tok == .prereq) tok.prereq else buf.items });
            if (!(try seen.getOrPut(arena, p)).found_existing) try paths.append(arena, p);
        },
        else => return error.InvalidDepFile,
    };
    if (!seen.contains(c.source)) try paths.insert(arena, 0, c.source);

    var entries: std.ArrayList(Entry) = .empty;
    var path_bytes: std.ArrayList(u8) = .empty;
    for (paths.items) |p| {
        const f = try cwd.openFile(io, p, .{});
        defer f.close(io);
        const st = try f.stat(io);
        const bytes = try arena.alloc(u8, st.size);
        _ = try f.readPositionalAll(io, bytes, 0);
        try entries.append(arena, entry(st, cache.hash(0, bytes), p.len, c.start_ns));
        try path_bytes.appendSlice(arena, p);
    }

    // The output: left alone when its bytes did not change, so that its
    // stat stays as the step that reads it recorded.
    const output = try cwd.readFileAlloc(io, c.tmp_out, arena, .unlimited);
    const output_hash = cache.hash(0, output);
    const same = c.old_output == output_hash and same: {
        const old = cwd.readFileAlloc(io, c.out_path, arena, .unlimited) catch break :same false;
        break :same std.mem.eql(u8, old, output);
    };
    if (!same) {
        try cwd.createDirPath(io, std.fs.path.dirname(c.out_path).?);
        try cwd.rename(c.tmp_out, cwd, c.out_path, io);
    }
    // Then the record, so that a record never names an output that is not
    // there.
    try cwd.createDirPath(io, std.fs.path.dirname(c.record_path).?);
    const header: Header = .{ .output_hash = output_hash, .n = @intCast(entries.items.len), .paths_len = @intCast(path_bytes.items.len) };
    try cache.writeReplace(io, cwd, c.record_path, &.{ std.mem.asBytes(&header), std.mem.sliceAsBytes(entries.items), path_bytes.items });
    return std.mem.join(arena, "\x00", paths.items);
}
