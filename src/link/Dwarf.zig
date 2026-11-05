//! DWARF 5 debug info for the linkers: a compile unit per `Atom.Debug.unit`,
//! with a subprogram entry (and an inlined subroutine entry per inline call)
//! per `Atom.Debug` entry and a line-number program with the unit's files
//! and a sequence per entry; and x86_64 call frame information for
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

/// The output's units, in first-use order, with what `place` built.
units: std.StringArrayHashMapUnmanaged(Unit) = .empty,
/// Sizes of .debug_info, .debug_rnglists, .debug_line, and .debug_aranges.
info_size: u64 = 0,
ranges_size: u64 = 0,
line_size: u64 = 0,
aranges_size: u64 = 0,
/// FDEs, one per entry with a frame, and their bytes.
n_frames: u32 = 0,
frame_bytes: u64 = 0,
rnglists_header: [rnglists_header_len]u8 = undefined,
/// Owns the units, their files, and their headers.
arena: std.heap.ArenaAllocator.State = .{},

/// Where a unit goes, as offsets and lengths within the sections: its
/// header, its entries, and the 0 ending them; its range list; its line
/// program; and its aranges set.
pub const Unit = struct {
    /// DW_AT_name and DW_AT_comp_dir.
    name: []const u8 = "",
    dir: []const u8 = "",
    /// The unit's line program's files.
    files: std.StringArrayHashMapUnmanaged(void) = .empty,
    info_off: u64 = 0,
    info_len: u64 = 0,
    ranges_off: u64 = 0,
    ranges_len: u64 = 0,
    line_off: u64 = 0,
    line_len: u64 = 0,
    aranges_off: u64 = 0,
    aranges_len: u64 = 0,
    /// The unit's header and entry, up to its children; its line program's
    /// header; and its aranges set's header.
    head: []u8 = &.{},
    line_head: []u8 = &.{},
    aranges_head: [aranges_head_len]u8 = undefined,
};

/// .debug_str. Names are inline strings, but readers such as std.debug
/// require the section.
pub const str = "bs\x00";

/// Abbreviation codes.
const abbrev_cu = 1;
const abbrev_subprogram = 2;
const abbrev_subprogram_parent = 3;
const abbrev_inline = 4;
const abbrev_inline_parent = 5;

const subprogram_attrs = [_]u8{ DW.AT.name, DW.FORM.string } ++
    [_]u8{ DW.AT.linkage_name, DW.FORM.string } ++
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

