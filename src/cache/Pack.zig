//! Every Atom one compilation last linked, in one append-only file, so a
//! relink reads one mapped file instead of an entry per unit. A build
//! appends the Atoms it regenerated (`append`) and links from the mapping
//! (`decodeAll`); which records are live is recorded in the manifest as
//! `AtomRef`s. Old records stay where they are, so a manifest written
//! before an append still describes the pack; when dead records outgrow
//! live ones, `compact` rewrites the pack with only the live records, in
//! link order, under a new id that the next manifest records.
//!
//! The caller holds the compilation's lock (`cache.lock`).
//!
//! File: `Header`, then atom records (`cache.atoms`), each 16-byte aligned.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const cache = @import("../cache.zig");
const atoms_codec = @import("atoms.zig");
const Atom = @import("../link/Atom.zig");
const Hash = cache.Hash;

const Pack = @This();

file: Io.File,
/// Random, new for each file; the manifest records which pack it refers to.
id: Hash,
/// File length: where the next record goes.
len: u64,
/// Maps `[0, len)`.
map: Io.File.MemoryMap,
/// Mappings replaced by appends, kept until `close` so atoms decoded from
/// them stay valid.
retired: std.ArrayList(Io.File.MemoryMap) = .empty,

/// Where a record is: 8 bytes, since a manifest holds one per Atom.
pub const AtomRef = extern struct {
    /// Offset in 16-byte units, so a pack can grow to 64 GiB.
    offset16: u32,
    len: u32,

    pub fn init(off: u64, len: u32) AtomRef {
        std.debug.assert(off % atoms_codec.alignment == 0);
        return .{ .offset16 = @intCast(off / atoms_codec.alignment), .len = len };
    }

    pub fn offset(r: AtomRef) u64 {
        return @as(u64, r.offset16) * atoms_codec.alignment;
    }
};

const magic = "ZAPPACK1".*;

const Header = extern struct {
    magic: [8]u8 = magic,
    unused: [8]u8 = @splat(0),
    id: Hash,
};

const sub_path = "pack";

/// Opens the pack in `dir`, or creates an empty one if there is none or it
/// is damaged.
pub fn open(io: Io, dir: Io.Dir) !Pack {
    const file = dir.openFile(io, sub_path, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => return create(io, dir),
        else => |e| return e,
    };
    errdefer file.close(io);
    var header: Header = undefined;
    const len = try file.length(io);
    if (len < @sizeOf(Header) or len % atoms_codec.alignment != 0 or
        try file.readPositionalAll(io, std.mem.asBytes(&header), 0) != @sizeOf(Header) or
        !std.mem.eql(u8, &header.magic, &magic))
    {
        file.close(io);
        return create(io, dir);
    }
    return .{ .file = file, .id = header.id, .len = len, .map = try cache.mapOpenFile(io, file, len, false) };
}

/// Replaces the pack in `dir` with an empty one with a new id.
pub fn create(io: Io, dir: Io.Dir) !Pack {
    var header: Header = .{ .id = undefined };
    io.random(std.mem.asBytes(&header.id));
    try cache.writeReplace(io, dir, sub_path, &.{std.mem.asBytes(&header)});
    const file = try dir.openFile(io, sub_path, .{ .mode = .read_write });
    errdefer file.close(io);
    return .{ .file = file, .id = header.id, .len = @sizeOf(Header), .map = try cache.mapOpenFile(io, file, @sizeOf(Header), false) };
}

pub fn close(p: *Pack, gpa: Allocator, io: Io) void {
    for (p.retired.items) |*m| m.destroy(io);
    p.retired.deinit(gpa);
    p.map.destroy(io);
    p.file.close(io);
}

/// Appends `atoms`, each with its entry in `debug` (sorted by `atom`, an
/// index into `atoms`) if it has one, with one write, and stores where each
/// went in `refs`. Append the build's new Atoms at once: each append maps
/// the file again.
pub fn append(p: *Pack, gpa: Allocator, io: Io, atoms: []const Atom, debug: []const Atom.Debug, refs: []AtomRef) !void {
    var total: usize = 0;
    var cursor: atoms_codec.DebugCursor = .{ .debug = debug };
    for (atoms, refs, 0..) |*a, *r, i| {
        const len = atoms_codec.encodedLen(a, cursor.of(i));
        r.* = .init(p.len + total, @intCast(len));
        total += len;
    }
    const buf = try gpa.alignedAlloc(u8, .@"16", total);
    defer gpa.free(buf);
    cursor = .{ .debug = debug };
    for (atoms, refs, 0..) |*a, r, i| atoms_codec.encode(a, cursor.of(i), buf[r.offset() - p.len ..][0..r.len]);
    try p.file.writePositionalAll(io, buf, p.len);
    try p.retired.ensureUnusedCapacity(gpa, 1);
    const map = try cache.mapOpenFile(io, p.file, p.len + total, false);
    p.retired.appendAssumeCapacity(p.map);
    p.map = map;
    p.len += total;
}

