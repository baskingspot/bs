//! The global store: cache entries shared by every project on the machine,
//! like Go's build cache. An entry is a unit's result (an opaque payload
//! for now, serialized by Sema later), the Atoms generated from it, and
//! the dependencies it was computed from with the result hash each had
//! then. Entries are named by their key: the key covers everything the
//! result is computed from except the dependencies, which are checked
//! against the recorded result hashes on use (`Entry.isValid`).
//!
//! Entries live in immutable packs, git-style. Each worker collects its new
//! entries in a `Batch`, and `commit` writes a build's batches as one pack:
//! the entries, then their keys sorted, with a fan-out table on the keys'
//! top byte. That is one file creation per build; one file per entry cost
//! ~25-30 µs each to create on the orb, about 0.7 s for a first build of
//! 30k units. `open`
//! maps every pack, and `get` searches them newest first without a system
//! call. When there are more than `max_packs`, `commit` merges the smallest
//! into one, under a lock that only maintenance takes.
//!
//! Concurrent builds need no locks: each writes a pack under a new random
//! name and links it into place. Packs are deleted only by maintenance;
//! a build that mapped a pack before it was deleted keeps reading it, and
//! one that listed it but had not opened it yet skips it, which costs
//! cache misses but never a wrong result. A key has one live entry, the
//! newest; packs may hold older copies until they are merged.
//!
//! Trimming is per pack: a pack records its last use in its mtime
//! (refreshed at most hourly), and maintenance deletes packs unused for
//! `max_unused_ns`. So that a pack does not live on for a few of its
//! entries, a hit in a pack older than `copy_forward_ns` is written again
//! by the build's `commit`; live entries move to young packs and old packs
//! fall out of use.
//!
//! Pack file: `PackHeader`; entries, each 16-byte aligned (`Header`,
//! `deps_len` `Dep`s, `atoms_len` atom records (`cache.atoms`,
//! `atoms_bytes` long), `payload_len` payload bytes); then the index:
//! `count` sorted keys, `count` `Loc`s, and a 257-entry fan-out table.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const cache = @import("../cache.zig");
const atoms_codec = @import("atoms.zig");
const Atom = @import("../link/Atom.zig");
const Hash = cache.Hash;

const Store = @This();

/// `<global cache>/zap/store`.
dir: Io.Dir,
/// Newest first.
packs: []PackFile,
/// When `open` ran, which ages are measured against.
opened: Io.Timestamp,
/// Hits in old packs, written again by the next `commit`.
forward: std.ArrayList(Forward) = .empty,
forward_mutex: Io.Mutex = .init,

pub const Key = Hash;

/// A dependency of an entry: what it read, and the result hash that had.
pub const Dep = extern struct {
    key: Hash,
    result_hash: Hash,
};

const entry_magic = "ZAPUNT01".*;

const Header = extern struct {
    magic: [8]u8 = entry_magic,
    deps_len: u32,
    atoms_len: u32,
    atoms_bytes: u64,
    payload_len: u64,
    src_hash: Hash,
    result_hash: Hash,
};

const pack_magic = "ZAPSTP01".*;
const pack_ext = ".zsp";

const PackHeader = extern struct {
    magic: [8]u8 = pack_magic,
    count: u32,
    unused: u32 = 0,
    /// Offset of the index: keys, then `Loc`s, then the fan-out table.
    index_off: u64,
    /// When the oldest of its entries was written, in nanoseconds; decides
    /// copying forward.
    created: i64,
    /// When the newest of its entries was written: lookups search packs in
    /// decreasing `order`.
    order: i64,
    unused2: u64 = 0,
    id: Hash,

    fn indexLen(count: usize) usize {
        return std.mem.alignForward(usize, count * (@sizeOf(Hash) + @sizeOf(Loc)) + fanout_len * 4, 16);
    }
};

/// Where an entry is in its pack: offset in 16-byte units, and length.
const Loc = extern struct { offset16: u32, len: u32 };

/// `fanout[b]` is the index of the first key whose top byte is `b` or more.
const fanout_len = 257;

comptime {
    std.debug.assert(@sizeOf(Header) == 64);
    std.debug.assert(@sizeOf(Dep) == 32);
    std.debug.assert(@sizeOf(PackHeader) == 64);
}

pub const max_packs = 16;
pub const used_refresh_ns = std.time.ns_per_hour;
pub const max_unused_ns = 5 * std.time.ns_per_day;
pub const copy_forward_ns = max_unused_ns / 2;
const trim_interval_ns = std.time.ns_per_day;