/// Places the chunks' parts, builds the units' file tables, and builds
/// their headers, whose ranges are relative to `text_addr` and whose
/// units have DW_AT_language `language`. Within each
/// section, units follow one another in first-use order, and a unit's
/// parts from each chunk follow its header in chunk order.
pub fn place(gpa: Allocator, chunks: []Chunk, comp_dir: []const u8, text_addr: u64, language: u16) Allocator.Error!Dwarf {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();
    var d: Dwarf = .{};
    const units = &d.units;

    // The units, their sizes, and each chunk's files' indices in its
    // unit's file table.
    var n_chunk_files: usize = 0;
    for (chunks) |*c| {
        c.frame_base = d.n_frames;
        c.frame_off = d.frame_bytes;
        d.n_frames += c.n_frames;
        d.frame_bytes += c.frame_bytes;
        n_chunk_files += c.files.count();
    }
    const file_map = try arena.alloc(u32, n_chunk_files);
    var unit_map: std.ArrayList(u32) = .empty;
    var at: usize = 0;
    for (chunks) |*c| {
        unit_map.clearRetainingCapacity();
        for (c.units.keys(), c.units.values()) |name, part| {
            const gop = try units.getOrPut(arena, name);
            const u = gop.value_ptr;
            if (!gop.found_existing) {
                u.* = .{};
                // File 0 is the unit's root file, as upstream writes it.
                if (name.len > 0) try u.files.put(arena, name, {});
            }
            u.info_len += part.info_len;
            u.line_len += part.line_len;
            u.ranges_len += part.n_runs * range_len;
            u.aranges_len += part.n_runs * aranges_tuple_len;
            try unit_map.append(arena, @intCast(gop.index));
        }
        c.file_map = file_map[at..][0..c.files.count()];
        at += c.files.count();
        for (c.files.keys(), c.file_map) |key, *index| {
            const u = &units.values()[unit_map.items[key.unit]];
            index.* = @intCast((try u.files.getOrPut(arena, key.path)).index);
        }
    }

    // Each unit's headers, and its place.
    d.ranges_size = rnglists_header_len;
    for (units.keys(), units.values()) |unit, *u| {
        // The set_file operand is a fixed-width ULEB128, and `file_of`
        // reserves the all-ones index for `skip`.
        if (u.files.count() >= (1 << file_bits) - 1) return error.OutOfMemory;
        if (unit.len > 0) {
            u.name = std.fs.path.basenamePosix(unit);
            u.dir = try std.fs.path.resolvePosix(arena, &.{ comp_dir, std.fs.path.dirnamePosix(unit) orelse "." });
        } else {
            u.name = u.files.keys()[0];
            u.dir = comp_dir;
        }
        var line: std.Io.Writer.Allocating = .init(arena);
        buildLineHeader(arena, &line.writer, u.files.keys(), u.dir, comp_dir) catch return error.OutOfMemory;
        u.line_head = line.written();
        u.head = try arena.alloc(u8, cuHeadLen(u.name, u.dir));

        u.info_len += u.head.len + 1;
        u.ranges_len += 1;
        u.line_len += u.line_head.len;
        u.aranges_len += aranges_head_len + aranges_tuple_len;
        u.info_off = d.info_size;
        u.ranges_off = d.ranges_size;
        u.line_off = d.line_size;
        u.aranges_off = d.aranges_size;
        d.info_size += u.info_len;
        d.ranges_size += u.ranges_len;
        d.line_size += u.line_len;
        d.aranges_size += u.aranges_len;
    }
    if (d.info_size > std.math.maxInt(u32) or d.ranges_size > std.math.maxInt(u32) or d.line_size > std.math.maxInt(u32)) return error.OutOfMemory;

    // The chunks' parts, after each unit's header.
    for (units.values()) |*u| {
        u.info_off += u.head.len;
        u.line_off += u.line_head.len;
        u.aranges_off += aranges_head_len;
    }
    for (chunks) |*c| {
        for (c.units.keys(), c.units.values()) |name, *part| {
            const u = units.getPtr(name).?;
            part.info_off = u.info_off;
            part.ranges_off = u.ranges_off;
            part.line_off = u.line_off;
            part.aranges_off = u.aranges_off;
            u.info_off += part.info_len;
            u.ranges_off += part.n_runs * range_len;
            u.line_off += part.line_len;
            u.aranges_off += part.n_runs * aranges_tuple_len;
        }
    }
    for (units.values()) |*u| {
        u.info_off -= u.info_len - 1;
        u.ranges_off -= u.ranges_len - 1;
        u.line_off -= u.line_len;
        u.aranges_off -= u.aranges_len - aranges_tuple_len;
    }

    for (units.values()) |*u| {
        var w: std.Io.Writer = .fixed(u.head);
        w.writeInt(u32, @intCast(u.info_len - 4), .little) catch unreachable;
        w.writeInt(u16, 5, .little) catch unreachable;
        w.writeAll(&.{ DW.UT.compile, 8 }) catch unreachable;
        w.writeInt(u32, 0, .little) catch unreachable; // debug_abbrev_offset
        w.writeByte(abbrev_cu) catch unreachable;
        w.writeInt(u32, 0, .little) catch unreachable; // producer, at the start of `str`
        w.writeInt(u16, language, .little) catch unreachable;
        w.writeAll(u.name) catch unreachable;
        w.writeByte(0) catch unreachable;
        w.writeAll(u.dir) catch unreachable;
        w.writeByte(0) catch unreachable;
        w.writeInt(u32, @intCast(u.line_off), .little) catch unreachable;
        w.writeInt(u64, text_addr, .little) catch unreachable;
        w.writeInt(u32, @intCast(u.ranges_off), .little) catch unreachable;
        std.debug.assert(w.end == u.head.len);
        std.mem.writeInt(u32, u.line_head[0..4], @intCast(u.line_len - 4), .little);
        const a = &u.aranges_head;
        @memset(a, 0);
        std.mem.writeInt(u32, a[0..4], @intCast(u.aranges_len - 4), .little);
        std.mem.writeInt(u16, a[4..6], 2, .little);
        std.mem.writeInt(u32, a[6..10], @intCast(u.info_off), .little);
        a[10] = 8; // address_size; segment_selector_size 0
    }
    d.rnglists_header = @splat(0);
    std.mem.writeInt(u32, d.rnglists_header[0..4], @intCast(d.ranges_size - 4), .little);
    std.mem.writeInt(u16, d.rnglists_header[4..6], 5, .little);
    d.rnglists_header[6] = 8; // address_size; segment_selector_size 0, offset_entry_count 0
    d.arena = arena_state.state;
    return d;
}