pub const DecodeError = atoms_codec.DecodeError;

/// Decodes the record at `ref`. Its slices point into the mapping.
pub fn decode(p: *const Pack, ref: AtomRef) DecodeError!atoms_codec.Decoded {
    const off = ref.offset();
    if (off < @sizeOf(Header) or off + ref.len > p.len) return error.CorruptAtom;
    const d = try atoms_codec.decode(@alignCast(p.map.memory[off..][0..ref.len]));
    if (d.len != ref.len) return error.CorruptAtom;
    return d;
}

/// Decodes the atoms at `refs` into `out`, ready to link, and appends
/// their debug info to `debug`, sorted by `atom`, an index into `out`.
/// Runs on one thread per CPU: writing the `Atom`s is most of the cost.
/// `gpa` must be thread-safe.
pub fn decodeAll(
    p: *const Pack,
    gpa: Allocator,
    io: Io,
    refs: []const AtomRef,
    out: []Atom,
    debug: *std.ArrayList(Atom.Debug),
) (DecodeError || Allocator.Error || Io.Cancelable)!void {
    const Chunk = struct {
        first: u32,
        refs: []const AtomRef,
        out: []Atom,
        debug: std.ArrayList(Atom.Debug) = .empty,
        err: ?(DecodeError || Allocator.Error) = null,

        fn decode(c: *@This(), pack: *const Pack, a: Allocator) void {
            c.decodeOrFail(pack, a) catch |e| {
                c.err = e;
            };
        }

        fn decodeOrFail(c: *@This(), pack: *const Pack, a: Allocator) !void {
            for (c.refs, c.out, c.first..) |r, *atom, i| {
                const d = try pack.decode(r);
                atom.* = d.atom;
                if (d.debug) |dbg| {
                    var e = dbg;
                    e.atom = @intCast(i);
                    try c.debug.append(a, e);
                }
            }
        }
    };
    const max_threads = 16;
    const n = @min(max_threads, std.Thread.getCpuCount() catch 1, @max(1, refs.len / 4096));
    var chunks: [max_threads]Chunk = undefined;
    for (chunks[0..n], 0..) |*c, i| {
        const lo = i * refs.len / n;
        const hi = (i + 1) * refs.len / n;
        c.* = .{ .first = @intCast(lo), .refs = refs[lo..hi], .out = out[lo..hi] };
    }
    defer for (chunks[0..n]) |*c| c.debug.deinit(gpa);
    var group: Io.Group = .init;
    for (chunks[1..n]) |*c| group.async(io, Chunk.decode, .{ c, p, gpa });
    chunks[0].decode(p, gpa);
    try group.await(io);
    var n_debug: usize = 0;
    for (chunks[0..n]) |*c| {
        if (c.err) |e| return e;
        n_debug += c.debug.items.len;
    }
    try debug.ensureUnusedCapacity(gpa, n_debug);
    for (chunks[0..n]) |*c| debug.appendSliceAssumeCapacity(c.debug.items);
}

/// Whether `compact` would at least halve the pack, given the bytes of
/// the records still referenced.
pub fn shouldCompact(p: *const Pack, live_bytes: u64) bool {
    return p.len - @sizeOf(Header) > 2 * live_bytes;
}

pub fn liveBytes(refs: []const AtomRef) u64 {
    var n: u64 = 0;
    for (refs) |r| n += r.len;
    return n;
}

