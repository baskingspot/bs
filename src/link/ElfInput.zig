//! ELF relocatable objects and archives as link inputs (x86_64-linux, and
//! static executables on aarch64-linux; "Object, archive and
//! shared-library inputs" in docs/slop/architecture.md).
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
const ElfShared = @import("ElfShared.zig");
const Elf = @import("Elf.zig");
const ElfDynamic = @import("ElfDynamic.zig");

const Inputs = @This();

arena: Allocator,
objects: std.ArrayList(Object) = .empty,
archives: std.ArrayList(ArchiveInput) = .empty,
/// Each global name the loaded objects define, strong over weak, else
/// the first in input order.
defs: std.StringHashMapUnmanaged(Def) = .empty,
/// The most constraining visibility (STV_INTERNAL 1, STV_HIDDEN 2,
/// STV_PROTECTED 3) of the names that any object's symbol, a reference
/// or a definition, gives one other than STV_DEFAULT, as the ELF gABI
/// and lld merge it: a name defined with default visibility but
/// referenced as hidden is hidden. Names not here are STV_DEFAULT.
visibility: std.StringHashMapUnmanaged(u2) = .empty,
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
/// The output is a shared object (`build-lib -dynamic`): thread-locals
/// keep their dynamic models, and absolute 32-bit addresses are errors.
shared: bool = false,
/// The loader relocates the output (an executable linking glibc, or a
/// shared object): GNU indirect functions resolve through it
/// (`ifuncAtoms`); otherwise they are errors.
dynamic: bool = false,
/// The shared libraries the link imports from. Upstream's linker sees
/// them before the C++ runtime's archives (`addArchive`'s `runtime`), so
/// a name one of them defines pulls no member from those archives.
shared_libs: []const ElfShared = &.{},
/// A C-only program, which upstream links with lld: the objects' globals
/// of default or protected visibility are listed in .symtab as global
/// (`Elf.LocalSymbol.bind`), as lld lists them, rather than local, as
/// upstream's own linker lists them in programs with Zig code.
lld: bool = false,
/// The architecture of the objects the link takes.
arch: Atom.Unwind.Arch = .x86_64,

pub const Def = struct { object: u32, sym: u32, weak: bool };
pub const Common = struct { size: u64, alignment: u64 };

const ArchiveInput = struct {
    path: []const u8,
    reader: Archive.Reader,
    /// Member header offsets already pulled.
    pulled: std.AutoHashMapUnmanaged(u64, void) = .empty,
    runtime: bool,
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
    return parseObjectFor(arena, path, bytes, .x86_64);
}

/// Parses an ELF64 ET_REL of `arch` in place.
pub fn parseObjectFor(arena: Allocator, path: []const u8, bytes: []const u8, arch: Atom.Unwind.Arch) Error!Object {
    if (bytes.len < @sizeOf(elf.Elf64_Ehdr) or !std.mem.eql(u8, bytes[0..4], elf.MAGIC)) return error.InvalidObject;
    const eh = std.mem.bytesToValue(elf.Elf64_Ehdr, bytes[0..@sizeOf(elf.Elf64_Ehdr)]);
    if (eh.e_ident[elf.EI.CLASS] != elf.ELFCLASS64 or eh.e_ident[elf.EI.DATA] != elf.ELFDATA2LSB) return error.InvalidObject;
    if (eh.e_type != .REL or eh.e_machine != @as(elf.EM, switch (arch) {
        .x86_64 => .X86_64,
        .aarch64 => .AARCH64,
    })) return error.InvalidObject;
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
    try in.load(try parseObjectFor(in.arena, path, bytes, in.arch));
}

