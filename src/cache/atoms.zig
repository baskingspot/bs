//! Serialized Atoms. A record is pointer-free and decodes in place: the
//! decoded `Atom`'s slices point into the record, so a relink from a mapped
//! pack copies nothing until the linker writes the output.
//!
//! Record layout, every record starting 16-byte aligned:
//!
//!   Header (64 bytes)
//!   targets      [targets_len]SymbolKey (16 bytes each)
//!   relocs       [relocs_len]Reloc (12 bytes each)
//!   DebugHeader  (40 bytes, if `has_debug`)
//!   bytes, name (always empty: the manifest keeps symbol names,
//!   `Manifest.atom_names`, so that a name can change without its record)
//!   if `has_debug`: file, name, lines, unit, files, inline names;
//!   then, aligned, patches (u32), inlines (`Atom.Debug.Inline`), and
//!   inline callees (SymbolKey, 16-byte aligned)
//!   zero padding to a multiple of 16
//!
//! The linkers take debug info apart from the atoms, as a slice of
//! `Atom.Debug` sorted by atom index. A record keeps a function's debug
//! info in its tail, so that the atom and its debug info are cached and
//! replaced together; `decode` returns them separately, and the caller
//! sets `Debug.atom` to the atom's index in the link.
//!
//! Records are host-endian; both of bs's targets are little-endian hosts.

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
    /// `Atom.unwind`, for every atom: its kind (`Atom.Unwind.Kind`, checked
    /// when decoding), saved registers, epilogue, and probes.
    unwind_kind: u8,
    unwind_saved: u16,
    unwind_epilogue: u16,
    unwind_probes: u8,
    unused: [11]u8 = @splat(0),
};

const DebugHeader = extern struct {
    base_line: u32,
    file_len: u32,
    name_len: u32,
    lines_len: u32,
    unit_len: u32,
    files_len: u32,
    inline_names_len: u32,
    /// Counts of elements: patches, and inlines (and inline callees).
    patches_len: u32,
    inlines_len: u32,
    unused: u32 = 0,
};

comptime {
    std.debug.assert(@sizeOf(Header) == 64);
    std.debug.assert(@sizeOf(DebugHeader) == 40);
    std.debug.assert(@alignOf(Atom.Debug.Inline) == 4);
}

/// Where a record's aligned debug runs start, given `off`, the offset in
/// the record just past the inline names.
const DebugRuns = struct {
    patches: usize,
    inlines: usize,
    callees: usize,
    end: usize,

    fn at(off: usize, dh: DebugHeader) DebugRuns {
        const patches = std.mem.alignForward(usize, off, 4);
        const inlines = patches + 4 * @as(usize, dh.patches_len);
        const callees = std.mem.alignForward(usize, inlines + @sizeOf(Atom.Debug.Inline) * @as(usize, dh.inlines_len), 16);
        return .{ .patches = patches, .inlines = inlines, .callees = callees, .end = callees + 16 * @as(usize, dh.inlines_len) };
    }
};

fn debugHeader(d: *const Atom.Debug) DebugHeader {
    std.debug.assert(d.inline_callees.len == d.inlines.len);
    return .{
        .base_line = d.base_line,
        .file_len = @intCast(d.file.len),
        .name_len = @intCast(d.name.len),
        .lines_len = @intCast(d.lines.len),
        .unit_len = @intCast(d.unit.len),
        .files_len = @intCast(d.files.len),
        .inline_names_len = @intCast(d.inline_names.len),
        .patches_len = @intCast(d.patches.len),
        .inlines_len = @intCast(d.inlines.len),
    };
}

/// The bytes of the debug strings: file, name, lines, unit, files, and
/// inline names.
fn debugBytesLen(dh: DebugHeader) usize {
    return @as(usize, dh.file_len) + dh.name_len + dh.lines_len + dh.unit_len + dh.files_len + dh.inline_names_len;
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
    n += atom.bytes.len;
    if (debug) |d| {
        const dh = debugHeader(d);
        n = DebugRuns.at(n + @sizeOf(DebugHeader) + debugBytesLen(dh), dh).end;
    }
    return std.mem.alignForward(usize, n, alignment);
}

