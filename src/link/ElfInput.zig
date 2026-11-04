//! ELF relocatable objects and archives as link inputs (x86_64-linux;
//! "Object, archive and shared-library inputs" in docs/architecture.md).
//! Objects are read in place. Each allocated section becomes one Atom, or
//! one per entry for mergeable sections, so the link stays one pass over
//! atoms and nothing downstream knows an atom came from C.
//!
//! `Inputs` resolves names across the objects, pulls archive members on
//! demand, and converts the loaded objects into atoms. The caller (Emit)
//! supplies the Zig side of resolution: the compilation's exports, which
//! come first, and compiler_rt, which comes after the inputs.

const std = @import("std");
const elf = std.elf;
const Allocator = std.mem.Allocator;
const Atom = @import("Atom.zig");
const SymbolKey = Atom.SymbolKey;
const Archive = @import("Archive.zig");
const Elf = @import("Elf.zig");

const Inputs = @This();

arena: Allocator,
objects: std.ArrayList(Object) = .empty,
archives: std.ArrayList(ArchiveInput) = .empty,
/// Each global name the loaded objects define, strong over weak, else
/// the first in input order.
defs: std.StringHashMapUnmanaged(Def) = .empty,
/// COMMON symbols: the largest size and alignment of each name, which one
/// zero-filled atom gets, unless an object defines the name.
commons: std.StringArrayHashMapUnmanaged(Common) = .empty,
/// COMDAT group signatures, each kept in its first object.
groups: std.StringHashMapUnmanaged(void) = .empty,
/// Names the loaded objects reference without defining, in first-use
/// order; some may be defined later (by a member pulled after).
undefs: std.StringArrayHashMapUnmanaged(void) = .empty,
/// Problems found while loading, as messages for the caller to report.
errors: std.ArrayList([]const u8) = .empty,

pub const Def = struct { object: u32, sym: u32, weak: bool };
pub const Common = struct { size: u64, alignment: u64 };

const ArchiveInput = struct {
    path: []const u8,
    reader: Archive.Reader,
    /// Member header offsets already pulled.
    pulled: std.AutoHashMapUnmanaged(u64, void) = .empty,
};

pub const Error = error{ OutOfMemory, InvalidObject, InvalidArchive, ThinArchive };

/// One object, read in place.
pub const Object = struct {
    /// As errors name it: the path, or `archive(member)`.
    path: []const u8,
    bytes: []const u8,
    /// Of the contents, for the atoms' keys: stable across paths and
    /// worktrees.
    hash: u64,
    /// Each section's atom key (`sectionKey`), which relocations look up
    /// often enough that hashing it each time shows.
    keys: []SymbolKey,
    shdrs: []align(1) const elf.Elf64_Shdr,
    syms: []align(1) const elf.Elf64_Sym,
    strtab: []const u8,
    shstrtab: []const u8,
    first_global: u32,
    /// Per section: dropped as a later copy of a COMDAT group.
    discarded: []bool,
    /// Per section: the SHT_RELA section applying to it, or 0.
    rela_of: []u32,
    /// Per section: a merged section's entries, in order, else empty.
    pieces: []const []const Piece,

    pub fn symName(o: *const Object, sym: elf.Elf64_Sym) []const u8 {
        if (sym.st_name >= o.strtab.len) return "";
        return std.mem.sliceTo(o.strtab[sym.st_name..], 0);
    }

    pub fn sectionName(o: *const Object, index: usize) []const u8 {
        const n = o.shdrs[index].sh_name;
        if (n >= o.shstrtab.len) return "";
        return std.mem.sliceTo(o.shstrtab[n..], 0);
    }

    pub fn sectionBytes(o: *const Object, index: usize) []const u8 {
        const sh = o.shdrs[index];
        if (sh.sh_type == elf.SHT_NOBITS) return &.{};
        return o.bytes[@intCast(sh.sh_offset)..][0..@intCast(sh.sh_size)];
    }
};

