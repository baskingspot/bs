//! DWARF 5 debug info for the linkers: a compile unit per `Atom.Debug.unit`,
//! with a subprogram entry (and an inlined subroutine entry per inline call)
//! per `Atom.Debug` entry; one line-number program, which every unit
//! shares, with a sequence per entry; and x86_64 call frame information for
//! .eh_frame. Type and variable info come later.
//!
//! A unit's functions are not contiguous in .text, so its address ranges
//! are a range list in .debug_rnglists (and, for Mach-O dSYMs, an aranges
//! set): one range per run of consecutive entries of the unit within a
//! chunk, which also covers code between them that has no debug info.
//!
//! The headers depend only on the file and unit tables and are built
//! serially; the per-function parts have sizes known from their
//! `Atom.Debug` alone, so threads can write them in place, and a sequence
//! is mostly a copy of the function's own line program fragment
//! (`Atom.Debug.lines`).

const std = @import("std");
const DW = std.dwarf;
const Allocator = std.mem.Allocator;
const Atom = @import("Atom.zig");
const ref = @import("Elf.zig").ref;
const Dwarf = @This();

/// Every unit's header and entry, one after another.
unit_heads: []u8 = &.{},
/// The line-number program header, with the file table.
line_header: []u8 = &.{},
/// .debug_rnglists' header, and each unit's aranges set header.
rnglists_header: [rnglists_header_len]u8 = undefined,
aranges_heads: []u8 = &.{},

/// .debug_str. Names are inline strings, but readers such as std.debug
/// require the section.
pub const str = "zap\x00";

/// Abbreviation codes.
const abbrev_cu = 1;
const abbrev_subprogram = 2;
const abbrev_subprogram_parent = 3;
const abbrev_inline = 4;
const abbrev_inline_parent = 5;

const subprogram_attrs = [_]u8{ DW.AT.name, DW.FORM.string } ++
    [_]u8{ DW.AT.low_pc, DW.FORM.addr } ++
    [_]u8{ DW.AT.high_pc, DW.FORM.data4 } ++
    [_]u8{ DW.AT.decl_file, DW.FORM.data4 } ++
    [_]u8{ DW.AT.decl_line, DW.FORM.data4 } ++
    [_]u8{ 0, 0 };
const inline_attrs = [_]u8{ DW.AT.name, DW.FORM.string } ++
    [_]u8{ DW.AT.low_pc, DW.FORM.addr } ++
    [_]u8{ DW.AT.high_pc, DW.FORM.data4 } ++
    [_]u8{ DW.AT.call_file, DW.FORM.data4 } ++
    [_]u8{ DW.AT.call_line, DW.FORM.data4 } ++
    [_]u8{ DW.AT.call_column, DW.FORM.data4 } ++
    [_]u8{ 0, 0 };

pub const abbrev = [_]u8{ abbrev_cu, DW.TAG.compile_unit, DW.CHILDREN.yes } ++
    [_]u8{ DW.AT.producer, DW.FORM.strp } ++
    [_]u8{ DW.AT.language, DW.FORM.data2 } ++
    [_]u8{ DW.AT.name, DW.FORM.string } ++
    [_]u8{ DW.AT.comp_dir, DW.FORM.string } ++
    [_]u8{ DW.AT.stmt_list, DW.FORM.sec_offset } ++
    [_]u8{ DW.AT.low_pc, DW.FORM.addr } ++
    [_]u8{ DW.AT.ranges, DW.FORM.sec_offset } ++
    [_]u8{ 0, 0 } ++
    [_]u8{ abbrev_subprogram, DW.TAG.subprogram, DW.CHILDREN.no } ++ subprogram_attrs ++
    [_]u8{ abbrev_subprogram_parent, DW.TAG.subprogram, DW.CHILDREN.yes } ++ subprogram_attrs ++
    [_]u8{ abbrev_inline, DW.TAG.inlined_subroutine, DW.CHILDREN.no } ++ inline_attrs ++
    [_]u8{ abbrev_inline_parent, DW.TAG.inlined_subroutine, DW.CHILDREN.yes } ++ inline_attrs ++
    [_]u8{0}; // end of the table

/// A unit's header and entry, up to its children: the unit header, then
/// producer, language, name, comp_dir, stmt_list, low_pc, ranges.
fn cuHeadLen(name: []const u8, comp_dir: []const u8) u64 {
    return 12 + 1 + 4 + 2 + name.len + 1 + comp_dir.len + 1 + 4 + 8 + 4;
}

pub const rnglists_header_len = 12;
/// An aranges set's header, padded to a multiple of the tuple size.
const aranges_head_len = 16;
/// A range list entry: DW_RLE_offset_pair from the unit's low_pc, with
/// both offsets ULEB128s padded to 5 bytes, so its size does not depend on
/// addresses.
pub const range_len = 11;
pub const aranges_tuple_len = 16;