const PackFile = struct {
    name: [32 + pack_ext.len]u8,
    map: Io.File.MemoryMap,
    created: i64,
    order: i64,
    /// The file's mtime when opened: its last use.
    mtime: Io.Timestamp,
    size: u64,
    keys: []const Hash,
    locs: []const Loc,
    fanout: *const [fanout_len]u32,
    used: std.atomic.Value(bool) = .init(false),

    fn find(p: *const PackFile, key: Key) ?usize {
        const b: u8 = @intCast(key >> 120);
        var lo: usize = p.fanout[b];
        var hi: usize = p.fanout[@as(usize, b) + 1];
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const k = p.keys[mid];
            if (k < key) lo = mid + 1 else if (k > key) hi = mid else return mid;
        }
        return null;
    }

    fn entryBytes(p: *const PackFile, i: usize) []align(16) const u8 {
        const loc = p.locs[i];
        return @alignCast(p.map.memory[@as(usize, loc.offset16) * 16 ..][0..loc.len]);
    }
};

const Forward = struct { key: Key, bytes: []align(16) const u8 };

pub const pack_header_len = @sizeOf(PackHeader);

/// Where an entry's atom records start, relative to the entry.
pub fn atomsOffset(deps_len: usize) usize {
    return @sizeOf(Header) + @sizeOf(Dep) * deps_len;
}

pub const PackName = [32 + pack_ext.len]u8;

/// The file name of pack `i` in `dir`.
pub fn packName(store: *const Store, i: u32) []const u8 {
    return &store.packs[i].name;
}

/// Maps every pack in `<global_cache>/zap/store`.
pub fn open(gpa: Allocator, io: Io, global_cache: Io.Dir) !Store {
    const dir = try global_cache.createDirPathOpen(io, "zap/store", .{ .open_options = .{ .iterate = true } });
    errdefer dir.close(io);
    return .{ .dir = dir, .packs = try loadPacks(gpa, io, dir), .opened = Io.Clock.real.now(io) };
}

/// Maps the packs in `dir`, newest first.
fn loadPacks(gpa: Allocator, io: Io, dir: Io.Dir) ![]PackFile {
    var packs: std.ArrayList(PackFile) = .empty;
    errdefer {
        for (packs.items) |*p| p.map.destroy(io);
        packs.deinit(gpa);
    }
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file or e.name.len != 32 + pack_ext.len or !std.mem.endsWith(u8, e.name, pack_ext)) continue;
        try packs.ensureUnusedCapacity(gpa, 1);
        if (try openPack(io, dir, e.name)) |p| packs.appendAssumeCapacity(p);
    }
    std.mem.sortUnstable(PackFile, packs.items, {}, struct {
        fn newer(_: void, a: PackFile, b: PackFile) bool {
            return a.order > b.order or (a.order == b.order and std.mem.order(u8, &a.name, &b.name) == .lt);
        }
    }.newer);
    return packs.toOwnedSlice(gpa);
}

