//! Mach-O relocatable objects and archives as link inputs (aarch64-macos;
//! "Mach-O object and archive inputs" in docs/slop/architecture.md). The
//! counterpart of `ElfInput`, with the same entry points, so the caller's
//! resolution order is the same: the compilation's exports, then the
//! objects, then compiler_rt, then libSystem's imports.
//!
//! Each section becomes one atom, except literal sections, whose entries
//! are content-addressed atoms that merge across objects, and
//! thread-local templates, which split at their symbols so that each
//! thread-local is an atom of its own for the writer's descriptors.
//! Names lose Darwin's leading underscore on reading: atom and import
//! names are platform-neutral, and the writer adds it back.

const std = @import("std");
const macho = std.macho;
const Allocator = std.mem.Allocator;
const Atom = @import("Atom.zig");
const SymbolKey = Atom.SymbolKey;
const Archive = @import("Archive.zig");
const Elf = @import("Elf.zig");
const ElfDynamic = @import("ElfDynamic.zig");

const Inputs = @This();

arena: Allocator,
objects: std.ArrayList(Object) = .empty,
archives: std.ArrayList(ArchiveInput) = .empty,
/// Each external name the loaded objects define, strong over weak, else
/// the first in input order.
defs: std.StringHashMapUnmanaged(Def) = .empty,
/// COMMON symbols: the largest size and alignment of each name.
commons: std.StringArrayHashMapUnmanaged(Common) = .empty,
/// Names the loaded objects reference without defining, in first-use
/// order.
undefs: std.StringArrayHashMapUnmanaged(void) = .empty,
/// Problems found while loading, as messages for the caller to report.
errors: std.ArrayList([]const u8) = .empty,

pub const Def = struct { object: u32, sym: u32, weak: bool };
pub const Common = struct { size: u64, alignment: u64 };

const ArchiveInput = struct {
    path: []const u8,
    reader: Archive.Reader,
    pulled: std.AutoHashMapUnmanaged(u64, void) = .empty,
};

pub const Error = error{ OutOfMemory, InvalidObject, InvalidArchive, ThinArchive };

/// `nlist_64`, read as plain fields.
pub const Sym = extern struct {
    n_strx: u32,
    n_type: u8,
    n_sect: u8,
    n_desc: u16,
    n_value: u64 align(4),

    fn kind(s: Sym) u8 {
        return s.n_type & macho.N_TYPE;
    }
    fn isExternal(s: Sym) bool {
        return s.n_type & macho.N_EXT != 0;
    }
    fn isStab(s: Sym) bool {
        return s.n_type & macho.N_STAB != 0;
    }
};

const n_weak_def: u16 = 0x80;
const n_weak_ref: u16 = 0x40;

/// `relocation_info`, read as plain fields.
const Reloc = struct {
    address: u32,
    symbolnum: u24,
    pcrel: bool,
    length: u2,
    external: bool,
    type: u4,

    fn read(bytes: *const [8]u8) Reloc {
        const a = std.mem.readInt(u32, bytes[0..4], .little);
        const w = std.mem.readInt(u32, bytes[4..8], .little);
        return .{
            .address = a,
            .symbolnum = @truncate(w),
            .pcrel = (w >> 24) & 1 != 0,
            .length = @truncate(w >> 25),
            .external = (w >> 27) & 1 != 0,
            .type = @truncate(w >> 28),
        };
    }
};

const R = macho.reloc_type_arm64;

/// One object, read in place.
pub const Object = struct {
    /// As errors name it: the path, or `archive(member)`.
    path: []const u8,
    bytes: []const u8,
    /// Of the contents, for the atoms' keys.
    hash: u64,
    /// Index 0 is unused: section ordinals start at 1.
    sects: []macho.section_64,
    keys: []SymbolKey,
    /// Per section: a literal section's entries, or a thread-local
    /// template's pieces between its symbols, in order; else empty.
    pieces: []const []const Piece,
    syms: []align(1) const Sym,
    strtab: []const u8,
    /// Per section: the targets of a `__thread_vars` section's descriptors
    /// (their initial values' places), by descriptor; else empty.
    tlv_inits: []const []const ?Target,

    pub fn symName(o: *const Object, sym: Sym) []const u8 {
        if (sym.n_strx >= o.strtab.len) return "";
        return std.mem.sliceTo(o.strtab[sym.n_strx..], 0);
    }

    /// An external symbol's name, without Darwin's leading underscore.
    pub fn linkName(o: *const Object, sym: Sym) []const u8 {
        const n = o.symName(sym);
        return if (n.len > 0 and n[0] == '_') n[1..] else n;
    }

    pub fn sectionBytes(o: *const Object, index: usize) []const u8 {
        const s = o.sects[index];
        if (isZeroFill(s)) return &.{};
        return o.bytes[s.offset..][0..@intCast(s.size)];
    }
};

const Piece = struct { start: u64, end: u64, key: SymbolKey };

fn sectionType(s: macho.section_64) u8 {
    return @truncate(s.flags & macho.SECTION_TYPE);
}

fn isZeroFill(s: macho.section_64) bool {
    return switch (sectionType(s)) {
        macho.S_ZEROFILL, macho.S_GB_ZEROFILL, macho.S_THREAD_LOCAL_ZEROFILL => true,
        else => false,
    };
}

fn name16(n: *const [16]u8) []const u8 {
    return std.mem.sliceTo(n, 0);
}

/// The arm64 slice of a universal file, or the file itself.
fn thinSlice(bytes: []const u8) Error![]const u8 {
    if (bytes.len < 8 or std.mem.readInt(u32, bytes[0..4], .big) != macho.FAT_MAGIC) return bytes;
    const n = std.mem.readInt(u32, bytes[4..8], .big);
    for (0..n) |i| {
        const at = 8 + i * @sizeOf(macho.fat_arch);
        if (at + @sizeOf(macho.fat_arch) > bytes.len) return error.InvalidObject;
        const cpu = std.mem.readInt(i32, bytes[at..][0..4], .big);
        const off = std.mem.readInt(u32, bytes[at + 8 ..][0..4], .big);
        const size = std.mem.readInt(u32, bytes[at + 12 ..][0..4], .big);
        if (cpu != macho.CPU_TYPE_ARM64) continue;
        if (@as(u64, off) + size > bytes.len) return error.InvalidObject;
        return bytes[off..][0..size];
    }
    return error.InvalidObject;
}