/// Builds the headers for the placed chunks: the units', whose ranges are
/// relative to `text_addr`, and the line program's.
pub fn init(gpa: Allocator, placed: *const Placed, comp_dir: []const u8, text_addr: u64) Allocator.Error!Dwarf {
    var d: Dwarf = .{};
    errdefer d.deinit(gpa);
    var line: std.Io.Writer.Allocating = .init(gpa);
    defer line.deinit();
    buildLineHeader(gpa, &line.writer, placed.files.keys(), comp_dir) catch return error.OutOfMemory;
    d.line_header = try line.toOwnedSlice();
    std.mem.writeInt(u32, d.line_header[0..4], @intCast(d.line_header.len + placed.line_len - 4), .little);

    const units = placed.units.values();
    var heads_len: usize = 0;
    for (units) |u| heads_len += u.head_len;
    d.unit_heads = try gpa.alloc(u8, heads_len);
    d.aranges_heads = try gpa.alloc(u8, units.len * aranges_head_len);
    var at: usize = 0;
    for (placed.units.keys(), units, 0..) |unit, u, k| {
        const name = if (unit.len > 0) unit else placed.files.keys()[0];
        var w: std.Io.Writer = .fixed(d.unit_heads[at..][0..u.head_len]);
        w.writeInt(u32, @intCast(u.info_len - 4), .little) catch unreachable;
        w.writeInt(u16, 5, .little) catch unreachable;
        w.writeAll(&.{ DW.UT.compile, 8 }) catch unreachable;
        w.writeInt(u32, 0, .little) catch unreachable; // debug_abbrev_offset
        w.writeByte(abbrev_cu) catch unreachable;
        w.writeInt(u32, 0, .little) catch unreachable; // producer, at the start of `str`
        w.writeInt(u16, DW.LANG.Zig, .little) catch unreachable;
        w.writeAll(name) catch unreachable;
        w.writeByte(0) catch unreachable;
        w.writeAll(comp_dir) catch unreachable;
        w.writeByte(0) catch unreachable;
        w.writeInt(u32, 0, .little) catch unreachable; // stmt_list
        w.writeInt(u64, text_addr, .little) catch unreachable;
        w.writeInt(u32, @intCast(u.ranges_off), .little) catch unreachable;
        std.debug.assert(w.end == u.head_len);
        at += u.head_len;

        const a = d.aranges_heads[k * aranges_head_len ..][0..aranges_head_len];
        @memset(a, 0);
        std.mem.writeInt(u32, a[0..4], @intCast(u.aranges_len - 4), .little);
        std.mem.writeInt(u16, a[4..6], 2, .little);
        std.mem.writeInt(u32, a[6..10], @intCast(u.info_off), .little);
        a[10] = 8; // address_size; segment_selector_size 0
    }
    d.rnglists_header = @splat(0);
    std.mem.writeInt(u32, d.rnglists_header[0..4], @intCast(placed.ranges_size - 4), .little);
    std.mem.writeInt(u16, d.rnglists_header[4..6], 5, .little);
    d.rnglists_header[6] = 8; // address_size; segment_selector_size 0, offset_entry_count 0
    return d;
}

fn buildLineHeader(gpa: Allocator, line: *std.Io.Writer, files: []const []const u8, comp_dir: []const u8) !void {
    try line.writeInt(u32, 0, .little); // unit_length, set by `init`
    try line.writeInt(u16, 5, .little);
    try line.writeAll(&.{ 8, 0 }); // address_size, segment_selector_size
    try line.writeInt(u32, 0, .little); // header_length, set below
    try line.writeAll(&.{ 1, 1, 1 }); // minimum_instruction_length, maximum_operations_per_instruction, default_is_stmt
    try line.writeAll(&.{ @bitCast(@as(i8, Atom.LineProgram.line_base)), Atom.LineProgram.line_range, Atom.LineProgram.opcode_base });
    try line.writeAll(&.{ 0, 1, 1, 1, 1, 0, 0, 0, 1, 0, 0, 1 }); // standard_opcode_lengths
    // Directory 0 is the compilation directory; the others are the files'
    // directories resolved against it, since std.debug does not.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var dirs: std.StringArrayHashMapUnmanaged(void) = .empty;
    try dirs.put(arena, comp_dir, {});
    const file_dirs = try arena.alloc(usize, files.len);
    for (files, file_dirs) |f, *dir| {
        const resolved = try std.fs.path.resolvePosix(arena, &.{ comp_dir, std.fs.path.dirnamePosix(f) orelse "." });
        dir.* = (try dirs.getOrPut(arena, resolved)).index;
    }
    try line.writeAll(&.{ 1, DW.LNCT.path, DW.FORM.string });
    try line.writeUleb128(dirs.count());
    for (dirs.keys()) |dir| {
        try line.writeAll(dir);
        try line.writeByte(0);
    }
    try line.writeAll(&.{ 2, DW.LNCT.path, DW.FORM.string, DW.LNCT.directory_index, DW.FORM.udata });
    try line.writeUleb128(files.len);
    for (files, file_dirs) |f, dir| {
        try line.writeAll(std.fs.path.basenamePosix(f));
        try line.writeByte(0);
        try line.writeUleb128(dir);
    }
    std.mem.writeInt(u32, line.buffered()[8..12], @intCast(line.end - 12), .little);
}

pub fn deinit(d: *Dwarf, gpa: Allocator) void {
    gpa.free(d.unit_heads);
    gpa.free(d.line_header);
    gpa.free(d.aranges_heads);
}

