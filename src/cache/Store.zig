//! The global store: one file per cache entry, shared by every project on
//! the machine, like Go's build cache. An entry is a unit's result (an
//! opaque payload for now, serialized by Sema later), the Atoms generated
//! from it, and the dependencies it was computed from with the result hash
//! each had then. Entries are named by their key and never change: a new
//! result gets a new key, because the key covers everything the result is
//! computed from except the dependencies, and dependencies are checked
//! against the recorded result hashes on use (`Entry.isValid`).
//!
//! Concurrent builds need no locks. A writer links a finished file into
//! place; a second writer of the same key finds it there and drops its
//! copy. Readers read or map files that never change. Entries unused for 5 days are
//! deleted by `trimIfDue`; `get` refreshes an entry's mtime at most once an
//! hour so that it records use without a write per lookup.
//!
//! File: `Header`, `deps_len` `Dep`s, `atoms_len` atom records
//! (`cache.atoms`, `atoms_bytes` long), then `payload_len` payload bytes.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const cache = @import("../cache.zig");
const atoms_codec = @import("atoms.zig");
const Atom = @import("../link/Atom.zig");
const Hash = cache.Hash;

const Store = @This();

/// `<global cache>/zap/units`.
dir: Io.Dir,

pub const Key = Hash;

/// A dependency of an entry: what it read, and the result hash that had.
pub const Dep = extern struct {
    key: Hash,
    result_hash: Hash,
};

const magic = "ZAPUNT01".*;

const Header = extern struct {
    magic: [8]u8 = magic,
    deps_len: u32,
    atoms_len: u32,
    atoms_bytes: u64,
    payload_len: u64,
    src_hash: Hash,
    result_hash: Hash,
};

comptime {
    std.debug.assert(@sizeOf(Header) == 64);
    std.debug.assert(@sizeOf(Dep) == 32);
}

pub const used_refresh_ns = std.time.ns_per_hour;
pub const max_unused_ns = 5 * std.time.ns_per_day;
const trim_interval_ns = std.time.ns_per_day;

pub fn open(io: Io, global_cache: Io.Dir) !Store {
    return .{ .dir = try global_cache.createDirPathOpen(io, "zap/units", .{}) };
}

pub fn close(store: *Store, io: Io) void {
    store.dir.close(io);
}

/// `<2 hex>/<32 hex>`: 256 subdirectories keep directories small.
fn entryPath(key: Key, buf: *[35]u8) []const u8 {
    const hex = std.fmt.hex(key);
    buf[0..2].* = hex[0..2].*;
    buf[2] = '/';
    buf[3..].* = hex;
    return buf;
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

/// Stores an entry under `key`, unless one is already there.
pub fn put(store: *const Store, gpa: Allocator, io: Io, key: Key, contents: Contents) !void {
    var atoms_len: usize = 0;
    var cursor: atoms_codec.DebugCursor = .{ .debug = contents.debug };
    for (contents.atoms, 0..) |*a, i| atoms_len += atoms_codec.encodedLen(a, cursor.of(i));
    const atom_bytes = try gpa.alignedAlloc(u8, .@"16", atoms_len);
    defer gpa.free(atom_bytes);
    var off: usize = 0;
    cursor = .{ .debug = contents.debug };
    for (contents.atoms, 0..) |*a, i| {
        const d = cursor.of(i);
        const len = atoms_codec.encodedLen(a, d);
        atoms_codec.encode(a, d, atom_bytes[off..][0..len]);
        off += len;
    }
    const header: Header = .{
        .deps_len = @intCast(contents.deps.len),
        .atoms_len = @intCast(contents.atoms.len),
        .atoms_bytes = atom_bytes.len,
        .payload_len = contents.payload.len,
        .src_hash = contents.src_hash,
        .result_hash = contents.result_hash,
    };
    var buf: [35]u8 = undefined;
    const path = entryPath(key, &buf);
    // The fan-out directory almost always exists; create it only when needed.
    var af = store.dir.createFileAtomic(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => try store.dir.createFileAtomic(io, path, .{ .make_path = true }),
        else => |e| return e,
    };
    defer af.deinit(io);
    try cache.writeParts(io, af.file, &.{ std.mem.asBytes(&header), @ptrCast(contents.deps), atom_bytes, contents.payload });
    af.link(io) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |e| return e,
    };
}