/// Parses an ELF64 x86_64 ET_REL in place.
pub fn parseObject(arena: Allocator, path: []const u8, bytes: []const u8) Error!Object {
    if (bytes.len < @sizeOf(elf.Elf64_Ehdr) or !std.mem.eql(u8, bytes[0..4], elf.MAGIC)) return error.InvalidObject;
    const eh = std.mem.bytesToValue(elf.Elf64_Ehdr, bytes[0..@sizeOf(elf.Elf64_Ehdr)]);
    if (eh.e_ident[elf.EI.CLASS] != elf.ELFCLASS64 or eh.e_ident[elf.EI.DATA] != elf.ELFDATA2LSB) return error.InvalidObject;
    if (eh.e_type != .REL or eh.e_machine != .X86_64) return error.InvalidObject;
    if (eh.e_shentsize != @sizeOf(elf.Elf64_Shdr)) return error.InvalidObject;
    const sh_end = std.math.add(u64, eh.e_shoff, @as(u64, eh.e_shnum) * @sizeOf(elf.Elf64_Shdr)) catch return error.InvalidObject;
    if (sh_end > bytes.len) return error.InvalidObject;
    const shdrs = std.mem.bytesAsSlice(elf.Elf64_Shdr, bytes[@intCast(eh.e_shoff)..@intCast(sh_end)]);
    for (shdrs) |sh| {
        if (sh.sh_type == elf.SHT_NOBITS) continue;
        const end = std.math.add(u64, sh.sh_offset, sh.sh_size) catch return error.InvalidObject;
        if (end > bytes.len) return error.InvalidObject;
    }
    if (eh.e_shstrndx >= shdrs.len) return error.InvalidObject;
    var o: Object = .{
        .path = path,
        .bytes = bytes,
        // Wyhash: about 12 GB/s here, where std's XxHash3 does 0.4.
        .hash = std.hash.Wyhash.hash(0, bytes),
        .keys = try arena.alloc(SymbolKey, shdrs.len),
        .shdrs = shdrs,
        .syms = &.{},
        .strtab = "",
        .shstrtab = undefined,
        .first_global = 0,
        .discarded = try arena.alloc(bool, shdrs.len),
        .rela_of = try arena.alloc(u32, shdrs.len),
        .pieces = &.{},
    };
    o.shstrtab = o.sectionBytes(eh.e_shstrndx);
    @memset(o.discarded, false);
    for (o.keys, 0..) |*k, i| {
        var buf: [64]u8 = undefined;
        k.* = .fromName(std.fmt.bufPrint(&buf, "obj:{x:0>16}:{d}", .{ o.hash, i }) catch unreachable);
    }
    for (shdrs) |sh| {
        if (sh.sh_type != elf.SHT_SYMTAB) continue;
        if (sh.sh_link >= shdrs.len or sh.sh_size % @sizeOf(elf.Elf64_Sym) != 0) return error.InvalidObject;
        o.syms = std.mem.bytesAsSlice(elf.Elf64_Sym, bytes[@intCast(sh.sh_offset)..][0..@intCast(sh.sh_size)]);
        o.strtab = o.sectionBytes(sh.sh_link);
        o.first_global = @intCast(@min(sh.sh_info, o.syms.len));
    }
    for (o.syms) |sym| {
        if (sym.st_shndx != elf.SHN_UNDEF and sym.st_shndx < elf.SHN_LORESERVE and sym.st_shndx >= shdrs.len) return error.InvalidObject;
    }
    @memset(o.rela_of, 0);
    for (shdrs, 0..) |sh, i| {
        if (sh.sh_type != elf.SHT_RELA) continue;
        if (sh.sh_info >= shdrs.len or sh.sh_size % @sizeOf(elf.Elf64_Rela) != 0) return error.InvalidObject;
        o.rela_of[sh.sh_info] = @intCast(i);
    }
    const pieces = try arena.alloc([]const Piece, shdrs.len);
    for (pieces, 0..) |*p, i| {
        p.* = &.{};
        const sh = shdrs[i];
        if (sh.sh_flags & elf.SHF_MERGE == 0 or sh.sh_type == elf.SHT_NOBITS or sectionOf(&o, i) == null) continue;
        var list: std.ArrayList(Piece) = .empty;
        var it = mergeIterator(&o, i);
        while (it.next()) |piece| try list.append(arena, piece);
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
    // COMDAT: a group whose signature an earlier object kept is dropped,
    // and its symbols resolve to the kept copy by name.
    for (obj.shdrs) |sh| {
        if (sh.sh_type != elf.SHT_GROUP or sh.sh_info >= obj.syms.len) continue;
        const sig = obj.symName(obj.syms[sh.sh_info]);
        const gop = try in.groups.getOrPut(in.arena, sig);
        if (!gop.found_existing) continue;
        const members = std.mem.bytesAsSlice(u32, obj.bytes[@intCast(sh.sh_offset)..][0..@intCast(sh.sh_size & ~@as(u64, 3))]);
        if (members.len == 0) continue;
        for (members[1..]) |m| if (m < obj.discarded.len) {
            obj.discarded[m] = true;
        };
    }
    for (obj.syms[obj.first_global..], obj.first_global..) |sym, s| {
        const bind = sym.st_bind();
        if (bind != elf.STB_GLOBAL and bind != elf.STB_WEAK) continue;
        const name = obj.symName(sym);
        if (sym.st_shndx == elf.SHN_UNDEF or (sym.st_shndx < elf.SHN_LORESERVE and obj.discarded[sym.st_shndx])) {
            if (!in.defs.contains(name)) try in.undefs.put(in.arena, name, {});
            continue;
        }
        if (sym.st_shndx == elf.SHN_COMMON) {
            const gop = try in.commons.getOrPut(in.arena, name);
            if (!gop.found_existing) gop.value_ptr.* = .{ .size = 0, .alignment = 1 };
            gop.value_ptr.size = @max(gop.value_ptr.size, sym.st_size);
            gop.value_ptr.alignment = @max(gop.value_ptr.alignment, sym.st_value);
            continue;
        }
        const weak = bind == elf.STB_WEAK;
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
}

/// Pulls the archive members that define a name the loaded objects or
/// `wanted` (the Zig code's externs) need and nothing defines yet,
/// repeating over all archives until nothing changes, as lld does, so that
/// archive order and cycles do not matter. `ctx.zigExport(name)` names
/// what the compilation itself defines, which no member replaces. Returns
/// the index of the first object it loaded.
pub fn pull(in: *Inputs, wanted: []const []const u8, ctx: anytype) !usize {
    const first = in.objects.items.len;
    for (wanted) |name| if (!in.defs.contains(name)) try in.undefs.put(in.arena, name, {});
    var changed = true;
    while (changed) {
        changed = false;
        for (in.archives.items) |*ar| for (ar.reader.symbols) |sym| {
            if (!in.undefs.contains(sym.name) or in.defs.contains(sym.name) or in.commons.contains(sym.name)) continue;
            if (try ctx.zigExport(sym.name) != null) continue;
            if ((try ar.pulled.getOrPut(in.arena, sym.member)).found_existing) continue;
            const m = try ar.reader.member(sym.member);
            const path = try std.fmt.allocPrint(in.arena, "{s}({s})", .{ ar.path, m.name });
            try in.load(parseObject(in.arena, path, m.bytes) catch |err| switch (err) {
                error.InvalidObject => {
                    try in.errors.append(in.arena, try std.fmt.allocPrint(in.arena, "{s}: not an x86_64 ELF relocatable object", .{path}));
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
    for (in.objects.items[first..]) |*o| for (o.syms[o.first_global..]) |sym| {
        if (sym.st_shndx != elf.SHN_UNDEF) continue;
        const name = o.symName(sym);
        if (in.defs.contains(name) or in.commons.contains(name)) continue;
        try out.append(gpa, name);
    };
}

/// Where a name the objects define resolves: an atom key and an offset in
/// that atom.
pub const Target = struct {
    key: SymbolKey,
    offset: u64,
    /// A shared library's symbol (`ctx.importSym`), which the loader
    /// binds: code reaches it through a slot, calls through a stub.
    import: bool = false,
};

/// The definition objects give `name`, or null.
pub fn lookup(in: *Inputs, name: []const u8) Allocator.Error!?Target {
    if (in.defs.get(name)) |d| {
        const o = &in.objects.items[d.object];
        return try in.symTarget(o, d.sym, 0);
    }
    if (in.commons.contains(name)) return .{ .key = commonKey(name), .offset = 0 };
    return null;
}

fn commonKey(name: []const u8) SymbolKey {
    var buf: [256]u8 = undefined;
    return .fromName(std.fmt.bufPrint(&buf, "common.{s}", .{name}) catch name);
}

/// The key of section `index` of `o`, which is not a merged one.
fn sectionKey(o: *const Object, index: usize) SymbolKey {
    return o.keys[index];
}

/// The key of the value 0 that an undefined weak symbol resolves to.
pub const undefined_weak_key: SymbolKey = .fromName("obj:undefined-weak");

/// Where local or defined symbol `s` of `o` points, `addend` bytes on (an
/// addend only moves a section symbol's target, as lld's), or null for an
/// absolute symbol.
fn symTarget(in: *Inputs, o: *const Object, s: u32, addend: i64) Allocator.Error!?Target {
    _ = in;
    const sym = o.syms[s];
    const shndx = sym.st_shndx;
    if (shndx == elf.SHN_ABS or shndx >= elf.SHN_LORESERVE or shndx == elf.SHN_UNDEF) return null;
    const sh = o.shdrs[shndx];
    const offset: u64 = sym.st_value;
    if (sh.sh_flags & elf.SHF_MERGE != 0) {
        const at: u64 = if (sym.st_type() == elf.STT_SECTION) @bitCast(@as(i64, @bitCast(offset)) +% addend) else offset;
        const piece = mergePiece(o, shndx, at) orelse return null;
        return .{ .key = piece.key, .offset = offset -% piece.start };
    }
    return .{ .key = sectionKey(o, shndx), .offset = offset };
}

const Piece = struct { start: u64, end: u64, key: SymbolKey };

/// The entry of merged section `index` containing offset `at`.
fn mergePiece(o: *const Object, index: usize, at: u64) ?Piece {
    const pieces = o.pieces[index];
    var lo: usize = 0;
    var hi: usize = pieces.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (pieces[mid].end <= at) lo = mid + 1 else hi = mid;
    }
    if (lo == pieces.len or at < pieces[lo].start) return null;
    return pieces[lo];
}

const MergeIterator = struct {
    bytes: []const u8,
    entsize: u64,
    strings: bool,
    alignment: std.mem.Alignment,
    section: Atom.Section,
    at: u64 = 0,

    fn next(it: *MergeIterator) ?Piece {
        if (it.at >= it.bytes.len) return null;
        const start = it.at;
        var end = start + it.entsize;
        if (it.strings) {
            // An entry ends at a NUL character of `entsize` bytes.
            end = start;
            while (end + it.entsize <= it.bytes.len) {
                const c = it.bytes[@intCast(end)..][0..@intCast(it.entsize)];
                end += it.entsize;
                if (std.mem.allEqual(u8, c, 0)) break;
            }
        }
        end = @min(end, it.bytes.len);
        it.at = end;
        const b = it.bytes[@intCast(start)..@intCast(end)];
        return .{ .start = start, .end = end, .key = .fromContents(it.section, it.alignment, b, &.{}, &.{}) };
    }

    fn pieceBytes(it: *const MergeIterator, p: Piece) []const u8 {
        return it.bytes[@intCast(p.start)..@intCast(p.end)];
    }
};

fn mergeIterator(o: *const Object, index: usize) MergeIterator {
    const sh = o.shdrs[index];
    return .{
        .bytes = o.sectionBytes(index),
        .entsize = @max(1, sh.sh_entsize),
        .strings = sh.sh_flags & elf.SHF_STRINGS != 0,
        .alignment = sectionAlignment(sh),
        .section = sectionOf(o, index).?,
    };
}

fn sectionAlignment(sh: elf.Elf64_Shdr) std.mem.Alignment {
    return .fromByteUnits(if (sh.sh_addralign == 0) 1 else std.math.ceilPowerOfTwoAssert(u64, sh.sh_addralign));
}

/// The `Atom.Section` an input section's atoms go to, or null for one the
/// link drops (not allocated, notes, unwind tables until stage B).
fn sectionOf(o: *const Object, index: usize) ?Atom.Section {
    const sh = o.shdrs[index];
    if (sh.sh_flags & elf.SHF_ALLOC == 0 or sh.sh_flags & elf.SHF_EXCLUDE != 0) return null;
    // GCC's .eh_frame is PROGBITS.
    if (std.mem.eql(u8, o.sectionName(index), ".eh_frame")) return null;
    switch (sh.sh_type) {
        elf.SHT_NOTE, elf.SHT_GROUP, elf.SHT_X86_64_UNWIND => return null,
        else => {},
    }
    switch (sh.sh_type) {
        elf.SHT_PREINIT_ARRAY => return .preinit_array,
        elf.SHT_INIT_ARRAY => return .init_array,
        elf.SHT_FINI_ARRAY => return .fini_array,
        else => {},
    }
    if (sh.sh_flags & elf.SHF_TLS != 0) return if (sh.sh_type == elf.SHT_NOBITS) .tbss else .tdata;
    if (sh.sh_type == elf.SHT_NOBITS) return .bss;
    if (sh.sh_flags & elf.SHF_EXECINSTR != 0) return .text;
    if (sh.sh_flags & elf.SHF_WRITE != 0) return .data;
    return .rodata;
}

/// The atoms of the loaded objects, and the link-time values they use.
pub const Converted = struct {
    atoms: []const Atom,
    values: []const Elf.Value,
    /// The objects' functions and objects within their sections' atoms,
    /// for .symtab, except those that name their atom.
    symbols: []const Elf.LocalSymbol,
};

/// Converts every loaded object into atoms. `ctx` resolves what the
/// objects leave undefined: `zigExport(name) !?SymbolKey` (the
/// compilation's exports, which come before the objects') and
/// `rtExport(name) !?SymbolKey` (compiler_rt, after them). Undefined
/// strong names and unsupported relocations go to `errors`.
pub fn convert(in: *Inputs, ctx: anytype) !Converted {
    const arena = in.arena;
    var atoms: std.ArrayList(Atom) = .empty;
    var values: std.ArrayList(Elf.Value) = .empty;
    var symbols: std.ArrayList(Elf.LocalSymbol) = .empty;
    var weak_used = false;
    var c: Converter(@TypeOf(ctx)) = .{ .in = in, .ctx = ctx, .atoms = &atoms, .weak_used = &weak_used };
    // Two strong definitions of a name, one Zig's, are an error, as ld's.
    var defs = in.defs.iterator();
    while (defs.next()) |d| if (!d.value_ptr.weak) if (try ctx.zigExport(d.key_ptr.*) != null) {
        try in.errors.append(arena, try std.fmt.allocPrint(arena, "duplicate symbol: {s}, defined by the Zig code and in {s}", .{ d.key_ptr.*, in.objects.items[d.value_ptr.object].path }));
    };
    for (in.objects.items) |*o| {
        c.o = o;
        c.names = try arena.realloc(c.names, o.shdrs.len);
        @memset(c.names, 0);
        var s = o.syms.len;
        while (s > o.first_global) {
            s -= 1;
            const sym = o.syms[s];
            if (sym.st_value == 0 and sym.st_shndx != elf.SHN_UNDEF and sym.st_shndx < o.shdrs.len) c.names[sym.st_shndx] = @intCast(s);
        }
        c.whole = try arena.realloc(c.whole, o.shdrs.len);
        @memset(c.whole, false);
        for (0..o.shdrs.len) |i| try c.section(@intCast(i));
        for (o.syms[1..], 1..) |sym, s_index| {
            const ty = sym.st_type();
            if (ty != elf.STT_FUNC and ty != elf.STT_OBJECT and ty != elf.STT_TLS) continue;
            if (sym.st_shndx >= o.shdrs.len or !c.whole[sym.st_shndx] or c.names[sym.st_shndx] == s_index) continue;
            const name = o.symName(sym);
            if (name.len == 0) continue;
            try symbols.append(arena, .{ .name = name, .atom = sectionKey(o, sym.st_shndx), .offset = sym.st_value, .size = sym.st_size });
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
    try sortArrays(arena, atoms.items, c.arrays.items);
    if (weak_used) try values.append(arena, .{ .key = undefined_weak_key, .value = 0 });
    try values.appendSlice(arena, c.abs_values.items);
    return .{ .atoms = atoms.items, .values = values.items, .symbols = symbols.items };
}

const ArrayAtom = struct { atom: u32, priority: u32 };

/// An init or fini array section's priority: `.init_array.<n>` is `n`,
/// and the plain `.init_array` comes after every numbered one, as in ld's
/// SORT_BY_INIT_PRIORITY.
fn priority(name: []const u8) ?u32 {
    const dot = std.mem.indexOfScalarPos(u8, name, 1, '.') orelse return 1 << 16;
    const n = std.fmt.parseInt(u16, name[dot + 1 ..], 10) catch return null;
    return n;
}

/// Orders the atoms of each init and fini array by priority, keeping the
/// input order among equal ones, within the places those atoms hold in
/// `atoms`.
fn sortArrays(arena: Allocator, atoms: []Atom, arrays: []const ArrayAtom) !void {
    if (arrays.len == 0) return;
    const sorted = try arena.alloc(ArrayAtom, arrays.len);
    const moved = try arena.alloc(Atom, arrays.len);
    for ([_]Atom.Section{ .preinit_array, .init_array, .fini_array }) |kind| {
        var n: usize = 0;
        for (arrays) |e| if (atoms[e.atom].section == kind) {
            sorted[n] = e;
            n += 1;
        };
        std.sort.insertion(ArrayAtom, sorted[0..n], {}, struct {
            fn lessThan(_: void, x: ArrayAtom, y: ArrayAtom) bool {
                return x.priority < y.priority;
            }
        }.lessThan);
        for (sorted[0..n], moved[0..n]) |e, *m| m.* = atoms[e.atom];
        var k: usize = 0;
        for (arrays) |e| if (atoms[e.atom].section == kind) {
            atoms[e.atom] = moved[k];
            k += 1;
        };
    }
}

fn Converter(comptime Ctx: type) type {
    return struct {
        in: *Inputs,
        ctx: Ctx,
        o: *const Object = undefined,
        atoms: *std.ArrayList(Atom),
        weak_used: *bool,
        abs_values: std.ArrayList(Elf.Value) = .empty,
        list: Atom.RelocList = .{},
        /// Per section of `o`: the symbol naming its atom, or 0.
        names: []u32 = &.{},
        /// Per section of `o`: whether it became one atom of its own.
        whole: []bool = &.{},
        /// How each global name the objects reference resolved.
        resolved: std.StringHashMapUnmanaged(?Target) = .empty,
        /// The init and fini arrays' atoms, in input order.
        arrays: std.ArrayList(ArrayAtom) = .empty,

        const C = @This();

        fn fail(c: *C, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
            try c.in.errors.append(c.in.arena, try std.fmt.allocPrint(c.in.arena, fmt, args));
        }

        fn section(c: *C, index: u32) !void {
            const o = c.o;
            if (o.discarded[index]) return;
            const kind = sectionOf(o, index) orelse return;
            const sh = o.shdrs[index];
            const name = o.sectionName(index);
            if (std.mem.startsWith(u8, name, ".ctors") or std.mem.startsWith(u8, name, ".dtors")) {
                return c.fail("{s}: zap does not link section '{s}' (legacy constructors and destructors); compile with .init_array", .{ o.path, name });
            }
            const arena = c.in.arena;
            if (sh.sh_flags & elf.SHF_MERGE != 0 and sh.sh_type != elf.SHT_NOBITS) {
                const it = mergeIterator(o, index);
                for (o.pieces[index]) |p| try c.atoms.append(arena, .{
                    .key = p.key,
                    .name = "",
                    .section = kind,
                    .alignment = it.alignment,
                    .bytes = it.pieceBytes(p),
                });
                if (o.rela_of[index] != 0) return c.fail("{s}: relocations in merged section '{s}' are not supported", .{ o.path, name });
                return;
            }
            var bytes = o.sectionBytes(index);
            c.list.targets.clearRetainingCapacity();
            c.list.relocs.clearRetainingCapacity();
            if (o.rela_of[index] != 0) {
                const rela = o.rela_of[index];
                const relas = std.mem.bytesAsSlice(elf.Elf64_Rela, o.sectionBytes(rela));
                var copy: ?[]u8 = null;
                var k: usize = 0;
                while (k < relas.len) : (k += 1) {
                    k += try c.reloc(index, relas, k, bytes, &copy);
                }
                if (copy) |b| bytes = b;
                c.list.sort();
            }
            switch (kind) {
                .preinit_array, .init_array, .fini_array => try c.arrays.append(arena, .{
                    .atom = @intCast(c.atoms.items.len),
                    .priority = priority(name) orelse return c.fail("{s}: section '{s}' has an invalid priority", .{ o.path, name }),
                }),
                else => {},
            }
            c.whole[index] = true;
            try c.atoms.append(arena, .{
                .key = sectionKey(o, index),
                .name = c.atomName(index),
                .section = kind,
                .alignment = sectionAlignment(sh),
                .bytes = if (kind.isZeroFill()) &.{} else bytes,
                .zero_fill = if (kind.isZeroFill()) sh.sh_size else 0,
                .targets = try arena.dupe(SymbolKey, c.list.targets.keys()),
                .relocs = try arena.dupe(Atom.Reloc, c.list.relocs.items),
            });
        }

        /// The section's first global symbol at its start, else its name.
        fn atomName(c: *C, index: u32) []const u8 {
            const s = c.names[index];
            return if (s != 0) c.o.symName(c.o.syms[s]) else c.o.sectionName(index);
        }

        /// Where symbol `s` resolves, `addend` bytes on, or null after
        /// reporting it undefined.
        fn target(c: *C, s: u32, addend: i64) !?Target {
            const o = c.o;
            if (s >= o.syms.len) {
                try c.fail("{s}: relocation against symbol {d}, which does not exist", .{ o.path, s });
                return null;
            }
            const sym = o.syms[s];
            const bind = sym.st_bind();
            if (s >= o.first_global and (bind == elf.STB_GLOBAL or bind == elf.STB_WEAK)) {
                const name = o.symName(sym);
                const gop = try c.resolved.getOrPut(c.in.arena, name);
                if (!gop.found_existing) gop.value_ptr.* = try c.resolve(name, bind == elf.STB_WEAK);
                if (gop.value_ptr.*) |t| return t;
                if (sym.st_shndx == elf.SHN_ABS) return try c.absolute(sym.st_value);
                if (bind == elf.STB_WEAK) {
                    c.weak_used.* = true;
                    return .{ .key = undefined_weak_key, .offset = 0 };
                }
                try c.fail("undefined symbol: {s} (referenced by {s})", .{ name, o.path });
                return null;
            }
            if (sym.st_shndx == elf.SHN_ABS) return try c.absolute(sym.st_value);
            if (sym.st_shndx == elf.SHN_UNDEF or sym.st_shndx >= elf.SHN_LORESERVE) {
                try c.fail("{s}: relocation against local symbol {d} with section index {d}", .{ o.path, s, sym.st_shndx });
                return null;
            }
            if (o.discarded[sym.st_shndx] or sectionOf(o, sym.st_shndx) == null) {
                try c.fail("{s}: relocation against discarded or unallocated section '{s}'", .{ o.path, o.sectionName(sym.st_shndx) });
                return null;
            }
            return try c.in.symTarget(o, s, addend) orelse {
                try c.fail("{s}: relocation into the middle of nothing in merged section '{s}'", .{ o.path, o.sectionName(sym.st_shndx) });
                return null;
            };
        }

        /// The compilation's exports come first, then the objects', then
        /// compiler_rt, as upstream links them.
        fn resolve(c: *C, name: []const u8, weak: bool) !?Target {
            if (try c.ctx.zigExport(name)) |key| return .{ .key = key, .offset = 0 };
            if (try c.in.lookup(name)) |t| return t;
            if (try c.ctx.rtExport(name)) |key| return .{ .key = key, .offset = 0 };
            if (try c.ctx.importSym(name, weak)) |key| return .{ .key = key, .offset = 0, .import = true };
            return null;
        }

        fn absolute(c: *C, value: u64) Allocator.Error!Target {
            var buf: [32]u8 = undefined;
            const key: SymbolKey = .fromName(std.fmt.bufPrint(&buf, "obj:abs:{x}", .{value}) catch unreachable);
            for (c.abs_values.items) |v| if (v.key == key) return .{ .key = key, .offset = 0 };
            try c.abs_values.append(c.in.arena, .{ .key = key, .value = value });
            return .{ .key = key, .offset = 0 };
        }

        fn add(c: *C, offset: u64, kind: Atom.Reloc.Kind, t: Target, addend: i64) Allocator.Error!void {
            const a = @as(i64, @bitCast(t.offset)) +% addend;
            const a32 = std.math.cast(i32, a) orelse return c.fail("{s}: relocation addend {d} out of range", .{ c.o.path, a });
            try c.list.append(c.in.arena, @intCast(offset), kind, t.key, a32);
        }

        /// Converts relocation `k` of section `index`, rewriting the code
        /// in `copy` (a copy of `bytes` made on the first rewrite) when it
        /// relaxes an instruction sequence. Returns how many relocations
        /// after `k` the rewrite consumed.
        fn reloc(c: *C, index: u32, relas: []align(1) const elf.Elf64_Rela, k: usize, bytes: []const u8, copy: *?[]u8) !usize {
            const o = c.o;
            const r = relas[k];
            const off = r.r_offset;
            const ty = r.r_type();
            const R = elf.R_X86_64;
            if (off >= bytes.len) {
                try c.fail("{s}: relocation at offset {d} past the end of section '{s}'", .{ o.path, off, o.sectionName(index) });
                return 0;
            }
            const t = try c.target(r.r_sym(), r.r_addend) orelse return 0;
            if (t.import) {
                try c.importReloc(index, r, bytes);
                return 0;
            }
            switch (@as(R, @fromBackingInt(@intCast(ty)))) {
                .@"64" => try c.add(off, .x86_64_abs64, t, r.r_addend),
                .PC32, .PLT32 => try c.add(off, .x86_64_pc32, t, r.r_addend),
                .@"32" => try c.add(off, .x86_64_abs32, t, r.r_addend),
                .@"32S" => try c.add(off, .x86_64_abs32s, t, r.r_addend),
                .GOTPCREL, .GOTPCRELX, .REX_GOTPCRELX => {
                    // Every target is the image's own: relax as ld does
                    // where the instruction allows, else go through a slot.
                    if (ty != @backingInt(R.GOTPCREL) and off >= 2) {
                        const op = bytes[@intCast(off - 2)];
                        const modrm = bytes[@intCast(off - 1)];
                        if (op == 0x8b) {
                            (try c.writable(bytes, copy))[@intCast(off - 2)] = 0x8d; // mov -> lea
                            try c.add(off, .x86_64_pc32, t, r.r_addend);
                            return 0;
                        }
                        if (op == 0xff and modrm == 0x15) {
                            const b = try c.writable(bytes, copy);
                            b[@intCast(off - 2)..][0..2].* = .{ 0x67, 0xe8 }; // addr32 call
                            try c.add(off, .x86_64_pc32, t, r.r_addend);
                            return 0;
                        }
                        if (op == 0xff and modrm == 0x25 and off + 4 <= bytes.len) {
                            const b = try c.writable(bytes, copy);
                            b[@intCast(off - 2)] = 0xe9; // jmp rel32; nop
                            std.mem.copyForwards(u8, b[@intCast(off - 1)..][0..4], bytes[@intCast(off)..][0..4]);
                            b[@intCast(off + 3)] = 0x90;
                            try c.add(off - 1, .x86_64_pc32, t, r.r_addend);
                            return 0;
                        }
                    }
                    try c.add(off, .x86_64_pc32, .{ .key = try c.slot(t), .offset = 0 }, r.r_addend);
                },
                // Every thread-local of an executable is its own: the
                // dynamic models relax to local exec, as ld relaxes them.
                .TPOFF32 => try c.add(off, .x86_64_tpoff32, t, r.r_addend),
                .GOTTPOFF => {
                    if (off < 3) {
                        try c.unsupported(index, ty);
                        return 0;
                    }
                    const rex = bytes[@intCast(off - 3)];
                    const op = bytes[@intCast(off - 2)];
                    const reg = bytes[@intCast(off - 1)] >> 3 & 7;
                    if ((rex != 0x48 and rex != 0x4c) or (op != 0x8b and op != 0x03)) {
                        try c.unsupported(index, ty);
                        return 0;
                    }
                    const b = try c.writable(bytes, copy);
                    b[@intCast(off - 3)..][0..3].* = .{ if (rex == 0x4c) 0x49 else 0x48, if (op == 0x8b) 0xc7 else 0x81, 0xc0 | reg };
                    try c.add(off, .x86_64_tpoff32, t, 0);
                },
                .TLSGD => {
                    // data16 lea rdi, [rip + x@tlsgd]; data16 data16 rex.W
                    // call __tls_get_addr@plt
                    const gd = [_]u8{ 0x66, 0x48, 0x8d, 0x3d };
                    if (off < 4 or off + 12 > bytes.len or !std.mem.eql(u8, bytes[@intCast(off - 4)..][0..4], &gd) or
                        !std.mem.eql(u8, bytes[@intCast(off + 4)..][0..4], &.{ 0x66, 0x66, 0x48, 0xe8 }) or !c.callsTlsGetAddr(relas, k, off + 8))
                    {
                        try c.unsupported(index, ty);
                        return 0;
                    }
                    const b = try c.writable(bytes, copy);
                    // mov rax, fs:0; lea rax, [rax + x@tpoff]
                    b[@intCast(off - 4)..][0..16].* = .{ 0x64, 0x48, 0x8b, 0x04, 0x25, 0, 0, 0, 0, 0x48, 0x8d, 0x80, 0, 0, 0, 0 };
                    try c.add(off + 8, .x86_64_tpoff32, t, 0);
                    return 1;
                },
                .TLSLD => {
                    // lea rdi, [rip + x@tlsld]; call __tls_get_addr@plt
                    if (off < 3 or off + 9 > bytes.len or !std.mem.eql(u8, bytes[@intCast(off - 3)..][0..3], &.{ 0x48, 0x8d, 0x3d }) or
                        bytes[@intCast(off + 4)] != 0xe8 or !c.callsTlsGetAddr(relas, k, off + 5))
                    {
                        try c.unsupported(index, ty);
                        return 0;
                    }
                    const b = try c.writable(bytes, copy);
                    // data16 data16 data16 mov rax, fs:0
                    b[@intCast(off - 3)..][0..12].* = .{ 0x66, 0x66, 0x66, 0x64, 0x48, 0x8b, 0x04, 0x25, 0, 0, 0, 0 };
                    return 1;
                },
                // With rax the thread pointer after the relaxed TLSLD.
                .DTPOFF32 => try c.add(off, .x86_64_tpoff32, t, r.r_addend),
                else => try c.unsupported(index, ty),
            }
            return 0;
        }

        /// A relocation to a shared library's symbol: an absolute address
        /// stays one, which the loader writes; a call goes through a stub
        /// that jumps through the symbol's slot; GOT-relative code uses
        /// the slot. Reading an import's data PC-relative would need a
        /// copy relocation.
        fn importReloc(c: *C, index: u32, r: elf.Elf64_Rela, bytes: []const u8) !void {
            const o = c.o;
            const off = r.r_offset;
            const sym = o.syms[r.r_sym()];
            const t: Target = .{ .key = (try c.target(r.r_sym(), r.r_addend)).?.key, .offset = 0 };
            const R = elf.R_X86_64;
            const ty: R = @fromBackingInt(@intCast(r.r_type()));
            switch (ty) {
                .@"64" => try c.add(off, .x86_64_abs64, t, r.r_addend),
                .GOTPCREL, .GOTPCRELX, .REX_GOTPCRELX => try c.add(off, .x86_64_pc32, .{ .key = try c.slot(t), .offset = 0 }, r.r_addend),
                .PLT32, .PC32 => {
                    const op = if (off >= 1) bytes[@intCast(off - 1)] else 0;
                    if (ty == .PC32 and op != 0xe8 and op != 0xe9) return c.fail("{s}: zap does not make copy relocations yet: section '{s}' reads {s}, which a shared library defines, PC-relative (GCC's -fPIE does); compile it with -fPIC", .{ o.path, o.sectionName(index), o.symName(sym) });
                    try c.add(off, .x86_64_pc32, .{ .key = try c.stub(t), .offset = 0 }, r.r_addend);
                },
                else => try c.fail("{s}: zap does not link relocation R_X86_64_{s} against {s}, which a shared library defines, yet", .{ o.path, @tagName(ty), o.symName(sym) }),
            }
        }

        /// A stub that jumps through `t`'s slot (`jmp [rip + slot]`),
        /// content-addressed, so all calls to one import share it.
        fn stub(c: *C, t: Target) Allocator.Error!SymbolKey {
            const arena = c.in.arena;
            const targets = try arena.dupe(SymbolKey, &.{try c.slot(t)});
            const relocs = try arena.dupe(Atom.Reloc, &.{.init(2, .x86_64_pc32, 0, -4)});
            const code: []const u8 = &.{ 0xff, 0x25, 0, 0, 0, 0 };
            const key: SymbolKey = .fromContents(.text, .@"8", code, targets, relocs);
            try c.atoms.append(arena, .{ .key = key, .name = "", .section = .text, .alignment = .@"8", .bytes = code, .targets = targets, .relocs = relocs });
            return key;
        }

        /// Whether relocation `k + 1` is the call to `__tls_get_addr` at
        /// `field` that a general- or local-dynamic sequence ends with.
        fn callsTlsGetAddr(c: *C, relas: []align(1) const elf.Elf64_Rela, k: usize, field: u64) bool {
            if (k + 1 >= relas.len) return false;
            const n = relas[k + 1];
            const ty: elf.R_X86_64 = @fromBackingInt(@intCast(n.r_type()));
            if (n.r_offset != field or (ty != .PLT32 and ty != .PC32)) return false;
            if (n.r_sym() >= c.o.syms.len) return false;
            return std.mem.eql(u8, c.o.symName(c.o.syms[n.r_sym()]), "__tls_get_addr");
        }

        fn unsupported(c: *C, index: u32, ty: u32) Allocator.Error!void {
            const name = if (std.enums.fromInt(elf.R_X86_64, ty)) |t| @tagName(t) else "unknown";
            try c.fail("{s}: zap does not link relocation R_X86_64_{s} ({d}) in section '{s}' yet", .{ c.o.path, name, ty, c.o.sectionName(index) });
        }

        fn writable(c: *C, bytes: []const u8, copy: *?[]u8) Allocator.Error![]u8 {
            if (copy.*) |b| return b;
            const b = try c.in.arena.dupe(u8, bytes);
            copy.* = b;
            return b;
        }

        /// An 8-byte slot holding `t`'s address, for GOT-relative code that
        /// cannot be relaxed: content-addressed, so references to one
        /// target share it.
        fn slot(c: *C, t: Target) Allocator.Error!SymbolKey {
            const arena = c.in.arena;
            const targets = try arena.dupe(SymbolKey, &.{t.key});
            const off = std.math.cast(i32, t.offset) orelse {
                try c.fail("{s}: GOT entry offset out of range", .{c.o.path});
                return t.key;
            };
            const relocs = try arena.dupe(Atom.Reloc, &.{.init(0, .x86_64_abs64, 0, off)});
            const zeros: []const u8 = &@as([8]u8, @splat(0));
            const key: SymbolKey = .fromContents(.rodata, .@"8", zeros, targets, relocs);
            try c.atoms.append(arena, .{ .key = key, .name = "", .section = .rodata, .alignment = .@"8", .bytes = zeros, .targets = targets, .relocs = relocs });
            return key;
        }
    };
}