/// The serially written parts of the sections, as (offset within the
/// section, bytes): each unit's header and the 0 ending its children in
/// .debug_info; .debug_rnglists' header and the end of each unit's list;
/// and with `aranges`, each unit's set header and terminating tuple in
/// .debug_aranges (dSYMs only: lldb maps addresses to a dSYM's units only
/// through that section, which dsymutil always writes).
pub fn heads(d: *const Dwarf, placed: *const Placed, ctx: anytype, comptime put: anytype) !void {
    var at: usize = 0;
    const zeros: [aranges_tuple_len]u8 = @splat(0);
    try put(ctx, .ranges, 0, &d.rnglists_header);
    for (placed.units.values(), 0..) |u, k| {
        try put(ctx, .info, u.info_off, d.unit_heads[at..][0..u.head_len]);
        at += u.head_len;
        try put(ctx, .info, u.info_off + u.info_len - 1, zeros[0..1]);
        try put(ctx, .ranges, u.ranges_off + u.ranges_len - 1, zeros[0..1]);
        try put(ctx, .aranges, u.aranges_off, d.aranges_heads[k * aranges_head_len ..][0..aranges_head_len]);
        try put(ctx, .aranges, u.aranges_off + u.aranges_len - aranges_tuple_len, &zeros);
    }
}

pub const Section = enum { info, ranges, aranges };

/// The subprogram entry's size, with its inlined subroutine entries.
fn subprogramSize(debug: *const Atom.Debug) u64 {
    var len: u64 = 1 + debug.name.len + 1 + 8 + 4 + 4 + 4;
    if (debug.inlines.len == 0) return len;
    // The entries with children each end with a 0.
    len += 1;
    for (debug.inlines, 0..) |inl, k| {
        len += 1 + inl.name.len + 1 + 8 + 4 + 4 + 4 + 4;
        len += @intFromBool(hasChildren(debug.inlines, k));
    }
    return len;
}

fn hasChildren(inlines: []const Atom.Debug.Inline, k: usize) bool {
    return k + 1 < inlines.len and inlines[k + 1].parent == k;
}

/// Maps a local file index of `debug` (see `Atom.Debug.files`) to the
/// output's.
const FileMap = struct {
    c: *const Chunk,
    debug: *const Atom.Debug,
    file: u32,

    fn get(m: FileMap, local: u32) u32 {
        if (local == 0) return m.file;
        return m.c.file_map[m.c.files.getIndex(m.debug.files[local - 1]).?];
    }
};

/// Writes the subprogram entry of the `size`-byte function at `addr`, and
/// its inlined subroutine entries, at the start of `out`, and returns
/// their size.
inline fn writeSubprogram(out: []u8, debug: *const Atom.Debug, addr: u64, size: u64, files: FileMap) usize {
    var at: usize = 0;
    out[at] = if (debug.inlines.len == 0) abbrev_subprogram else abbrev_subprogram_parent;
    at += 1;
    @memcpy(out[at..][0..debug.name.len], debug.name);
    out[at + debug.name.len] = 0;
    at += debug.name.len + 1;
    std.mem.writeInt(u64, out[at..][0..8], addr, .little);
    std.mem.writeInt(u32, out[at + 8 ..][0..4], @intCast(size), .little);
    std.mem.writeInt(u32, out[at + 12 ..][0..4], files.file, .little);
    std.mem.writeInt(u32, out[at + 16 ..][0..4], debug.base_line + 1, .little);
    at += 20;
    if (debug.inlines.len == 0) return at;
    return at + writeInlines(out[at..], debug, addr, files);
}

/// Writes the inlined subroutine entries of a subprogram entry, and the
/// ends of their and its children, and returns their size.
noinline fn writeInlines(out: []u8, debug: *const Atom.Debug, addr: u64, files: FileMap) usize {
    var at: usize = 0;
    const inlines = debug.inlines;
    const none = Atom.Debug.Inline.none;
    for (inlines, 0..) |inl, k| {
        // Close the entries between the previous one and this one's
        // parent; `layOutChunk` checked the order.
        if (k > 0 and !hasChildren(inlines, k - 1)) {
            var p = inlines[k - 1].parent;
            while (p != inl.parent) : (p = inlines[p].parent) {
                out[at] = 0;
                at += 1;
            }
        }
        const parent_file, const parent_base = if (inl.parent == none) .{ 0, debug.base_line } else .{ inlines[inl.parent].file, inlines[inl.parent].base_line };
        out[at] = if (hasChildren(inlines, k)) abbrev_inline_parent else abbrev_inline;
        at += 1;
        @memcpy(out[at..][0..inl.name.len], inl.name);
        out[at + inl.name.len] = 0;
        at += inl.name.len + 1;
        std.mem.writeInt(u64, out[at..][0..8], addr + inl.low, .little);
        std.mem.writeInt(u32, out[at + 8 ..][0..4], inl.high - inl.low, .little);
        std.mem.writeInt(u32, out[at + 12 ..][0..4], files.get(parent_file), .little);
        std.mem.writeInt(u32, out[at + 16 ..][0..4], parent_base + inl.call_line + 1, .little);
        std.mem.writeInt(u32, out[at + 20 ..][0..4], inl.call_column + 1, .little);
        at += 24;
    }
    // Close the last entry's open ancestors, then the subprogram.
    var p = inlines[inlines.len - 1].parent;
    while (p != none) : (p = inlines[p].parent) {
        out[at] = 0;
        at += 1;
    }
    out[at] = 0;
    return at + 1;
}