/// Maps a pack, or returns null if it is gone (merged by another build) or
/// damaged.
fn openPack(io: Io, dir: Io.Dir, name: []const u8) !?PackFile {
    const f = dir.openFile(io, name, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    defer f.close(io);
    const stat = try f.stat(io);
    if (stat.size < @sizeOf(PackHeader) + PackHeader.indexLen(0)) return null;
    var map = try cache.mapOpenFile(io, f, stat.size, false);
    errdefer map.destroy(io);
    const mem = map.memory;
    const h: *const PackHeader = @ptrCast(mem.ptr);
    if (!std.mem.eql(u8, &h.magic, &pack_magic) or h.index_off % 16 != 0 or
        h.index_off + PackHeader.indexLen(h.count) != stat.size)
    {
        map.destroy(io);
        return null;
    }
    const keys_off: usize = @intCast(h.index_off);
    const locs_off = keys_off + h.count * @sizeOf(Hash);
    const fanout_off = locs_off + h.count * @sizeOf(Loc);
    var p: PackFile = .{
        .name = undefined,
        .map = map,
        .created = h.created,
        .order = h.order,
        .mtime = stat.mtime,
        .size = stat.size,
        .keys = @ptrCast(@alignCast(mem[keys_off..locs_off])),
        .locs = @ptrCast(@alignCast(mem[locs_off..fanout_off])),
        .fanout = @ptrCast(@alignCast(mem[fanout_off..][0 .. fanout_len * 4])),
    };
    if (p.fanout[fanout_len - 1] != h.count) {
        map.destroy(io);
        return null;
    }
    @memcpy(&p.name, name);
    return p;
}

/// Records which packs this build used, and unmaps them. Entries from
/// `get` are invalid afterwards.
pub fn close(store: *Store, gpa: Allocator, io: Io) void {
    store.refreshUsed(io);
    for (store.packs) |*p| p.map.destroy(io);
    gpa.free(store.packs);
    store.forward.deinit(gpa);
    store.dir.close(io);
}

/// Sets the mtime of the packs `get` found entries in, if it is older than
/// `used_refresh_ns`, so that trimming keeps them.
fn refreshUsed(store: *Store, io: Io) void {
    for (store.packs) |*p| {
        if (!p.used.swap(false, .monotonic)) continue;
        if (p.mtime.durationTo(store.opened).toNanoseconds() < used_refresh_ns) continue;
        store.dir.setTimestampsNow(io, &p.name, .{}) catch {};
        p.mtime = store.opened;
    }
}

/// An entry in a mapped pack. Its slices, and the atoms it decodes, stay
/// valid until the store is closed.
pub const Entry = struct {
    bytes: []align(16) const u8,
    /// Which of the store's packs holds it (`packName`), and where.
    pack: u32 = 0,
    offset: u64 = 0,

    fn header(e: Entry) *const Header {
        return @ptrCast(e.bytes.ptr);
    }

    pub fn srcHash(e: Entry) Hash {
        return e.header().src_hash;
    }

    pub fn resultHash(e: Entry) Hash {
        return e.header().result_hash;
    }

    pub fn deps(e: Entry) []const Dep {
        const h = e.header();
        return @ptrCast(@alignCast(e.bytes[@sizeOf(Header)..][0 .. @sizeOf(Dep) * h.deps_len]));
    }

    fn atomBytes(e: Entry) []align(16) const u8 {
        const h = e.header();
        return @alignCast(e.bytes[@sizeOf(Header) + @sizeOf(Dep) * h.deps_len ..][0..h.atoms_bytes]);
    }

    pub fn payload(e: Entry) []const u8 {
        const h = e.header();
        return e.bytes[e.bytes.len - h.payload_len ..];
    }

    pub fn atomCount(e: Entry) u32 {
        return e.header().atoms_len;
    }

    /// Decodes the entry's atoms into `out`, which has `atomCount()` items,
    /// and their debug info into the start of `debug`, which has as many;
    /// `Debug.atom` is the index in `out`. Returns how many have debug info.
    pub fn decodeAtoms(e: Entry, out: []Atom, debug: []Atom.Debug) atoms_codec.DecodeError!usize {
        const bytes = e.atomBytes();
        var off: usize = 0;
        var n_debug: usize = 0;
        for (out, 0..) |*a, i| {
            const d = try atoms_codec.decode(@alignCast(bytes[off..]));
            a.* = d.atom;
            if (d.debug) |dbg| {
                debug[n_debug] = dbg;
                debug[n_debug].atom = @intCast(i);
                n_debug += 1;
            }
            off += d.len;
        }
        if (off != bytes.len) return error.CorruptAtom;
        return n_debug;
    }

    /// Whether the entry still holds for a unit whose own source hashes to
    /// `src_hash`: each dependency must still have the result hash it had.
    /// `context.resultHash(key)` returns a dependency's current result
    /// hash, or null if it no longer exists.
    pub fn isValid(e: Entry, src_hash: Hash, context: anytype) bool {
        if (e.srcHash() != src_hash) return false;
        for (e.deps()) |d| {
            if (context.resultHash(d.key) != d.result_hash) return false;
        }
        return true;
    }
};

/// The newest entry for `key`, or null if there is none or it is damaged.
/// Thread-safe; makes no system calls.
pub fn get(store: *Store, gpa: Allocator, io: Io, key: Key) Allocator.Error!?Entry {
    for (store.packs, 0..) |*p, pack_index| {
        const i = p.find(key) orelse continue;
        const bytes = p.entryBytes(i);
        if (bytes.len < @sizeOf(Header)) return null;
        const e: Entry = .{ .bytes = bytes, .pack = @intCast(pack_index), .offset = @as(u64, p.locs[i].offset16) * 16 };
        const h = e.header();
        if (!std.mem.eql(u8, &h.magic, &entry_magic) or
            @sizeOf(Header) + @sizeOf(Dep) * @as(u64, h.deps_len) + h.atoms_bytes + h.payload_len != bytes.len)
        {
            return null;
        }
        if (!p.used.load(.monotonic)) p.used.store(true, .monotonic);
        if (store.opened.toNanoseconds() - p.created > copy_forward_ns) {
            store.forward_mutex.lockUncancelable(io);
            defer store.forward_mutex.unlock(io);
            try store.forward.append(gpa, .{ .key = key, .bytes = bytes });
        }
        return e;
    }
    return null;
}

pub const Contents = struct {
    /// The hash of the unit's own source (`src_hash`), checked on use.
    src_hash: Hash,
    /// The hash of the result, which dependents record.
    result_hash: Hash,
    deps: []const Dep = &.{},
    atoms: []const Atom = &.{},
    /// Sorted by `atom`, an index into `atoms`.
    debug: []const Atom.Debug = &.{},
    payload: []const u8 = &.{},
};

/// New entries, written as one pack by `commit`. Not thread-safe: each
/// worker fills its own, and `commit` writes them all.
pub const Batch = struct {
    /// The entries, each 16-byte aligned.
    bytes: std.array_list.Aligned(u8, .@"16") = .empty,
    /// Offsets are relative to `bytes`.
    index: std.ArrayList(IndexEntry) = .empty,

    const IndexEntry = struct { key: Key, loc: Loc };

    pub fn deinit(b: *Batch, gpa: Allocator) void {
        b.bytes.deinit(gpa);
        b.index.deinit(gpa);
    }

    /// Adds an entry and returns its offset in the batch. In the pack
    /// `commit` writes, batch `i`'s entries start at `pack_header_len` plus
    /// the bytes of the batches before it; the entry's atom records start
    /// `atomsOffset(deps.len)` into it, one after another.
    pub fn put(b: *Batch, gpa: Allocator, key: Key, contents: Contents) Allocator.Error!usize {
        var atoms_len: usize = 0;
        var cursor: atoms_codec.DebugCursor = .{ .debug = contents.debug };
        for (contents.atoms, 0..) |*a, i| atoms_len += atoms_codec.encodedLen(a, cursor.of(i));
        const header: Header = .{
            .deps_len = @intCast(contents.deps.len),
            .atoms_len = @intCast(contents.atoms.len),
            .atoms_bytes = atoms_len,
            .payload_len = contents.payload.len,
            .src_hash = contents.src_hash,
            .result_hash = contents.result_hash,
        };
        const len = @sizeOf(Header) + @sizeOf(Dep) * contents.deps.len + atoms_len + contents.payload.len;
        const start = b.bytes.items.len;
        const out = try b.reserve(gpa, key, len);
        @memcpy(out[0..@sizeOf(Header)], std.mem.asBytes(&header));
        var off: usize = @sizeOf(Header);
        @memcpy(out[off..][0 .. @sizeOf(Dep) * contents.deps.len], @as([]const u8, @ptrCast(contents.deps)));
        off += @sizeOf(Dep) * contents.deps.len;
        cursor = .{ .debug = contents.debug };
        for (contents.atoms, 0..) |*a, i| {
            const d = cursor.of(i);
            const n = atoms_codec.encodedLen(a, d);
            atoms_codec.encode(a, d, out[off..][0..n]);
            off += n;
        }
        @memcpy(out[off..], contents.payload);
        return start;
    }

    fn putRaw(b: *Batch, gpa: Allocator, key: Key, bytes: []const u8) Allocator.Error!void {
        @memcpy(try b.reserve(gpa, key, bytes.len), bytes);
    }

    /// Appends room for an entry of `len` bytes and indexes it.
    fn reserve(b: *Batch, gpa: Allocator, key: Key, len: usize) Allocator.Error![]u8 {
        const start = b.bytes.items.len;
        const padded = std.mem.alignForward(usize, len, 16);
        try b.index.ensureUnusedCapacity(gpa, 1);
        try b.bytes.resize(gpa, start + padded);
        @memset(b.bytes.items[start + len ..], 0);
        b.index.appendAssumeCapacity(.{ .key = key, .loc = .{ .offset16 = @intCast(start / 16), .len = @intCast(len) } });
        return b.bytes.items[start..][0..len];
    }

    pub fn clear(b: *Batch) void {
        b.bytes.clearRetainingCapacity();
        b.index.clearRetainingCapacity();
    }
};

/// Writes the entries of `batches`, and the entries `get` found in old
/// packs, as one new pack, then merges or trims packs if due. Empties the
/// batches. Of entries with the same key, the one in the earliest batch is
/// kept.
/// Returns the new pack's file name, or null if there was nothing to
/// write. With `keep`, the pack is written there first and then
/// hard-linked (or, across file systems, copied) into the store, so that
/// another build's maintenance cannot delete it before the caller has it.
pub fn commit(store: *Store, gpa: Allocator, io: Io, batches: []Batch, keep: ?Io.Dir) !?PackName {
    const name = try store.write(gpa, io, batches, keep);
    store.refreshUsed(io);
    try maintainIfDue(gpa, io, store.dir, store.packs.len + 1);
    return name;
}

/// `commit` without the maintenance.
pub fn write(store: *Store, gpa: Allocator, io: Io, batches: []Batch, keep: ?Io.Dir) !?PackName {
    var forward: Batch = .{};
    defer forward.deinit(gpa);
    for (store.forward.items) |f| try forward.putRaw(gpa, f.key, f.bytes);
    store.forward.clearRetainingCapacity();
    defer for (batches) |*b| b.clear();
    const parts = try gpa.alloc(*const Batch, batches.len + 1);
    defer gpa.free(parts);
    var n_parts: usize = 0;
    for (batches) |*b| if (b.index.items.len > 0) {
        parts[n_parts] = b;
        n_parts += 1;
    };
    if (forward.index.items.len > 0) {
        parts[n_parts] = &forward;
        n_parts += 1;
    }
    if (n_parts == 0) return null;
    const now: i64 = @intCast(store.opened.toNanoseconds());
    const k = keep orelse return try writePack(gpa, io, store.dir, parts[0..n_parts], now, now);
    const name = try writePack(gpa, io, k, parts[0..n_parts], now, now);
    k.hardLink(&name, store.dir, &name, io, .{}) catch |err| switch (err) {
        error.CrossDevice, error.OperationUnsupported => try k.copyFile(&name, store.dir, &name, io, .{}),
        else => |e| return e,
    };
    return name;
}

/// Writes the entries of `parts` as a pack, with the index sorted by key
/// and, of repeated keys, only the first. Returns its name.
fn writePack(gpa: Allocator, io: Io, dir: Io.Dir, parts: []const *const Batch, created: i64, order: i64) !PackName {
    var count: usize = 0;
    var entries_len: usize = 0;
    for (parts) |p| {
        count += p.index.items.len;
        entries_len += p.bytes.items.len;
    }
    const index = try gpa.alloc(Batch.IndexEntry, count);
    defer gpa.free(index);
    {
        var i: usize = 0;
        var base: usize = @sizeOf(PackHeader);
        for (parts) |p| {
            for (p.index.items) |e| {
                index[i] = .{ .key = e.key, .loc = .{ .offset16 = @intCast(base / 16 + e.loc.offset16), .len = e.loc.len } };
                i += 1;
            }
            base += p.bytes.items.len;
        }
    }
    std.sort.pdq(Batch.IndexEntry, index, {}, struct {
        fn lt(_: void, a: Batch.IndexEntry, b: Batch.IndexEntry) bool {
            return a.key < b.key or (a.key == b.key and a.loc.offset16 < b.loc.offset16);
        }
    }.lt);
    var n: usize = 0;
    for (index, 0..) |e, i| {
        if (i > 0 and e.key == index[n - 1].key) continue;
        index[n] = e;
        n += 1;
    }
    const index_len = PackHeader.indexLen(n);
    const index_bytes = try gpa.alignedAlloc(u8, .@"16", index_len);
    defer gpa.free(index_bytes);
    @memset(index_bytes, 0);
    const keys: []Hash = @ptrCast(@alignCast(index_bytes[0 .. n * @sizeOf(Hash)]));
    const locs: []Loc = @ptrCast(@alignCast(index_bytes[n * @sizeOf(Hash) ..][0 .. n * @sizeOf(Loc)]));
    const fanout: *[fanout_len]u32 = @ptrCast(@alignCast(index_bytes[n * (@sizeOf(Hash) + @sizeOf(Loc)) ..][0 .. fanout_len * 4]));
    var b: usize = 0;
    for (index[0..n], keys, locs, 0..) |e, *k, *l, i| {
        k.* = e.key;
        l.* = e.loc;
        const top: usize = @intCast(e.key >> 120);
        while (b <= top) : (b += 1) fanout[b] = @intCast(i);
    }
    while (b < fanout_len) : (b += 1) fanout[b] = @intCast(n);
    var header: PackHeader = .{
        .count = @intCast(n),
        .index_off = @sizeOf(PackHeader) + entries_len,
        .created = created,
        .order = order,
        .id = undefined,
    };
    io.random(std.mem.asBytes(&header.id));
    var name: [32 + pack_ext.len]u8 = undefined;
    _ = std.fmt.bufPrint(&name, "{x:0>32}" ++ pack_ext, .{header.id}) catch unreachable;
    var af = try dir.createFileAtomic(io, &name, .{});
    defer af.deinit(io);
    try writeSegments(gpa, io, af.file, std.mem.asBytes(&header), parts, index_bytes);
    try af.link(io);
    return name;
}

/// Writes `header`, the parts' entries, and `index` to `f`. Large packs are
/// written from several threads: copying into the page cache is most of
/// the cost of a first build's commit.
fn writeSegments(gpa: Allocator, io: Io, f: Io.File, header: []const u8, parts: []const *const Batch, index: []const u8) !void {
    var total: usize = header.len + index.len;
    for (parts) |p| total += p.bytes.items.len;
    const n_threads = @min(16, std.Thread.getCpuCount() catch 1, total / (4 << 20));
    if (n_threads <= 1) {
        var vecs: std.ArrayList([]const u8) = try .initCapacity(gpa, parts.len + 2);
        defer vecs.deinit(gpa);
        vecs.appendAssumeCapacity(header);
        for (parts) |p| vecs.appendAssumeCapacity(p.bytes.items);
        vecs.appendAssumeCapacity(index);
        var w = f.writerStreaming(io, &.{});
        w.interface.writeVecAll(vecs.items) catch return w.err.?;
        return;
    }
    // Segments of at most 4 MiB, dealt out to the threads in turn.
    const Segment = struct { bytes: []const u8, off: u64 };
    var segments: std.ArrayList(Segment) = .empty;
    defer segments.deinit(gpa);
    try segments.append(gpa, .{ .bytes = header, .off = 0 });
    var off: u64 = header.len;
    for (parts) |p| {
        var rest: []const u8 = p.bytes.items;
        while (rest.len > 0) {
            const len = @min(rest.len, 4 << 20);
            try segments.append(gpa, .{ .bytes = rest[0..len], .off = off });
            off += len;
            rest = rest[len..];
        }
    }
    try segments.append(gpa, .{ .bytes = index, .off = off });
    const Worker = struct {
        fn run(file: Io.File, io_: Io, segs: []const Segment, first: usize, stride: usize, err: *?Io.File.WritePositionalError) void {
            var i = first;
            while (i < segs.len) : (i += stride) {
                file.writePositionalAll(io_, segs[i].bytes, segs[i].off) catch |e| {
                    err.* = e;
                    return;
                };
            }
        }
    };
    var errs: [16]?Io.File.WritePositionalError = @splat(null);
    var group: Io.Group = .init;
    for (1..n_threads) |i| group.async(io, Worker.run, .{ f, io, segments.items, i, n_threads, &errs[i] });
    Worker.run(f, io, segments.items, 0, n_threads, &errs[0]);
    try group.await(io);
    for (errs[0..n_threads]) |e| if (e) |err| return err;
}

/// Merges packs when there are more than `max_packs`, and deletes unused
/// ones once a day, unless another build is doing so.
fn maintainIfDue(gpa: Allocator, io: Io, dir: Io.Dir, n_packs: usize) !void {
    const now = Io.Clock.real.now(io);
    const trim_due = if (dir.statFile(io, "trim", .{})) |stat|
        stat.mtime.durationTo(now).toNanoseconds() >= trim_interval_ns
    else |err| switch (err) {
        error.FileNotFound => true,
        else => |e| return e,
    };
    if (!trim_due and n_packs <= max_packs) return;
    _ = try maintain(gpa, io, dir, .{ .trim = trim_due, .now = now });
}

pub const MaintainOptions = struct {
    trim: bool,
    now: Io.Timestamp,
};

pub const MaintainResult = struct { deleted: u32 = 0, merged: u32 = 0 };

/// Under the store's maintenance lock, unless another build holds it:
/// deletes packs unused for `max_unused_ns` if `options.trim`, then merges
/// the smallest packs into one while there are more than `max_packs`.
pub fn maintain(gpa: Allocator, io: Io, dir: Io.Dir, options: MaintainOptions) !MaintainResult {
    const lock_file = try dir.createFile(io, "lock", .{ .truncate = false });
    defer lock_file.close(io);
    if (!try lock_file.tryLock(io, .exclusive)) return .{};
    var result: MaintainResult = .{};
    // Packs written since this build opened the store count too.
    const packs = try loadPacks(gpa, io, dir);
    defer {
        for (packs) |*p| p.map.destroy(io);
        gpa.free(packs);
    }
    var live: std.ArrayList(*const PackFile) = .empty;
    defer live.deinit(gpa);
    for (packs) |*p| {
        if (options.trim and p.mtime.durationTo(options.now).toNanoseconds() > max_unused_ns) {
            dir.deleteFile(io, &p.name) catch {};
            result.deleted += 1;
        } else try live.append(gpa, p);
    }
    if (options.trim) try dir.writeFile(io, .{ .sub_path = "trim", .data = "" });
    if (live.items.len <= max_packs) return result;

    // Merge packs adjacent in lookup order, so that the merged pack takes
    // their place in it and lookups still find the newest copy of a key,
    // down to half the limit. Of those runs, merge the one with the fewest
    // bytes, so that large packs are rarely rewritten.
    const run_len = live.items.len - max_packs / 2 + 1;
    var run_size: u64 = 0;
    for (live.items[0..run_len]) |p| run_size += p.size;
    var best_start: usize = 0;
    var best_size = run_size;
    for (run_len..live.items.len) |i| {
        run_size = run_size + live.items[i].size - live.items[i - run_len].size;
        if (run_size < best_size) {
            best_size = run_size;
            best_start = i - run_len + 1;
        }
    }
    // Newest first, as `live` is.
    const merge = live.items[best_start..][0..run_len];
    var count: usize = 0;
    var created: i64 = std.math.maxInt(i64);
    var mtime: Io.Timestamp = .zero;
    for (merge) |p| {
        count += p.keys.len;
        created = @min(created, p.created);
        if (p.mtime.compare(.gt, mtime)) mtime = p.mtime;
    }
    var merged: Batch = .{
        .bytes = try .initCapacity(gpa, @intCast(best_size)),
        .index = try .initCapacity(gpa, count),
    };
    defer merged.deinit(gpa);
    for (merge) |p| {
        for (p.keys, 0..) |k, i| try merged.putRaw(gpa, k, p.entryBytes(i));
    }
    // `writePack` keeps the first copy of a key: the newest pack's.
    const name = try writePack(gpa, io, dir, &.{&merged}, created, merge[0].order);
    // The merged pack was last used when the most recently used of its
    // parts was.
    try dir.setTimestamps(io, &name, .{ .modify_timestamp = .{ .new = mtime } });
    for (merge) |p| dir.deleteFile(io, &p.name) catch {};
    result.merged = @intCast(merge.len);
    return result;
}

fn countPacks(io: Io, dir: Io.Dir) !usize {
    var n: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (std.mem.endsWith(u8, e.name, pack_ext)) n += 1;
    }
    return n;
}

