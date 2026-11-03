//! DWARF 5 debug info for the linkers: one compile unit for the whole
//! output, with a subprogram entry and a line-number sequence per
//! `Atom.Debug` entry, and x86_64 call frame information for .eh_frame.
//! Type and variable info come later.
//!
//! The headers depend only on the file table and are built serially; the
//! per-function parts have sizes known from their `Atom.Debug` alone, so
//! threads can write them in place, and a sequence is mostly a copy of the
//! function's own line program fragment (`Atom.Debug.lines`).

const std = @import("std");
const DW = std.dwarf;
const Allocator = std.mem.Allocator;
const Atom = @import("Atom.zig");
const ref = @import("Elf.zig").ref;
const Dwarf = @This();

/// The compile unit's header and entry, ending with its low_pc and high_pc.
info_header: []u8 = &.{},
/// The line-number program header, with the file table.
line_header: []u8 = &.{},

/// .debug_str. Names are inline strings, but readers such as std.debug
/// require the section.
pub const str = "zap\x00";

/// Abbreviation codes.
const abbrev_cu = 1;
const abbrev_subprogram = 2;

pub const abbrev = [_]u8{ abbrev_cu, DW.TAG.compile_unit, DW.CHILDREN.yes } ++
    [_]u8{ DW.AT.producer, DW.FORM.strp } ++
    [_]u8{ DW.AT.language, DW.FORM.data2 } ++
    [_]u8{ DW.AT.name, DW.FORM.string } ++
    [_]u8{ DW.AT.comp_dir, DW.FORM.string } ++
    [_]u8{ DW.AT.stmt_list, DW.FORM.sec_offset } ++
    [_]u8{ DW.AT.low_pc, DW.FORM.addr } ++
    [_]u8{ DW.AT.high_pc, DW.FORM.data8 } ++
    [_]u8{ 0, 0 } ++
    [_]u8{ abbrev_subprogram, DW.TAG.subprogram, DW.CHILDREN.no } ++
    [_]u8{ DW.AT.name, DW.FORM.string } ++
    [_]u8{ DW.AT.low_pc, DW.FORM.addr } ++
    [_]u8{ DW.AT.high_pc, DW.FORM.data4 } ++
    [_]u8{ DW.AT.decl_file, DW.FORM.data4 } ++
    [_]u8{ DW.AT.decl_line, DW.FORM.data4 } ++
    [_]u8{ 0, 0 } ++
    [_]u8{0}; // end of the table

/// Builds the headers for `files`, the output's file table in order.
/// `files[0]` names the compile unit.
pub fn init(gpa: Allocator, files: []const []const u8, comp_dir: []const u8) Allocator.Error!Dwarf {
    var info: std.Io.Writer.Allocating = .init(gpa);
    defer info.deinit();
    var line: std.Io.Writer.Allocating = .init(gpa);
    defer line.deinit();
    buildHeaders(gpa, &info.writer, &line.writer, files, comp_dir) catch return error.OutOfMemory;
    var d: Dwarf = .{ .info_header = try info.toOwnedSlice() };
    errdefer gpa.free(d.info_header);
    d.line_header = try line.toOwnedSlice();
    return d;
}

fn buildHeaders(gpa: Allocator, info: *std.Io.Writer, line: *std.Io.Writer, files: []const []const u8, comp_dir: []const u8) !void {
    try info.writeInt(u32, 0, .little); // unit_length, set by finishInfoHeader
    try info.writeInt(u16, 5, .little);
    try info.writeAll(&.{ DW.UT.compile, 8 });
    try info.writeInt(u32, 0, .little); // debug_abbrev_offset
    try info.writeUleb128(abbrev_cu);
    try info.writeInt(u32, 0, .little); // producer, at the start of `str`
    try info.writeInt(u16, DW.LANG.Zig, .little);
    try info.writeAll(files[0]);
    try info.writeByte(0);
    try info.writeAll(comp_dir);
    try info.writeByte(0);
    try info.writeInt(u32, 0, .little); // stmt_list
    try info.splatByteAll(0, 16); // low_pc, high_pc

    try line.writeInt(u32, 0, .little); // unit_length, set by finishLineHeader
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
    gpa.free(d.info_header);
    gpa.free(d.line_header);
}

/// Sets the unit's length (the whole .debug_info, `info_size` bytes) and
/// its address range.
pub fn finishInfoHeader(d: *Dwarf, info_size: u64, low_pc: u64, size: u64) void {
    std.mem.writeInt(u32, d.info_header[0..4], @intCast(info_size - 4), .little);
    const end = d.info_header.len;
    std.mem.writeInt(u64, d.info_header[end - 16 ..][0..8], low_pc, .little);
    std.mem.writeInt(u64, d.info_header[end - 8 ..][0..8], size, .little);
}

/// Sets the line program's length (the whole .debug_line, `line_size` bytes).
pub fn finishLineHeader(d: *Dwarf, line_size: u64) void {
    std.mem.writeInt(u32, d.line_header[0..4], @intCast(line_size - 4), .little);
}

/// .debug_aranges for the compile unit at offset 0 of .debug_info, covering
/// the `size` bytes at `low_pc`: a version 2 set with one range. lldb maps
/// addresses to the units of a dSYM only through this section, which
/// dsymutil always writes.
pub fn aranges(low_pc: u64, size: u64) [aranges_size]u8 {
    var a: [aranges_size]u8 = @splat(0);
    std.mem.writeInt(u32, a[0..4], aranges_size - 4, .little);
    std.mem.writeInt(u16, a[4..6], 2, .little);
    // debug_info_offset 0, then address_size and segment_selector_size,
    // then padding to a multiple of the tuple size.
    a[10] = 8;
    std.mem.writeInt(u64, a[16..24], low_pc, .little);
    std.mem.writeInt(u64, a[24..32], size, .little);
    // A (0, 0) tuple ends the set.
    return a;
}

