//! Serialized Atoms. A record is pointer-free and decodes in place: the
//! decoded `Atom`'s slices point into the record, so a relink from a mapped
//! pack copies nothing until the linker writes the output.
//!
//! Record layout, every record starting 16-byte aligned:
//!
//!   Header (64 bytes)
//!   targets      [targets_len]SymbolKey (16 bytes each)
//!   relocs       [relocs_len]Reloc (12 bytes each)
//!   DebugHeader  (16 bytes, if `has_debug`)
//!   bytes, name, debug file, debug name, debug lines
//!   zero padding to a multiple of 16
//!
//! The linkers take debug info apart from the atoms, as a slice of
//! `Atom.Debug` sorted by atom index. A record keeps a function's debug
//! info in its tail, so that the atom and its debug info are cached and
//! replaced together; `decode` returns them separately, and the caller
//! sets `Debug.atom` to the atom's index in the link.
//!
//! Records are host-endian; both of zap's targets are little-endian hosts.

const std = @import("std");
const builtin = @import("builtin");
const Atom = @import("../link/Atom.zig");

comptime {
    std.debug.assert(builtin.cpu.arch.endian() == .little);
}

pub const alignment = 16;

const Header = extern struct {
    key: Atom.SymbolKey,
    /// Length of the whole record, a multiple of `alignment`.
    len: u32,
    name_len: u32,
    bytes_len: u32,
    targets_len: u32,
    relocs_len: u32,
    zero_fill_lo: u32,
    zero_fill_hi: u32,
    /// `Atom.Section`, checked when decoding.
    section: u8,
    /// `std.mem.Alignment` as log2 bytes.
    alignment: u8,
    has_debug: bool,
    /// `Atom.Debug.Frame`, if `has_debug`.
    debug_frame: u8,
    unused: [16]u8 = @splat(0),
};

const DebugHeader = extern struct {
    base_line: u32,
    file_len: u32,
    name_len: u32,
    lines_len: u32,
};

comptime {
    std.debug.assert(@sizeOf(Header) == 64);
    std.debug.assert(@sizeOf(DebugHeader) == 16);
}

/// Walks a link's debug slice, sorted by `Debug.atom`, alongside its atoms
/// in index order.
pub const DebugCursor = struct {
    debug: []const Atom.Debug,
    next_index: usize = 0,

    /// The debug info of atom `atom_index`, if any. Calls must be in
    /// increasing `atom_index` order.
    pub fn of(c: *DebugCursor, atom_index: usize) ?*const Atom.Debug {
        if (c.next_index == c.debug.len or c.debug[c.next_index].atom != atom_index) return null;
        defer c.next_index += 1;
        return &c.debug[c.next_index];
    }
};

/// The length of the record of `atom` with `debug`.
pub fn encodedLen(atom: *const Atom, debug: ?*const Atom.Debug) usize {
    var n: usize = @sizeOf(Header) + 16 * atom.targets.len + @sizeOf(Atom.Reloc) * atom.relocs.len;
    n += atom.bytes.len + atom.name.len;
    if (debug) |d| n += @sizeOf(DebugHeader) + d.file.len + d.name.len + d.lines.len;
    return std.mem.alignForward(usize, n, alignment);
}

/// Writes the record of `atom` with `debug` to `out`, which is
/// `encodedLen(atom, debug)` bytes.
pub fn encode(atom: *const Atom, debug: ?*const Atom.Debug, out: []u8) void {
    std.debug.assert(out.len == encodedLen(atom, debug));
    const header: Header = .{
        .key = atom.key,
        .len = @intCast(out.len),
        .name_len = @intCast(atom.name.len),
        .bytes_len = @intCast(atom.bytes.len),
        .targets_len = @intCast(atom.targets.len),
        .relocs_len = @intCast(atom.relocs.len),
        .zero_fill_lo = @truncate(atom.zero_fill),
        .zero_fill_hi = @intCast(atom.zero_fill >> 32),
        .section = @backingInt(atom.section),
        .alignment = @backingInt(atom.alignment),
        .has_debug = debug != null,
        .debug_frame = if (debug) |d| @backingInt(d.frame) else 0,
    };
    var w: std.Io.Writer = .fixed(out);
    w.writeAll(std.mem.asBytes(&header)) catch unreachable;
    w.writeAll(@ptrCast(atom.targets)) catch unreachable;
    w.writeAll(@ptrCast(atom.relocs)) catch unreachable;
    if (debug) |d| w.writeAll(std.mem.asBytes(&DebugHeader{
        .base_line = d.base_line,
        .file_len = @intCast(d.file.len),
        .name_len = @intCast(d.name.len),
        .lines_len = @intCast(d.lines.len),
    })) catch unreachable;
    w.writeAll(atom.bytes) catch unreachable;
    w.writeAll(atom.name) catch unreachable;
    if (debug) |d| {
        w.writeAll(d.file) catch unreachable;
        w.writeAll(d.name) catch unreachable;
        w.writeAll(d.lines) catch unreachable;
    }
    @memset(out[w.end..], 0);
}