/// A line program's header for `files`. Directory 0 is the unit's
/// directory; the others are the files' directories, resolved against
/// `comp_dir`, since std.debug does not resolve them.
fn buildLineHeader(arena: Allocator, line: *std.Io.Writer, files: []const []const u8, unit_dir: []const u8, comp_dir: []const u8) !void {
    try line.writeInt(u32, 0, .little); // unit_length, set by `place`
    try line.writeInt(u16, 5, .little);
    try line.writeAll(&.{ 8, 0 }); // address_size, segment_selector_size
    try line.writeInt(u32, 0, .little); // header_length, set below
    try line.writeAll(&.{ 1, 1, 1 }); // minimum_instruction_length, maximum_operations_per_instruction, default_is_stmt
    try line.writeAll(&.{ @bitCast(@as(i8, Atom.LineProgram.line_base)), Atom.LineProgram.line_range, Atom.LineProgram.opcode_base });
    try line.writeAll(&standard_opcode_lengths);
    var dirs: std.StringArrayHashMapUnmanaged(void) = .empty;
    try dirs.put(arena, unit_dir, {});
    const file_dirs = try arena.alloc(usize, files.len);
    // Files share few directories: resolve each spelling once.
    var by_dirname: std.StringHashMapUnmanaged(usize) = .empty;
    for (files, file_dirs) |f, *dir| {
        const dirname = std.fs.path.dirnamePosix(f) orelse ".";
        const gop = try by_dirname.getOrPut(arena, dirname);
        if (!gop.found_existing) {
            const resolved = try std.fs.path.resolvePosix(arena, &.{ comp_dir, dirname });
            gop.value_ptr.* = (try dirs.getOrPut(arena, resolved)).index;
        }
        dir.* = gop.value_ptr.*;
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

/// Operands of the standard opcodes 1 to `opcode_base` - 1, as the line
/// programs' headers declare them.
const standard_opcode_lengths = [_]u8{ 0, 1, 1, 1, 1, 0, 0, 0, 1, 0, 0, 1 };

/// What a field that a relocatable object relocates holds: an address in
/// .text, or an offset in .debug_abbrev, .debug_str, .debug_line, or
/// .debug_rnglists.
pub const Field = enum { addr, abbrev, str, line, ranges };

/// Calls `f(ctx, section, offset, field)`, `section` being `.info` or
/// `.line`, for each field of `info` and `line`, .debug_info and
/// .debug_line as `place` and `ChunkWriter` wrote them, that holds an
/// address or an offset in another section, in order within each section.
/// For relocatable output, where each becomes a relocation.
pub fn relocatableFields(info: []const u8, line: []const u8, ctx: anytype, comptime f: anytype) !void {
    var at: usize = 0;
    while (at < info.len) {
        const end = at + 4 + std.mem.readInt(u32, info[at..][0..4], .little);
        // See `place`: the unit header, then producer, language, name,
        // comp_dir, stmt_list, low_pc, ranges.
        try f(ctx, .info, at + 8, .abbrev);
        try f(ctx, .info, at + 13, .str);
        var p = skipString(info, skipString(info, at + 19));
        try f(ctx, .info, p, .line);
        try f(ctx, .info, p + 4, .addr);
        try f(ctx, .info, p + 12, .ranges);
        p += 16;
        while (p < end) {
            const code = info[p];
            p += 1;
            switch (code) {
                0 => {}, // the end of an entry's children
                abbrev_subprogram, abbrev_subprogram_parent => {
                    p = skipString(info, skipString(info, p));
                    try f(ctx, .info, p, .addr);
                    p += 20;
                },
                abbrev_inline, abbrev_inline_parent => {
                    p = skipString(info, p);
                    try f(ctx, .info, p, .addr);
                    p += 24;
                },
                else => unreachable,
            }
        }
        at = end;
    }
    at = 0;
    while (at < line.len) {
        const end = at + 4 + std.mem.readInt(u32, line[at..][0..4], .little);
        var p = at + 12 + std.mem.readInt(u32, line[at + 8 ..][0..4], .little);
        while (p < end) {
            const op = line[p];
            p += 1;
            if (op >= Atom.LineProgram.opcode_base) continue;
            switch (op) {
                0 => {
                    var len: u64 = 0;
                    var shift: u6 = 0;
                    while (true) : (shift += 7) {
                        const b = line[p];
                        p += 1;
                        len |= @as(u64, b & 0x7f) << shift;
                        if (b & 0x80 == 0) break;
                    }
                    if (line[p] == DW.LNE.set_address) try f(ctx, .line, p + 1, .addr);
                    p += @intCast(len);
                },
                DW.LNS.fixed_advance_pc => p += 2,
                else => for (0..standard_opcode_lengths[op - 1]) |_| {
                    while (line[p] & 0x80 != 0) p += 1;
                    p += 1;
                },
            }
        }
        at = end;
    }
}

fn skipString(bytes: []const u8, at: usize) usize {
    return std.mem.indexOfScalarPos(u8, bytes, at, 0).? + 1;
}

pub fn deinit(d: *Dwarf, gpa: Allocator) void {
    d.arena.promote(gpa).deinit();
}

/// Whether there is debug info: an entry whose atom was kept.
pub fn present(d: *const Dwarf) bool {
    return d.units.count() > 0;
}

/// The serially written parts of the sections, as (offset within the
/// section, bytes): each unit's header and the 0 ending its children in
/// .debug_info; .debug_rnglists' header and the end of each unit's list;
/// each unit's line program header in .debug_line; and each unit's set
/// header and terminating tuple in .debug_aranges (dSYMs only: lldb maps
/// addresses to a dSYM's units only through that section, which dsymutil
/// always writes).
pub fn heads(d: *const Dwarf, ctx: anytype, comptime put: anytype) !void {
    const zeros: [aranges_tuple_len]u8 = @splat(0);
    try put(ctx, .ranges, 0, &d.rnglists_header);
    for (d.units.values()) |*u| {
        try put(ctx, .info, u.info_off, u.head);
        try put(ctx, .info, u.info_off + u.info_len - 1, zeros[0..1]);
        try put(ctx, .ranges, u.ranges_off + u.ranges_len - 1, zeros[0..1]);
        try put(ctx, .line, u.line_off, u.line_head);
        try put(ctx, .aranges, u.aranges_off, &u.aranges_head);
        try put(ctx, .aranges, u.aranges_off + u.aranges_len - aranges_tuple_len, &zeros);
    }
}

pub const Section = enum { info, ranges, line, aranges };

/// The subprogram entry's size, with its inlined subroutine entries.
fn subprogramSize(debug: *const Atom.Debug, linkage_name: []const u8) u64 {
    var len: u64 = 1 + debug.name.len + 1 + linkage_name.len + 1 + 8 + 4 + 4 + 4;
    if (debug.inlines.len == 0) return len;
    // The entries with children each end with a 0.
    len += 1;
    for (debug.inlines, 0..) |inl, k| {
        len += 1 + inl.name_len + 1 + 8 + 4 + 4 + 4 + 4;
        len += @intFromBool(hasChildren(debug.inlines, k));
    }
    return len;
}

fn hasChildren(inlines: []const Atom.Debug.Inline, k: usize) bool {
    return k + 1 < inlines.len and inlines[k + 1].parent == k;
}

/// Maps a local file index of `debug` (see `Atom.Debug.files`) to its
/// unit's file table, `unit` being its index in chunk `c`'s units.
const FileMap = struct {
    c: *const Chunk,
    /// The index in the chunk's `files` of each of the entry's local files
    /// after the first (`Chunk.locals`).
    locals: []const u32,
    file: u32,

    fn get(m: FileMap, local: u32) u32 {
        if (local == 0) return m.file;
        return m.c.file_map[m.locals[local - 1]];
    }
};

/// Writes the subprogram entry of the `size`-byte function at `addr`, and
/// its inlined subroutine entries, at the start of `out`, and returns
/// their size.
inline fn writeSubprogram(out: []u8, debug: *const Atom.Debug, linkage_name: []const u8, addr: u64, size: u64, files: FileMap) usize {
    var at: usize = 0;
    out[at] = if (debug.inlines.len == 0) abbrev_subprogram else abbrev_subprogram_parent;
    at += 1;
    @memcpy(out[at..][0..debug.name.len], debug.name);
    out[at + debug.name.len] = 0;
    at += debug.name.len + 1;
    @memcpy(out[at..][0..linkage_name.len], linkage_name);
    out[at + linkage_name.len] = 0;
    at += linkage_name.len + 1;
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
        @memcpy(out[at..][0..inl.name_len], debug.inlineName(inl));
        out[at + inl.name_len] = 0;
        at += inl.name_len + 1;
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
// collects their units and files (`layOutChunk`), a serial step places the
// chunks' parts and builds the units' file tables and headers (`place`),
// and the linker writes each chunk's parts in place (`ChunkWriter`).

pub const chunk_len = 2048;

/// One `chunk_len` run of consecutive debug entries.
pub const Chunk = struct {
    // Filled in by `layOutChunk`.
    /// Entries whose atom's `unwind` is not `none`, and their FDEs' bytes.
    n_frames: u32,
    frame_bytes: u32,
    /// Source files of the chunk's entries, each with its entry's unit, in
    /// first-use order; `file_of` indexes it.
    files: std.ArrayHashMapUnmanaged(FileKey, void, FileKey.Context, true),
    /// Units of the chunk's entries, in first-use order, and the chunk's
    /// part of each.
    units: std.StringArrayHashMapUnmanaged(UnitPart),
    /// The index in `files` of each local file (`Atom.Debug.files`) of the
    /// entries written, in order, so that writing them hashes no path;
    /// `local_starts` has each such entry's start in it.
    locals: std.ArrayList(u32),
    local_starts: std.ArrayList(u32),
    // Filled in by `place`.
    /// FDEs in the chunks before this one, and their bytes.
    frame_base: u32,
    frame_off: u64,
    /// Index of each of `files` in its unit's file table.
    file_map: []u32,

    pub const empty: Chunk = .{ .n_frames = 0, .frame_bytes = 0, .files = .empty, .units = .empty, .locals = .empty, .local_starts = .empty, .frame_base = 0, .frame_off = 0, .file_map = &.{} };

    pub fn deinit(c: *Chunk, gpa: Allocator) void {
        c.files.deinit(gpa);
        c.units.deinit(gpa);
        c.locals.deinit(gpa);
        c.local_starts.deinit(gpa);
    }

    /// Bytes of the chunk's subprogram entries, range lists, line
    /// sequences, and aranges tuples, in all its units.
    pub fn lens(c: *const Chunk) struct { info: u64, ranges: u64, line: u64, aranges: u64 } {
        var info: u64 = 0;
        var line: u64 = 0;
        var runs: u64 = 0;
        for (c.units.values()) |u| {
            info += u.info_len;
            line += u.line_len;
            runs += u.n_runs;
        }
        return .{ .info = info, .ranges = runs * range_len, .line = line, .aranges = runs * aranges_tuple_len };
    }
};

pub const FileKey = struct {
    /// Index in the chunk's units.
    unit: u32,
    path: []const u8,

    pub const Context = struct {
        pub fn hash(_: Context, k: FileKey) u32 {
            return @truncate(std.hash.Wyhash.hash(k.unit, k.path));
        }
        pub fn eql(_: Context, a: FileKey, b: FileKey, _: usize) bool {
            return a.unit == b.unit and std.mem.eql(u8, a.path, b.path);
        }
    };
};

/// A chunk's part of a unit.
pub const UnitPart = struct {
    // Filled in by `layOutChunk`.
    info_len: u64 = 0,
    line_len: u64 = 0,
    /// Runs of consecutive entries of the unit, each one range.
    n_runs: u32 = 0,
    // Filled in by `place`: offsets within .debug_info, .debug_rnglists,
    // .debug_line, and .debug_aranges.
    info_off: u64 = 0,
    ranges_off: u64 = 0,
    line_off: u64 = 0,
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
    c.n_frames = 0;
    c.frame_bytes = 0;
    // Functions from one file, or one unit, usually share its path's bytes,
    // so tables by address save hashing the path for most entries.
    var files_by_addr: ByAddr = .{};
    var units_by_addr: ByAddr = .{};
    var units: UnitCursor = .{};
    for (l.file_of[begin..end], begin..) |*file_of, j| {
        file_of.* = skip;
        const atom = l.input.debugAtom(j);
        if (atom >= l.n_atoms or (j > 0 and l.input.debugAtom(j - 1) >= atom)) {
            return l.fail(task, @min(atom, l.n_atoms), error.InvalidDebugInfo, .{});
        }
        const atom_place = l.places[atom];
        if (atom_place.isDuplicate()) continue;
        if (atom_place.section != text) {
            return l.fail(task, atom, error.InvalidDebugInfo, .{ .atom = l.input.atom(atom).name });
        }
        const debug = l.input.debug(j);
        const d = ref(&debug);
        const unit = units.next(l.gpa, c, &units_by_addr, d.unit) catch return l.fail(task, atom, error.OutOfMemory, .{});
        const file = files_by_addr.get(d.file, unit) orelse index: {
            const gop = c.files.getOrPut(l.gpa, .{ .unit = unit, .path = d.file }) catch return l.fail(task, atom, error.OutOfMemory, .{});
            files_by_addr.put(d.file, unit, @intCast(gop.index));
            break :index @as(u32, @intCast(gop.index));
        };
        c.local_starts.append(l.gpa, @intCast(c.locals.items.len)) catch return l.fail(task, atom, error.OutOfMemory, .{});
        if (d.inlines.len > 0 or d.patches.len > 0 or d.files.len > 0) {
            if (!valid(d, l.input.atom(atom).bytes.len)) return l.fail(task, atom, error.InvalidDebugInfo, .{ .atom = l.input.atom(atom).name });
            var start: usize = 0;
            while (start < d.files.len) {
                const path_end = std.mem.indexOfScalarPos(u8, d.files, start, 0).?;
                const gop = c.files.getOrPut(l.gpa, .{ .unit = unit, .path = d.files[start..path_end] }) catch return l.fail(task, atom, error.OutOfMemory, .{});
                c.locals.append(l.gpa, @intCast(gop.index)) catch return l.fail(task, atom, error.OutOfMemory, .{});
                start = path_end + 1;
            }
        }
        file_of.* = file | unit << file_bits;
        const part = units.part;
        const a = l.input.atom(atom);
        part.info_len += subprogramSize(d, a.name);
        part.line_len += sequenceSize(d);
        part.n_runs += @intFromBool(units.new_run);
        if (a.unwind.kind != .none) {
            c.n_frames += 1;
            c.frame_bytes += fdeSize(a.unwind, a.bytes.len);
        }
    }
}

/// Whether the inline calls and patches of the entry of a `size`-byte
/// function are well formed.
fn valid(d: *const Atom.Debug, size: u64) bool {
    const none = Atom.Debug.Inline.none;
    if (d.inlines.len >= none) return false;
    // Each path is nonempty and ends with a 0 byte.
    if (d.files.len > 0 and d.files[d.files.len - 1] != 0) return false;
    var n_files: usize = 0;
    for (d.files, 0..) |b, i| {
        if (b != 0) continue;
        if (i == 0 or d.files[i - 1] == 0) return false;
        n_files += 1;
    }
    for (d.inlines, 0..) |inl, k| {
        if (inl.file > n_files or inl.low > inl.high or inl.high > size) return false;
        if (inl.name_off > d.inline_names.len or inl.name_len > d.inline_names.len - inl.name_off) return false;
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
                if (d.lines.len - p < set_file_len or readPaddedUleb(d.lines[p + 1 ..][0..3]) > n_files) return false;
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

    inline fn next(u: *UnitCursor, gpa: Allocator, c: *Chunk, by_addr: *ByAddr, unit: []const u8) Allocator.Error!u32 {
        // Consecutive entries' units are usually the same bytes.
        if (u.prev) |prev| if (prev.ptr == unit.ptr and prev.len == unit.len) {
            u.new_run = false;
            return u.index;
        };
        return u.find(gpa, c, by_addr, unit);
    }

    noinline fn find(u: *UnitCursor, gpa: Allocator, c: *Chunk, by_addr: *ByAddr, unit: []const u8) Allocator.Error!u32 {
        const index = by_addr.get(unit, 0) orelse index: {
            const gop = try c.units.getOrPut(gpa, unit);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            by_addr.put(unit, 0, @intCast(gop.index));
            break :index @as(u32, @intCast(gop.index));
        };
        u.new_run = u.prev == null or index != u.index;
        u.prev = unit;
        u.index = index;
        u.part = &c.units.values()[index];
        return index;
    }
};

/// Open addressing from a path's address and length, and a unit, to an
/// index. Holds up to 3/4 of its slots; paths past that are looked up by
/// contents every time.
const ByAddr = struct {
    slots: [1024]Slot = @splat(.{ .ptr = 0, .len = 0, .unit = 0, .index = 0 }),
    count: usize = 0,

    const Slot = struct { ptr: usize, len: usize, unit: u32, index: u32 };

    fn home(path: []const u8) usize {
        return @intCast((@intFromPtr(path.ptr) *% 0x9e3779b97f4a7c15) >> 54);
    }

    fn get(t: *const ByAddr, path: []const u8, unit: u32) ?u32 {
        var i = home(path);
        while (t.slots[i].ptr != 0) : (i = (i + 1) % t.slots.len) {
            const slot = t.slots[i];
            if (slot.ptr == @intFromPtr(path.ptr) and slot.len == path.len and slot.unit == unit) return slot.index;
        }
        return null;
    }

    fn put(t: *ByAddr, path: []const u8, unit: u32, index: u32) void {
        if (t.count >= t.slots.len / 4 * 3) return;
        var i = home(path);
        while (t.slots[i].ptr != 0) i = (i + 1) % t.slots.len;
        t.slots[i] = .{ .ptr = @intFromPtr(path.ptr), .len = path.len, .unit = unit, .index = index };
        t.count += 1;
    }
};

/// Writes one chunk's entries in order: each entry's subprogram entry to
/// its unit's part of `info` and its sequence to its unit's part of `line`,
/// and each run's range to its unit's part of `ranges` and, if not empty,
/// `aranges`. A part is where the chunk's part of a unit goes, in the
/// chunk's unit order; the writer advances them.
pub const ChunkWriter = struct {
    c: *const Chunk,
    info: [][]u8,
    ranges: [][]u8,
    line: [][]u8,
    aranges: [][]u8,
    /// Range offsets are from the units' low_pc.
    text_addr: u64,
    /// The current run's unit, as an index in the chunk's units or
    /// `no_unit`, and the rest of its parts of `info` and `line`.
    k: u32 = no_unit,
    unit_info: []u8 = &.{},
    unit_line: []u8 = &.{},
    run_start: u64 = 0,
    run_end: u64 = 0,
    /// The entries written so far.
    n: u32 = 0,

    /// Writes the entry `debug` of the `size`-byte function at `addr`,
    /// whose file is `file_of` (see `layOutChunk`) and whose symbol is
    /// `linkage_name`.
    pub inline fn entry(w: *ChunkWriter, debug: *const Atom.Debug, linkage_name: []const u8, addr: u64, size: u64, file_of: u32) void {
        const k = file_of >> file_bits;
        if (k != w.k) w.switchUnit(k, addr);
        w.run_end = addr + size;
        const files: FileMap = .{ .c = w.c, .locals = w.c.locals.items[w.c.local_starts.items[w.n]..], .file = w.c.file_map[file_of & (1 << file_bits) - 1] };
        w.n += 1;
        w.unit_info = w.unit_info[writeSubprogram(w.unit_info, debug, linkage_name, addr, size, files)..];
        w.unit_line = w.unit_line[writeSequence(w.unit_line, debug, addr, size, files)..];
    }

    const no_unit = std.math.maxInt(u32);

    fn switchUnit(w: *ChunkWriter, k: u32, addr: u64) void {
        if (w.k != no_unit) w.endRun();
        w.k = k;
        w.unit_info = w.info[k];
        w.unit_line = w.line[k];
        w.run_start = addr;
    }

    pub fn finish(w: *ChunkWriter) void {
        if (w.k != no_unit) w.endRun();
    }

    fn endRun(w: *ChunkWriter) void {
        const k = w.k;
        w.info[k] = w.unit_info;
        w.line[k] = w.unit_line;
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

// Call frame information (.eh_frame and .eh_frame_hdr, x86_64 and
// aarch64). Every
// function with a frame (`Atom.unwind` other than `none`) gets one FDE,
// all sharing the CIE at the start of .eh_frame. An FDE's size depends on
// its unwind record and code size alone (`fdeSize`), so the layout pass
// sizes each chunk's FDEs and the linker places them before writing any.

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

/// aarch64's CIE, of the same size: return address column 30 (lr), and
/// at a function's entry the CFA is sp.
pub const cie_aarch64 = [_]u8{
    20, 0, 0, 0, // length
    0, 0, 0, 0, // CIE id
    1, // version
    'z', 'R', 0, // augmentation
    1, // code alignment factor
    0x78, // data alignment factor: SLEB128 -8
    30, // return address register
    1, // augmentation data length
    pe_pcrel_sdata4, // FDE pointer encoding
    DW.CFA.def_cfa, 31, 0, // CFA = sp
    DW.CFA.nop, DW.CFA.nop, DW.CFA.nop, DW.CFA.nop,
};
// zig fmt: on

/// The CIE of `arch`'s .eh_frame.
pub fn cieOf(arch: Atom.Unwind.Arch) *const [cie.len]u8 {
    return switch (arch) {
        .x86_64 => &cie,
        .aarch64 => &cie_aarch64,
    };
}

/// The size of an FDE with no saved registers in a function under 64 KiB
/// whose code ends with its `ret`; the largest of a function with no code
/// after its `ret` (`Atom.Unwind.epilogue` at most 1); and the largest.
pub const fde_size = 32;
pub const max_short_fde_size = 48;
pub const max_fde_size = 64;

/// The size of the FDE of a `size`-byte function whose `unwind` is not
/// `none`: the frame-pointer program, 3 bytes per saved register, and the
/// epilogue's rows, padded to 8.
pub fn fdeSize(u: Atom.Unwind, size: u64) u32 {
    if (u.kind != .frame_pointer) return fde_size;
    const n: u32 = @popCount(u.saved & Atom.Unwind.savedBits(.x86_64));
    const rows: u32 = if (epilogueRows(u, size)) |e| e.size(n) else 0;
    return std.mem.alignForward(u32, @as(u32, frame_pointer_program.len) + 3 * n + rows, 8);
}

/// Where the rows after the prologue's go in a frame-pointer FDE.
const EpilogueRows = struct {
    /// From the prologue's last row to the epilogue's `ret`, where the CFA
    /// becomes rsp + 8.
    advance: u32,
    /// Frameless stubs follow the `ret`: the rbp and saved registers'
    /// rules revert to the CIE's (DW_CFA_restore), since their slots are
    /// no longer just below rsp.
    stubs: bool,
    /// From the `ret` to the stack probes, which take back the body's
    /// rules (DW_CFA_remember_state at the `ret`, DW_CFA_restore_state
    /// here), or null without probes.
    probes: ?u32,

    fn size(e: EpilogueRows, n_saved: u32) u32 {
        var len = advanceSize(e.advance) + 3;
        if (e.stubs) len += 1 + n_saved;
        if (e.probes) |adv| len += 1 + advanceSize(adv) + 1;
        return len;
    }
};

/// The epilogue's rows of a `size`-byte function (`Atom.Unwind.epilogue`
/// and `probes`), or null without an epilogue or when `size` leaves no
/// room for it.
fn epilogueRows(u: Atom.Unwind, size: u64) ?EpilogueRows {
    if (u.kind != .frame_pointer or u.epilogue == 0 or u.probes >= u.epilogue) return null;
    var end: u64 = 4;
    for (saved_regs, 0..) |r, bit| end += if (u.saved >> @intCast(bit) & 1 != 0) r.push_len else 0;
    // At least `pop rbp` between the prologue and the `ret`.
    if (size < end + 1 + u.epilogue or size > std.math.maxInt(u32)) return null;
    const ret = size - u.epilogue;
    return .{
        .advance = @intCast(ret - end),
        .stubs = u.epilogue - 1 > u.probes,
        .probes = if (u.probes != 0) u.epilogue - u.probes else null,
    };
}

/// Writes the shortest advance_loc that moves `delta` bytes and returns
/// its length.
fn writeAdvance(out: []u8, delta: u32) u32 {
    switch (advanceSize(delta)) {
        1 => out[0] = DW.CFA.advance_loc + @as(u8, @intCast(delta)),
        2 => out[0..2].* = .{ DW.CFA.advance_loc1, @intCast(delta) },
        3 => {
            out[0] = DW.CFA.advance_loc2;
            std.mem.writeInt(u16, out[1..3], @intCast(delta), .little);
        },
        else => {
            out[0] = DW.CFA.advance_loc4;
            std.mem.writeInt(u32, out[1..5], delta, .little);
        },
    }
    return advanceSize(delta);
}

/// The length of the shortest advance_loc that moves `delta` bytes.
fn advanceSize(delta: u32) u32 {
    return if (delta < 64) 1 else if (delta < 1 << 8) 2 else if (delta < 1 << 16) 3 else 5;
}

/// The x86_64 callee-saved registers of `Atom.Unwind.saved`, in push
/// order: DWARF register number and push length.
const saved_regs = [_]struct { dwarf: u8, push_len: u8 }{ .{ .dwarf = 3, .push_len = 1 }, .{ .dwarf = 12, .push_len = 2 }, .{ .dwarf = 13, .push_len = 2 }, .{ .dwarf = 14, .push_len = 2 }, .{ .dwarf = 15, .push_len = 2 } };

/// An FDE for the frame-pointer prologue `push rbp; mov rbp, rsp`, up to
/// its saved registers: after the 1-byte push, the CFA is rsp + 16 with
/// rbp saved at CFA - 16; after the 3-byte mov, the CFA is rbp + 16 for
/// the rest of the function. `writeFde` adds the saved registers, each
/// from the end of its push, and the epilogue's `ret`, where the CFA is
/// rsp + 8 again. At the `ret` the saved registers' rules stay: their
/// slots below rsp keep the values `pop` restored (in the red zone, which
/// signal delivery skips), as in upstream's FDEs. Stubs after the `ret`
/// restore them to the CIE's, and probes after those take back the body's
/// (`EpilogueRows`).
// zig fmt: off
const frame_pointer_program = [_]u8{
    0, 0, 0, 0, // length
    0, 0, 0, 0, // CIE pointer
    0, 0, 0, 0, // pc_begin
    0, 0, 0, 0, // pc_range
    0, // augmentation data length
    DW.CFA.advance_loc + 1,
    DW.CFA.def_cfa_offset, 16, // CFA = rsp + 16
    DW.CFA.offset + 6, 2, // rbp at CFA - 16
    DW.CFA.advance_loc + 3,
    DW.CFA.def_cfa_register, 6, // CFA = rbp + 16
};

/// An FDE for the outermost frame, such as `_start`'s: the CIE's CFA of
/// rsp + 8, and no return address (rip undefined), which tells unwinders
/// that the stack ends here.
const outermost_program = frame_pointer_program[0..17].* ++ [_]u8{
    DW.CFA.undefined, 16, // rip undefined
};
// zig fmt: on

/// aarch64's FDE for the frame record prologue `stp x29, x30, [sp,
/// #-16]!; mov x29, sp`: after the stp, the CFA is sp + 16 with x29 at
/// CFA - 16 and x30 at CFA - 8; after the mov, the CFA is x29 + 16.
// zig fmt: off
const frame_pointer_program_aarch64 = frame_pointer_program[0..17].* ++ [_]u8{
    DW.CFA.advance_loc + 4,
    DW.CFA.def_cfa_offset, 16, // CFA = sp + 16
    DW.CFA.offset + 29, 2, // x29 at CFA - 16
    DW.CFA.offset + 30, 1, // x30 at CFA - 8
    DW.CFA.advance_loc + 4,
    DW.CFA.def_cfa_register, 29, // CFA = x29 + 16
};

/// aarch64's outermost frame: the CIE's CFA, and lr undefined.
const outermost_program_aarch64 = frame_pointer_program[0..17].* ++ [_]u8{
    DW.CFA.undefined, 30, // lr undefined
};
// zig fmt: on

/// Whole FDEs, up to their pointers and range, for the common cases.
const frame_pointer_fde = fdeTemplate(&frame_pointer_program);
const outermost_fde = fdeTemplate(&outermost_program);
const frame_pointer_fde_aarch64 = fdeTemplate(&frame_pointer_program_aarch64);
const outermost_fde_aarch64 = fdeTemplate(&outermost_program_aarch64);

fn fdeTemplate(comptime program: []const u8) [fde_size]u8 {
    var out: [fde_size]u8 = @splat(DW.CFA.nop);
    out[0..program.len].* = program[0..program.len].*;
    std.mem.writeInt(u32, out[0..4], fde_size - 4, .little);
    return out;
}

comptime {
    std.debug.assert(cie.len % 8 == 0 and fdeSize(.frame_pointer, 0) == fde_size and outermost_program.len <= fde_size);
    std.debug.assert(cie_aarch64.len == cie.len and frame_pointer_program_aarch64.len <= fde_size);
    // An epilogue within 64 KiB of the prologue keeps the common size.
    std.debug.assert(fdeSize(.{ .kind = .frame_pointer, .epilogue = 1 }, 1 << 16) == fde_size);
    std.debug.assert(fdeSize(.{ .kind = .frame_pointer, .epilogue = 1, .saved = 0x1f }, std.math.maxInt(u32)) == max_short_fde_size);
    std.debug.assert(fdeSize(.{ .kind = .frame_pointer, .epilogue = std.math.maxInt(u16), .probes = 1, .saved = 0x1f }, std.math.maxInt(u32)) == max_fde_size);
}

/// Writes the FDE at offset `fde_off` of .eh_frame, `fdeSize(u, size)`
/// bytes of `out`, for the `size`-byte function `pc_rel` bytes after the
/// FDE's pc_begin field, whose `unwind` is `u`, not `none`.
///
/// On aarch64 the FDE describes the frame record alone, padded to the
/// size `fdeSize` gives: bs's aarch64 code saves no other registers and
/// records no epilogue yet.
pub fn writeFde(arch: Atom.Unwind.Arch, out: []u8, u: Atom.Unwind, fde_off: u32, pc_rel: i32, size: u32) void {
    if (arch == .aarch64) {
        @memset(out, DW.CFA.nop);
        out[0..fde_size].* = if (u.kind == .outermost) outermost_fde_aarch64 else frame_pointer_fde_aarch64;
        std.mem.writeInt(u32, out[0..4], @intCast(out.len - 4), .little);
    } else switch (u.kind) {
        .none => unreachable,
        .outermost => out[0..fde_size].* = outermost_fde,
        .frame_pointer => {
            const epilogue = epilogueRows(u, size);
            if (u.saved == 0 and epilogue == null) {
                out[0..fde_size].* = frame_pointer_fde;
            } else writeFramePointer(out, u.saved, epilogue);
        },
    }
    std.mem.writeInt(u32, out[4..8], fde_off + 4, .little);
    std.mem.writeInt(i32, out[8..12], pc_rel, .little);
    std.mem.writeInt(u32, out[12..16], size, .little);
}

/// The frame-pointer FDE's program with the `saved` registers, each at
/// CFA - 24 - 8k for the k-th pushed, from the end of its push, then the
/// `epilogue`'s rows: CFA = rsp + 8 from its `ret`, and for the stubs and
/// probes after it, as `EpilogueRows` says.
noinline fn writeFramePointer(out: []u8, saved: u16, epilogue: ?EpilogueRows) void {
    out[0..frame_pointer_program.len].* = frame_pointer_program;
    var at: usize = frame_pointer_program.len;
    var k: u8 = 0;
    for (saved_regs, 0..) |r, bit| if (saved >> @intCast(bit) & 1 != 0) {
        out[at..][0..3].* = .{ DW.CFA.advance_loc + r.push_len, DW.CFA.offset + r.dwarf, 3 + k };
        at += 3;
        k += 1;
    };
    if (epilogue) |e| {
        at += writeAdvance(out[at..], e.advance);
        if (e.probes != null) {
            out[at] = DW.CFA.remember_state;
            at += 1;
        }
        out[at..][0..3].* = .{ DW.CFA.def_cfa, 7, 8 }; // CFA = rsp + 8
        at += 3;
        if (e.stubs) {
            out[at] = DW.CFA.restore + 6; // rbp
            at += 1;
            for (saved_regs, 0..) |r, bit| if (saved >> @intCast(bit) & 1 != 0) {
                out[at] = DW.CFA.restore + r.dwarf;
                at += 1;
            };
        }
        if (e.probes) |adv| {
            at += writeAdvance(out[at..], adv);
            out[at] = DW.CFA.restore_state;
            at += 1;
        }
    }
    @memset(out[at..], DW.CFA.nop);
    std.mem.writeInt(u32, out[0..4], @intCast(out.len - 4), .little);
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