/// Adds an archive, whose members load when they define a name the
/// inputs or the caller need (`pull`).
/// `runtime` marks an archive the link adds after every input, as
/// upstream's linker sees libc++, libc++abi, libunwind and
/// libc_nonshared.a (`shared_libs`).
pub fn addArchive(in: *Inputs, path: []const u8, bytes: []const u8, runtime: bool) Error!void {
    try in.archives.append(in.arena, .{ .path = path, .reader = try .init(in.arena, bytes), .runtime = runtime });
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
        const vis: u2 = @truncate(sym.st_other);
        if (vis != 0) {
            const v = try in.visibility.getOrPut(in.arena, name);
            if (!v.found_existing or vis < v.value_ptr.*) v.value_ptr.* = vis;
        }
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
            if (ar.runtime and for (in.shared_libs) |lib| {
                if (lib.symbols.contains(sym.name)) break true;
            } else false) continue;
            if ((try ar.pulled.getOrPut(in.arena, sym.member)).found_existing) continue;
            const m = try ar.reader.member(sym.member);
            const path = try std.fmt.allocPrint(in.arena, "{s}({s})", .{ ar.path, m.name });
            try in.load(parseObjectFor(in.arena, path, m.bytes, in.arch) catch |err| switch (err) {
                error.InvalidObject => {
                    try in.errors.append(in.arena, try std.fmt.allocPrint(in.arena, "{s}: not an {t} ELF relocatable object", .{ path, in.arch }));
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

/// Whether symbol `s` of `o` is the definition the link keeps for `name`.
fn isKept(in: *const Inputs, o: *const Object, s: u32, name: []const u8) bool {
    const d = in.defs.get(name) orelse return false;
    return &in.objects.items[d.object] == o and d.sym == s;
}

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
    const sym = o.syms[s];
    const shndx = sym.st_shndx;
    if (shndx == elf.SHN_ABS or shndx >= elf.SHN_LORESERVE or shndx == elf.SHN_UNDEF) return null;
    // An indirect function is its stub, the address calls and pointers
    // use, as upstream's canonical PLT entry.
    if (sym.st_type() == elf.STT_GNU_IFUNC and in.dynamic) return .{ .key = (try in.ifuncAtoms(o, s)).stub.key, .offset = 0 };
    const sh = o.shdrs[shndx];
    const offset: u64 = sym.st_value;
    if (sh.sh_flags & elf.SHF_MERGE != 0) {
        const at: u64 = if (sym.st_type() == elf.STT_SECTION) @bitCast(@as(i64, @bitCast(offset)) +% addend) else offset;
        const piece = mergePiece(o, shndx, at) orelse return null;
        return .{ .key = piece.key, .offset = offset -% piece.start };
    }
    return .{ .key = sectionKey(o, shndx), .offset = offset };
}

/// GNU indirect function `s` of `o`: an 8-byte slot the loader fills
/// with the address its resolver returns (`x86_64_irelative`), and the
/// stub `jmp [rip + slot]` that stands for the function. Content-
/// addressed, so the symbols of one resolver share them.
fn ifuncAtoms(in: *Inputs, o: *const Object, s: u32) Allocator.Error!struct { slot: Atom, stub: Atom } {
    const sym = o.syms[s];
    const zeros: []const u8 = &@as([8]u8, @splat(0));
    const jmp: []const u8 = &[_]u8{ 0xff, 0x25, 0, 0, 0, 0, 0xcc, 0xcc };
    const slot_targets = try in.arena.dupe(SymbolKey, &.{sectionKey(o, sym.st_shndx)});
    const slot_relocs = try in.arena.dupe(Atom.Reloc, &.{.init(0, .x86_64_irelative, 0, @intCast(sym.st_value))});
    const slot: Atom = .{ .key = .fromContents(.data, .@"8", zeros, slot_targets, slot_relocs), .name = "", .section = .data, .alignment = .@"8", .bytes = zeros, .targets = slot_targets, .relocs = slot_relocs };
    const stub_targets = try in.arena.dupe(SymbolKey, &.{slot.key});
    const stub_relocs = try in.arena.dupe(Atom.Reloc, &.{.init(2, .x86_64_pc32, 0, -4)});
    const stub: Atom = .{ .key = .fromContents(.text, .@"8", jmp, stub_targets, stub_relocs), .name = o.symName(sym), .section = .text, .alignment = .@"8", .bytes = jmp, .targets = stub_targets, .relocs = stub_relocs };
    return .{ .slot = slot, .stub = stub };
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
/// link drops (not allocated, notes, .eh_frame, which `inputSections` copies).
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
    /// Their unwind and debug sections, which the link copies.
    sections: []const Elf.InputSection,
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
    var sections: std.ArrayList(Elf.InputSection) = .empty;
    var weak_used = false;
    var ifuncs: std.AutoHashMapUnmanaged(SymbolKey, void) = .empty;
    var c: Converter(@TypeOf(ctx)) = .{ .in = in, .ctx = ctx, .atoms = &atoms, .sections = &sections, .weak_used = &weak_used };
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
            // A global names its section's atom when it covers the whole
            // section, so that the atom's symbol has the symbol's size.
            if (sym.st_value == 0 and sym.st_shndx != elf.SHN_UNDEF and sym.st_shndx < o.shdrs.len and
                sym.st_size == o.shdrs[sym.st_shndx].sh_size) c.names[sym.st_shndx] = @intCast(s);
        }
        c.whole = try arena.realloc(c.whole, o.shdrs.len);
        @memset(c.whole, false);
        for (0..o.shdrs.len) |i| try c.section(@intCast(i));
        try c.inputSections();
        // GNU indirect functions (`ifunc`, `target_clones`): their stubs
        // and slots where the loader calls the resolvers, else refused
        // rather than linked as the resolvers.
        for (o.syms[1..], 1..) |sym, s_index| if (sym.st_type() == elf.STT_GNU_IFUNC and sym.st_shndx != elf.SHN_UNDEF and
            sym.st_shndx < o.shdrs.len and !o.discarded[sym.st_shndx])
        {
            if (!in.dynamic) {
                try in.errors.append(arena, try std.fmt.allocPrint(arena, "{s}: bs links GNU indirect functions (STT_GNU_IFUNC, from __attribute__((ifunc)) or __attribute__((target_clones))) only into executables that link libc and shared libraries, whose loader calls their resolvers: {s}", .{ o.path, o.symName(sym) }));
                continue;
            }
            const ifunc = try in.ifuncAtoms(o, @intCast(s_index));
            if ((try ifuncs.getOrPut(arena, ifunc.stub.key)).found_existing) continue;
            try atoms.appendSlice(arena, &.{ ifunc.slot, ifunc.stub });
        };
        for (o.syms[1..], 1..) |sym, s_index| {
            const ty = sym.st_type();
            // Assembly labels are STT_NOTYPE; the assembler's own `.L`
            // labels stay out, as upstream's.
            if (ty != elf.STT_FUNC and ty != elf.STT_OBJECT and ty != elf.STT_TLS and ty != elf.STT_NOTYPE) continue;
            if (sym.st_shndx >= o.shdrs.len or !c.whole[sym.st_shndx]) continue;
            const name = o.symName(sym);
            if (name.len == 0 or std.mem.startsWith(u8, name, ".L")) continue;
            // The definition the link keeps, unless the merged visibility
            // hides it.
            const bind: @FieldType(Elf.LocalSymbol, "bind") = if (in.lld and s_index >= o.first_global and in.isKept(o, @intCast(s_index), name) and
                (in.visibility.get(name) orelse 0) != 1 and (in.visibility.get(name) orelse 0) != 2)
                if (sym.st_bind() == elf.STB_WEAK) .weak else .global
            else
                .local;
            if (bind == .local and c.names[sym.st_shndx] == s_index) continue;
            try symbols.append(arena, .{ .name = name, .atom = sectionKey(o, sym.st_shndx), .offset = sym.st_value, .size = sym.st_size, .bind = bind });
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
    try sortArrays(arena, atoms.items, c.arrays.items);
    if (weak_used) try values.append(arena, .{ .key = undefined_weak_key, .value = 0 });
    try values.appendSlice(arena, c.abs_values.items);
    return .{ .atoms = atoms.items, .values = values.items, .symbols = symbols.items, .sections = sections.items };
}

/// The objects' globals a shared object exports, after `convert`: those
/// with default or protected visibility that the Zig code does not
/// define (`skip`), at their place in their sections' atoms, sorted by
/// name.
pub fn dynamicExports(in: *Inputs, skip: anytype) ![]ElfDynamic.Export {
    var out: std.ArrayList(ElfDynamic.Export) = .empty;
    var it = in.defs.iterator();
    while (it.next()) |d| {
        const name = d.key_ptr.*;
        if (try skip.zigExport(name) != null) continue;
        const o = &in.objects.items[d.value_ptr.object];
        const sym = o.syms[d.value_ptr.sym];
        const vis = in.visibility.get(name) orelse 0;
        if (vis == 1 or vis == 2) continue;
        const t = try in.symTarget(o, d.value_ptr.sym, 0) orelse continue;
        try out.append(in.arena, .{ .key = t.key, .name = name, .offset = t.offset, .size = sym.st_size, .weak = d.value_ptr.weak, .visibility = if (vis == 3) .protected else .default });
    }
    for (in.commons.keys(), in.commons.values()) |name, common| {
        if (in.defs.contains(name) or try skip.zigExport(name) != null) continue;
        const vis = in.visibility.get(name) orelse 0;
        if (vis == 1 or vis == 2) continue;
        try out.append(in.arena, .{ .key = commonKey(name), .name = name, .size = common.size, .visibility = if (vis == 3) .protected else .default });
    }
    std.mem.sortUnstable(ElfDynamic.Export, out.items, {}, struct {
        fn lt(_: void, a: ElfDynamic.Export, b: ElfDynamic.Export) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
    return out.items;
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
        sections: *std.ArrayList(Elf.InputSection),
        weak_used: *bool,
        abs_values: std.ArrayList(Elf.Value) = .empty,
        list: Atom.RelocList = .{},
        /// Per section of `o`: the symbol naming its atom, or 0.
        names: []u32 = &.{},
        /// Per section of `o`: whether it became one atom of its own.
        whole: []bool = &.{},
        /// Per section of `o`: its index in `sections`, or `no_input`.
        input_of: []u32 = &.{},
        /// How each global name the objects reference resolved.
        resolved: std.StringHashMapUnmanaged(?Target) = .empty,
        /// The init and fini arrays' atoms, in input order.
        arrays: std.ArrayList(ArrayAtom) = .empty,
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

        /// Reports `undefs`: "undefined symbol: X (referenced by a.o,
        /// b.o and 3 more objects)".
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
                return c.fail("{s}: bs does not link section '{s}' (legacy constructors and destructors); compile with .init_array", .{ o.path, name });
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

        const no_input = std.math.maxInt(u32);

        /// Adds `o`'s unwind and debug sections to `sections`: each debug
        /// section whole, and .eh_frame without the FDEs of sections the
        /// link dropped (later copies of a COMDAT group).
        fn inputSections(c: *C) !void {
            const o = c.o;
            const arena = c.in.arena;
            c.input_of = try arena.realloc(c.input_of, o.shdrs.len);
            @memset(c.input_of, no_input);
            for (o.shdrs, 0..) |sh, i| {
                if (o.discarded[i] or sh.sh_type == elf.SHT_NOBITS or sh.sh_type == elf.SHT_RELA) continue;
                const name = o.sectionName(i);
                const kind = Elf.InputKind.fromName(name) orelse continue;
                // Only an allocated .eh_frame is the unwinder's.
                if ((kind == .eh_frame) != (sh.sh_flags & elf.SHF_ALLOC != 0)) continue;
                if (sh.sh_flags & elf.SHF_COMPRESSED != 0) {
                    try c.fail("{s}: bs does not link compressed debug sections ('{s}') yet; compile without -gz", .{ o.path, name });
                    continue;
                }
                c.input_of[i] = @intCast(c.sections.items.len);
                try c.sections.append(arena, .{ .kind = kind, .name = o.path, .bytes = o.sectionBytes(i) });
            }
            for (c.input_of, 0..) |n, i| {
                if (n == no_input) continue;
                const s = &c.sections.items[n];
                c.list.targets.clearRetainingCapacity();
                var relocs: std.ArrayList(Elf.InputReloc) = .empty;
                if (s.kind == .eh_frame) try c.ehFrame(@intCast(i), s, &relocs) else try c.debugRelocs(@intCast(i), s, &relocs);
                s.targets = try arena.dupe(SymbolKey, c.list.targets.keys());
                s.relocs = relocs.items;
            }
        }

        /// The relocations of section `index`, sorted by offset.
        fn sortedRelas(c: *C, index: u32) ![]elf.Elf64_Rela {
            const o = c.o;
            if (o.rela_of[index] == 0) return &.{};
            const src = std.mem.bytesAsSlice(elf.Elf64_Rela, o.sectionBytes(o.rela_of[index]));
            const relas = try c.in.arena.alloc(elf.Elf64_Rela, src.len);
            for (relas, src) |*d, r| d.* = r;
            std.sort.pdq(elf.Elf64_Rela, relas, {}, struct {
                fn lt(_: void, a: elf.Elf64_Rela, b: elf.Elf64_Rela) bool {
                    return a.r_offset < b.r_offset;
                }
            }.lt);
            return relas;
        }

        const InputTarget = union(enum) {
            atom: Target,
            /// An input section of `sections`, and the offset in it.
            section: struct { index: u32, offset: u64 },
            constant: u64,
            /// Dropped by the link, or undefined.
            none,
        };

        /// Where a relocation of an unwind or debug section against
        /// symbol `s` points, `addend` bytes on.
        fn inputTarget(c: *C, s: u32, addend: i64) !InputTarget {
            const o = c.o;
            if (s >= o.syms.len) return .none;
            const sym = o.syms[s];
            const bind = sym.st_bind();
            const plus: u64 = @bitCast(addend);
            if (s >= o.first_global and (bind == elf.STB_GLOBAL or bind == elf.STB_WEAK)) {
                const gop = try c.resolved.getOrPut(c.in.arena, o.symName(sym));
                if (!gop.found_existing) gop.value_ptr.* = try c.resolve(gop.key_ptr.*, bind == elf.STB_WEAK);
                if (gop.value_ptr.*) |t| return if (t.import) .none else .{ .atom = t };
                if (sym.st_shndx == elf.SHN_ABS) return .{ .constant = sym.st_value +% plus };
                return .none;
            }
            const shndx = sym.st_shndx;
            if (shndx == elf.SHN_ABS) return .{ .constant = sym.st_value +% plus };
            if (shndx == elf.SHN_UNDEF or shndx >= elf.SHN_LORESERVE) return .none;
            if (c.input_of[shndx] != no_input) return .{ .section = .{ .index = c.input_of[shndx], .offset = sym.st_value } };
            if (o.discarded[shndx] or sectionOf(o, shndx) == null) return .none;
            return if (try c.in.symTarget(o, s, addend)) |t| .{ .atom = t } else .none;
        }

        /// Converts relocation `r` of an unwind or debug section. A
        /// reference to what the link dropped becomes `tombstone`, as
        /// lld's.
        fn inputReloc(c: *C, index: u32, relocs: *std.ArrayList(Elf.InputReloc), r: elf.Elf64_Rela, new_offset: u64, tombstone: u64) !void {
            const R = elf.R_X86_64;
            // aarch64's data relocations, as x86_64's of the same width.
            const ty: R = if (c.in.arch == .aarch64) switch (std.enums.fromInt(elf.R_AARCH64, r.r_type()) orelse return c.unsupported(index, r.r_type())) {
                .NONE => .NONE,
                .ABS32 => .@"32",
                .ABS64 => .@"64",
                .PREL32 => .PC32,
                else => return c.unsupported(index, r.r_type()),
            } else std.enums.fromInt(R, r.r_type()) orelse return c.unsupported(index, r.r_type());
            const wide = switch (ty) {
                .NONE => return,
                .@"32", .PC32, .DTPOFF32 => false,
                .@"64", .DTPOFF64 => true,
                else => return c.unsupported(index, r.r_type()),
            };
            var rel: Elf.InputReloc = .{ .offset = @intCast(new_offset), .target = 0, .addend = r.r_addend, .kind = undefined };
            switch (try c.inputTarget(r.r_sym(), r.r_addend)) {
                .atom => |t| {
                    rel.kind = switch (ty) {
                        .@"32" => .abs32,
                        .@"64" => .abs64,
                        .PC32 => .pc32,
                        .DTPOFF32 => .dtpoff32,
                        .DTPOFF64 => .dtpoff64,
                        else => unreachable,
                    };
                    const gop = try c.list.targets.getOrPut(c.in.arena, t.key);
                    rel.target = @intCast(gop.index);
                    rel.addend = @as(i64, @bitCast(t.offset)) +% r.r_addend;
                },
                .section => |t| {
                    if (ty != .@"32" and ty != .@"64") return c.unsupported(index, r.r_type());
                    rel.kind = if (wide) .offset64 else .offset32;
                    rel.target = t.index;
                    rel.addend = @as(i64, @bitCast(t.offset)) +% r.r_addend;
                },
                .constant => |v| {
                    rel.kind = if (wide) .const64 else .const32;
                    rel.addend = @bitCast(v);
                },
                .none => {
                    rel.kind = if (wide) .const64 else .const32;
                    rel.addend = @bitCast(tombstone);
                },
            }
            try relocs.append(c.in.arena, rel);
        }

        fn debugRelocs(c: *C, index: u32, s: *Elf.InputSection, relocs: *std.ArrayList(Elf.InputReloc)) !void {
            // A dropped function's range would end a DWARF 4 range or
            // location list as (0, 0); lld writes 1 there.
            const tombstone: u64 = @intFromBool(s.kind == .debug_ranges or s.kind == .debug_loc);
            for (try c.sortedRelas(index)) |r| {
                if (r.r_offset >= s.bytes.len) return c.fail("{s}: relocation at offset {d} past the end of section '{s}'", .{ c.o.path, r.r_offset, c.o.sectionName(index) });
                try c.inputReloc(index, relocs, r, r.r_offset, tombstone);
            }
        }

        /// Converts .eh_frame section `index`: its CIEs, and the FDEs of
        /// the sections the link keeps, each FDE's initial location a
        /// PC-relative relocation, as the unwinder's binary search table
        /// needs. The records stop at a terminator, if any.
        fn ehFrame(c: *C, index: u32, s: *Elf.InputSection, relocs: *std.ArrayList(Elf.InputReloc)) !void {
            const o = c.o;
            const bytes = s.bytes;
            const relas = try c.sortedRelas(index);
            const arena = c.in.arena;
            // Each record's start and length, and whether it is dropped.
            const Rec = struct { off: usize, len: usize, drop: bool };
            var recs: std.ArrayList(Rec) = .empty;
            var dropped = false;
            var off: usize = 0;
            var ri: usize = 0;
            while (bytes.len - off >= 4) {
                const len = std.mem.readInt(u32, bytes[off..][0..4], .little);
                if (len == 0) break;
                if (len == 0xffffffff or len < 4 or len > bytes.len - off - 4) return c.fail("{s}: malformed or 64-bit record at offset {d} of .eh_frame", .{ o.path, off });
                var drop = false;
                if (std.mem.readInt(u32, bytes[off + 4 ..][0..4], .little) != 0) {
                    while (ri < relas.len and relas[ri].r_offset < off + 8) ri += 1;
                    const pc32: u32 = if (c.in.arch == .aarch64) @backingInt(elf.R_AARCH64.PREL32) else @backingInt(elf.R_X86_64.PC32);
                    if (ri == relas.len or relas[ri].r_offset != off + 8 or relas[ri].r_type() != pc32)
                        return c.fail("{s}: the FDE at offset {d} of .eh_frame is not PC-relative, which bs does not link yet", .{ o.path, off });
                    drop = switch (try c.inputTarget(relas[ri].r_sym(), relas[ri].r_addend)) {
                        .atom => false,
                        else => true,
                    };
                    dropped = dropped or drop;
                }
                try recs.append(arena, .{ .off = off, .len = 4 + len, .drop = drop });
                off += 4 + len;
            }
            // Without dropped records, the section is copied as it is.
            var kept: []u8 = &.{};
            if (dropped) kept = try arena.alloc(u8, off);
            var at: usize = 0;
            var removed: usize = 0;
            ri = 0;
            for (recs.items) |rec| {
                while (ri < relas.len and relas[ri].r_offset < rec.off) ri += 1;
                if (rec.drop) {
                    removed += rec.len;
                    continue;
                }
                if (dropped) {
                    @memcpy(kept[at..][0..rec.len], bytes[rec.off..][0..rec.len]);
                    // An FDE's CIE pointer spans the records dropped
                    // between them.
                    const id = std.mem.readInt(u32, bytes[rec.off + 4 ..][0..4], .little);
                    if (id != 0) {
                        if (id > rec.off + 4) return c.fail("{s}: an FDE of .eh_frame points before the section", .{o.path});
                        const cie = rec.off + 4 - id;
                        var gap: usize = 0;
                        for (recs.items) |other| {
                            if (other.off >= cie and other.off < rec.off and other.drop) gap += other.len;
                        }
                        std.mem.writeInt(u32, kept[at + 4 ..][0..4], @intCast(id - gap), .little);
                    }
                }
                while (ri < relas.len and relas[ri].r_offset < rec.off + rec.len) : (ri += 1) {
                    try c.inputReloc(index, relocs, relas[ri], relas[ri].r_offset - removed, 0);
                }
                at += rec.len;
            }
            s.bytes = if (dropped) kept[0..at] else bytes[0..off];
            for (relocs.items) |r| switch (r.kind) {
                .pc32, .abs64, .abs32 => {},
                else => if (r.addend != 0 or (r.kind != .const32 and r.kind != .const64))
                    return c.fail("{s}: .eh_frame references a dropped section or a shared library's symbol, which bs does not link yet", .{o.path}),
            };
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
                try c.undefinedSymbol(name);
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
            // The image's own handle, which C++ code passes to
            // `__cxa_atexit` and `__cxa_thread_atexit`: crtbegin.o defines
            // it, which bs does not link, so the linker does, as lld.
            // Only its address matters, which must be in the image.
            if (std.mem.eql(u8, name, "__dso_handle")) {
                const key: SymbolKey = .fromName("obj:__dso_handle");
                try c.atoms.append(c.in.arena, .{ .key = key, .name = name, .section = .rodata, .alignment = .@"8", .bytes = &@as([8]u8, @splat(0)) });
                return .{ .key = key, .offset = 0 };
            }
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
            if (c.in.arch == .aarch64) {
                try c.relocA64(index, relas[k], bytes, copy);
                return 0;
            }
            const o = c.o;
            const r = relas[k];
            const off = r.r_offset;
            const ty = r.r_type();
            const R = elf.R_X86_64;
            if (off >= bytes.len) {
                try c.fail("{s}: relocation at offset {d} past the end of section '{s}'", .{ o.path, off, o.sectionName(index) });
                return 0;
            }
            // TLS descriptors (-mtls-dialect=gnu2, GCC's default in some
            // distributions): `lea rax, [rip + x@tlsdesc]; call [rax]`
            // leaves x's offset from the thread pointer in rax. An
            // executable's own thread-locals are in its static block, so
            // the lea becomes `mov rax, x@tpoff` (local-exec), a shared
            // library's `mov rax, [rip + slot]` (initial-exec, `tlsSlot`),
            // and the call a 2-byte nop, as ld relaxes them.
            // `_TLS_MODULE_BASE_`, the local-dynamic form's base, becomes
            // 0: its DTPOFF32 offsets become TPOFF32 ones, as after a
            // relaxed TLSLD.
            //
            // In a shared object the lea addresses the variable's descriptor
            // (`tlsPair`), which the loader completes, and the call stays.
            if (c.in.shared) switch (@as(R, @fromBackingInt(@intCast(ty)))) {
                .TLSDESC_CALL => return 0,
                .GOTPC32_TLSDESC => {
                    if (c.isTlsModuleBase(r.r_sym())) {
                        try c.fail("{s}: bs does not link _TLS_MODULE_BASE_ into shared objects yet; recompile with -mtls-dialect=gnu", .{o.path});
                        return 0;
                    }
                    const t = try c.target(r.r_sym(), 0) orelse return 0;
                    if (try c.sharedTlsImport(r, t)) return 0;
                    try c.add(off, .x86_64_pc32, .{ .key = try c.tlsPair(t, .x86_64_tlsdesc, try c.preemptible(r.r_sym())), .offset = 0 }, r.r_addend);
                    return 0;
                },
                .GOTTPOFF, .TPOFF32, .@"32", .@"32S" => {
                    try c.fail("{s}: relocation R_X86_64_{s} in section '{s}' cannot be used in a shared object; recompile with -fPIC", .{
                        o.path, @tagName(@as(R, @fromBackingInt(@intCast(ty)))), o.sectionName(index),
                    });
                    return 0;
                },
                else => {},
            };
            if (ty == @backingInt(R.TLSDESC_CALL)) {
                if (off + 2 > bytes.len or !std.mem.eql(u8, bytes[@intCast(off)..][0..2], &.{ 0xff, 0x10 })) {
                    try c.unsupported(index, ty);
                    return 0;
                }
                (try c.writable(bytes, copy))[@intCast(off)..][0..2].* = .{ 0x66, 0x90 };
                return 0;
            }
            if (ty == @backingInt(R.GOTPC32_TLSDESC)) {
                // lea r64, [rip + disp32], with r64 rax in practice.
                const rex = if (off >= 3) bytes[@intCast(off - 3)] else 0;
                const modrm = if (off >= 3) bytes[@intCast(off - 1)] else 0;
                if ((rex != 0x48 and rex != 0x4c) or bytes[@intCast(off - 2)] != 0x8d or modrm & 0xc7 != 0x05) {
                    try c.unsupported(index, ty);
                    return 0;
                }
                const b = try c.writable(bytes, copy);
                if (c.isTlsModuleBase(r.r_sym())) {
                    b[@intCast(off - 3)..][0..7].* = .{ if (rex == 0x4c) 0x49 else 0x48, 0xc7, 0xc0 | (modrm >> 3 & 7), 0, 0, 0, 0 };
                    return 0;
                }
                const t = try c.target(r.r_sym(), 0) orelse return 0;
                if (t.import) {
                    b[@intCast(off - 2)] = 0x8b; // lea -> mov
                    try c.add(off, .x86_64_pc32, .{ .key = try c.tlsSlot(t), .offset = 0 }, r.r_addend);
                    return 0;
                }
                b[@intCast(off - 3)..][0..3].* = .{ if (rex == 0x4c) 0x49 else 0x48, 0xc7, 0xc0 | (modrm >> 3 & 7) };
                try c.add(off, .x86_64_tpoff32, t, 0);
                return 0;
            }
            const t = try c.target(r.r_sym(), r.r_addend) orelse return 0;
            if (t.import) switch (@as(R, @fromBackingInt(@intCast(ty)))) {
                .TLSGD, .TLSLD, .DTPOFF32 => if (try c.sharedTlsImport(r, t)) return 0,
                else => {},
            };
            if (t.import) return c.importReloc(index, relas, k, bytes, copy);
            // A weak name nothing defines: a C-only executable that the
            // loader relocates imports it for its GOT loads and calls, as
            // lld does, so that a library loaded at run time (LD_PRELOAD)
            // may define it; its other references stay 0.
            if (t.key == undefined_weak_key and c.in.dynamic and !c.in.shared) switch (@as(R, @fromBackingInt(@intCast(ty)))) {
                .PLT32, .GOTPCREL, .GOTPCRELX, .REX_GOTPCRELX => |rt| if (try c.ctx.weakImport(c.o.symName(c.o.syms[r.r_sym()]))) |key| {
                    const imp: Target = .{ .key = key, .offset = 0, .import = true };
                    const via = if (rt == .PLT32) try c.stub(imp, .x86_64_abs64) else try c.slot(imp, .x86_64_abs64);
                    try c.add(off, .x86_64_pc32, .{ .key = via, .offset = 0 }, r.r_addend);
                    return 0;
                },
                else => {},
            };
            // A shared object reaches its exports with default visibility
            // through the loader, so that a definition in the executable
            // or an earlier library preempts them, as upstream's: -fPIC
            // code addresses them through the GOT and calls them through
            // the PLT for that. Others bind here.
            if (c.in.shared) switch (@as(R, @fromBackingInt(@intCast(ty)))) {
                .@"64", .PLT32, .GOTPCREL, .GOTPCRELX, .REX_GOTPCRELX => if (try c.preemptible(r.r_sym())) {
                    try c.preemptReloc(index, r, t, bytes, copy);
                    return 0;
                },
                else => {},
            };
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
                    try c.add(off, .x86_64_pc32, .{ .key = try c.slot(t, .x86_64_abs64), .offset = 0 }, r.r_addend);
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
                    // In a shared object the module's own thread-local:
                    // rdi points at a (module, offset) pair the loader
                    // completes (`tlsPair`), and the call stays.
                    if (c.in.shared) {
                        try c.add(off, .x86_64_pc32, .{ .key = try c.tlsPair(t, .x86_64_dtpmod64, try c.preemptible(r.r_sym())), .offset = 0 }, r.r_addend);
                        return 0;
                    }
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
                    // In a shared object, the module's pair (`ElfDynamic`),
                    // whatever thread-local of it names the module.
                    if (c.in.shared) {
                        try c.add(off, .x86_64_tlsld, .{ .key = t.key, .offset = 0 }, r.r_addend);
                        return 0;
                    }
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
                // With rax the thread pointer after the relaxed TLSLD; in a
                // shared object, the module's block.
                .DTPOFF32 => try c.add(off, if (c.in.shared) .x86_64_dtpoff32 else .x86_64_tpoff32, t, r.r_addend),
                else => try c.unsupported(index, ty),
            }
            return 0;
        }

        /// A relocation to a shared library's symbol: an absolute address
        /// stays one, which the loader writes; a call goes through a stub
        /// that jumps through the symbol's slot; GOT-relative code uses
        /// the slot. Data the code reaches PC-relative or by a 32-bit
        /// address (GCC's -fPIE and non-PIC code) is copied into the
        /// executable (`ctx.copySym`), and every reference then uses the
        /// copy. A thread-local is reached initial-exec, through a slot
        /// the loader writes its offset from the thread pointer into
        /// (`tlsSlot`): ld's relaxations of general-dynamic to
        /// initial-exec. Returns how many relocations after `k` the
        /// rewrite consumed, as `reloc`.
        fn importReloc(c: *C, index: u32, relas: []align(1) const elf.Elf64_Rela, k: usize, bytes: []const u8, copy: *?[]u8) !usize {
            const r = relas[k];
            const o = c.o;
            const off = r.r_offset;
            const sym = o.syms[r.r_sym()];
            const t: Target = .{ .key = (try c.target(r.r_sym(), r.r_addend)).?.key, .offset = 0 };
            const R = elf.R_X86_64;
            const ty: R = @fromBackingInt(@intCast(r.r_type()));
            switch (ty) {
                .@"64" => try c.add(off, .x86_64_abs64, t, r.r_addend),
                .GOTPCREL, .GOTPCRELX, .REX_GOTPCRELX => try c.add(off, .x86_64_pc32, .{ .key = try c.slot(t, .x86_64_abs64), .offset = 0 }, r.r_addend),
                .PLT32, .PC32 => {
                    const op = if (off >= 1) bytes[@intCast(off - 1)] else 0;
                    if (ty == .PLT32 or op == 0xe8 or op == 0xe9) {
                        try c.add(off, .x86_64_pc32, .{ .key = try c.stub(t, .x86_64_abs64), .offset = 0 }, r.r_addend);
                        return 0;
                    }
                    try c.add(off, .x86_64_pc32, .{ .key = try c.copied(index, sym) orelse return 0, .offset = 0 }, r.r_addend);
                },
                .@"32", .@"32S" => try c.add(off, if (ty == .@"32") .x86_64_abs32 else .x86_64_abs32s, .{ .key = try c.copied(index, sym) orelse return 0, .offset = 0 }, r.r_addend),
                // mov or add reg, [rip + x@gottpoff]: the slot is the GOT
                // entry, as is.
                .GOTTPOFF => try c.add(off, .x86_64_pc32, .{ .key = try c.tlsSlot(t), .offset = 0 }, r.r_addend),
                .TLSGD => {
                    const gd = [_]u8{ 0x66, 0x48, 0x8d, 0x3d };
                    if (off < 4 or off + 12 > bytes.len or !std.mem.eql(u8, bytes[@intCast(off - 4)..][0..4], &gd) or
                        !std.mem.eql(u8, bytes[@intCast(off + 4)..][0..4], &.{ 0x66, 0x66, 0x48, 0xe8 }) or !c.callsTlsGetAddr(relas, k, off + 8))
                    {
                        try c.unsupported(index, @backingInt(ty));
                        return 0;
                    }
                    const b = try c.writable(bytes, copy);
                    // mov rax, fs:0; add rax, [rip + x@gottpoff]
                    b[@intCast(off - 4)..][0..16].* = .{ 0x64, 0x48, 0x8b, 0x04, 0x25, 0, 0, 0, 0, 0x48, 0x03, 0x05, 0, 0, 0, 0 };
                    try c.add(off + 8, .x86_64_pc32, .{ .key = try c.tlsSlot(t), .offset = 0 }, -4);
                    return 1;
                },
                else => try c.fail("{s}: bs does not link relocation R_X86_64_{s} against {s}, which a shared library defines, yet", .{ o.path, @tagName(ty), o.symName(sym) }),
            }
            return 0;
        }

        /// The executable's copy of the data object `sym` names, or null
        /// after reporting that it is not one.
        fn copied(c: *C, index: u32, sym: elf.Elf64_Sym) !?SymbolKey {
            const o = c.o;
            if (try c.ctx.copySym(o.symName(sym))) |key| return key;
            try c.fail("{s}: section '{s}' takes the address of {s}, a function a shared library defines, without the GOT (non-PIC code does), which bs does not link yet; compile it with -fPIC", .{ o.path, o.sectionName(index), o.symName(sym) });
            return null;
        }

        /// A stub that jumps through `t`'s slot (`jmp [rip + slot]`, the
        /// slot's relocation of `kind`), content-addressed, so all calls
        /// to one target share it.
        fn stub(c: *C, t: Target, kind: Atom.Reloc.Kind) Allocator.Error!SymbolKey {
            const arena = c.in.arena;
            const targets = try arena.dupe(SymbolKey, &.{try c.slot(t, kind)});
            const relocs = try arena.dupe(Atom.Reloc, &.{.init(2, .x86_64_pc32, 0, -4)});
            const code: []const u8 = &.{ 0xff, 0x25, 0, 0, 0, 0 };
            const key: SymbolKey = .fromContents(.text, .@"8", code, targets, relocs);
            try c.atoms.append(arena, .{ .key = key, .name = "", .section = .text, .alignment = .@"8", .bytes = code, .targets = targets, .relocs = relocs });
            return key;
        }

        /// Whether `s` is `_TLS_MODULE_BASE_`, which the linker defines.
        fn isTlsModuleBase(c: *C, s: u32) bool {
            return s < c.o.syms.len and std.mem.eql(u8, c.o.symName(c.o.syms[s]), "_TLS_MODULE_BASE_");
        }

        /// Whether thread-local `t`, which relocation `r` names, is another
        /// module's in a shared object, which bs does not link yet, after
        /// reporting it.
        fn sharedTlsImport(c: *C, r: elf.Elf64_Rela, t: Target) !bool {
            if (!c.in.shared or !t.import) return false;
            try c.fail("{s}: bs does not import thread-local {s} into shared objects yet", .{ c.o.path, c.o.symName(c.o.syms[r.r_sym()]) });
            return true;
        }

        /// Whether symbol `s`, which the shared object defines, is one it
        /// exports with default visibility (`Inputs.dynamicExports`),
        /// which an executable may preempt. Indirect functions and the Zig
        /// code's exports bind locally.
        fn preemptible(c: *C, s: u32) !bool {
            const sym = c.o.syms[s];
            if (s < c.o.first_global or sym.st_bind() == elf.STB_LOCAL) return false;
            const name = c.o.symName(sym);
            if (try c.ctx.zigExport(name) != null) return false;
            if (c.in.visibility.contains(name)) return false;
            const d = c.in.defs.get(name) orelse return c.in.commons.contains(name);
            return c.in.objects.items[d.object].syms[d.sym].st_type() != elf.STT_GNU_IFUNC;
        }

        /// Converts relocation `r` against `t`, an export another module
        /// may preempt (`preemptible`): an address in data is the
        /// loader's, against the export, with the relocation's addend in
        /// the field; a GOT load reads a slot the loader fills; a call
        /// jumps through such a slot.
        fn preemptReloc(c: *C, index: u32, r: elf.Elf64_Rela, t: Target, bytes: []const u8, copy: *?[]u8) !void {
            const off = r.r_offset;
            switch (@as(elf.R_X86_64, @fromBackingInt(@intCast(r.r_type())))) {
                .@"64" => {
                    if (off + 8 > bytes.len) return c.unsupported(index, r.r_type());
                    std.mem.writeInt(i64, (try c.writable(bytes, copy))[@intCast(off)..][0..8], r.r_addend, .little);
                    try c.add(off, .x86_64_abs64_sym, t, 0);
                },
                .PLT32 => try c.add(off, .x86_64_pc32, .{ .key = try c.stub(t, .x86_64_abs64_sym), .offset = 0 }, r.r_addend),
                else => try c.add(off, .x86_64_pc32, .{ .key = try c.slot(t, .x86_64_abs64_sym), .offset = 0 }, r.r_addend),
            }
        }

        /// A shared object's 16-byte pair for its thread-local `t`, which
        /// the loader completes: with `.x86_64_dtpmod64`, the (module,
        /// offset) pair `__tls_get_addr` takes; with `.x86_64_tlsdesc`,
        /// its TLS descriptor. Relative to the symbol if `preempt`, so
        /// that an executable's definition wins as upstream's; else the
        /// module's own, whose offset in its block is known.
        /// Content-addressed, so references to one variable share it.
        fn tlsPair(c: *C, t: Target, kind: Atom.Reloc.Kind, preempt: bool) Allocator.Error!SymbolKey {
            const arena = c.in.arena;
            const targets = try arena.dupe(SymbolKey, &.{t.key});
            const off = std.math.cast(i32, t.offset) orelse {
                try c.fail("{s}: thread-local offset out of range", .{c.o.path});
                return t.key;
            };
            const relocs = if (kind == .x86_64_tlsdesc)
                try arena.dupe(Atom.Reloc, &.{.init(0, if (preempt) .x86_64_tlsdesc_sym else .x86_64_tlsdesc, 0, off)})
            else if (preempt)
                try arena.dupe(Atom.Reloc, &.{ .init(0, .x86_64_dtpmod64_sym, 0, off), .init(8, .x86_64_dtpoff64_sym, 0, off) })
            else
                try arena.dupe(Atom.Reloc, &.{ .init(0, .x86_64_dtpmod64, 0, 0), .init(8, .x86_64_dtpoff32, 0, off) });
            const zeros: []const u8 = &@as([16]u8, @splat(0));
            const key: SymbolKey = .fromContents(.data, .@"8", zeros, targets, relocs);
            try c.atoms.append(arena, .{ .key = key, .name = "", .section = .data, .alignment = .@"8", .bytes = zeros, .targets = targets, .relocs = relocs });
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
            const prefix, const name = switch (c.in.arch) {
                .x86_64 => .{ "R_X86_64_", if (std.enums.fromInt(elf.R_X86_64, ty)) |t| @tagName(t) else "unknown" },
                .aarch64 => .{ "R_AARCH64_", if (std.enums.fromInt(elf.R_AARCH64, ty)) |t| @tagName(t) else "unknown" },
            };
            try c.fail("{s}: bs does not link relocation {s}{s} ({d}) in section '{s}' yet", .{ c.o.path, prefix, name, ty, c.o.sectionName(index) });
        }

        /// Converts aarch64 relocation `r` of section `index`, in a static
        /// executable, where every target is the image's own: GOT loads
        /// keep their kinds, which the linker relaxes to the target's
        /// address (`Elf.aarch64Reloc`), and thread-locals reached through
        /// TLS descriptors or the GOT (initial-exec) become local-exec,
        /// rewriting the code in `copy` as lld relaxes it: the
        /// descriptor's `adrp` and `ldr` become nops, its `add` and `blr`
        /// `movz x0, #tprel_g1, lsl #16; movk x0, #tprel_g0_nc`, and the
        /// initial-exec `adrp` and `ldr` the same pair into their own
        /// register.
        fn relocA64(c: *C, index: u32, r: elf.Elf64_Rela, bytes: []const u8, copy: *?[]u8) !void {
            const o = c.o;
            if (r.r_offset + 4 > bytes.len) return c.fail("{s}: relocation at offset {d} past the end of section '{s}'", .{ o.path, r.r_offset, o.sectionName(index) });
            const R = elf.R_AARCH64;
            const ty = std.enums.fromInt(R, r.r_type()) orelse return c.unsupported(index, r.r_type());
            const at: usize = @intCast(r.r_offset);
            const insn = std.mem.readInt(u32, bytes[at..][0..4], .little);
            // The relaxed instruction, if this one changes.
            const relaxed: ?u32 = switch (ty) {
                .TLSDESC_ADR_PAGE21, .TLSDESC_LD64_LO12 => {
                    std.mem.writeInt(u32, (try c.writable(bytes, copy))[at..][0..4], 0xd503201f, .little); // nop
                    return;
                },
                .TLSDESC_ADD_LO12 => 0xd2a00000, // movz x0, #0, lsl #16
                .TLSDESC_CALL => 0xf2800000, // movk x0, #0
                .TLSIE_ADR_GOTTPREL_PAGE21 => if (insn & 0x9f000000 == 0x90000000) 0xd2a00000 | (insn & 0x1f) else return c.unsupported(index, r.r_type()),
                .TLSIE_LD64_GOTTPREL_LO12_NC => if (insn & 0xffc00000 == 0xf9400000) 0xf2800000 | (insn & 0x1f) else return c.unsupported(index, r.r_type()),
                else => null,
            };
            const kind: Atom.Reloc.Kind = switch (ty) {
                .TLSDESC_ADD_LO12, .TLSIE_ADR_GOTTPREL_PAGE21, .TLSLE_MOVW_TPREL_G1 => .aarch64_tprel_g1,
                .TLSDESC_CALL, .TLSIE_LD64_GOTTPREL_LO12_NC, .TLSLE_MOVW_TPREL_G0_NC => .aarch64_tprel_g0_nc,
                .NONE => return,
                .ABS64 => .aarch64_abs64,
                .ABS32 => .aarch64_abs32,
                .PREL32 => .aarch64_prel32,
                .CALL26, .JUMP26 => .aarch64_branch26,
                .ADR_PREL_PG_HI21, .ADR_PREL_PG_HI21_NC => .aarch64_page21,
                .ADD_ABS_LO12_NC, .LDST8_ABS_LO12_NC, .LDST16_ABS_LO12_NC, .LDST32_ABS_LO12_NC, .LDST64_ABS_LO12_NC, .LDST128_ABS_LO12_NC => .aarch64_pageoff12,
                .ADR_GOT_PAGE => .aarch64_got_load_page21,
                .LD64_GOT_LO12_NC => .aarch64_got_load_pageoff12,
                .TLSLE_ADD_TPREL_HI12 => .aarch64_tprel_hi12,
                .TLSLE_ADD_TPREL_LO12, .TLSLE_ADD_TPREL_LO12_NC => .aarch64_tprel_lo12_nc,
                else => return c.unsupported(index, r.r_type()),
            };
            if ((kind == .aarch64_got_load_page21 or kind == .aarch64_got_load_pageoff12) and r.r_addend != 0)
                return c.fail("{s}: GOT relocation with addend {d} in section '{s}'", .{ o.path, r.r_addend, o.sectionName(index) });
            const t = try c.target(r.r_sym(), r.r_addend) orelse return;
            if (t.import) return c.fail("{s}: bs does not link aarch64 objects against shared libraries yet ('{s}')", .{ o.path, o.symName(o.syms[r.r_sym()]) });
            if (relaxed) |v| std.mem.writeInt(u32, (try c.writable(bytes, copy))[at..][0..4], v, .little);
            try c.add(r.r_offset, kind, t, r.r_addend);
        }

        fn writable(c: *C, bytes: []const u8, copy: *?[]u8) Allocator.Error![]u8 {
            if (copy.*) |b| return b;
            const b = try c.in.arena.dupe(u8, bytes);
            copy.* = b;
            return b;
        }

        /// An 8-byte slot holding `t`'s address, for GOT-relative code that
        /// cannot be relaxed: content-addressed, so references to one
        /// target share it. `kind` is `.x86_64_abs64`, or
        /// `.x86_64_abs64_sym` for an export the loader may preempt.
        fn slot(c: *C, t: Target, kind: Atom.Reloc.Kind) Allocator.Error!SymbolKey {
            const arena = c.in.arena;
            const targets = try arena.dupe(SymbolKey, &.{t.key});
            const off = std.math.cast(i32, t.offset) orelse {
                try c.fail("{s}: GOT entry offset out of range", .{c.o.path});
                return t.key;
            };
            const relocs = try arena.dupe(Atom.Reloc, &.{.init(0, kind, 0, off)});
            const zeros: []const u8 = &@as([8]u8, @splat(0));
            const key: SymbolKey = .fromContents(.rodata, .@"8", zeros, targets, relocs);
            try c.atoms.append(arena, .{ .key = key, .name = "", .section = .rodata, .alignment = .@"8", .bytes = zeros, .targets = targets, .relocs = relocs });
            return key;
        }

        /// An 8-byte slot holding import `t`'s offset from the thread
        /// pointer, which the loader writes (TPOFF64): initial-exec code's
        /// GOT entry, content-addressed as `slot`.
        fn tlsSlot(c: *C, t: Target) Allocator.Error!SymbolKey {
            const arena = c.in.arena;
            const targets = try arena.dupe(SymbolKey, &.{t.key});
            const relocs = try arena.dupe(Atom.Reloc, &.{.init(0, .x86_64_tpoff64, 0, 0)});
            const zeros: []const u8 = &@as([8]u8, @splat(0));
            const key: SymbolKey = .fromContents(.rodata, .@"8", zeros, targets, relocs);
            try c.atoms.append(arena, .{ .key = key, .name = "", .section = .rodata, .alignment = .@"8", .bytes = zeros, .targets = targets, .relocs = relocs });
            return key;
        }
    };
}