/// Whether Mach-O object `file` references, without defining, a symbol
/// whose name, without its leading underscore, starts with `prefix`; true
/// if it does not parse.
pub fn referencesUndefined(arena: Allocator, file: []const u8, prefix: []const u8) Allocator.Error!bool {
    const o = parseObject(arena, "", file) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return true,
    };
    for (o.syms) |sym| {
        if (sym.isStab() or !sym.isExternal() or sym.kind() != macho.N_UNDF or sym.n_value != 0) continue;
        if (std.mem.startsWith(u8, o.linkName(sym), prefix)) return true;
    }
    return false;
}

pub fn parseObject(arena: Allocator, path: []const u8, file: []const u8) Error!Object {
    const bytes = try thinSlice(file);
    if (bytes.len < @sizeOf(macho.mach_header_64)) return error.InvalidObject;
    const mh = std.mem.bytesToValue(macho.mach_header_64, bytes[0..@sizeOf(macho.mach_header_64)]);
    if (mh.magic != macho.MH_MAGIC_64 or mh.cputype != macho.CPU_TYPE_ARM64 or mh.filetype != macho.MH_OBJECT) return error.InvalidObject;
    var sects: std.ArrayList(macho.section_64) = .empty;
    try sects.append(arena, std.mem.zeroes(macho.section_64));
    var syms: []align(1) const Sym = &.{};
    var strtab: []const u8 = "";
    var off: usize = @sizeOf(macho.mach_header_64);
    for (0..mh.ncmds) |_| {
        if (off + 8 > bytes.len) return error.InvalidObject;
        const cmd = std.mem.readInt(u32, bytes[off..][0..4], .little);
        const size = std.mem.readInt(u32, bytes[off + 4 ..][0..4], .little);
        if (size < 8 or size > bytes.len - off) return error.InvalidObject;
        if (cmd == @backingInt(macho.LC.SEGMENT_64)) {
            if (size < @sizeOf(macho.segment_command_64)) return error.InvalidObject;
            const seg = std.mem.bytesToValue(macho.segment_command_64, bytes[off..][0..@sizeOf(macho.segment_command_64)]);
            if (@sizeOf(macho.segment_command_64) + @as(u64, seg.nsects) * @sizeOf(macho.section_64) > size) return error.InvalidObject;
            for (0..seg.nsects) |k| {
                const at = off + @sizeOf(macho.segment_command_64) + k * @sizeOf(macho.section_64);
                const s = std.mem.bytesToValue(macho.section_64, bytes[at..][0..@sizeOf(macho.section_64)]);
                if (!isZeroFill(s) and @as(u64, s.offset) + s.size > bytes.len) return error.InvalidObject;
                if (@as(u64, s.reloff) + @as(u64, s.nreloc) * 8 > bytes.len) return error.InvalidObject;
                try sects.append(arena, s);
            }
        } else if (cmd == @backingInt(macho.LC.SYMTAB)) {
            const st = std.mem.bytesToValue(macho.symtab_command, bytes[off..][0..@sizeOf(macho.symtab_command)]);
            if (@as(u64, st.symoff) + @as(u64, st.nsyms) * @sizeOf(Sym) > bytes.len or @as(u64, st.stroff) + st.strsize > bytes.len) return error.InvalidObject;
            syms = std.mem.bytesAsSlice(Sym, bytes[st.symoff..][0 .. @as(usize, st.nsyms) * @sizeOf(Sym)]);
            strtab = bytes[st.stroff..][0..st.strsize];
        }
        off += size;
    }
    for (syms) |s| if (!s.isStab() and s.kind() == macho.N_SECT and (s.n_sect == 0 or s.n_sect >= sects.items.len)) return error.InvalidObject;
    var o: Object = .{
        .path = path,
        .bytes = bytes,
        .hash = std.hash.Wyhash.hash(0, bytes),
        .sects = sects.items,
        .keys = try arena.alloc(SymbolKey, sects.items.len),
        .pieces = &.{},
        .syms = syms,
        .strtab = strtab,
        .tlv_inits = &.{},
    };
    for (o.keys, 0..) |*k, i| {
        var buf: [64]u8 = undefined;
        k.* = .fromName(std.fmt.bufPrint(&buf, "mobj:{x:0>16}:{d}", .{ o.hash, i }) catch unreachable);
    }
    const pieces = try arena.alloc([]const Piece, sects.items.len);
    for (pieces, o.sects, 0..) |*p, s, i| {
        p.* = &.{};
        if (i == 0) continue;
        const kind = sectionOf(&o, i) orelse continue;
        var list: std.ArrayList(Piece) = .empty;
        switch (sectionType(s)) {
            macho.S_CSTRING_LITERALS, macho.S_4BYTE_LITERALS, macho.S_8BYTE_LITERALS, macho.S_16BYTE_LITERALS => {
                const b = o.sectionBytes(i);
                const entsize: u64 = switch (sectionType(s)) {
                    macho.S_4BYTE_LITERALS => 4,
                    macho.S_8BYTE_LITERALS => 8,
                    macho.S_16BYTE_LITERALS => 16,
                    else => 0,
                };
                var at: u64 = 0;
                while (at < b.len) {
                    var end = at + entsize;
                    if (entsize == 0) end = if (std.mem.indexOfScalarPos(u8, b, @intCast(at), 0)) |z| z + 1 else b.len;
                    end = @min(end, b.len);
                    try list.append(arena, .{ .start = at, .end = end, .key = .fromContents(kind, sectionAlignment(s), b[@intCast(at)..@intCast(end)], &.{}, &.{}) });
                    at = end;
                }
            },
            macho.S_THREAD_LOCAL_REGULAR, macho.S_THREAD_LOCAL_ZEROFILL => {
                // Split at each symbol's place.
                var starts: std.ArrayList(u64) = .empty;
                try starts.append(arena, 0);
                for (syms) |sym| if (!sym.isStab() and sym.kind() == macho.N_SECT and sym.n_sect == i) {
                    if (sym.n_value < s.addr or sym.n_value - s.addr >= s.size) continue;
                    try starts.append(arena, sym.n_value - s.addr);
                };
                std.mem.sortUnstable(u64, starts.items, {}, std.sort.asc(u64));
                for (starts.items, 0..) |start, k| {
                    if (k > 0 and starts.items[k - 1] == start) continue;
                    var end: u64 = s.size;
                    for (starts.items[k + 1 ..]) |n| if (n != start) {
                        end = n;
                        break;
                    };
                    var buf: [64]u8 = undefined;
                    try list.append(arena, .{ .start = start, .end = end, .key = .fromName(std.fmt.bufPrint(&buf, "mobj:{x:0>16}:{d}:{d}", .{ o.hash, i, start }) catch unreachable) });
                }
            },
            else => {},
        }
        p.* = list.items;
    }
    o.pieces = pieces;
    return o;
}