fn sequenceSize(debug: *const Atom.Debug) u64 {
    return set_address_len + set_file_len + 1 + slebLen(debug.base_line) + debug.lines.len + set_address_len + 3;
}

const set_address_len = 11;
/// The file index is a ULEB128 padded to 3 bytes, so that sizes do not
/// depend on the file table.
const set_file_len = 4;

/// Writes the line-number sequence of the `size`-byte function at `addr` at
/// the start of `out`, and returns its size: start at the function with the
/// line registers its fragment expects, copy the fragment and rewrite its
/// patches, and end the sequence at the end of the function.
inline fn writeSequence(out: []u8, debug: *const Atom.Debug, addr: u64, size: u64, files: FileMap) usize {
    setAddress(out[0..set_address_len], addr);
    var at: usize = set_address_len;
    paddedFile(out[at..][0..set_file_len], files.file);
    at += set_file_len;
    out[at] = DW.LNS.advance_line;
    at += 1;
    at += writeSleb(out[at..], debug.base_line);
    const lines = out[at..][0..debug.lines.len];
    @memcpy(lines, debug.lines);
    if (debug.patches.len > 0) applyPatches(lines, debug, files);
    at += debug.lines.len;
    setAddress(out[at..][0..set_address_len], addr + size);
    at += set_address_len;
    out[at..][0..3].* = .{ 0, 1, DW.LNE.end_sequence };
    return at + 3;
}

/// Rewrites the operands of `lines`, a copy of `debug.lines`, at its
/// patches.
noinline fn applyPatches(lines: []u8, debug: *const Atom.Debug, files: FileMap) void {
    var base = debug.base_line;
    for (debug.patches) |p| {
        if (lines[p] == DW.LNS.set_file) {
            paddedFile(lines[p..][0..set_file_len], files.get(readPaddedUleb(lines[p + 1 ..][0..3])));
        } else {
            const k: u32 = @intCast(readPaddedSleb(lines[p + 1 ..][0..5]));
            const to = if (k == 0) debug.base_line else debug.inlines[k - 1].base_line;
            lines[p + 1 ..][0..5].* = Atom.LineProgram.paddedSleb(@as(i64, to) - base);
            base = to;
        }
    }
}

fn paddedFile(out: *[set_file_len]u8, file: u32) void {
    out.* = .{ DW.LNS.set_file, @as(u8, @truncate(file)) | 0x80, @as(u8, @truncate(file >> 7)) | 0x80, @intCast(file >> 14) };
}

fn readPaddedUleb(b: *const [3]u8) u32 {
    return @as(u32, b[0] & 0x7f) | @as(u32, b[1] & 0x7f) << 7 | @as(u32, b[2]) << 14;
}

fn readPaddedSleb(b: *const [5]u8) i64 {
    var v: u64 = 0;
    for (b, 0..) |byte, i| v |= @as(u64, byte & 0x7f) << @intCast(7 * i);
    return @as(i64, @bitCast(v << 29)) >> 29;
}

fn paddedUleb5(v: u64) [5]u8 {
    var out: [5]u8 = undefined;
    for (&out, 0..) |*b, i| b.* = @as(u7, @truncate(v >> @intCast(7 * i))) | @as(u8, if (i < 4) 0x80 else 0);
    return out;
}

fn setAddress(out: *[set_address_len]u8, addr: u64) void {
    out[0..3].* = .{ 0, 9, DW.LNE.set_address };
    std.mem.writeInt(u64, out[3..11], addr, .little);
}

fn slebLen(v: u32) usize {
    // Non-negative: 7 bits per byte, and the top bit of the last must be 0.
    return @as(usize, (32 - @clz(v)) / 7) + 1;
}

fn writeSleb(out: []u8, value: u32) usize {
    var v = value;
    var i: usize = 0;
    while (v >= 0x40) : (v >>= 7) {
        out[i] = @as(u8, @truncate(v)) | 0x80;
        i += 1;
    }
    out[i] = @intCast(v);
    return i + 1;
}

// The per-entry passes, shared by the linkers. Entries are split into
// chunks of `chunk_len`; one parallel pass sizes each chunk's entries and
// collects its files (`layOutChunk`), a serial step places the chunks and
// builds the file table (`placeChunks`), and the linker writes each chunk's
// parts in place.

pub const chunk_len = 2048;