test "entries round-trip through packs, are checked, copied forward, merged, and trimmed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const t = std.testing;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const atoms = [_]Atom{
        .{ .key = .fromName("c"), .name = "t:c", .section = .rodata, .alignment = .@"8", .bytes = "abcdefgh" },
        .{ .key = .fromName("f"), .name = "t:f", .section = .text, .bytes = &.{0xc3} },
    };
    const debug = [_]Atom.Debug{.{ .atom = 1, .file = "t.zig", .name = "f", .base_line = 3, .lines = &.{1}, .frame = .frame_pointer }};
    const deps = [_]Dep{ .{ .key = 1, .result_hash = 10 }, .{ .key = 2, .result_hash = 20 } };
    // Keys 7 and 7 + 2^127 share no fan-out bucket; 8 shares 7's.
    const k2: Key = 7 + (1 << 127);
    {
        var store: Store = try .open(gpa, io, tmp.dir);
        defer store.close(gpa, io);
        try t.expectEqual(null, try store.get(gpa, io, 7));
        var batch: Batch = .{};
        defer batch.deinit(gpa);
        _ = try batch.put(gpa, 7, .{ .src_hash = 99, .result_hash = 100, .deps = &deps, .atoms = &atoms, .debug = &debug, .payload = "result" });
        _ = try batch.put(gpa, k2, .{ .src_hash = 1, .result_hash = 2, .payload = "x" });
        _ = try batch.put(gpa, 8, .{ .src_hash = 3, .result_hash = 4 });
        _ = try store.commit(gpa, io, (&batch)[0..1], null);
    }
    {
        var store: Store = try .open(gpa, io, tmp.dir);
        defer store.close(gpa, io);
        try t.expectEqual(1, store.packs.len);
        const entry = (try store.get(gpa, io, 7)).?;
        try t.expectEqual(100, entry.resultHash());
        try t.expectEqualSlices(u8, @ptrCast(&deps), @ptrCast(entry.deps()));
        try t.expectEqualStrings("result", entry.payload());
        var decoded: [2]Atom = undefined;
        var decoded_debug: [2]Atom.Debug = undefined;
        try t.expectEqual(2, entry.atomCount());
        try t.expectEqual(1, try entry.decodeAtoms(&decoded, &decoded_debug));
        for (atoms, decoded) |e, a| try atoms_codec.expectEqualAtoms(e, a);
        try t.expectEqual(1, decoded_debug[0].atom);
        try atoms_codec.expectEqualDebug(&debug[0], &decoded_debug[0]);
        try t.expectEqualStrings("x", (try store.get(gpa, io, k2)).?.payload());
        try t.expectEqual(4, (try store.get(gpa, io, 8)).?.resultHash());
        try t.expectEqual(null, try store.get(gpa, io, 9));

        const Graph = struct {
            dep2: Hash,
            pub fn resultHash(g: @This(), key: Hash) ?Hash {
                return switch (key) {
                    1 => 10,
                    2 => g.dep2,
                    else => null,
                };
            }
        };
        try t.expect(entry.isValid(99, Graph{ .dep2 = 20 }));
        try t.expect(!entry.isValid(98, Graph{ .dep2 = 20 }));
        try t.expect(!entry.isValid(99, Graph{ .dep2 = 21 }));

        // A newer entry for key 8 wins. Once the pack is three days old,
        // the entry hit in it (7) is written again.
        store.packs[0].created -= 3 * std.time.ns_per_day;
        _ = try store.get(gpa, io, 7);
        var batch: Batch = .{};
        defer batch.deinit(gpa);
        _ = try batch.put(gpa, 8, .{ .src_hash = 3, .result_hash = 5 });
        _ = try store.commit(gpa, io, (&batch)[0..1], null);
    }
    {
        var store: Store = try .open(gpa, io, tmp.dir);
        defer store.close(gpa, io);
        try t.expectEqual(2, store.packs.len);
        try t.expectEqual(5, (try store.get(gpa, io, 8)).?.resultHash());
        try t.expectEqual(2, store.packs[0].keys.len);
        try t.expect(store.packs[0].find(7) != null);
        try t.expectEqualStrings("result", (try store.get(gpa, io, 7)).?.payload());
    }

    // Past `max_packs`, the smallest packs are merged; the newest copy of
    // each key survives.
    for (0..max_packs - 1) |i| {
        var store: Store = try .open(gpa, io, tmp.dir);
        defer store.close(gpa, io);
        var batch: Batch = .{};
        defer batch.deinit(gpa);
        _ = try batch.put(gpa, 8, .{ .src_hash = 3, .result_hash = 6 + i });
        _ = try batch.put(gpa, 1000 + i, .{ .src_hash = 0, .result_hash = 0 });
        _ = try store.commit(gpa, io, (&batch)[0..1], null);
    }
    var store_dir = try tmp.dir.openDir(io, "zap/store", .{ .iterate = true });
    defer store_dir.close(io);
    try t.expectEqual(max_packs / 2, try countPacks(io, store_dir));
    {
        var store: Store = try .open(gpa, io, tmp.dir);
        defer store.close(gpa, io);
        try t.expectEqual(6 + max_packs - 2, (try store.get(gpa, io, 8)).?.resultHash());
        for (0..max_packs - 1) |i| try t.expect(try store.get(gpa, io, 1000 + i) != null);
        try t.expectEqualStrings("x", (try store.get(gpa, io, k2)).?.payload());
    }

    // Packs unused for `max_unused_ns` are deleted.
    const later = Io.Clock.real.now(io).addDuration(.fromNanoseconds(max_unused_ns + std.time.ns_per_s));
    const r = try maintain(gpa, io, store_dir, .{ .trim = true, .now = later });
    try t.expectEqual(max_packs / 2, r.deleted);
    try t.expectEqual(0, try countPacks(io, store_dir));
}