/// Adds an object given on the command line.
pub fn addObject(in: *Inputs, path: []const u8, bytes: []const u8) Error!void {
    try in.load(try parseObject(in.arena, path, bytes));
}

/// Adds an archive, whose members load when they define a name the
/// inputs or the caller need (`pull`).
pub fn addArchive(in: *Inputs, path: []const u8, bytes: []const u8) Error!void {
    try in.archives.append(in.arena, .{ .path = path, .reader = try .init(in.arena, bytes) });
}

fn load(in: *Inputs, o: Object) Error!void {
    const index: u32 = @intCast(in.objects.items.len);
    try in.objects.append(in.arena, o);
    const obj = &in.objects.items[index];
    for (obj.syms, 0..) |sym, s| {
        if (sym.isStab() or !sym.isExternal()) continue;
        const name = obj.linkName(sym);
        switch (sym.kind()) {
            macho.N_UNDF => {
                if (sym.n_value != 0) {
                    const gop = try in.commons.getOrPut(in.arena, name);
                    if (!gop.found_existing) gop.value_ptr.* = .{ .size = 0, .alignment = 1 };
                    gop.value_ptr.size = @max(gop.value_ptr.size, sym.n_value);
                    gop.value_ptr.alignment = @max(gop.value_ptr.alignment, @as(u64, 1) << @intCast((sym.n_desc >> 8) & 0xf));
                } else if (!in.defs.contains(name)) try in.undefs.put(in.arena, name, {});
                continue;
            },
            macho.N_SECT, macho.N_ABS => {},
            else => {
                try in.errors.append(in.arena, try std.fmt.allocPrint(in.arena, "{s}: symbol '{s}' has a type bs does not link ({x})", .{ obj.path, name, sym.n_type }));
                continue;
            },
        }
        const weak = sym.n_desc & n_weak_def != 0;
        const gop = try in.defs.getOrPut(in.arena, name);
        if (gop.found_existing) {
            const prev = gop.value_ptr.*;
            if (!prev.weak and !weak) {
                try in.errors.append(in.arena, try std.fmt.allocPrint(in.arena, "duplicate symbol: {s}, defined in {s} and {s}", .{ name, in.objects.items[prev.object].path, obj.path }));
            } else if (prev.weak and !weak) gop.value_ptr.* = .{ .object = index, .sym = @intCast(s), .weak = false };
            continue;
        }
        gop.value_ptr.* = .{ .object = index, .sym = @intCast(s), .weak = weak };
    }
    try in.readTlvs(obj);
}

/// Records where each of `o`'s thread-local descriptors' initial values
/// are: the descriptor's symbol resolves there, since the writer makes
/// its own descriptors.
fn readTlvs(in: *Inputs, o: *Object) Error!void {
    const inits = try in.arena.alloc([]const ?Target, o.sects.len);
    for (inits, o.sects, 0..) |*t, s, i| {
        t.* = &.{};
        if (i == 0 or sectionType(s) != macho.S_THREAD_LOCAL_VARIABLES) continue;
        const list = try in.arena.alloc(?Target, @intCast(s.size / 24));
        @memset(list, null);
        const relocs = o.bytes[s.reloff..][0 .. @as(usize, s.nreloc) * 8];
        for (0..s.nreloc) |k| {
            const r = Reloc.read(relocs[k * 8 ..][0..8]);
            if (r.address % 24 != 16 or r.type != @backingInt(R.ARM64_RELOC_UNSIGNED) or !r.external or r.address / 24 >= list.len) continue;
            if (r.symbolnum >= o.syms.len) return error.InvalidObject;
            const sym = o.syms[r.symbolnum];
            if (sym.kind() != macho.N_SECT) continue;
            list[r.address / 24] = localTarget(o, sym.n_sect, sym.n_value);
        }
        t.* = list;
    }
    o.tlv_inits = inits;
}

/// Pulls the archive members that define a name the loaded objects or
/// `wanted` need and nothing defines yet, until nothing changes (see
/// `ElfInput.pull`). Returns the index of the first object it loaded.
pub fn pull(in: *Inputs, wanted: []const []const u8, ctx: anytype) !usize {
    const first = in.objects.items.len;
    for (wanted) |name| if (!in.defs.contains(name)) try in.undefs.put(in.arena, name, {});
    var changed = true;
    while (changed) {
        changed = false;
        for (in.archives.items) |*ar| for (ar.reader.symbols) |sym| {
            const name = if (sym.name.len > 0 and sym.name[0] == '_') sym.name[1..] else sym.name;
            if (!in.undefs.contains(name) or in.defs.contains(name) or in.commons.contains(name)) continue;
            if (try ctx.zigExport(name) != null) continue;
            if ((try ar.pulled.getOrPut(in.arena, sym.member)).found_existing) continue;
            const m = try ar.reader.member(sym.member);
            const path = try std.fmt.allocPrint(in.arena, "{s}({s})", .{ ar.path, m.name });
            try in.load(parseObject(in.arena, path, m.bytes) catch |err| switch (err) {
                error.InvalidObject => {
                    try in.errors.append(in.arena, try std.fmt.allocPrint(in.arena, "{s}: not an arm64 Mach-O relocatable object", .{path}));
                    continue;
                },
                else => |e| return e,
            });
            changed = true;
        };
    }
    return first;
}

/// The names objects `first..` reference that neither the objects nor
/// COMMON define, for the caller to request from compiler_rt.
pub fn undefinedSince(in: *const Inputs, first: usize, out: *std.ArrayList([]const u8), gpa: Allocator) Allocator.Error!void {
    for (in.objects.items[first..]) |*o| for (o.syms) |sym| {
        if (sym.isStab() or !sym.isExternal() or sym.kind() != macho.N_UNDF or sym.n_value != 0) continue;
        const name = o.linkName(sym);
        if (in.defs.contains(name) or in.commons.contains(name)) continue;
        try out.append(gpa, name);
    };
}

