//! DWARF 5 debug info for the linkers: one compile unit for the whole
//! output, with a subprogram entry and a line-number sequence per
//! `Atom.Debug` entry. Type and variable info come later.
//!
//! The headers depend only on the file table and are built serially; the
//! per-function parts have sizes known from their `Atom.Debug` alone, so
//! threads can write them in place, and a sequence is mostly a copy of the
//! function's own line program fragment (`Atom.Debug.lines`).

const std = @import("std");
const DW = std.dwarf;
const Allocator = std.mem.Allocator;
const Atom = @import("Atom.zig");
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