/// One `chunk_len` run of consecutive debug entries.
pub const Chunk = struct {
    // Filled in by `layOutChunk`.
    /// Bytes of the chunk's line sequences.
    line_len: u64,
    /// Entries with a `frame` other than `none`.
    n_frames: u32,
    /// Source files of the chunk's entries, in first-use order; the
    /// linker's `file_of` indexes it.
    files: std.StringArrayHashMapUnmanaged(void),
    /// Units of the chunk's entries, in first-use order, and the chunk's
    /// part of each.
    units: std.StringArrayHashMapUnmanaged(UnitPart),
    // Filled in by `placeChunks`.
    /// Where the chunk's sequences start in .debug_line, after the header.
    line_off: u64,
    /// Entries with a frame in the chunks before this one.
    frame_base: u32,
    /// Index in the output's file table of each of `files`.
    file_map: []u32,

    pub const empty: Chunk = .{ .line_len = 0, .n_frames = 0, .files = .empty, .units = .empty, .line_off = 0, .frame_base = 0, .file_map = &.{} };

    pub fn deinit(c: *Chunk, gpa: Allocator) void {
        c.files.deinit(gpa);
        c.units.deinit(gpa);
    }

    /// Bytes of the chunk's subprogram entries, range lists, and aranges
    /// tuples, in all its units.
    pub fn lens(c: *const Chunk) struct { info: u64, ranges: u64, aranges: u64 } {
        var info: u64 = 0;
        var runs: u64 = 0;
        for (c.units.values()) |u| {
            info += u.info_len;
            runs += u.n_runs;
        }
        return .{ .info = info, .ranges = runs * range_len, .aranges = runs * aranges_tuple_len };
    }
};

/// A chunk's part of a unit.
pub const UnitPart = struct {
    // Filled in by `layOutChunk`.
    info_len: u64 = 0,
    /// Runs of consecutive entries of the unit, each one range.
    n_runs: u32 = 0,
    // Filled in by `placeChunks`: offsets within .debug_info,
    // .debug_rnglists, and .debug_aranges.
    info_off: u64 = 0,
    ranges_off: u64 = 0,
    aranges_off: u64 = 0,
};

/// The `file_of` of an entry whose atom was deduplicated away. Otherwise
/// it holds the entry's file, as an index into its chunk's `files`, in the
/// low `file_bits` bits, and its unit, as an index into the chunk's
/// `units`, above them; a chunk has fewer than 1 << 11 units.
pub const skip = std.math.maxInt(u32);
const file_bits = 21;

/// Sizes the entries of debug chunk `chunk` and collects their files and
/// units. `l` is a linker's shared state, with `gpa`, `input`, `n_atoms`,
/// `n_debug`, `places`, `debug_chunks`, `file_of`, and `fail`; `task` is
/// the chunk's failure slot and `text` the linkers' section number of code.
/// The atoms of the entries are checked to ascend and be in range before
/// `debug(j)` reads anything of theirs, and each entry's inline calls and
/// patches are checked, so writing it cannot fail.
pub fn layOutChunk(l: anytype, chunk: usize, task: usize, text: u3) void {
    const begin = chunk * chunk_len;
    const end = @min(l.n_debug, begin + chunk_len);
    const c = &l.debug_chunks[chunk];
    c.line_len = 0;
    c.n_frames = 0;
    // Functions from one file usually share its path's bytes, so a table by
    // address saves hashing the path for most entries.
    var by_addr: FilesByAddr = .{};
    var units: UnitCursor = .{};
    var units_by_addr: FilesByAddr = .{};
    for (l.file_of[begin..end], begin..) |*file_of, j| {
        file_of.* = skip;
        const atom = l.input.debugAtom(j);
        if (atom >= l.n_atoms or (j > 0 and l.input.debugAtom(j - 1) >= atom)) {
            return l.fail(task, @min(atom, l.n_atoms), error.InvalidDebugInfo, .{});
        }
        const place = l.places[atom];
        if (place.isDuplicate()) continue;
        if (place.section != text) {
            return l.fail(task, atom, error.InvalidDebugInfo, .{ .atom = l.input.atom(atom).name });
        }
        const debug = l.input.debug(j);
        const d = ref(&debug);
        const file: u32 = by_addr.get(d.file) orelse index: {
            const gop = c.files.getOrPut(l.gpa, d.file) catch return l.fail(task, atom, error.OutOfMemory, .{});
            by_addr.put(d.file, @intCast(gop.index));
            break :index @intCast(gop.index);
        };
        if (d.inlines.len > 0 or d.patches.len > 0 or d.files.len > 0) {
            if (!valid(d, l.input.atom(atom).bytes.len)) return l.fail(task, atom, error.InvalidDebugInfo, .{ .atom = l.input.atom(atom).name });
            for (d.files) |f| _ = c.files.getOrPut(l.gpa, f) catch return l.fail(task, atom, error.OutOfMemory, .{});
        }
        file_of.* = file;
        const unit = units.next(l.gpa, c, &units_by_addr, d.unit) catch return l.fail(task, atom, error.OutOfMemory, .{});
        file_of.* |= unit << file_bits;
        const part = units.part;
        part.info_len += subprogramSize(d);
        part.n_runs += @intFromBool(units.new_run);
        c.line_len += sequenceSize(d);
        c.n_frames += @intFromBool(d.frame != .none);
    }
}