pub const DecodeError = error{CorruptAtom};

pub const Decoded = struct {
    atom: Atom,
    /// `atom` is left undefined: it is the atom's index in the link.
    debug: ?Atom.Debug,
    /// The record's length.
    len: usize,
};

/// Checks the record at the start of `bytes`, which must be
/// `alignment`-aligned, and returns its length, or null if it is
/// malformed: its lengths overrun it or `bytes`, or an enum field is out of
/// range. A record that passes can be read with `view`.
pub fn check(bytes: []align(alignment) const u8) ?usize {
    if (bytes.len < @sizeOf(Header)) return null;
    const h: *const Header = @ptrCast(bytes.ptr);
    if (h.len > bytes.len or h.len % alignment != 0) return null;
    if (std.enums.fromInt(Atom.Section, h.section) == null) return null;
    if (h.alignment > std.math.maxInt(std.math.Log2Int(usize))) return null;
    var end: usize = @sizeOf(Header) + 16 * @as(usize, h.targets_len) + @sizeOf(Atom.Reloc) * @as(usize, h.relocs_len);
    end += @as(usize, h.bytes_len) + h.name_len;
    if (h.has_debug) {
        if (std.enums.fromInt(Atom.Debug.Frame, h.debug_frame) == null) return null;
        const dh_off = end - h.bytes_len - h.name_len;
        if (dh_off + @sizeOf(DebugHeader) > h.len) return null;
        const dh = std.mem.bytesToValue(DebugHeader, bytes[dh_off..][0..@sizeOf(DebugHeader)]);
        end += @sizeOf(DebugHeader) + @as(usize, dh.file_len) + dh.name_len + dh.lines_len;
    }
    if (end > h.len) return null;
    return h.len;
}

/// The atom and debug info of a record that passed `check`, without
/// checking it again. The slices point into the record.
pub inline fn view(rec: [*]align(alignment) const u8) struct { atom: Atom, debug: ?Atom.Debug } {
    const h: *const Header = @ptrCast(rec);
    var off: usize = @sizeOf(Header);
    const targets: [*]const Atom.SymbolKey = @ptrCast(@alignCast(rec + off));
    off += 16 * @as(usize, h.targets_len);
    const relocs: [*]const Atom.Reloc = @ptrCast(@alignCast(rec + off));
    off += @sizeOf(Atom.Reloc) * @as(usize, h.relocs_len);
    var dh: DebugHeader = undefined;
    if (h.has_debug) {
        dh = std.mem.bytesToValue(DebugHeader, rec[off..][0..@sizeOf(DebugHeader)]);
        off += @sizeOf(DebugHeader);
    }
    const bytes = rec[off..][0..h.bytes_len];
    off += h.bytes_len;
    const name = rec[off..][0..h.name_len];
    off += h.name_len;
    const debug: ?Atom.Debug = if (h.has_debug) d: {
        const file = rec[off..][0..dh.file_len];
        off += dh.file_len;
        const debug_name = rec[off..][0..dh.name_len];
        off += dh.name_len;
        break :d .{
            .file = file,
            .name = debug_name,
            .base_line = dh.base_line,
            .lines = rec[off..][0..dh.lines_len],
            .frame = @fromBackingInt(@intCast(h.debug_frame)),
        };
    } else null;
    return .{ .atom = .{
        .key = h.key,
        .name = name,
        .section = @fromBackingInt(@intCast(h.section)),
        .alignment = @fromBackingInt(@intCast(h.alignment)),
        .bytes = bytes,
        .zero_fill = @as(u64, h.zero_fill_hi) << 32 | h.zero_fill_lo,
        .targets = targets[0..h.targets_len],
        .relocs = relocs[0..h.relocs_len],
    }, .debug = debug };
}