/// Rewrites the pack with only the records at `refs`, in that order, under
/// a new id, and updates `refs`. Atoms decoded before stay valid until
/// `close`. The caller writes a manifest with the new refs and id next; a
/// manifest left with the old id is ignored, which costs a rebuild from the
/// global store but never a wrong link.
pub fn compact(p: *Pack, gpa: Allocator, io: Io, dir: Io.Dir, refs: []AtomRef) !void {
    var header: Header = .{ .id = undefined };
    io.random(std.mem.asBytes(&header.id));
    const buf = try gpa.alignedAlloc(u8, .@"16", @sizeOf(Header) + liveBytes(refs));
    defer gpa.free(buf);
    @memcpy(buf[0..@sizeOf(Header)], std.mem.asBytes(&header));
    var off: u64 = @sizeOf(Header);
    for (refs) |*r| {
        if (r.offset() + r.len > p.len) return error.CorruptAtom;
        @memcpy(buf[off..][0..r.len], p.map.memory[r.offset()..][0..r.len]);
        r.* = .init(off, r.len);
        off += r.len;
    }
    try cache.writeReplace(io, dir, sub_path, &.{buf});
    const file = try dir.openFile(io, sub_path, .{ .mode = .read_write });
    errdefer file.close(io);
    try p.retired.ensureUnusedCapacity(gpa, 1);
    const map = try cache.mapOpenFile(io, file, buf.len, false);
    p.retired.appendAssumeCapacity(p.map);
    p.file.close(io);
    p.* = .{ .file = file, .id = header.id, .len = buf.len, .map = map, .retired = p.retired };
}

test "append, reopen, decode, and compact" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const atoms = [_]Atom{
        .{ .key = .fromName("a"), .name = "t:a", .section = .text, .bytes = &.{ 0x90, 0xc3 } },
        .{ .key = .fromName("b"), .name = "t:b", .section = .data, .alignment = .@"8", .bytes = "12345678" },
        .{ .key = .fromName("c"), .name = "t:c", .section = .bss, .zero_fill = 64 },
    };
    const debug = [_]Atom.Debug{.{ .atom = 0, .file = "t.zig", .name = "a", .base_line = 9, .lines = &.{0x13}, .frame = .frame_pointer }};
    var refs: [3]AtomRef = undefined;
    var id: Hash = undefined;
    {
        var p: Pack = try .open(io, tmp.dir);
        defer p.close(gpa, io);
        id = p.id;
        try p.append(gpa, io, atoms[0..2], &debug, refs[0..2]);
        const a = (try p.decode(refs[0])).atom;
        try p.append(gpa, io, atoms[2..], &.{}, refs[2..]);
        // Decoded before the second append, still valid.
        try atoms_codec.expectEqualAtoms(atoms[0], a);
    }
    var p: Pack = try .open(io, tmp.dir);
    defer p.close(gpa, io);
    try std.testing.expectEqual(id, p.id);
    var decoded: [3]Atom = undefined;
    var decoded_debug: std.ArrayList(Atom.Debug) = .empty;
    defer decoded_debug.deinit(gpa);
    // Atom a comes second here, so its debug entry must name index 1.
    const order = [_]AtomRef{ refs[1], refs[0], refs[2] };
    try p.decodeAll(gpa, io, &order, &decoded, &decoded_debug);
    for ([_]usize{ 1, 0, 2 }, decoded) |e, a| try atoms_codec.expectEqualAtoms(atoms[e], a);
    try std.testing.expectEqual(1, decoded_debug.items.len);
    try std.testing.expectEqual(1, decoded_debug.items[0].atom);
    try atoms_codec.expectEqualDebug(&debug[0], &decoded_debug.items[0]);
    try std.testing.expectError(error.CorruptAtom, p.decode(.init(p.len, 64)));

    // Only b and a are live, in that order.
    var live = [_]AtomRef{ refs[1], refs[0] };
    try std.testing.expect(!p.shouldCompact(liveBytes(&live)));
    try std.testing.expect(p.shouldCompact(liveBytes(live[0..1])));
    try p.compact(gpa, io, tmp.dir, &live);
    try std.testing.expect(p.id != id);
    try std.testing.expectEqual(32 + liveBytes(&live), p.len);
    try atoms_codec.expectEqualAtoms(atoms[1], (try p.decode(live[0])).atom);
    const a = try p.decode(live[1]);
    try atoms_codec.expectEqualAtoms(atoms[0], a.atom);
    try atoms_codec.expectEqualDebug(&debug[0], &a.debug.?);
    // Decoded before compaction, still valid.
    try atoms_codec.expectEqualAtoms(atoms[2], decoded[2]);
}