/// Whether the inline calls and patches of the entry of a `size`-byte
/// function are well formed.
fn valid(d: *const Atom.Debug, size: u64) bool {
    const none = Atom.Debug.Inline.none;
    if (d.inlines.len >= none) return false;
    for (d.inlines, 0..) |inl, k| {
        if (inl.file > d.files.len or inl.low > inl.high or inl.high > size) return false;
        // Preorder: the parent is the previous entry or one of its
        // ancestors.
        if (k == 0) {
            if (inl.parent != none) return false;
        } else if (inl.parent != k - 1) {
            var p = d.inlines[k - 1].parent;
            while (p != inl.parent) : (p = d.inlines[p].parent) {
                if (p == none) return false;
            }
        }
    }
    var prev: u64 = 0;
    for (d.patches, 0..) |p, i| {
        if ((i > 0 and p <= prev) or p >= d.lines.len) return false;
        prev = p;
        switch (d.lines[p]) {
            DW.LNS.set_file => {
                if (d.lines.len - p < set_file_len or readPaddedUleb(d.lines[p + 1 ..][0..3]) > d.files.len) return false;
            },
            DW.LNS.advance_line => {
                if (d.lines.len - p < 6) return false;
                const k = readPaddedSleb(d.lines[p + 1 ..][0..5]);
                if (k < 0 or k > d.inlines.len) return false;
            },
            else => return false,
        }
    }
    return true;
}

/// Finds the index in the chunk's units of each entry's unit, in entry
/// order, and whether the entry starts a run of the unit.
const UnitCursor = struct {
    prev: ?[]const u8 = null,
    index: u32 = 0,
    part: *UnitPart = undefined,
    new_run: bool = false,

    inline fn next(u: *UnitCursor, gpa: Allocator, c: *Chunk, by_addr: *FilesByAddr, unit: []const u8) Allocator.Error!u32 {
        // Consecutive entries' units are usually the same bytes.
        if (u.prev) |prev| if (prev.ptr == unit.ptr and prev.len == unit.len) {
            u.new_run = false;
            return u.index;
        };
        return u.find(gpa, c, by_addr, unit);
    }

    noinline fn find(u: *UnitCursor, gpa: Allocator, c: *Chunk, by_addr: *FilesByAddr, unit: []const u8) Allocator.Error!u32 {
        const index = by_addr.get(unit) orelse index: {
            const gop = try c.units.getOrPut(gpa, unit);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            by_addr.put(unit, @intCast(gop.index));
            break :index @as(u32, @intCast(gop.index));
        };
        u.new_run = u.prev == null or index != u.index;
        u.prev = unit;
        u.index = index;
        u.part = &c.units.values()[index];
        return index;
    }
};

/// Open addressing from a path's address and length to its index in a
/// chunk's `files`. Holds up to 3/4 of its slots; paths past that are looked
/// up by contents every time.
const FilesByAddr = struct {
    slots: [1024]Slot = @splat(.{ .ptr = 0, .len = 0, .index = 0 }),
    count: usize = 0,

    const Slot = struct { ptr: usize, len: usize, index: u32 };

    fn home(file: []const u8) usize {
        return @intCast((@intFromPtr(file.ptr) *% 0x9e3779b97f4a7c15) >> 54);
    }

    fn get(t: *const FilesByAddr, file: []const u8) ?u32 {
        var i = home(file);
        while (t.slots[i].ptr != 0) : (i = (i + 1) % t.slots.len) {
            if (t.slots[i].ptr == @intFromPtr(file.ptr) and t.slots[i].len == file.len) return t.slots[i].index;
        }
        return null;
    }

    fn put(t: *FilesByAddr, file: []const u8, index: u32) void {
        if (t.count >= t.slots.len / 4 * 3) return;
        var i = home(file);
        while (t.slots[i].ptr != 0) i = (i + 1) % t.slots.len;
        t.slots[i] = .{ .ptr = @intFromPtr(file.ptr), .len = file.len, .index = index };
        t.count += 1;
    }
};

/// The chunks' totals, and the output's file and unit tables.
pub const Placed = struct {
    line_len: u64 = 0,
    n_frames: u32 = 0,
    /// The whole .debug_info, .debug_rnglists, and .debug_aranges.
    info_size: u64 = 0,
    ranges_size: u64 = 0,
    aranges_size: u64 = 0,
    /// The output's file table, from the chunks' files in first-use order.
    files: std.StringArrayHashMapUnmanaged(void) = .empty,
    file_map: []u32 = &.{},
    /// The output's units, in first-use order.
    units: std.StringArrayHashMapUnmanaged(Unit) = .empty,

    pub fn deinit(p: *Placed, gpa: Allocator) void {
        p.files.deinit(gpa);
        gpa.free(p.file_map);
        p.units.deinit(gpa);
    }
};

/// Where a unit goes: its entries, its range list, and its aranges set,
/// as offsets and lengths within their sections.
pub const Unit = struct {
    info_off: u64 = 0,
    info_len: u64 = 0,
    /// Its header and entry, before its children.
    head_len: u64 = 0,
    ranges_off: u64 = 0,
    ranges_len: u64 = 0,
    aranges_off: u64 = 0,
    aranges_len: u64 = 0,
};

