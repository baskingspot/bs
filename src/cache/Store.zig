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
//! `max_unused_ns`, and the least recently used ones while the packs total
//! more than `max_bytes`. So that a pack does not live on for a few of its
//! entries, a hit in a pack older than `copy_forward_ns` is written again
//! by the build's `commit`; live entries move to young packs and old packs
//! fall out of use.
//!
//! The global cache's ZIR (`<global cache>/bs/zir/<32 hex>`, every
//! project's, `Frontend`) counts and goes with the packs: each file is a
//! candidate by its mtime, which a build that maps it renews daily.
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

/// `<global cache>/bs/store`.
dir: Io.Dir,
/// Newest first.
packs: []PackFile,
/// When `open` ran, which ages are measured against.
opened: Io.Timestamp,
/// Hits in old packs, written again by the next `commit`.
forward: std.ArrayList(Forward) = .empty,
/// `commit` evicts the least recently used packs while they total more.
max_bytes: u64 = cache.default_max_bytes,
/// The size of the packs `open` found but could not read: another bs's
/// format, or damaged. They count toward `max_bytes` too.
other_bytes: u64 = 0,
forward_mutex: Io.Mutex = .init,
/// The id of the pack the next `commit` writes, if `reserveName` chose it.
next_id: ?Hash = null,

pub const Key = Hash;

/// A dependency of an entry: what it read, and the result hash that had.
pub const Dep = extern struct {
    key: Hash,
    result_hash: Hash,
};

const entry_magic = "ZAPUNT02".*;

const Header = extern struct {
    magic: [8]u8 = entry_magic,
    deps_len: u32,
    atoms_len: u32,
    atoms_bytes: u64,
    payload_len: u64,
    src_hash: Hash,
    result_hash: Hash,

    /// Whether it is an entry's header, of an entry `len` bytes long.
    fn fits(h: *const Header, len: u64) bool {
        return std.mem.eql(u8, &h.magic, &entry_magic) and
            @sizeOf(Header) + @sizeOf(Dep) * @as(u64, h.deps_len) + h.atoms_bytes + h.payload_len == len;
    }
};

const pack_magic = "ZAPSTP07".*;
const pack_ext = ".zsp";
/// Donors (`Incremental.publishDonor`): directories each holding a
/// compilation's manifest and links to the packs it names. `maintain`
/// trims them with the packs, by last use, counting the manifest and the
/// linked packs the store itself no longer has.
pub const donors_dir = "donors";
/// The global cache's ZIR directory (`Frontend`), relative to the store.
const zir_dir = ".." ++ Io.Dir.path.sep_str ++ "zir";
/// A donor being written; `maintain` deletes one older than an hour.
pub const donor_tmp_prefix = "tmp-";

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
pub const used_refresh_ns = 60 * std.time.ns_per_min;
pub const max_unused_ns = 5 * std.time.ns_per_day;
pub const copy_forward_ns = max_unused_ns / 2;
const trim_interval_ns = 24 * std.time.ns_per_hour;
/// `maintainStale` and `commit` run `maintain` at least this often, so
/// that what the packs' sizes do not show (donors, the global ZIR) is
/// counted against the limit within minutes of being written.
const scan_interval_ns = 10 * std.time.ns_per_min;

/// Whether stamp file `name` in the store's directory is older than
/// `interval_ns`, or missing.
fn stampDue(dir: Io.Dir, io: Io, name: []const u8, now: Io.Timestamp, interval_ns: i96) bool {
    const stat = dir.statFile(io, name, .{}) catch return true;
    return stat.mtime.durationTo(now).toNanoseconds() >= interval_ns;
}