pub const aranges_size = 48;

pub fn subprogramSize(debug: *const Atom.Debug) u64 {
    return 1 + debug.name.len + 1 + 8 + 4 + 4 + 4;
}

/// Writes the subprogram entry of the `size`-byte function at `addr` at the
/// start of `out`, and returns its size.
pub fn writeSubprogram(out: []u8, debug: *const Atom.Debug, addr: u64, size: u64, file: u32) usize {
    var at: usize = 0;
    out[at] = abbrev_subprogram;
    at += 1;
    @memcpy(out[at..][0..debug.name.len], debug.name);
    out[at + debug.name.len] = 0;
    at += debug.name.len + 1;
    std.mem.writeInt(u64, out[at..][0..8], addr, .little);
    std.mem.writeInt(u32, out[at + 8 ..][0..4], @intCast(size), .little);
    std.mem.writeInt(u32, out[at + 12 ..][0..4], file, .little);
    std.mem.writeInt(u32, out[at + 16 ..][0..4], debug.base_line + 1, .little);
    return at + 20;
}

pub fn sequenceSize(debug: *const Atom.Debug) u64 {
    return set_address_len + set_file_len + 1 + slebLen(debug.base_line) + debug.lines.len + set_address_len + 3;
}

const set_address_len = 11;
/// The file index is a ULEB128 padded to 3 bytes, so that sizes do not
/// depend on the file table.
const set_file_len = 4;

/// Writes the line-number sequence of the `size`-byte function at `addr` at
/// the start of `out`, and returns its size: start at the function with the
/// line registers its fragment expects, copy the fragment, and end the
/// sequence at the end of the function.
pub fn writeSequence(out: []u8, debug: *const Atom.Debug, addr: u64, size: u64, file: u32) usize {
    setAddress(out[0..set_address_len], addr);
    var at: usize = set_address_len;
    out[at..][0..set_file_len].* = .{ DW.LNS.set_file, @as(u8, @truncate(file)) | 0x80, @as(u8, @truncate(file >> 7)) | 0x80, @intCast(file >> 14) };
    at += set_file_len;
    out[at] = DW.LNS.advance_line;
    at += 1;
    at += writeSleb(out[at..], debug.base_line);
    @memcpy(out[at..][0..debug.lines.len], debug.lines);
    at += debug.lines.len;
    setAddress(out[at..][0..set_address_len], addr + size);
    at += set_address_len;
    out[at..][0..3].* = .{ 0, 1, DW.LNE.end_sequence };
    return at + 3;
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
    /// Bytes of the chunk's subprogram entries and line sequences.
    info_len: u64,
    line_len: u64,
    /// Entries with a `frame` other than `none`.
    n_frames: u32,
    /// Source files of the chunk's entries, in first-use order; the
    /// linker's `file_of` indexes it.
    files: std.StringArrayHashMapUnmanaged(void),
    // Filled in by `placeChunks`.
    /// Where the chunk's entries and sequences start, after the headers.
    info_off: u64,
    line_off: u64,
    /// Entries with a frame in the chunks before this one.
    frame_base: u32,
    /// Index in the output's file table of each of `files`.
    file_map: []u32,
};

/// The `file_of` of an entry whose atom was deduplicated away.
pub const skip = std.math.maxInt(u32);

/// Sizes the entries of debug chunk `chunk` and collects their files. `l`
/// is a linker's shared state, with `gpa`, `input`, `n_atoms`, `n_debug`,
/// `places`, `debug_chunks`, `file_of`, and `fail`; `task` is the chunk's
/// failure slot and `text` the linkers' section number of code. The atoms
/// of the entries are checked to ascend and be in range before `debug(j)`
/// reads anything of theirs.
pub fn layOutChunk(l: anytype, chunk: usize, task: usize, text: u3) void {
    const begin = chunk * chunk_len;
    const end = @min(l.n_debug, begin + chunk_len);
    const c = &l.debug_chunks[chunk];
    c.info_len = 0;
    c.line_len = 0;
    c.n_frames = 0;
    // Functions from one file usually share its path's bytes, so a table by
    // address saves hashing the path for most entries.
    var by_addr: FilesByAddr = .{};
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
        file_of.* = by_addr.get(d.file) orelse index: {
            const gop = c.files.getOrPut(l.gpa, d.file) catch return l.fail(task, atom, error.OutOfMemory, .{});
            by_addr.put(d.file, @intCast(gop.index));
            break :index @intCast(gop.index);
        };
        c.info_len += subprogramSize(d);
        c.line_len += sequenceSize(d);
        c.n_frames += @intFromBool(d.frame != .none);
    }
}

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

/// The chunks' totals and the output's file table.
pub const Placed = struct {
    info_len: u64 = 0,
    line_len: u64 = 0,
    n_frames: u32 = 0,
    /// The output's file table, from the chunks' files in first-use order.
    files: std.StringArrayHashMapUnmanaged(void) = .empty,
    file_map: []u32 = &.{},

    pub fn deinit(p: *Placed, gpa: Allocator) void {
        p.files.deinit(gpa);
        gpa.free(p.file_map);
    }
};

/// Places the chunks after one another and builds the file table.
pub fn placeChunks(gpa: Allocator, chunks: []Chunk) error{OutOfMemory}!Placed {
    var p: Placed = .{};
    errdefer p.deinit(gpa);
    var n_chunk_files: usize = 0;
    for (chunks) |*c| {
        c.info_off = p.info_len;
        c.line_off = p.line_len;
        c.frame_base = p.n_frames;
        p.info_len += c.info_len;
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
    if (p.files.count() >= 1 << 21) return error.OutOfMemory;
    return p;
}

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