/// Decodes the record at the start of `bytes`, which must be
/// `alignment`-aligned. The slices point into `bytes`.
pub fn decode(bytes: []align(alignment) const u8) DecodeError!Decoded {
    const len = check(bytes) orelse return error.CorruptAtom;
    const v = view(bytes.ptr);
    return .{ .atom = v.atom, .debug = v.debug, .len = len };
}

pub fn expectEqualAtoms(expected: Atom, actual: Atom) !void {
    const t = std.testing;
    try t.expectEqual(expected.key, actual.key);
    try t.expectEqualStrings(expected.name, actual.name);
    try t.expectEqual(expected.section, actual.section);
    try t.expectEqual(expected.alignment, actual.alignment);
    try t.expectEqualSlices(u8, expected.bytes, actual.bytes);
    try t.expectEqual(expected.zero_fill, actual.zero_fill);
    try t.expectEqualSlices(Atom.SymbolKey, expected.targets, actual.targets);
    try t.expectEqualSlices(u8, @ptrCast(expected.relocs), @ptrCast(actual.relocs));
}

/// Compares debug info, ignoring `atom`.
pub fn expectEqualDebug(expected: ?*const Atom.Debug, actual: ?*const Atom.Debug) !void {
    const t = std.testing;
    try t.expectEqual(expected == null, actual == null);
    if (expected) |e| {
        const a = actual.?;
        try t.expectEqualStrings(e.file, a.file);
        try t.expectEqualStrings(e.name, a.name);
        try t.expectEqual(e.base_line, a.base_line);
        try t.expectEqualSlices(u8, e.lines, a.lines);
        try t.expectEqual(e.frame, a.frame);
    }
}

test "atoms round-trip through records" {
    const gpa = std.testing.allocator;
    const callee: Atom.SymbolKey = .fromName("callee");
    const atoms = [_]Atom{
        .{
            .key = .fromName("f"),
            .name = "test:f",
            .section = .text,
            .alignment = .@"16",
            .bytes = &.{ 0xe8, 0, 0, 0, 0, 0xc3 },
            .targets = &.{callee},
            .relocs = &.{.init(1, .x86_64_pc32, 0, -4)},
        },
        // More than 4 GiB of zero fill: the high half must survive.
        .{ .key = .fromName("big"), .name = "test:big", .section = .bss, .alignment = .@"8", .zero_fill = (5 << 32) + 3 },
        .{ .key = .fromName("g"), .name = "", .section = .text, .bytes = &.{0xc3} },
    };
    // Atoms 0 and 2 have debug info; the cursor must skip atom 1.
    const debug = [_]Atom.Debug{
        .{ .atom = 0, .file = "src/t.zig", .name = "f", .base_line = 41, .lines = &.{ 5, 0x13 }, .frame = .frame_pointer },
        .{ .atom = 2, .file = "src/u.zig", .name = "g", .base_line = 7, .lines = &.{0x14}, .frame = .none },
    };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var cursor: DebugCursor = .{ .debug = &debug };
    for (&atoms, 0..) |*a, i| {
        const d = cursor.of(i);
        const start = buf.items.len;
        try buf.appendNTimes(gpa, 0xaa, encodedLen(a, d));
        encode(a, d, buf.items[start..]);
    }
    const copy = try gpa.alignedAlloc(u8, .@"16", buf.items.len);
    defer gpa.free(copy);
    @memcpy(copy, buf.items);
    var off: usize = 0;
    cursor = .{ .debug = &debug };
    for (atoms, 0..) |expected, i| {
        const actual = try decode(@alignCast(copy[off..]));
        try expectEqualAtoms(expected, actual.atom);
        try expectEqualDebug(cursor.of(i), if (actual.debug) |*d| d else null);
        off += actual.len;
    }
    try std.testing.expectEqual(copy.len, off);
    // A truncated record is an error, not an out-of-bounds read.
    try std.testing.expectError(error.CorruptAtom, decode(copy[0 .. encodedLen(&atoms[0], &debug[0]) - 16]));
    // So is a bad section, alignment, or frame kind, or debug lengths that
    // overrun the record (atom 0's debug header is at 64 + 16 + 12).
    const len0 = encodedLen(&atoms[0], &debug[0]);
    try std.testing.expectEqual(len0, check(copy));
    for ([_]struct { usize, u8 }{ .{ 44, 0xff }, .{ 45, 64 }, .{ 47, 0xff }, .{ 92 + 12, 0xff } }) |m| {
        const saved = copy[m[0]];
        copy[m[0]] = m[1];
        try std.testing.expectEqual(null, check(copy));
        copy[m[0]] = saved;
    }
}