/// An entry read into memory, or mapped if it is large. Its slices, and
/// the atoms it decodes, stay valid until `close`.
pub const Entry = struct {
    bytes: []align(16) const u8,
    map: ?Io.File.MemoryMap,

    /// Entries up to this size are read rather than mapped: mapping,
    /// faulting, and unmapping cost more than copying a few pages.
    const max_read = 64 * 1024;

    fn header(e: *const Entry) *const Header {
        return @ptrCast(e.bytes.ptr);
    }

    pub fn srcHash(e: *const Entry) Hash {
        return e.header().src_hash;
    }

    pub fn resultHash(e: *const Entry) Hash {
        return e.header().result_hash;
    }

    pub fn deps(e: *const Entry) []const Dep {
        const h = e.header();
        return @ptrCast(@alignCast(e.bytes[@sizeOf(Header)..][0 .. @sizeOf(Dep) * h.deps_len]));
    }

    fn atomBytes(e: *const Entry) []align(16) const u8 {
        const h = e.header();
        return @alignCast(e.bytes[@sizeOf(Header) + @sizeOf(Dep) * h.deps_len ..][0..h.atoms_bytes]);
    }

    pub fn payload(e: *const Entry) []const u8 {
        const h = e.header();
        return e.bytes[e.bytes.len - h.payload_len ..];
    }

    pub fn atomCount(e: *const Entry) u32 {
        return e.header().atoms_len;
    }

    /// Decodes the entry's atoms into `out`, which has `atomCount()` items,
    /// and their debug info into the start of `debug`, which has as many;
    /// `Debug.atom` is the index in `out`. Returns how many have debug info.
    pub fn decodeAtoms(e: *const Entry, out: []Atom, debug: []Atom.Debug) atoms_codec.DecodeError!usize {
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
    pub fn isValid(e: *const Entry, src_hash: Hash, context: anytype) bool {
        if (e.srcHash() != src_hash) return false;
        for (e.deps()) |d| {
            if (context.resultHash(d.key) != d.result_hash) return false;
        }
        return true;
    }

    pub fn close(e: *Entry, gpa: Allocator, io: Io) void {
        if (e.map) |*m| m.destroy(io) else gpa.free(e.bytes);
    }
};

/// Maps the entry for `key`, or returns null if there is none (or it is
/// damaged, in which case the caller recomputes and `put` cannot replace
/// it; `trimIfDue` eventually deletes it).
pub fn get(store: *const Store, gpa: Allocator, io: Io, key: Key) !?Entry {
    var buf: [35]u8 = undefined;
    const f = store.dir.openFile(io, entryPath(key, &buf), .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    defer f.close(io);
    const stat = try f.stat(io);
    if (stat.size < @sizeOf(Header)) return null;
    var entry: Entry = if (stat.size <= Entry.max_read) read: {
        const bytes = try gpa.alignedAlloc(u8, .@"16", stat.size);
        errdefer gpa.free(bytes);
        if (try f.readPositionalAll(io, bytes, 0) != bytes.len) {
            gpa.free(bytes);
            return null;
        }
        break :read .{ .bytes = bytes, .map = null };
    } else map: {
        const map = try cache.mapOpenFile(io, f, stat.size, false);
        break :map .{ .bytes = map.memory, .map = map };
    };
    errdefer entry.close(gpa, io);
    const h = entry.header();
    if (!std.mem.eql(u8, &h.magic, &magic) or
        @sizeOf(Header) + @sizeOf(Dep) * @as(u64, h.deps_len) + h.atoms_bytes + h.payload_len != stat.size)
    {
        entry.close(gpa, io);
        return null;
    }
    const now = Io.Clock.real.now(io);
    if (stat.mtime.durationTo(now).toNanoseconds() > used_refresh_ns) f.setTimestampsNow(io) catch {};
    return entry;
}

/// Deletes entries unused for `max_unused_ns`, at most once a day, as
/// recorded by the mtime of `units/trim`. Returns how many it deleted.
pub fn trimIfDue(store: *const Store, io: Io) !u32 {
    const now = Io.Clock.real.now(io);
    if (store.dir.statFile(io, "trim", .{})) |stat| {
        if (stat.mtime.durationTo(now).toNanoseconds() < trim_interval_ns) return 0;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    }
    try store.dir.writeFile(io, .{ .sub_path = "trim", .data = "" });
    return store.trim(io, now.subDuration(.fromNanoseconds(max_unused_ns)));
}

/// Deletes entries whose mtime is before `cutoff`.
pub fn trim(store: *const Store, io: Io, cutoff: Io.Timestamp) !u32 {
    var deleted: u32 = 0;
    for (0..256) |i| {
        const name = std.fmt.hex(@as(u8, @intCast(i)));
        var sub = store.dir.openDir(io, &name, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |e| return e,
        };
        defer sub.close(io);
        var it = sub.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            const stat = sub.statFile(io, entry.name, .{}) catch continue;
            if (stat.mtime.compare(.lt, cutoff)) {
                sub.deleteFile(io, entry.name) catch continue;
                deleted += 1;
            }
        }
    }
    return deleted;
}

test "entries round-trip, are checked against their dependencies, and are trimmed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store: Store = try .open(io, tmp.dir);
    defer store.close(io);

    const atoms = [_]Atom{
        .{ .key = .fromName("c"), .name = "t:c", .section = .rodata, .alignment = .@"8", .bytes = "abcdefgh" },
        .{ .key = .fromName("f"), .name = "t:f", .section = .text, .bytes = &.{0xc3} },
    };
    const debug = [_]Atom.Debug{.{ .atom = 1, .file = "t.zig", .name = "f", .base_line = 3, .lines = &.{1}, .frame = .frame_pointer }};
    const deps = [_]Dep{ .{ .key = 1, .result_hash = 10 }, .{ .key = 2, .result_hash = 20 } };
    try std.testing.expectEqual(null, try store.get(gpa, io, 7));
    try store.put(gpa, io, 7, .{ .src_hash = 99, .result_hash = 100, .deps = &deps, .atoms = &atoms, .debug = &debug, .payload = "result" });
    // A second writer of the same key keeps the first file.
    try store.put(gpa, io, 7, .{ .src_hash = 99, .result_hash = 100, .deps = &deps, .atoms = &atoms, .debug = &debug, .payload = "result" });

    var entry = (try store.get(gpa, io, 7)).?;
    defer entry.close(gpa, io);
    try std.testing.expectEqual(100, entry.resultHash());
    try std.testing.expectEqualSlices(u8, @ptrCast(&deps), @ptrCast(entry.deps()));
    try std.testing.expectEqualStrings("result", entry.payload());
    var decoded: [2]Atom = undefined;
    var decoded_debug: [2]Atom.Debug = undefined;
    try std.testing.expectEqual(2, entry.atomCount());
    try std.testing.expectEqual(1, try entry.decodeAtoms(&decoded, &decoded_debug));
    for (atoms, decoded) |e, a| try atoms_codec.expectEqualAtoms(e, a);
    try std.testing.expectEqual(1, decoded_debug[0].atom);
    try atoms_codec.expectEqualDebug(&debug[0], &decoded_debug[0]);

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
    try std.testing.expect(entry.isValid(99, Graph{ .dep2 = 20 }));
    try std.testing.expect(!entry.isValid(98, Graph{ .dep2 = 20 }));
    try std.testing.expect(!entry.isValid(99, Graph{ .dep2 = 21 }));

    try std.testing.expectEqual(0, try store.trim(io, .fromNanoseconds(0)));
    try std.testing.expectEqual(1, try store.trim(io, Io.Clock.real.now(io).addDuration(.fromNanoseconds(std.time.ns_per_s))));
    try std.testing.expectEqual(null, try store.get(gpa, io, 7));
}