/// Places the chunks' sequences after one another, builds the file table,
/// and places each unit's header, the chunks' parts of it in chunk order,
/// and the end of its children; likewise its range list and aranges set.
pub fn placeChunks(gpa: Allocator, chunks: []Chunk, comp_dir: []const u8) error{OutOfMemory}!Placed {
    var p: Placed = .{};
    errdefer p.deinit(gpa);
    var n_chunk_files: usize = 0;
    for (chunks) |*c| {
        c.line_off = p.line_len;
        c.frame_base = p.n_frames;
        p.line_len += c.line_len;
        p.n_frames += c.n_frames;
        n_chunk_files += c.files.count();
    }
    p.file_map = try gpa.alloc(u32, n_chunk_files);
    var at: usize = 0;
    for (chunks) |*c| {
        c.file_map = p.file_map[at..][0..c.files.count()];
        at += c.files.count();
        for (c.files.keys(), c.file_map) |f, *global| {
            global.* = @intCast((try p.files.getOrPut(gpa, f)).index);
        }
    }
    // The set_file operand is a fixed-width ULEB128.
    if (p.files.count() >= (1 << file_bits) - 1) return error.OutOfMemory;
    if (p.files.count() == 0) return p;

    // Each unit's size, then its place, then each chunk's part of it.
    for (chunks) |*c| {
        for (c.units.keys(), c.units.values()) |name, part| {
            const gop = try p.units.getOrPut(gpa, name);
            if (!gop.found_existing) gop.value_ptr.* = .{ .head_len = cuHeadLen(if (name.len > 0) name else p.files.keys()[0], comp_dir) };
            const u = gop.value_ptr;
            u.info_len += part.info_len;
            u.ranges_len += part.n_runs * range_len;
            u.aranges_len += part.n_runs * aranges_tuple_len;
        }
    }
    p.ranges_size = rnglists_header_len;
    for (p.units.values()) |*u| {
        u.info_len += u.head_len + 1;
        u.ranges_len += 1;
        u.aranges_len += aranges_head_len + aranges_tuple_len;
        u.info_off = p.info_size;
        u.ranges_off = p.ranges_size;
        u.aranges_off = p.aranges_size;
        p.info_size += u.info_len;
        p.ranges_size += u.ranges_len;
        p.aranges_size += u.aranges_len;
        // The parts' cursors.
        u.info_off += u.head_len;
        u.aranges_off += aranges_head_len;
    }
    if (p.info_size > std.math.maxInt(u32) or p.ranges_size > std.math.maxInt(u32)) return error.OutOfMemory;
    for (chunks) |*c| {
        for (c.units.keys(), c.units.values()) |name, *part| {
            const u = p.units.getPtr(name).?;
            part.info_off = u.info_off;
            part.ranges_off = u.ranges_off;
            part.aranges_off = u.aranges_off;
            u.info_off += part.info_len;
            u.ranges_off += part.n_runs * range_len;
            u.aranges_off += part.n_runs * aranges_tuple_len;
        }
    }
    // Back from the cursors to the units' starts.
    for (p.units.values()) |*u| {
        u.info_off -= u.info_len - 1;
        u.ranges_off -= u.ranges_len - 1;
        u.aranges_off -= u.aranges_len - aranges_tuple_len;
    }
    return p;
}

/// Writes one chunk's entries in order: each entry's subprogram entry to
/// its unit's part of `info`, its sequence to `line`, and each run's range
/// to its unit's part of `ranges` and, if not empty, `aranges`. A part is
/// where the chunk's part of a unit goes, in the chunk's unit order; the
/// writer advances them.
pub const ChunkWriter = struct {
    c: *const Chunk,
    info: [][]u8,
    ranges: [][]u8,
    aranges: [][]u8,
    line: []u8,
    /// Range offsets are from the units' low_pc.
    text_addr: u64,
    /// The current run's unit, as an index in the chunk's units or
    /// `no_unit`, and the rest of its part of `info`.
    k: u32 = no_unit,
    unit_info: []u8 = &.{},
    run_start: u64 = 0,
    run_end: u64 = 0,

    /// Writes the entry `debug` of the `size`-byte function at `addr`,
    /// whose file is `file_of` (see `layOutChunk`).
    pub inline fn entry(w: *ChunkWriter, debug: *const Atom.Debug, addr: u64, size: u64, file_of: u32) void {
        const k = file_of >> file_bits;
        if (k != w.k) w.switchUnit(k, addr);
        w.run_end = addr + size;
        const files: FileMap = .{ .c = w.c, .debug = debug, .file = w.c.file_map[file_of & (1 << file_bits) - 1] };
        w.unit_info = w.unit_info[writeSubprogram(w.unit_info, debug, addr, size, files)..];
        w.line = w.line[writeSequence(w.line, debug, addr, size, files)..];
    }

    const no_unit = std.math.maxInt(u32);

    fn switchUnit(w: *ChunkWriter, k: u32, addr: u64) void {
        if (w.k != no_unit) w.endRun();
        w.k = k;
        w.unit_info = w.info[k];
        w.run_start = addr;
    }

    pub fn finish(w: *ChunkWriter) void {
        if (w.k != no_unit) w.endRun();
    }

    fn endRun(w: *ChunkWriter) void {
        const k = w.k;
        w.info[k] = w.unit_info;
        w.ranges[k][0] = DW.RLE.offset_pair;
        w.ranges[k][1..6].* = paddedUleb5(w.run_start - w.text_addr);
        w.ranges[k][6..11].* = paddedUleb5(w.run_end - w.text_addr);
        w.ranges[k] = w.ranges[k][range_len..];
        if (w.aranges.len > 0) {
            std.mem.writeInt(u64, w.aranges[k][0..8], w.run_start, .little);
            std.mem.writeInt(u64, w.aranges[k][8..16], w.run_end - w.run_start, .little);
            w.aranges[k] = w.aranges[k][aranges_tuple_len..];
        }
    }
};