const PackFile = struct {
    name: [32 + pack_ext.len]u8,
    /// Open for `peek`, which reads entry headers without touching `map`.
    file: Io.File,
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

    fn close(p: *PackFile, io: Io) void {
        p.map.destroy(io);
        p.file.close(io);
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

/// The size of pack `i`.
pub fn packSize(store: *const Store, i: u32) u64 {
    return store.packs[i].size;
}

/// The file name of pack `i` in `dir`.
pub fn packName(store: *const Store, i: u32) []const u8 {
    return &store.packs[i].name;
}

/// Chooses the name of the pack the next `commit` writes, if it writes one,
/// so that a manifest can name it before the commit finishes.
pub fn reserveName(store: *Store, io: Io) PackName {
    var id: Hash = undefined;
    io.random(std.mem.asBytes(&id));
    store.next_id = id;
    return nameOf(id);
}

fn nameOf(id: Hash) PackName {
    var name: PackName = undefined;
    _ = std.mem.print(&name, "{x:0>32}" ++ pack_ext, .{id}) catch unreachable;
    return name;
}

/// Maps every pack in `<global_cache>/bs/store`.
pub fn open(gpa: Allocator, io: Io, global_cache: Io.Dir) !Store {
    const dir = try global_cache.createDirPathOpen(io, "bs/store", .{ .open_options = .{ .iterate = true } });
    errdefer dir.close(io);
    var others: std.ArrayList(OtherPack) = .empty;
    defer others.deinit(gpa);
    const packs = try loadPacks(gpa, io, dir, &others);
    var other_bytes: u64 = 0;
    for (others.items) |o| other_bytes += o.size;
    return .{ .dir = dir, .packs = packs, .opened = Io.Clock.real.now(io), .other_bytes = other_bytes };
}

/// A pack that `openPack` cannot read: written by a bs whose pack format
/// differs (which may still use it), or damaged. Maintenance counts it
/// toward the size limit and deletes it by its mtime, as any other pack,
/// but never because it is unreadable, so that two bs versions sharing
/// a store do not delete each other's packs.
const OtherPack = struct { name: [32 + pack_ext.len]u8, size: u64, mtime: Io.Timestamp };

/// Maps the packs in `dir`, newest first, and appends those it cannot
/// read to `others`.
fn loadPacks(gpa: Allocator, io: Io, dir: Io.Dir, others: *std.ArrayList(OtherPack)) ![]PackFile {
    var packs: std.ArrayList(PackFile) = .empty;
    errdefer {
        for (packs.items) |*p| p.close(io);
        packs.deinit(gpa);
    }
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file or e.name.len != 32 + pack_ext.len or !std.mem.endsWith(u8, e.name, pack_ext)) continue;
        try packs.ensureUnusedCapacity(gpa, 1);
        if (try openPack(io, dir, e.name)) |p| {
            packs.appendAssumeCapacity(p);
        } else if (dir.statFile(io, e.name, .{})) |stat| {
            try others.append(gpa, .{ .name = e.name[0 .. 32 + pack_ext.len].*, .size = stat.size, .mtime = stat.mtime });
        } else |_| {}
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
    var keep = false;
    defer if (!keep) f.close(io);
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
        .file = f,
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
    keep = true;
    return p;
}

/// Records which packs this build used, and unmaps them. Entries from
/// `get` are invalid afterwards.
pub fn close(store: *Store, gpa: Allocator, io: Io) void {
    store.refreshUsed(io);
    for (store.packs) |*p| p.close(io);
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
        cache.setTimestamps(io, store.dir, &p.name, .{ .access_timestamp = .now, .modify_timestamp = .now }) catch {}; // ziglint-ignore: Z026 -- cache upkeep is best effort
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

    /// The length of the atom records.
    pub fn atomsBytes(e: Entry) u64 {
        return e.header().atoms_bytes;
    }

    /// Decodes the entry's atoms into `out`, which has `atomCount()` items,
    /// and their debug info into the start of `debug`, which has as many;
    /// `Debug.atom` is the index in `out`. Returns how many have debug info.
    /// `arch` is the architecture whose unwind records are valid.
    pub fn decodeAtoms(e: Entry, arch: Atom.Unwind.Arch, out: []Atom, debug: []Atom.Debug) atoms_codec.DecodeError!usize {
        const bytes = e.atomBytes();
        var off: usize = 0;
        var n_debug: usize = 0;
        for (out, 0..) |*a, i| {
            const d = try atoms_codec.decode(@alignCast(bytes[off..]), arch);
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
        if (!e.header().fits(bytes.len)) return null;
        try store.noteUse(gpa, io, p, key, bytes);
        return e;
    }
    return null;
}

/// What `get` finds for `key`, but with the entry's header read from the
/// pack file instead of its mapping, so that a lookup of every unit of a
/// build (`Incremental.record`) maps in no pack page: it made a warm-store
/// record's resident memory 230 MB larger on the zig workload. Thread-safe.
pub fn peek(store: *Store, gpa: Allocator, io: Io, key: Key) Allocator.Error!?Peeked {
    for (store.packs, 0..) |*p, pack_index| {
        const i = p.find(key) orelse continue;
        const loc = p.locs[i];
        const offset = @as(u64, loc.offset16) * 16;
        if (loc.len < @sizeOf(Header)) return null;
        var h: Header = undefined;
        const n = p.file.readPositionalAll(io, std.mem.asBytes(&h), offset) catch return null;
        if (n != @sizeOf(Header) or !h.fits(loc.len)) return null;
        try store.noteUse(gpa, io, p, key, p.entryBytes(i));
        return .{ .pack = @intCast(pack_index), .offset = offset, .result_hash = h.result_hash, .deps_len = h.deps_len, .atoms_len = h.atoms_len, .atoms_bytes = h.atoms_bytes };
    }
    return null;
}

pub const Peeked = struct {
    pack: u32,
    offset: u64,
    result_hash: Hash,
    deps_len: u32,
    atoms_len: u32,
    atoms_bytes: u64,
};

/// Marks pack `p` used, and queues the entry to be copied forward if the
/// pack is old.
fn noteUse(store: *Store, gpa: Allocator, io: Io, p: *PackFile, key: Key, bytes: []align(16) const u8) Allocator.Error!void {
    if (!p.used.load(.monotonic)) p.used.store(true, .monotonic);
    if (store.opened.toNanoseconds() - p.created > copy_forward_ns) {
        store.forward_mutex.lockUncancelable(io);
        defer store.forward_mutex.unlock(io);
        try store.forward.append(gpa, .{ .key = key, .bytes = bytes });
    }
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

    pub fn deinit(b: *Batch, gpa: Allocator) void {
        b.bytes.deinit(gpa);
        b.index.deinit(gpa);
        b.* = undefined;
    }

    /// Adds an entry and returns its offset in the batch. In the pack
    /// `commit` writes, batch `i`'s entries start at `pack_header_len` plus
    /// the bytes of the batches before it; the entry's atom records start
    /// `atomsOffset(deps.len)` into it, one after another.
    pub fn put(b: *Batch, gpa: Allocator, key: Key, contents: Contents) Allocator.Error!usize {
        const start = b.bytes.items.len;
        encodeEntry(contents, try b.reserve(gpa, key, entryLen(contents)));
        return start;
    }

    fn putRaw(b: *Batch, gpa: Allocator, key: Key, bytes: []const u8) Allocator.Error!void {
        @memcpy(try b.reserve(gpa, key, bytes.len), bytes);
    }

    /// Appends room for an entry of `len` bytes and indexes it.
    /// Makes room for `n` entries of `bytes` bytes in all, padding
    /// included, so that `put` neither grows nor copies the batch.
    pub fn ensureUnusedCapacity(b: *Batch, gpa: Allocator, n: usize, bytes: usize) Allocator.Error!void {
        try b.index.ensureUnusedCapacity(gpa, n);
        try b.bytes.ensureUnusedCapacity(gpa, bytes);
    }

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

/// The length of the entry of `contents`, before padding to 16 bytes.
pub fn entryLen(contents: Contents) usize {
    var len = @sizeOf(Header) + @sizeOf(Dep) * contents.deps.len + contents.payload.len;
    var cursor: atoms_codec.DebugCursor = .{ .debug = contents.debug };
    for (contents.atoms, 0..) |*a, i| len += atoms_codec.encodedLen(a, cursor.of(i));
    return len;
}

/// Writes the entry of `contents` to `out`, which is `entryLen(contents)`
/// bytes. Its atom records start `atomsOffset(deps.len)` into it, one after
/// another.
pub fn encodeEntry(contents: Contents, out: []u8) void {
    const atoms_len = out.len - @sizeOf(Header) - @sizeOf(Dep) * contents.deps.len - contents.payload.len;
    const header: Header = .{
        .deps_len = @intCast(contents.deps.len),
        .atoms_len = @intCast(contents.atoms.len),
        .atoms_bytes = atoms_len,
        .payload_len = contents.payload.len,
        .src_hash = contents.src_hash,
        .result_hash = contents.result_hash,
    };
    @memcpy(out[0..@sizeOf(Header)], std.mem.asBytes(&header));
    var off: usize = @sizeOf(Header);
    @memcpy(out[off..][0 .. @sizeOf(Dep) * contents.deps.len], @as([]const u8, @ptrCast(contents.deps)));
    off += @sizeOf(Dep) * contents.deps.len;
    var cursor: atoms_codec.DebugCursor = .{ .debug = contents.debug };
    for (contents.atoms, 0..) |*a, i| {
        const d = cursor.of(i);
        const n = atoms_codec.encodedLen(a, d);
        atoms_codec.encode(a, d, out[off..][0..n]);
        off += n;
    }
    @memcpy(out[off..], contents.payload);
}

/// Where an entry is in a pack: its key, and offset and length.
pub const IndexEntry = struct {
    key: Key,
    loc: Loc,

    pub fn init(key: Key, offset: u64, len: usize) IndexEntry {
        std.debug.assert(offset % 16 == 0);
        return .{ .key = key, .loc = .{ .offset16 = @intCast(offset / 16), .len = @intCast(len) } };
    }
};

/// A pack whose entries the caller writes in place, from several threads
/// if it likes (`beginPack`, `writeAt`, `commitPack`), so that a build's
/// entries are never all in memory: the caller lays them out from
/// `pack_header_len`, each 16-byte aligned, with `entryLen` and
/// `encodeEntry`.
pub const PackWriter = struct {
    af: Io.File.Atomic,
    id: Hash,
    /// `af` refers to it, so a `PackWriter` must not move.
    name: PackName,

    pub fn writeAt(w: *PackWriter, io: Io, bytes: []const u8, offset: u64) !void {
        try w.af.file.writePositionalAll(io, bytes, offset);
    }

    /// Discards the pack, unless `commitPack` placed it.
    pub fn deinit(w: *PackWriter, io: Io) void {
        w.af.deinit(io);
        w.* = undefined;
    }
};

/// Starts a pack in `w`, in `keep` if given (see `commit`), named as
/// `reserveName` chose if it did.
pub fn beginPack(store: *Store, io: Io, keep: ?Io.Dir, w: *PackWriter) !void {
    if (store.next_id) |i| w.id = i else io.random(std.mem.asBytes(&w.id));
    store.next_id = null;
    w.name = nameOf(w.id);
    w.af = try (keep orelse store.dir).createFileAtomic(io, &w.name, .{});
}

/// Finishes a pack from `beginPack`, whose entries are at `entries` and end
/// at `end`: adds the entries `get` found in old packs, writes the index
/// and header, places the pack as `commit` does, and merges or trims packs
/// if due. Returns the pack's file name.
pub fn commitPack(store: *Store, gpa: Allocator, io: Io, w: *PackWriter, entries: []const IndexEntry, end: u64, keep: ?Io.Dir) !PackName {
    var all: std.ArrayList(IndexEntry) = try .initCapacity(gpa, entries.len + store.forward.items.len);
    defer all.deinit(gpa);
    all.appendSliceAssumeCapacity(entries);
    var off = end;
    for (store.forward.items) |f| {
        try w.writeAt(io, f.bytes, off);
        all.appendAssumeCapacity(.init(f.key, off, f.bytes.len));
        off += std.mem.alignForward(u64, f.bytes.len, 16);
    }
    store.forward.clearRetainingCapacity();
    const now: i64 = @intCast(store.opened.toNanoseconds());
    const name = try finishPack(gpa, io, w, all.items, off, now, now);
    if (keep) |k| try placeInStore(io, k, store.dir, &name);
    store.refreshUsed(io);
    store.maintainIfDue(gpa, io, off + PackHeader.indexLen(all.items.len));
    return name;
}

fn placeInStore(io: Io, keep: Io.Dir, store_dir: Io.Dir, name: []const u8) !void {
    keep.hardLink(name, store_dir, name, io, .{}) catch |err| switch (err) {
        error.CrossDevice, error.OperationUnsupported => try keep.copyFile(name, store_dir, name, io, .{}),
        else => |e| return e,
    };
}

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
    var new_bytes: u64 = 0;
    if (name) |n| new_bytes = if (store.dir.statFile(io, &n, .{})) |st| st.size else |_| 0;
    store.maintainIfDue(gpa, io, new_bytes);
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
    const id = store.next_id;
    store.next_id = null;
    const k = keep orelse return try writePack(gpa, io, store.dir, parts[0..n_parts], now, now, id);
    const name = try writePack(gpa, io, k, parts[0..n_parts], now, now, id);
    try placeInStore(io, k, store.dir, &name);
    return name;
}

/// Writes the entries of `parts` as a pack with id `id`, or a random one,
/// with the index sorted by key and, of repeated keys, only the first.
/// Returns its name.
fn writePack(gpa: Allocator, io: Io, dir: Io.Dir, parts: []const *const Batch, created: i64, order: i64, id: ?Hash) !PackName {
    var count: usize = 0;
    for (parts) |p| count += p.index.items.len;
    const index = try gpa.alloc(IndexEntry, count);
    defer gpa.free(index);
    var end: u64 = @sizeOf(PackHeader);
    {
        var i: usize = 0;
        for (parts) |p| {
            for (p.index.items) |e| {
                index[i] = .{ .key = e.key, .loc = .{ .offset16 = @intCast(end / 16 + e.loc.offset16), .len = e.loc.len } };
                i += 1;
            }
            end += p.bytes.items.len;
        }
    }
    var w: PackWriter = undefined;
    if (id) |i| w.id = i else io.random(std.mem.asBytes(&w.id));
    w.name = nameOf(w.id);
    w.af = try dir.createFileAtomic(io, &w.name, .{});
    defer w.deinit(io);
    try writeSegments(gpa, io, w.af.file, parts);
    return finishPack(gpa, io, &w, index, end, created, order);
}

/// Sorts `index` (absolute offsets; of repeated keys, the earliest entry
/// stays), writes it at `end` and the header at 0, and links the pack under
/// its name.
fn finishPack(gpa: Allocator, io: Io, w: *PackWriter, index: []IndexEntry, end: u64, created: i64, order: i64) !PackName {
    std.sort.pdq(IndexEntry, index, {}, struct {
        fn lt(_: void, a: IndexEntry, b: IndexEntry) bool {
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
    const header: PackHeader = .{
        .count = @intCast(n),
        .index_off = end,
        .created = created,
        .order = order,
        .id = w.id,
    };
    try w.writeAt(io, index_bytes, end);
    try w.writeAt(io, std.mem.asBytes(&header), 0);
    try w.af.link(io);
    return w.name;
}

/// Writes the parts' entries to `f`, from `pack_header_len` on. Large packs
/// are written from several threads: copying into the page cache is most
/// of the cost of a first build's commit.
fn writeSegments(gpa: Allocator, io: Io, f: Io.File, parts: []const *const Batch) !void {
    // Segments of at most 4 MiB, dealt out to the threads in turn.
    const Segment = struct { bytes: []const u8, off: u64 };
    var segments: std.ArrayList(Segment) = .empty;
    defer segments.deinit(gpa);
    var off: u64 = @sizeOf(PackHeader);
    for (parts) |p| {
        var rest: []const u8 = p.bytes.items;
        while (rest.len > 0) {
            const len = @min(rest.len, 4 << 20);
            try segments.append(gpa, .{ .bytes = rest[0..len], .off = off });
            off += len;
            rest = rest[len..];
        }
    }
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
    const n_threads = @max(1, @min(16, std.Thread.getCpuCount() catch 1, segments.items.len));
    var errs: [16]?Io.File.WritePositionalError = @splat(null);
    var group: Io.Group = .init;
    for (1..n_threads) |i| group.async(io, Worker.run, .{ f, io, segments.items, i, n_threads, &errs[i] });
    Worker.run(f, io, segments.items, 0, n_threads, &errs[0]);
    try group.await(io);
    for (errs[0..n_threads]) |e| if (e) |err| return err;
}

/// After a commit that wrote a pack of `new_bytes`: merges packs when there
/// are more than `max_packs`, evicts packs when they total more than
/// `max_bytes`, and deletes unused ones once a day, unless another build is
/// doing so. Maintenance is best effort; its failures do not fail the
/// commit.
fn maintainIfDue(store: *const Store, gpa: Allocator, io: Io, new_bytes: u64) void {
    const now = Io.Clock.real.now(io);
    const trim_due = stampDue(store.dir, io, "trim", now, trim_interval_ns);
    var bytes = new_bytes + store.other_bytes;
    for (store.packs) |*p| bytes += p.size;
    const n_packs = store.packs.len + @intFromBool(new_bytes != 0);
    if (!trim_due and !stampDue(store.dir, io, "scan", now, scan_interval_ns) and n_packs <= max_packs and bytes <= store.max_bytes) return;
    _ = maintain(gpa, io, store.dir, .{ .trim = trim_due, .now = now, .max_bytes = store.max_bytes }) catch {}; // ziglint-ignore: Z026 -- cache upkeep is best effort
}

const CandidateKind = enum { pack, donor, zir };

fn deleteCandidate(io: Io, dir: Io.Dir, donors: ?Io.Dir, zir: ?Io.Dir, kind: CandidateKind, name: []const u8) !void {
    switch (kind) {
        .pack => try dir.deleteFile(io, name),
        .donor => try donors.?.deleteTree(io, name),
        .zir => try zir.?.deleteFile(io, name),
    }
}

/// `maintain`, if the daily trim or the scan (`scan_interval_ns`) is
/// due: for builds that commit nothing to the store but write ZIR or use
/// donors, so that the global cache's limit holds without a commit. One
/// stat when nothing is due.
pub fn maintainStale(gpa: Allocator, io: Io, dir: Io.Dir, max_bytes: u64) ?MaintainResult {
    const now = Io.Clock.real.now(io);
    const trim_due = stampDue(dir, io, "trim", now, trim_interval_ns);
    if (!trim_due and !stampDue(dir, io, "scan", now, scan_interval_ns)) return null;
    return maintain(gpa, io, dir, .{ .trim = trim_due, .now = now, .max_bytes = max_bytes }) catch null;
}

pub const MaintainOptions = struct {
    trim: bool,
    now: Io.Timestamp,
    max_bytes: u64 = cache.default_max_bytes,
};

pub const MaintainResult = struct { deleted: u32 = 0, evicted: u32 = 0, merged: u32 = 0 };

/// Under the store's maintenance lock, unless another build holds it:
/// deletes packs unused for `max_unused_ns` if `options.trim`; while the
/// packs total more than `options.max_bytes`, deletes the least recently
/// used down to three quarters of it; then, while there are more than
/// `max_packs`, merges the smallest into one.
pub fn maintain(gpa: Allocator, io: Io, dir: Io.Dir, options: MaintainOptions) !MaintainResult {
    const lock_file = try dir.createFile(io, "lock", .{ .truncate = false });
    defer lock_file.close(io);
    if (!try lock_file.tryLock(io, .exclusive)) return .{};
    try dir.writeFile(io, .{ .sub_path = "scan", .data = "" });
    var result: MaintainResult = .{};
    // Packs written since this build opened the store count too.
    var others: std.ArrayList(OtherPack) = .empty;
    defer others.deinit(gpa);
    const packs = try loadPacks(gpa, io, dir, &others);
    defer {
        for (packs) |*p| p.close(io);
        gpa.free(packs);
    }
    // Every pack, readable (`live`) or not (`OtherPack`), as candidates
    // for deletion.
    const Candidate = struct { name: []const u8, size: u64, mtime: Io.Timestamp, order: i64, live: ?*const PackFile, kind: CandidateKind = .pack };
    var candidates: std.ArrayList(Candidate) = .empty;
    defer candidates.deinit(gpa);
    var live: std.ArrayList(*const PackFile) = .empty;
    defer live.deinit(gpa);
    for (packs) |*p| try candidates.append(gpa, .{ .name = &p.name, .size = p.size, .mtime = p.mtime, .order = p.order, .live = p });
    for (others.items) |*o| try candidates.append(gpa, .{ .name = &o.name, .size = o.size, .mtime = o.mtime, .order = std.math.minInt(i64), .live = null });
    var names: std.StringHashMapUnmanaged(void) = .empty;
    defer names.deinit(gpa);
    for (candidates.items) |c| try names.put(gpa, c.name, {});
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var donors: ?Io.Dir = dir.openDir(io, donors_dir, .{ .iterate = true }) catch null;
    defer if (donors) |*d| d.close(io);
    if (donors) |d| {
        var it = d.iterate();
        while (try it.next(io)) |e| {
            if (e.kind != .directory) continue;
            if (std.mem.startsWith(u8, e.name, donor_tmp_prefix)) {
                const st = d.statFile(io, e.name, .{}) catch continue;
                if (st.mtime.durationTo(options.now).toNanoseconds() > std.time.ns_per_hour) d.deleteTree(io, e.name) catch {}; // ziglint-ignore: Z026 -- cache upkeep is best effort
                continue;
            }
            var dd = d.openDir(io, e.name, .{ .iterate = true }) catch continue;
            defer dd.close(io);
            const manifest = dd.statFile(io, "manifest", .{}) catch continue;
            var size = manifest.size;
            var dit = dd.iterate();
            while (try dit.next(io)) |f| {
                if (!std.mem.endsWith(u8, f.name, pack_ext) or names.contains(f.name)) continue;
                size += (dd.statFile(io, f.name, .{}) catch continue).size;
            }
            try candidates.append(gpa, .{
                .name = try arena_state.allocator().dupe(u8, e.name),
                .size = size,
                .mtime = manifest.mtime,
                .order = std.math.minInt(i64),
                .live = null,
                .kind = .donor,
            });
        }
    }
    var zir: ?Io.Dir = dir.openDir(io, zir_dir, .{ .iterate = true }) catch null;
    defer if (zir) |*d| d.close(io);
    if (zir) |d| {
        var it = d.iterate();
        while (try it.next(io)) |e| {
            var hash: [16]u8 = undefined;
            if (e.kind != .file or e.name.len != 2 * hash.len) continue;
            _ = std.fmt.hexToBytes(&hash, e.name) catch continue;
            const st = d.statFile(io, e.name, .{}) catch continue;
            try candidates.append(gpa, .{
                .name = try arena_state.allocator().dupe(u8, e.name),
                .size = st.size,
                .mtime = st.mtime,
                .order = std.math.minInt(i64),
                .live = null,
                .kind = .zir,
            });
        }
    }
    var total: u64 = 0;
    var n_kept: usize = 0;
    for (candidates.items) |c| {
        if (options.trim and c.mtime.durationTo(options.now).toNanoseconds() > max_unused_ns) {
            deleteCandidate(io, dir, donors, zir, c.kind, c.name) catch {}; // ziglint-ignore: Z026 -- cache upkeep is best effort
            result.deleted += 1;
            continue;
        }
        candidates.items[n_kept] = c;
        n_kept += 1;
        total += c.size;
    }
    candidates.shrinkRetainingCapacity(n_kept);
    if (options.trim) try dir.writeFile(io, .{ .sub_path = "trim", .data = "" });

    if (total > options.max_bytes) {
        // Least recently used first. The space of a pack that a
        // compilation directory links stays in use until that directory
        // drops it (`cache.maintainCompilations`).
        std.mem.sortUnstable(Candidate, candidates.items, {}, struct {
            fn older(_: void, a: Candidate, b: Candidate) bool {
                return a.mtime.compare(.lt, b.mtime) or (a.mtime.compare(.eq, b.mtime) and a.order < b.order);
            }
        }.older);
        const target = options.max_bytes - options.max_bytes / 4;
        for (candidates.items) |*c| {
            if (total <= target) break;
            deleteCandidate(io, dir, donors, zir, c.kind, c.name) catch continue;
            total -= c.size;
            result.evicted += 1;
            c.live = null;
        }
    }
    // Newest first, as `packs` is.
    for (packs) |*p| {
        for (candidates.items) |c| if (c.live == p) {
            try live.append(gpa, p);
            break;
        };
    }
    if (live.items.len <= max_packs) return result;

    // Merge the smallest packs, down to half the limit, so that large
    // packs are rarely rewritten: a rewrite costs their size again, and
    // while a compilation directory still links the old pack, as much
    // disk. The merged pack takes the place in lookup order of the newest
    // of them, so an entry is dropped where a pack left out of the merge
    // and newer than the entry's own holds the same key: lookups still
    // find the newest copy of every key.
    const n_merge = live.items.len - max_packs / 2 + 1;
    const merge = try gpa.alloc(bool, live.items.len);
    defer gpa.free(merge);
    @memset(merge, false);
    {
        const by_size = try gpa.alloc(u32, live.items.len);
        defer gpa.free(by_size);
        for (by_size, 0..) |*s, i| s.* = @intCast(i);
        std.mem.sortUnstable(u32, by_size, live.items, struct {
            fn smaller(ps: []const *const PackFile, a: u32, b: u32) bool {
                return ps[a].size < ps[b].size or (ps[a].size == ps[b].size and a < b);
            }
        }.smaller);
        for (by_size[0..n_merge]) |i| merge[i] = true;
    }
    var size: u64 = 0;
    var count: usize = 0;
    var created: i64 = std.math.maxInt(i64);
    var order: i64 = std.math.minInt(i64);
    var mtime: Io.Timestamp = .zero;
    for (live.items, merge) |p, m| if (m) {
        size += p.size;
        count += p.keys.len;
        created = @min(created, p.created);
        order = @max(order, p.order);
        if (p.mtime.compare(.gt, mtime)) mtime = p.mtime;
    };
    var merged: Batch = .{
        .bytes = try .initCapacity(gpa, @intCast(size)),
        .index = try .initCapacity(gpa, count),
    };
    defer merged.deinit(gpa);
    // Newest first, as `live` is.
    for (live.items, merge, 0..) |p, m, pi| if (m) {
        keys: for (p.keys, 0..) |k, i| {
            for (live.items[0..pi], merge[0..pi]) |q, qm| {
                if (!qm and q.find(k) != null) continue :keys;
            }
            try merged.putRaw(gpa, k, p.entryBytes(i));
        }
    };
    // `writePack` keeps the first copy of a key: the newest pack's.
    const name = try writePack(gpa, io, dir, &.{&merged}, created, order, null);
    // The merged pack was last used when the most recently used of its
    // parts was.
    try dir.setTimestamps(io, &name, .{ .modify_timestamp = .{ .new = mtime } });
    for (live.items, merge) |p, m| if (m) dir.deleteFile(io, &p.name) catch {}; // ziglint-ignore: Z026 -- cache upkeep is best effort
    result.merged = @intCast(n_merge);
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
        .{ .key = .fromName("f"), .name = "t:f", .section = .text, .bytes = &.{0xc3}, .unwind = .frame_pointer },
    };
    const debug = [_]Atom.Debug{.{ .atom = 1, .file = "t.zig", .name = "f", .base_line = 3, .lines = &.{1} }};
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
        try t.expectEqual(1, try entry.decodeAtoms(.x86_64, &decoded, &decoded_debug));
        for (atoms, decoded) |e, a| try atoms_codec.expectEqualAtoms(e, a);
        try t.expectEqual(1, decoded_debug[0].atom);
        try atoms_codec.expectEqualDebug(&debug[0], &decoded_debug[0]);
        try t.expectEqualStrings("x", (try store.get(gpa, io, k2)).?.payload());
        try t.expectEqual(4, (try store.get(gpa, io, 8)).?.resultHash());
        try t.expectEqual(null, try store.get(gpa, io, 9));

        const Graph = struct {
            dep2: Hash,
            const Self = @This();
            pub fn resultHash(g: Self, key: Hash) ?Hash {
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
    var store_dir = try tmp.dir.openDir(io, "bs/store", .{ .iterate = true });
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

test "merges leave large packs alone, and the size limit evicts the least recently used" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const t = std.testing;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const big_payload = try gpa.alloc(u8, 64 << 10);
    defer gpa.free(big_payload);
    @memset(big_payload, 'b');
    // Key 5 in the oldest pack, then again in a large one; then small packs
    // until a commit merges. The merge takes the smallest, which include
    // the oldest pack and are newer than the large one as a group, so the
    // oldest pack's copy of 5 must not shadow the large pack's.
    for (0..max_packs + 1) |i| {
        var store: Store = try .open(gpa, io, tmp.dir);
        defer store.close(gpa, io);
        var batch: Batch = .{};
        defer batch.deinit(gpa);
        switch (i) {
            0 => _ = try batch.put(gpa, 5, .{ .src_hash = 0, .result_hash = 1 }),
            1 => _ = try batch.put(gpa, 5, .{ .src_hash = 0, .result_hash = 2, .payload = big_payload }),
            else => {},
        }
        // The oldest pack is the smallest.
        _ = try batch.put(gpa, 100 + i, .{ .src_hash = 0, .result_hash = i, .payload = if (i == 0) "" else big_payload[0..256] });
        _ = try store.commit(gpa, io, (&batch)[0..1], null);
        // Distinct `order`s.
        try io.sleep(.fromMilliseconds(2), .awake);
    }
    var store_dir = try tmp.dir.openDir(io, "bs/store", .{ .iterate = true });
    defer store_dir.close(io);
    try t.expectEqual(max_packs / 2, try countPacks(io, store_dir));
    var big_name: PackName = undefined;
    {
        var store: Store = try .open(gpa, io, tmp.dir);
        defer store.close(gpa, io);
        try t.expectEqual(2, (try store.get(gpa, io, 5)).?.resultHash());
        for (0..max_packs + 1) |i| try t.expectEqual(i, (try store.get(gpa, io, 100 + i)).?.resultHash());
        // The large pack was not rewritten: it still holds one entry
        // besides 5. The oldest pack was merged, without its 5.
        var big: ?*const PackFile = null;
        for (store.packs) |*p| if (big == null or p.size > big.?.size) {
            big = p;
        };
        try t.expectEqual(2, big.?.keys.len);
        big_name = big.?.name;
        for (store.packs) |*p| if (p != big) try t.expect(p.find(5) == null);
    }
    // Over the limit, the least recently used packs go first: here the
    // large one, after which the rest fit.
    const now = Io.Clock.real.now(io);
    try store_dir.setTimestamps(io, &big_name, .{ .modify_timestamp = .{ .new = now.addDuration(.fromNanoseconds(-std.time.ns_per_hour)) } });
    const r = try maintain(gpa, io, store_dir, .{ .trim = false, .now = now, .max_bytes = 64 << 10 });
    try t.expectEqual(1, r.evicted);
    try t.expectError(error.FileNotFound, store_dir.statFile(io, &big_name, .{}));
    {
        var store: Store = try .open(gpa, io, tmp.dir);
        defer store.close(gpa, io);
        try t.expectEqual(null, try store.get(gpa, io, 5));
        try t.expectEqual(0, (try store.get(gpa, io, 100)).?.resultHash());
    }
    // A pack in another format stays while it fits, and counts toward the
    // limit like any other.
    const other_name = "ffffffffffffffffffffffffffffffff" ++ pack_ext;
    const other_bytes = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(other_bytes);
    @memset(other_bytes, 'Z');
    try store_dir.writeFile(io, .{ .sub_path = other_name, .data = other_bytes });
    try store_dir.setTimestamps(io, other_name, .{ .modify_timestamp = .{ .new = now.addDuration(.fromNanoseconds(-std.time.ns_per_hour)) } });
    {
        var store: Store = try .open(gpa, io, tmp.dir);
        defer store.close(gpa, io);
        try t.expectEqual(1 << 20, store.other_bytes);
    }
    try t.expectEqual(0, (try maintain(gpa, io, store_dir, .{ .trim = false, .now = now, .max_bytes = 2 << 20 })).evicted);
    try t.expectEqual(1, (try maintain(gpa, io, store_dir, .{ .trim = false, .now = now, .max_bytes = 1 << 20 })).evicted);
    try t.expectError(error.FileNotFound, store_dir.statFile(io, other_name, .{}));
    {
        var store: Store = try .open(gpa, io, tmp.dir);
        defer store.close(gpa, io);
        try t.expectEqual(0, (try store.get(gpa, io, 100)).?.resultHash());
    }
    // The global cache's ZIR counts and goes with the packs, by mtime: an
    // hour-old file is evicted before the newer packs, and one unused for
    // `max_unused_ns` is trimmed. Its other files are not candidates.
    try tmp.dir.createDirPath(io, "bs/zir");
    var zd = try tmp.dir.openDir(io, "bs/zir", .{});
    defer zd.close(io);
    const zir_old = "0123456789abcdef0123456789abcdef";
    const zir_new = "fedcba9876543210fedcba9876543210";
    try zd.writeFile(io, .{ .sub_path = zir_old, .data = other_bytes });
    try zd.setTimestamps(io, zir_old, .{ .modify_timestamp = .{ .new = now.addDuration(.fromNanoseconds(-std.time.ns_per_hour)) } });
    try zd.writeFile(io, .{ .sub_path = zir_new, .data = "z" });
    try zd.writeFile(io, .{ .sub_path = "index", .data = other_bytes });
    try t.expectEqual(0, (try maintain(gpa, io, store_dir, .{ .trim = false, .now = now, .max_bytes = 2 << 20 })).evicted);
    try t.expectEqual(1, (try maintain(gpa, io, store_dir, .{ .trim = false, .now = now, .max_bytes = 1 << 20 })).evicted);
    try t.expectError(error.FileNotFound, zd.statFile(io, zir_old, .{}));
    _ = try zd.statFile(io, zir_new, .{});
    const later = now.addDuration(.fromNanoseconds(max_unused_ns + std.time.ns_per_s));
    _ = try maintain(gpa, io, store_dir, .{ .trim = true, .now = later });
    try t.expectError(error.FileNotFound, zd.statFile(io, zir_new, .{}));
    _ = try zd.statFile(io, "index", .{});
}

test "the store's limit holds for ZIR written by builds that commit nothing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const t = std.testing;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store_dir = try tmp.dir.createDirPathOpen(io, "bs/store", .{ .open_options = .{ .iterate = true } });
    defer store_dir.close(io);
    var zd = try tmp.dir.createDirPathOpen(io, "bs/zir", .{});
    defer zd.close(io);
    // No pack, so a commit's estimate sees nothing; 2 MiB of ZIR against a
    // 1.5 MiB limit, the older file written an hour ago.
    const bytes = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(bytes);
    @memset(bytes, 'Z');
    const now = Io.Clock.real.now(io);
    const zir_old = "0123456789abcdef0123456789abcdef";
    const zir_new = "fedcba9876543210fedcba9876543210";
    try zd.writeFile(io, .{ .sub_path = zir_old, .data = bytes });
    try zd.setTimestamps(io, zir_old, .{ .modify_timestamp = .{ .new = now.addDuration(.fromNanoseconds(-std.time.ns_per_hour)) } });
    try zd.writeFile(io, .{ .sub_path = zir_new, .data = bytes });
    // Due on the first build (no scan yet), not again within the interval.
    try t.expectEqual(1, maintainStale(gpa, io, store_dir, 3 << 19).?.evicted);
    try t.expectError(error.FileNotFound, zd.statFile(io, zir_old, .{}));
    _ = try zd.statFile(io, zir_new, .{});
    try zd.writeFile(io, .{ .sub_path = zir_old, .data = bytes });
    try t.expectEqual(null, maintainStale(gpa, io, store_dir, 3 << 19));
    try store_dir.setTimestamps(io, "scan", .{ .modify_timestamp = .{ .new = now.addDuration(.fromNanoseconds(-scan_interval_ns)) } });
    try t.expectEqual(1, maintainStale(gpa, io, store_dir, 3 << 19).?.evicted);
}

test "a pack written in place reads back like a committed batch" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const t = std.testing;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const keep = try tmp.dir.createDirPathOpen(io, "c", .{});
    defer keep.close(io);

    const atoms = [_]Atom{.{ .key = .fromName("f"), .name = "t:f", .section = .text, .bytes = &.{0xc3} }};
    const contents = [_]Contents{
        .{ .src_hash = 1, .result_hash = 2, .atoms = &atoms },
        .{ .src_hash = 3, .result_hash = 4, .deps = &.{.{ .key = 5, .result_hash = 6 }}, .payload = "xyz" },
    };
    const keys = [_]Key{ 11, 10 };
    var name: PackName = undefined;
    {
        var store: Store = try .open(gpa, io, tmp.dir);
        defer store.close(gpa, io);
        const reserved = store.reserveName(io);
        var w: PackWriter = undefined;
        try store.beginPack(io, keep, &w);
        defer w.deinit(io);
        var entries: [2]IndexEntry = undefined;
        var off: u64 = pack_header_len;
        // Written in reverse order, as threads may.
        var offsets: [2]u64 = undefined;
        for (contents, keys, &entries, &offsets) |c, k, *e, *o| {
            o.* = off;
            e.* = .init(k, off, entryLen(c));
            off += std.mem.alignForward(u64, entryLen(c), 16);
        }
        var i: usize = contents.len;
        while (i > 0) {
            i -= 1;
            const buf = try gpa.alloc(u8, entryLen(contents[i]));
            defer gpa.free(buf);
            encodeEntry(contents[i], buf);
            try w.writeAt(io, buf, offsets[i]);
        }
        name = try store.commitPack(gpa, io, &w, &entries, off, keep);
        try t.expectEqualSlices(u8, &reserved, &name);
    }
    // In the store, and kept in `keep`.
    _ = try keep.statFile(io, &name, .{});
    var store: Store = try .open(gpa, io, tmp.dir);
    defer store.close(gpa, io);
    const e0 = (try store.get(gpa, io, 11)).?;
    try t.expectEqual(2, e0.resultHash());
    var decoded: [1]Atom = undefined;
    var decoded_debug: [1]Atom.Debug = undefined;
    _ = try e0.decodeAtoms(.x86_64, &decoded, &decoded_debug);
    try atoms_codec.expectEqualAtoms(atoms[0], decoded[0]);
    const e1 = (try store.get(gpa, io, 10)).?;
    try t.expectEqual(4, e1.resultHash());
    try t.expectEqualStrings("xyz", e1.payload());
    try t.expectEqual(6, e1.deps()[0].result_hash);
}