/// Writes the record of `atom` with `debug` to `out`, which is
/// `encodedLen(atom, debug)` bytes. Not its name: a decoded atom's is
/// empty.
pub fn encode(atom: *const Atom, debug: ?*const Atom.Debug, out: []u8) void {
    std.debug.assert(out.len == encodedLen(atom, debug));
    const header: Header = .{
        .key = atom.key,
        .len = @intCast(out.len),
        .name_len = 0,
        .bytes_len = @intCast(atom.bytes.len),
        .targets_len = @intCast(atom.targets.len),
        .relocs_len = @intCast(atom.relocs.len),
        .zero_fill_lo = @truncate(atom.zero_fill),
        .zero_fill_hi = @intCast(atom.zero_fill >> 32),
        .section = @backingInt(atom.section),
        .alignment = @backingInt(atom.alignment),
        .has_debug = debug != null,
        .unwind_kind = @backingInt(atom.unwind.kind),
        .unwind_saved = atom.unwind.saved,
        .unwind_epilogue = atom.unwind.epilogue,
        .unwind_probes = atom.unwind.probes,
    };
    var w: std.Io.Writer = .fixed(out);
    w.writeAll(std.mem.asBytes(&header)) catch unreachable;
    w.writeAll(@ptrCast(atom.targets)) catch unreachable;
    w.writeAll(@ptrCast(atom.relocs)) catch unreachable;
    if (debug) |d| w.writeAll(std.mem.asBytes(&debugHeader(d))) catch unreachable;
    w.writeAll(atom.bytes) catch unreachable;
    if (debug) |d| {
        for ([_][]const u8{ d.file, d.name, d.lines, d.unit, d.files, d.inline_names }) |bytes| w.writeAll(bytes) catch unreachable;
        const runs = DebugRuns.at(w.end, debugHeader(d));
        w.splatByteAll(0, runs.patches - w.end) catch unreachable;
        w.writeAll(@ptrCast(d.patches)) catch unreachable;
        w.writeAll(@ptrCast(d.inlines)) catch unreachable;
        w.splatByteAll(0, runs.callees - w.end) catch unreachable;
        w.writeAll(@ptrCast(d.inline_callees)) catch unreachable;
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
/// malformed: its lengths overrun it or `bytes`, an enum field is out of
/// range, or its unwind record is not one `arch` can describe. A record
/// that passes can be read with `view`.
pub fn check(bytes: []align(alignment) const u8, arch: Atom.Unwind.Arch) ?usize {
    if (bytes.len < @sizeOf(Header)) return null;
    const h: *const Header = @ptrCast(bytes.ptr);
    if (h.len > bytes.len or h.len % alignment != 0) return null;
    if (std.enums.fromInt(Atom.Section, h.section) == null) return null;
    if (h.alignment > std.math.maxInt(std.math.Log2Int(usize))) return null;
    const kind = std.enums.fromInt(Atom.Unwind.Kind, h.unwind_kind) orelse return null;
    if (!Atom.Unwind.valid(.{ .kind = kind, .epilogue = h.unwind_epilogue, .probes = h.unwind_probes, .saved = h.unwind_saved }, arch)) return null;
    var end: usize = @sizeOf(Header) + 16 * @as(usize, h.targets_len) + @sizeOf(Atom.Reloc) * @as(usize, h.relocs_len);
    end += @as(usize, h.bytes_len) + h.name_len;
    if (h.has_debug) {
        const dh_off = end - h.bytes_len - h.name_len;
        if (dh_off + @sizeOf(DebugHeader) > h.len) return null;
        const dh = std.mem.bytesToValue(DebugHeader, bytes[dh_off..][0..@sizeOf(DebugHeader)]);
        end = DebugRuns.at(end + @sizeOf(DebugHeader) + debugBytesLen(dh), dh).end;
    }
    if (end > h.len) return null;
    if (h.has_debug) {
        const v = view(bytes.ptr);
        if (!debugValid(v.atom.bytes.len, &v.debug.?)) return null;
    }
    return h.len;
}

/// Whether debug info whose runs are in bounds of its record is also
/// consistent, so that the linker reads only within them: each inline
/// call's name, file, parent (preorder), and code range within an atom of
/// `atom_len` bytes, and each patch, ascending, a whole `set_file` or
/// `advance_line` opcode within `lines` (see `LineProgram.switchTo`).
fn debugValid(atom_len: usize, d: *const Atom.Debug) bool {
    // 0-terminated, nonempty paths.
    if (d.files.len != 0 and (d.files[0] == 0 or d.files[d.files.len - 1] != 0 or std.mem.find(u8, d.files, "\x00\x00") != null)) return false;
    const files = std.mem.countScalar(u8, d.files, 0);
    for (d.inlines, 0..) |inl, i| {
        if (@as(u64, inl.name_off) + inl.name_len > d.inline_names.len) return false;
        if (inl.file > files) return false;
        if (inl.parent != Atom.Debug.Inline.none and inl.parent >= i) return false;
        if (inl.low > inl.high or inl.high > atom_len) return false;
    }
    var next: u64 = 0;
    for (d.patches) |off| {
        if (off < next or off >= d.lines.len) return false;
        const width: u64 = switch (d.lines[off]) {
            std.dwarf.LNS.set_file => 1 + 3,
            std.dwarf.LNS.advance_line => 1 + 5,
            else => return false,
        };
        next = @as(u64, off) + width;
        if (next > d.lines.len) return false;
    }
    return true;
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
        const lines = rec[off..][0..dh.lines_len];
        off += dh.lines_len;
        const unit = rec[off..][0..dh.unit_len];
        off += dh.unit_len;
        const files = rec[off..][0..dh.files_len];
        off += dh.files_len;
        const inline_names = rec[off..][0..dh.inline_names_len];
        off += dh.inline_names_len;
        const runs = DebugRuns.at(off, dh);
        const patches: [*]const u32 = @ptrCast(@alignCast(rec + runs.patches));
        const inlines: [*]const Atom.Debug.Inline = @ptrCast(@alignCast(rec + runs.inlines));
        const callees: [*]const Atom.SymbolKey = @ptrCast(@alignCast(rec + runs.callees));
        break :d .{
            .file = file,
            .name = debug_name,
            .base_line = dh.base_line,
            .lines = lines,
            .unit = unit,
            .files = files,
            .inlines = inlines[0..dh.inlines_len],
            .inline_names = inline_names,
            .inline_callees = callees[0..dh.inlines_len],
            .patches = patches[0..dh.patches_len],
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
        .unwind = .{ .kind = @fromBackingInt(h.unwind_kind), .epilogue = h.unwind_epilogue, .probes = h.unwind_probes, .saved = h.unwind_saved },
    }, .debug = debug };
}

/// Decodes the record at the start of `bytes`, which must be
/// `alignment`-aligned, with `arch`'s unwind records. The slices point
/// into `bytes`.
pub fn decode(bytes: []align(alignment) const u8, arch: Atom.Unwind.Arch) DecodeError!Decoded {
    const len = check(bytes, arch) orelse return error.CorruptAtom;
    const v = view(bytes.ptr);
    return .{ .atom = v.atom, .debug = v.debug, .len = len };
}

/// Compares atoms, ignoring the name, which records do not keep.
pub fn expectEqualAtoms(expected: Atom, actual: Atom) !void {
    const t = std.testing;
    try t.expectEqual(expected.key, actual.key);
    try t.expectEqual(expected.section, actual.section);
    try t.expectEqual(expected.alignment, actual.alignment);
    try t.expectEqualSlices(u8, expected.bytes, actual.bytes);
    try t.expectEqual(expected.zero_fill, actual.zero_fill);
    try t.expectEqualSlices(Atom.SymbolKey, expected.targets, actual.targets);
    try t.expectEqualSlices(u8, @ptrCast(expected.relocs), @ptrCast(actual.relocs));
    try t.expectEqual(expected.unwind, actual.unwind);
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
        try t.expectEqualStrings(e.unit, a.unit);
        try t.expectEqualSlices(u8, e.files, a.files);
        try t.expectEqualSlices(u8, @ptrCast(e.inlines), @ptrCast(a.inlines));
        try t.expectEqualSlices(u8, e.inline_names, a.inline_names);
        try t.expectEqualSlices(Atom.SymbolKey, e.inline_callees, a.inline_callees);
        try t.expectEqualSlices(u32, e.patches, a.patches);
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
            .unwind = .{ .kind = .frame_pointer, .epilogue = 1, .saved = 0x13 },
        },
        // More than 4 GiB of zero fill: the high half must survive.
        .{ .key = .fromName("big"), .name = "test:big", .section = .bss, .alignment = .@"8", .zero_fill = (5 << 32) + 3 },
        .{ .key = .fromName("g"), .name = "", .section = .text, .bytes = &.{0xc3} },
    };
    // Atoms 0 and 2 have debug info; the cursor must skip atom 1.
    const debug = [_]Atom.Debug{
        .{
            .atom = 0,
            .file = "src/t.zig",
            .name = "f",
            .base_line = 41,
            .lines = &.{ 5, 0x13, 0x04, 0x81, 0x80, 0x00, 0x03, 0x81, 0x80, 0x80, 0x80, 0x00 },
            .unit = "src/main.zig",
            .files = "lib/std/start.zig\x00",
            .inlines = &.{.{ .name_off = 0, .name_len = 8, .file = 1, .base_line = 600, .call_line = 2, .call_column = 4, .low = 1, .high = 5, .parent = Atom.Debug.Inline.none }},
            .inline_names = "callMain",
            .inline_callees = &.{.fromName("std.start.callMain")},
            .patches = &.{ 2, 6 },
        },
        .{ .atom = 2, .file = "src/u.zig", .name = "g", .base_line = 7, .lines = &.{0x14} },
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
        const actual = try decode(@alignCast(copy[off..]), .x86_64);
        try expectEqualAtoms(expected, actual.atom);
        try std.testing.expectEqualStrings("", actual.atom.name);
        try expectEqualDebug(cursor.of(i), if (actual.debug) |*d| d else null);
        off += actual.len;
    }
    try std.testing.expectEqual(copy.len, off);
    // A truncated record is an error, not an out-of-bounds read.
    try std.testing.expectError(error.CorruptAtom, decode(copy[0 .. encodedLen(&atoms[0], &debug[0]) - 16], .x86_64));
    // So is a bad section, alignment, unwind kind, probes not after the
    // epilogue's `ret`, saved registers the architecture does not have or
    // with no frame pointer, or debug
    // lengths that overrun the record (atom 0's debug header is at 64 +
    // 16 + 12).
    const len0 = encodedLen(&atoms[0], &debug[0]);
    try std.testing.expectEqual(len0, check(copy, .x86_64));
    for ([_]struct { usize, u8 }{ .{ 44, 0xff }, .{ 45, 64 }, .{ 47, 3 }, .{ 47, 0 }, .{ 48, 0x33 }, .{ 49, 0x01 }, .{ 52, 2 }, .{ 92 + 12, 0xff } }) |m| {
        const saved = copy[m[0]];
        copy[m[0]] = m[1];
        try std.testing.expectEqual(null, check(copy, .x86_64));
        copy[m[0]] = saved;
    }
    // d8/d9 is aarch64's.
    copy[49] = 0x01;
    try std.testing.expectEqual(len0, check(copy, .aarch64));
}