// Call frame information (.eh_frame and .eh_frame_hdr, x86_64). Every
// function with a frame (`Atom.Debug.Frame` other than `none`) gets one FDE
// of `fde_size` bytes,
// all sharing the CIE at the start of .eh_frame, so the linker places
// them by count alone.

/// The CIE at offset 0 of .eh_frame: augmentation "zR" with pc-relative
/// sdata4 FDE pointers, code alignment 1, data alignment -8, and return
/// address column 16 (rip). At a function's entry the CFA is rsp + 8 and the
/// return address is at CFA - 8.
// zig fmt: off
pub const cie = [_]u8{
    20, 0, 0, 0, // length
    0, 0, 0, 0, // CIE id
    1, // version
    'z', 'R', 0, // augmentation
    1, // code alignment factor
    0x78, // data alignment factor: SLEB128 -8
    16, // return address register
    1, // augmentation data length
    pe_pcrel_sdata4, // FDE pointer encoding
    DW.CFA.def_cfa, 7, 8, // CFA = rsp + 8
    DW.CFA.offset + 16, 1, // rip at CFA - 8
    DW.CFA.nop, DW.CFA.nop,
};
// zig fmt: on

pub const fde_size = 32;

/// An FDE for the frame-pointer prologue `push rbp; mov rbp, rsp`: after
/// the 1-byte push, the CFA is rsp + 16 with rbp saved at CFA - 16; after
/// the 3-byte mov, the CFA is rbp + 16 for the rest of the function. The
/// one instruction between an epilogue's `pop rbp` and its `ret` is not
/// described: CodeGen may return from several places, and the FDE has a
/// fixed size.
// zig fmt: off
const fde_template = [_]u8{
    28, 0, 0, 0, // length
    0, 0, 0, 0, // CIE pointer
    0, 0, 0, 0, // pc_begin
    0, 0, 0, 0, // pc_range
    0, // augmentation data length
    DW.CFA.advance_loc + 1,
    DW.CFA.def_cfa_offset, 16, // CFA = rsp + 16
    DW.CFA.offset + 6, 2, // rbp at CFA - 16
    DW.CFA.advance_loc + 3,
    DW.CFA.def_cfa_register, 6, // CFA = rbp + 16
} ++ @as([7]u8, @splat(DW.CFA.nop));

/// An FDE for the outermost frame, such as `_start`'s: the CIE's CFA of
/// rsp + 8, and no return address (rip undefined), which tells unwinders
/// that the stack ends here.
const outermost_fde_template = fde_template[0..17].* ++ [_]u8{
    DW.CFA.undefined, 16, // rip undefined
} ++ @as([13]u8, @splat(DW.CFA.nop));
// zig fmt: on

comptime {
    std.debug.assert(cie.len % 8 == 0 and fde_template.len == fde_size and outermost_fde_template.len == fde_size);
}

/// Writes the FDE at offset `fde_off` of .eh_frame, for the `size`-byte
/// function `pc_rel` bytes after the FDE's pc_begin field, with a
/// `frame` other than `none`.
pub fn writeFde(out: *[fde_size]u8, frame: Atom.Debug.Frame, fde_off: u32, pc_rel: i32, size: u32) void {
    out.* = switch (frame) {
        .none => unreachable,
        .frame_pointer => fde_template,
        .outermost => outermost_fde_template,
    };
    std.mem.writeInt(u32, out[4..8], fde_off + 4, .little);
    std.mem.writeInt(i32, out[8..12], pc_rel, .little);
    std.mem.writeInt(u32, out[12..16], size, .little);
}

/// .eh_frame_hdr up to its search table: pointers are pc-relative or, in
/// the table, relative to the start of .eh_frame_hdr. The table follows,
/// one `eh_frame_hdr_entry_size` pair (function, FDE) per FDE, sorted by
/// function address.
pub fn ehFrameHdr(eh_frame_rel: i32, fde_count: u32) [eh_frame_hdr_size]u8 {
    var h: [eh_frame_hdr_size]u8 = .{ 1, pe_pcrel_sdata4, pe_udata4, pe_datarel_sdata4 } ++ @as([8]u8, @splat(0));
    std.mem.writeInt(i32, h[4..8], eh_frame_rel, .little);
    std.mem.writeInt(u32, h[8..12], fde_count, .little);
    return h;
}

pub const eh_frame_hdr_size = 12;
pub const eh_frame_hdr_entry_size = 8;

// Pointer encodings (DW_EH_PE_*).
const pe_udata4 = 0x03;
const pe_pcrel_sdata4 = 0x1b;
const pe_datarel_sdata4 = 0x3b;