/// Where a name resolves: an atom key and an offset in that atom.
pub const Target = struct {
    key: SymbolKey,
    offset: u64,
    /// A libSystem symbol (`ctx.importSym`).
    import: bool = false,
};

/// The definition objects give `name`, or null.
pub fn lookup(in: *Inputs, name: []const u8) Allocator.Error!?Target {
    if (in.defs.get(name)) |d| {
        const o = &in.objects.items[d.object];
        const sym = o.syms[d.sym];
        if (sym.kind() != macho.N_SECT) return null;
        return symTarget(o, sym);
    }
    if (in.commons.contains(name)) return .{ .key = commonKey(name), .offset = 0 };
    return null;
}

/// The objects' external definitions a dylib exports, sorted by name:
/// every N_EXT symbol but private externals (N_PEXT) and the names
/// `skip.zigExport` claims, and the COMMON symbols, as ld64 exports them.
pub fn dynamicExports(in: *Inputs, skip: anytype) ![]ElfDynamic.Export {
    var out: std.ArrayList(ElfDynamic.Export) = .empty;
    var it = in.defs.iterator();
    while (it.next()) |d| {
        const name = d.key_ptr.*;
        if (try skip.zigExport(name) != null) continue;
        const o = &in.objects.items[d.value_ptr.object];
        const sym = o.syms[d.value_ptr.sym];
        if (sym.kind() != macho.N_SECT or sym.n_type & macho.N_PEXT != 0) continue;
        const t = symTarget(o, sym) orelse continue;
        try out.append(in.arena, .{ .key = t.key, .name = name, .offset = t.offset, .weak = d.value_ptr.weak });
    }
    for (in.commons.keys()) |name| {
        if (in.defs.contains(name) or try skip.zigExport(name) != null) continue;
        try out.append(in.arena, .{ .key = commonKey(name), .name = name });
    }
    std.mem.sortUnstable(ElfDynamic.Export, out.items, {}, struct {
        fn lt(_: void, a: ElfDynamic.Export, b: ElfDynamic.Export) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
    return out.items;
}

fn commonKey(name: []const u8) SymbolKey {
    var buf: [256]u8 = undefined;
    return .fromName(std.fmt.bufPrint(&buf, "common.{s}", .{name}) catch name);
}

/// Where defined symbol `sym` points: a thread-local descriptor's symbol
/// at its initial value.
fn symTarget(o: *const Object, sym: Sym) ?Target {
    const s = o.sects[sym.n_sect];
    if (sectionType(s) == macho.S_THREAD_LOCAL_VARIABLES) {
        const k = (sym.n_value -% s.addr) / 24;
        const inits = o.tlv_inits[sym.n_sect];
        return if (k < inits.len) inits[@intCast(k)] else null;
    }
    return localTarget(o, sym.n_sect, sym.n_value);
}

/// The atom and offset at address `addr` of section `index`, in the
/// object's own addresses, or null if it lies in no atom.
fn localTarget(o: *const Object, index: usize, addr: u64) ?Target {
    if (index == 0 or index >= o.sects.len) return null;
    const s = o.sects[index];
    const at = addr -% s.addr;
    if (at > s.size) return null;
    const pieces = o.pieces[index];
    if (pieces.len == 0) return .{ .key = o.keys[index], .offset = at };
    var lo: usize = 0;
    var hi: usize = pieces.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (pieces[mid].end <= at) lo = mid + 1 else hi = mid;
    }
    if (lo == pieces.len) {
        // The end of the section.
        if (at == s.size and pieces.len > 0) return .{ .key = pieces[pieces.len - 1].key, .offset = at - pieces[pieces.len - 1].start };
        return null;
    }
    return .{ .key = pieces[lo].key, .offset = at - pieces[lo].start };
}

pub const undefined_weak_key: SymbolKey = .fromName("mobj:undefined-weak");

fn sectionAlignment(s: macho.section_64) std.mem.Alignment {
    return .fromByteUnits(@as(u64, 1) << @intCast(@min(s.@"align", 15)));
}

/// The `Atom.Section` a section's atoms go to, or null for one the link
/// drops: debug info, unwind tables (stage A2), descriptors, and
/// toolchain metadata.
fn sectionOf(o: *const Object, index: usize) ?Atom.Section {
    const s = o.sects[index];
    const seg = name16(&s.segname);
    const sect = name16(&s.sectname);
    if (s.flags & macho.S_ATTR_DEBUG != 0 or std.mem.eql(u8, seg, "__DWARF") or std.mem.eql(u8, seg, "__LD") or std.mem.eql(u8, seg, "__LLVM")) return null;
    if (std.mem.eql(u8, sect, "__eh_frame") or std.mem.eql(u8, sect, "__llvm_addrsig")) return null;
    return switch (sectionType(s)) {
        macho.S_ZEROFILL, macho.S_GB_ZEROFILL => .bss,
        macho.S_CSTRING_LITERALS, macho.S_4BYTE_LITERALS, macho.S_8BYTE_LITERALS, macho.S_16BYTE_LITERALS => .rodata,
        macho.S_MOD_INIT_FUNC_POINTERS => .init_array,
        macho.S_THREAD_LOCAL_REGULAR => .tdata,
        macho.S_THREAD_LOCAL_ZEROFILL => .tbss,
        macho.S_THREAD_LOCAL_VARIABLES => null,
        else => if (s.flags & (macho.S_ATTR_PURE_INSTRUCTIONS | macho.S_ATTR_SOME_INSTRUCTIONS) != 0)
            .text
        else if (std.mem.eql(u8, seg, "__TEXT") or std.mem.eql(u8, seg, "__DATA_CONST") or std.mem.eql(u8, sect, "__const"))
            .rodata
        else
            .data,
    };
}

/// The section types and names bs does not link, with why.
fn unsupportedSection(s: macho.section_64) ?[]const u8 {
    const sect = name16(&s.sectname);
    if (std.mem.startsWith(u8, sect, "__objc_") or std.mem.eql(u8, sect, "__cfstring")) return "Objective-C";
    return switch (sectionType(s)) {
        macho.S_MOD_TERM_FUNC_POINTERS => "termination functions (ld64 rejects them too)",
        macho.S_THREAD_LOCAL_VARIABLE_POINTERS, macho.S_THREAD_LOCAL_INIT_FUNCTION_POINTERS => "thread-local pointers or initializers",
        macho.S_INIT_FUNC_OFFSETS => "initializer offsets",
        macho.S_SYMBOL_STUBS, macho.S_LAZY_SYMBOL_POINTERS, macho.S_NON_LAZY_SYMBOL_POINTERS, macho.S_LAZY_DYLIB_SYMBOL_POINTERS => "linker-made stubs or pointers",
        else => null,
    };
}

/// The atoms of the loaded objects, and the link-time values they use.
pub const Converted = struct {
    atoms: []const Atom,
    values: []const Elf.Value,
    /// The objects' functions and objects within their sections' atoms,
    /// for the symbol table, except those that name their atom.
    symbols: []const Elf.LocalSymbol,
};

/// Converts every loaded object into atoms. `ctx` resolves what the
/// objects leave undefined, as for `ElfInput.convert`:
/// `zigExport(name) !?SymbolKey`, `rtExport(name) !?SymbolKey` and
/// `importSym(name, weak) !?SymbolKey` (libSystem). Undefined strong
/// names and unsupported relocations go to `errors`.
pub fn convert(in: *Inputs, ctx: anytype) !Converted {
    const arena = in.arena;
    var atoms: std.ArrayList(Atom) = .empty;
    var values: std.ArrayList(Elf.Value) = .empty;
    var symbols: std.ArrayList(Elf.LocalSymbol) = .empty;
    var weak_used = false;
    var c: Converter(@TypeOf(ctx)) = .{ .in = in, .ctx = ctx, .atoms = &atoms, .weak_used = &weak_used };
    var defs = in.defs.iterator();
    while (defs.next()) |d| if (!d.value_ptr.weak) if (try ctx.zigExport(d.key_ptr.*) != null) {
        try in.errors.append(arena, try std.fmt.allocPrint(arena, "duplicate symbol: {s}, defined by the Zig code and in {s}", .{ d.key_ptr.*, in.objects.items[d.value_ptr.object].path }));
    };
    for (in.objects.items) |*o| {
        c.o = o;
        for (1..o.sects.len) |i| try c.section(@intCast(i));
        // Named places inside atoms, for the symbol table: functions and
        // objects, static ones too, but not the assembler's labels
        // (`ltmp0`, `l_.str`), which C names never start with, since
        // they get Darwin's underscore.
        for (o.syms) |sym| {
            if (sym.isStab() or sym.kind() != macho.N_SECT) continue;
            const raw = o.symName(sym);
            if (raw.len == 0 or raw[0] == 'l' or raw[0] == 'L') continue;
            const kind = sectionOf(o, sym.n_sect) orelse continue;
            if (kind == .tdata or kind == .tbss or o.pieces[sym.n_sect].len != 0) continue;
            const t = localTarget(o, sym.n_sect, sym.n_value) orelse continue;
            if (t.offset == 0 and std.mem.eql(u8, c.atomName(sym.n_sect), o.linkName(sym))) continue;
            try symbols.append(arena, .{ .name = o.linkName(sym), .atom = t.key, .offset = t.offset, .size = 0 });
        }
    }
    for (in.commons.keys(), in.commons.values()) |name, common| {
        if (in.defs.contains(name)) continue;
        try atoms.append(arena, .{
            .key = commonKey(name),
            .name = name,
            .section = .bss,
            .alignment = .fromByteUnits(std.math.ceilPowerOfTwoAssert(u64, @max(1, common.alignment))),
            .zero_fill = common.size,
        });
    }
    try c.reportUndefined();
    if (weak_used) try values.append(arena, .{ .key = undefined_weak_key, .value = 0 });
    try values.appendSlice(arena, c.abs_values.items);
    return .{ .atoms = atoms.items, .values = values.items, .symbols = symbols.items };
}

fn Converter(comptime Ctx: type) type {
    return struct {
        in: *Inputs,
        ctx: Ctx,
        o: *const Object = undefined,
        atoms: *std.ArrayList(Atom),
        weak_used: *bool,
        abs_values: std.ArrayList(Elf.Value) = .empty,
        /// How each external name the objects reference resolved.
        resolved: std.StringHashMapUnmanaged(?Target) = .empty,
        /// The strong names nothing defines, each with the objects that
        /// reference it, in input order, for one error per name.
        undefs: std.StringArrayHashMapUnmanaged(std.ArrayList([]const u8)) = .empty,

        const C = @This();

        fn undefinedSymbol(c: *C, name: []const u8) Allocator.Error!void {
            const gop = try c.undefs.getOrPut(c.in.arena, name);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            const objects = gop.value_ptr;
            // Objects convert one at a time, so a repeat is the last one.
            if (objects.items.len == 0 or objects.items[objects.items.len - 1].ptr != c.o.path.ptr) try objects.append(c.in.arena, c.o.path);
        }

        /// Reports `undefs` as `ElfInput` does.
        fn reportUndefined(c: *C) Allocator.Error!void {
            const max_listed = 8;
            for (c.undefs.keys(), c.undefs.values()) |name, objects| {
                var msg: std.ArrayList(u8) = .empty;
                try msg.print(c.in.arena, "undefined symbol: {s} (referenced by ", .{name});
                for (objects.items[0..@min(objects.items.len, max_listed)], 0..) |path, i| {
                    if (i != 0) try msg.appendSlice(c.in.arena, ", ");
                    try msg.appendSlice(c.in.arena, path);
                }
                if (objects.items.len > max_listed) try msg.print(c.in.arena, " and {d} more objects", .{objects.items.len - max_listed});
                try msg.append(c.in.arena, ')');
                try c.in.errors.append(c.in.arena, msg.items);
            }
        }

        /// A converted relocation, at an offset in its section.
        const Rel = struct { offset: u64, kind: Atom.Reloc.Kind, target: Target, addend: i64 };

        fn fail(c: *C, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
            try c.in.errors.append(c.in.arena, try std.fmt.allocPrint(c.in.arena, fmt, args));
        }

        fn sectName(c: *C, index: usize) []const u8 {
            const s = &c.o.sects[index];
            return std.fmt.allocPrint(c.in.arena, "{s},{s}", .{ name16(&s.segname), name16(&s.sectname) }) catch "?";
        }

        fn section(c: *C, index: u32) !void {
            const o = c.o;
            const s = o.sects[index];
            if (unsupportedSection(s)) |why| return c.fail("{s}: bs does not link section '{s}' ({s})", .{ o.path, c.sectName(index), why });
            const kind = sectionOf(o, index) orelse return;
            const literal = switch (sectionType(s)) {
                macho.S_CSTRING_LITERALS, macho.S_4BYTE_LITERALS, macho.S_8BYTE_LITERALS, macho.S_16BYTE_LITERALS => true,
                else => false,
            };
            var bytes = o.sectionBytes(index);
            var rels: std.ArrayList(Rel) = .empty;
            if (s.nreloc != 0) {
                if (literal) return c.fail("{s}: relocations in literal section '{s}' are not supported", .{ o.path, c.sectName(index) });
                var copy: ?[]u8 = null;
                try c.relocs(index, bytes, &copy, &rels);
                if (copy) |b| bytes = b;
            }
            const pieces = o.pieces[index];
            if (pieces.len == 0) return c.addAtom(.{
                .key = o.keys[index],
                .name = c.atomName(index),
                .section = kind,
                .alignment = sectionAlignment(s),
                .bytes = if (kind.isZeroFill()) &.{} else bytes,
                .zero_fill = if (kind.isZeroFill()) s.size else 0,
            }, rels.items, 0, s.size);
            for (pieces) |p| {
                const name = if (literal) "" else c.tlvName(p.key) orelse c.pieceName(index, p.start);
                try c.addAtom(.{
                    .key = p.key,
                    .name = name,
                    .section = kind,
                    .alignment = if (literal) sectionAlignment(s) else pieceAlignment(s, p.start),
                    .bytes = if (kind.isZeroFill()) &.{} else bytes[@intCast(p.start)..@intCast(p.end)],
                    .zero_fill = if (kind.isZeroFill()) p.end - p.start else 0,
                }, rels.items, p.start, p.end);
            }
        }

        /// The largest power of two, up to the section's alignment, that
        /// divides `start`.
        fn pieceAlignment(s: macho.section_64, start: u64) std.mem.Alignment {
            const max = sectionAlignment(s);
            if (start == 0) return max;
            return .fromByteUnits(@min(max.toByteUnits(), @as(u64, 1) << @intCast(@ctz(start))));
        }

        /// Adds `a` with the relocations of `rels` in `[start, end)`.
        fn addAtom(c: *C, a: Atom, rels: []const Rel, start: u64, end: u64) !void {
            const arena = c.in.arena;
            var list: Atom.RelocList = .{};
            for (rels) |r| {
                if (r.offset < start or r.offset >= end) continue;
                const v = @as(i64, @bitCast(r.target.offset)) +% r.addend;
                const a32 = std.math.cast(i32, v) orelse return c.fail("{s}: relocation addend {d} out of range", .{ c.o.path, v });
                try list.append(arena, @intCast(r.offset - start), r.kind, r.target.key, a32);
            }
            list.sort();
            var atom = a;
            atom.targets = try arena.dupe(SymbolKey, list.targets.keys());
            atom.relocs = try arena.dupe(Atom.Reloc, list.relocs.items);
            try c.atoms.append(arena, atom);
        }

        /// The section's first external symbol at its start, else the
        /// first at its start, else its name.
        fn atomName(c: *C, index: usize) []const u8 {
            return c.pieceName(index, 0);
        }

        /// The name of the thread-local whose descriptor resolves to the
        /// template piece `key`: the writer puts the atom's symbol at its
        /// own descriptor, as ld64 puts `_x` there and `_x$tlv$init` at
        /// the template.
        fn tlvName(c: *C, key: SymbolKey) ?[]const u8 {
            const o = c.o;
            for (o.syms) |sym| {
                if (sym.isStab() or sym.kind() != macho.N_SECT or sectionType(o.sects[sym.n_sect]) != macho.S_THREAD_LOCAL_VARIABLES) continue;
                // Assembler labels (`ltmp4`) mark the section, not a variable.
                const n = o.symName(sym);
                if (n.len > 0 and (n[0] == 'l' or n[0] == 'L')) continue;
                const t = symTarget(o, sym) orelse continue;
                if (t.key == key and t.offset == 0) return o.linkName(sym);
            }
            return null;
        }

        fn pieceName(c: *C, index: usize, at: u64) []const u8 {
            const o = c.o;
            const addr = o.sects[index].addr + at;
            var local: ?[]const u8 = null;
            for (o.syms) |sym| {
                if (sym.isStab() or sym.kind() != macho.N_SECT or sym.n_sect != index or sym.n_value != addr) continue;
                if (sym.isExternal()) return o.linkName(sym);
                const n = o.symName(sym);
                if (local == null and !std.mem.startsWith(u8, n, "l") and !std.mem.startsWith(u8, n, "L")) local = if (n.len > 0 and n[0] == '_') n[1..] else n;
            }
            return local orelse name16(&o.sects[index].sectname);
        }

        /// Where symbol `s` resolves, or null after reporting it.
        fn target(c: *C, s: u32) !?Target {
            const o = c.o;
            if (s >= o.syms.len) {
                try c.fail("{s}: relocation against symbol {d}, which does not exist", .{ o.path, s });
                return null;
            }
            const sym = o.syms[s];
            if (sym.isExternal()) {
                const name = o.linkName(sym);
                const gop = try c.resolved.getOrPut(c.in.arena, name);
                if (!gop.found_existing) gop.value_ptr.* = try c.resolve(name, sym.n_desc & n_weak_ref != 0);
                if (gop.value_ptr.*) |t| return t;
                if (sym.kind() == macho.N_ABS) return try c.absolute(sym.n_value);
                if (sym.n_desc & n_weak_ref != 0) {
                    c.weak_used.* = true;
                    return .{ .key = undefined_weak_key, .offset = 0 };
                }
                try c.undefinedSymbol(name);
                return null;
            }
            switch (sym.kind()) {
                macho.N_ABS => return try c.absolute(sym.n_value),
                macho.N_SECT => {},
                else => {
                    try c.fail("{s}: relocation against local symbol '{s}' of type {x}", .{ o.path, o.symName(sym), sym.n_type });
                    return null;
                },
            }
            if (sectionOf(o, sym.n_sect) == null and sectionType(o.sects[sym.n_sect]) != macho.S_THREAD_LOCAL_VARIABLES) {
                try c.fail("{s}: relocation against dropped section '{s}'", .{ o.path, c.sectName(sym.n_sect) });
                return null;
            }
            return symTarget(o, sym) orelse {
                try c.fail("{s}: relocation against '{s}', in no atom", .{ o.path, o.symName(sym) });
                return null;
            };
        }

        fn resolve(c: *C, name: []const u8, weak: bool) !?Target {
            if (try c.ctx.zigExport(name)) |key| return .{ .key = key, .offset = 0 };
            if (try c.in.lookup(name)) |t| return t;
            if (try c.ctx.rtExport(name)) |key| return .{ .key = key, .offset = 0 };
            // The image's handle for `__cxa_atexit`, which ld64 defines as
            // the Mach header: an address in the image is all its users
            // need (see `ElfInput`'s).
            if (std.mem.eql(u8, name, "__dso_handle")) {
                const key: SymbolKey = .fromName("mobj:__dso_handle");
                try c.atoms.append(c.in.arena, .{ .key = key, .name = name, .section = .rodata, .alignment = .@"8", .bytes = &@as([8]u8, @splat(0)) });
                return .{ .key = key, .offset = 0 };
            }
            if (try c.ctx.importSym(name, weak)) |key| return .{ .key = key, .offset = 0, .import = true };
            return null;
        }

        fn absolute(c: *C, value: u64) Allocator.Error!Target {
            var buf: [32]u8 = undefined;
            const key: SymbolKey = .fromName(std.fmt.bufPrint(&buf, "mobj:abs:{x}", .{value}) catch unreachable);
            for (c.abs_values.items) |v| if (v.key == key) return .{ .key = key, .offset = 0 };
            try c.abs_values.append(c.in.arena, .{ .key = key, .value = value });
            return .{ .key = key, .offset = 0 };
        }

        fn writable(c: *C, bytes: []const u8, copy: *?[]u8) Allocator.Error![]u8 {
            if (copy.*) |b| return b;
            const b = try c.in.arena.dupe(u8, bytes);
            copy.* = b;
            return b;
        }

        /// Converts section `index`'s relocations into `rels`, rewriting
        /// the bytes in `copy` where a relocation's addend lives in the
        /// field or an instruction changes.
        fn relocs(c: *C, index: u32, bytes: []const u8, copy: *?[]u8, rels: *std.ArrayList(Rel)) !void {
            const o = c.o;
            const s = o.sects[index];
            const raw = o.bytes[s.reloff..][0 .. @as(usize, s.nreloc) * 8];
            var addend: ?i64 = null;
            var k: usize = 0;
            while (k < s.nreloc) : (k += 1) {
                const r = Reloc.read(raw[k * 8 ..][0..8]);
                const ty = std.enums.fromInt(R, r.type) orelse return c.fail("{s}: unknown relocation type {d} in '{s}'", .{ o.path, r.type, c.sectName(index) });
                if (ty == .ARM64_RELOC_ADDEND) {
                    addend = @as(i24, @bitCast(r.symbolnum));
                    continue;
                }
                defer addend = null;
                const width: u64 = @as(u64, 1) << r.length;
                if (r.address > bytes.len or bytes.len - r.address < width) return c.fail("{s}: relocation at offset {d} past the end of '{s}'", .{ o.path, r.address, c.sectName(index) });
                const off: u64 = r.address;
                switch (ty) {
                    .ARM64_RELOC_UNSIGNED => {
                        if (r.length != 3) return c.fail("{s}: 32-bit absolute relocation in '{s}', which bs does not link yet", .{ o.path, c.sectName(index) });
                        const field = std.mem.readInt(i64, bytes[@intCast(off)..][0..8], .little);
                        const t = if (r.external) try c.target(r.symbolnum) orelse continue else sect: {
                            // The field holds the target's address.
                            break :sect localTarget(o, r.symbolnum, @bitCast(field)) orelse return c.fail("{s}: pointer in '{s}' to an address in no atom", .{ o.path, c.sectName(index) });
                        };
                        const a: i64 = if (r.external) field else 0;
                        try rels.append(c.in.arena, .{ .offset = off, .kind = .aarch64_abs64, .target = t, .addend = a });
                    },
                    .ARM64_RELOC_SUBTRACTOR => {
                        // A - B + field, with the UNSIGNED for A next: a
                        // constant when A and B share an atom.
                        if (k + 1 >= s.nreloc) return c.fail("{s}: SUBTRACTOR without its UNSIGNED in '{s}'", .{ o.path, c.sectName(index) });
                        const n = Reloc.read(raw[(k + 1) * 8 ..][0..8]);
                        k += 1;
                        if (n.type != @backingInt(R.ARM64_RELOC_UNSIGNED) or n.address != r.address or !r.external or !n.external)
                            return c.fail("{s}: malformed SUBTRACTOR pair in '{s}'", .{ o.path, c.sectName(index) });
                        const b = try c.target(r.symbolnum) orelse continue;
                        const a = try c.target(n.symbolnum) orelse continue;
                        if (a.key != b.key or a.import) return c.fail("{s}: difference of two symbols in different atoms in '{s}', which bs does not link yet", .{ o.path, c.sectName(index) });
                        const w = try c.writable(bytes, copy);
                        const delta: i64 = @as(i64, @bitCast(a.offset -% b.offset));
                        if (r.length == 3) {
                            const f = w[@intCast(off)..][0..8];
                            std.mem.writeInt(i64, f, std.mem.readInt(i64, f, .little) +% delta, .little);
                        } else if (r.length == 2) {
                            const f = w[@intCast(off)..][0..4];
                            std.mem.writeInt(i32, f, std.mem.readInt(i32, f, .little) +% @as(i32, @truncate(delta)), .little);
                        } else return c.fail("{s}: SUBTRACTOR of width {d} in '{s}'", .{ o.path, width, c.sectName(index) });
                    },
                    .ARM64_RELOC_BRANCH26, .ARM64_RELOC_PAGE21, .ARM64_RELOC_PAGEOFF12, .ARM64_RELOC_GOT_LOAD_PAGE21, .ARM64_RELOC_GOT_LOAD_PAGEOFF12, .ARM64_RELOC_TLVP_LOAD_PAGE21, .ARM64_RELOC_TLVP_LOAD_PAGEOFF12 => {
                        if (!r.external or r.length != 2) return c.fail("{s}: section-relative {s} in '{s}', which bs does not link yet", .{ o.path, @tagName(ty), c.sectName(index) });
                        const t = try c.target(r.symbolnum) orelse continue;
                        const a = addend orelse 0;
                        const kind: Atom.Reloc.Kind = switch (ty) {
                            .ARM64_RELOC_BRANCH26 => .aarch64_branch26,
                            .ARM64_RELOC_PAGE21 => .aarch64_page21,
                            .ARM64_RELOC_PAGEOFF12 => .aarch64_pageoff12,
                            .ARM64_RELOC_GOT_LOAD_PAGE21 => .aarch64_got_load_page21,
                            .ARM64_RELOC_GOT_LOAD_PAGEOFF12 => .aarch64_got_load_pageoff12,
                            .ARM64_RELOC_TLVP_LOAD_PAGE21 => .aarch64_tlvp_page21,
                            .ARM64_RELOC_TLVP_LOAD_PAGEOFF12 => .aarch64_tlvp_pageoff12,
                            else => unreachable,
                        };
                        if ((kind == .aarch64_tlvp_page21 or kind == .aarch64_tlvp_pageoff12) and t.import)
                            return c.fail("{s}: thread-local from a dylib, which bs does not link yet", .{o.path});
                        if (kind == .aarch64_tlvp_pageoff12) {
                            // `ldr x0, [x0, desc@TLVPPAGEOFF]` loads the
                            // descriptor's address from a slot; the
                            // descriptor is the image's own, so it becomes
                            // `add x0, x0, desc@PAGEOFF`, as ld64 relaxes it.
                            const insn = std.mem.readInt(u32, bytes[@intCast(off)..][0..4], .little);
                            if (insn & 0xffc00000 == 0xf9400000) {
                                const w = try c.writable(bytes, copy);
                                std.mem.writeInt(u32, w[@intCast(off)..][0..4], 0x91000000 | (insn & 0x3ff), .little);
                            } else if (insn & 0xff800000 != 0x91000000) return c.fail("{s}: TLVP_LOAD_PAGEOFF12 on an instruction bs does not relax ({x:0>8})", .{ o.path, insn });
                        }
                        if (t.import and kind != .aarch64_branch26 and kind != .aarch64_got_load_page21 and kind != .aarch64_got_load_pageoff12)
                            return c.fail("{s}: '{s}' reaches {s}, which libSystem defines, without the GOT", .{ o.path, c.sectName(index), o.linkName(o.syms[r.symbolnum]) });
                        try rels.append(c.in.arena, .{ .offset = off, .kind = kind, .target = t, .addend = a });
                    },
                    .ARM64_RELOC_POINTER_TO_GOT => return c.fail("{s}: POINTER_TO_GOT in '{s}', which bs does not link yet", .{ o.path, c.sectName(index) }),
                    .ARM64_RELOC_ADDEND => unreachable,
                }
            }
        }
    };
}

test "objects and a Darwin archive from upstream's Clang and llvm-ar" {
    const testing = std.testing;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // test/link_input/macho_*.c, compiled for aarch64-macos by build.zig's
    // `addMachOInputs`; Archive.zig's tests check the archive itself.
    const lib = @embedFile("macho_input_lib.a");
    var in: Inputs = .{ .arena = arena };
    try in.addObject("main.o", @embedFile("macho_input_main.o"));
    try in.addArchive("lib.a", lib);
    const Ctx = struct {
        fn zigExport(_: @This(), _: []const u8) !?SymbolKey {
            return null;
        }
        fn rtExport(_: @This(), _: []const u8) !?SymbolKey {
            return null;
        }
        fn importSym(_: @This(), _: []const u8, _: bool) !?SymbolKey {
            return null;
        }
    };
    // `second` pulls its member; nothing references `unpulled`.
    try testing.expectEqual(1, try in.pull(&.{}, Ctx{}));
    try testing.expectEqual(2, in.objects.items.len);
    try testing.expectEqualStrings("lib.a(macho_input_long_member_name.o)", in.objects.items[1].path);

    const c = try in.convert(Ctx{});
    try testing.expectEqual(0, in.errors.items.len);
    const second = (try in.lookup("second")).?;
    try testing.expectEqual(4, second.offset);
    var text: ?Atom = null;
    var init_array: ?Atom = null;
    var data: ?Atom = null;
    for (c.atoms) |a| switch (a.section) {
        .text => if (a.bytes.len > 0) {
            try testing.expect(text == null);
            text = a;
        },
        .init_array => init_array = a,
        .data => data = a,
        else => return error.TestUnexpectedResult,
    };
    // The member's `__data`, named after its first symbol.
    try testing.expectEqualStrings("first", data.?.name);
    try testing.expectEqual(second.key, data.?.key);
    try testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0, 41, 0, 0, 0 }, data.?.bytes);
    // main.o's `__text` starts with the static constructor, which names
    // it; the other functions are symbols within it.
    try testing.expectEqualStrings("init", text.?.name);
    var helper: ?u64 = null;
    var read_second: ?u64 = null;
    for (c.symbols) |sym| {
        if (std.mem.eql(u8, sym.name, "helper")) helper = sym.offset;
        if (std.mem.eql(u8, sym.name, "read_second")) read_second = sym.offset;
        if (std.mem.eql(u8, sym.name, "helper") or std.mem.eql(u8, sym.name, "read_second"))
            try testing.expectEqual(text.?.key, sym.atom);
    }
    try testing.expect(helper.? > 0 and read_second.? > 0);
    // `__mod_init_func` becomes an init_array entry pointing at `init`.
    try testing.expectEqual(1, init_array.?.relocs.len);
    const entry = init_array.?.relocs[0];
    try testing.expectEqual(.aarch64_abs64, entry.info.kind);
    try testing.expectEqual(text.?.key, init_array.?.targets[entry.info.target]);
    try testing.expectEqual(0, entry.addend);
    // Both functions load `second` through the GOT, and the loads target
    // the member's data atom 4 bytes in; `read_second` calls `helper`.
    var got_loads: usize = 0;
    var calls: usize = 0;
    for (text.?.relocs) |r| {
        const target = text.?.targets[r.info.target];
        switch (r.info.kind) {
            .aarch64_got_load_page21, .aarch64_got_load_pageoff12 => {
                try testing.expectEqual(second.key, target);
                try testing.expectEqual(4, r.addend);
                got_loads += 1;
            },
            .aarch64_branch26 => {
                try testing.expectEqual(text.?.key, target);
                try testing.expectEqual(helper.?, @as(u64, @intCast(r.addend)));
                try testing.expect(r.offset >= read_second.? and r.offset < helper.?);
                calls += 1;
            },
            else => return error.TestUnexpectedResult,
        }
    }
    try testing.expectEqual(4, got_loads);
    try testing.expectEqual(1, calls);
}