test "check rejects inconsistent debug runs" {
    const good: Atom.Debug = .{
        .file = "t.zig",
        .name = "f",
        .base_line = 1,
        .lines = &.{ 0x04, 0x81, 0x80, 0x00, 0x03, 0x81, 0x80, 0x80, 0x80, 0x00, 0x13 },
        .files = "u.zig\x00",
        .inlines = &.{
            .{ .name_off = 0, .name_len = 1, .file = 1, .base_line = 3, .call_line = 0, .call_column = 0, .low = 0, .high = 4, .parent = Atom.Debug.Inline.none },
            .{ .name_off = 1, .name_len = 1, .file = 0, .base_line = 5, .call_line = 0, .call_column = 0, .low = 1, .high = 2, .parent = 0 },
        },
        .inline_names = "gh",
        .inline_callees = &.{ .fromName("g"), .fromName("h") },
        .patches = &.{ 0, 4 },
    };
    try std.testing.expect(debugValid(4, &good));
    var d = good;
    const t = struct {
        fn inl(base: Atom.Debug, i: usize, comptime field: []const u8, v: u32) [2]Atom.Debug.Inline {
            var out = base.inlines[0..2].*;
            @field(out[i], field) = v;
            return out;
        }
    };
    const cases = [_]struct { []const u8, [2]Atom.Debug.Inline }{
        .{ "name", t.inl(good, 1, "name_len", 2) },
        .{ "file", t.inl(good, 0, "file", 2) },
        .{ "parent", t.inl(good, 1, "parent", 1) },
        .{ "range", t.inl(good, 0, "high", 5) },
        .{ "order", t.inl(good, 1, "low", 3) },
    };
    for (&cases) |*c| {
        d.inlines = &c[1];
        std.testing.expect(!debugValid(4, &d)) catch |err| {
            std.debug.print("accepted a bad {s}\n", .{c[0]});
            return err;
        };
    }
    d = good;
    for ([_][]const u32{ &.{ 4, 0 }, &.{ 0, 1 }, &.{ 0, 10 }, &.{ 0, 6 } }) |patches| {
        d.patches = patches;
        try std.testing.expect(!debugValid(4, &d));
    }
    d = good;
    for ([_][]const u8{ "u.zig", "\x00", "u.zig\x00\x00" }) |files| {
        d.files = files;
        try std.testing.expect(!debugValid(4, &d));
    }
}
