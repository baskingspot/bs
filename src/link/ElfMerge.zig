//! Relocatable links (`ld -r`): one x86_64 or aarch64 ET_REL from several, for
//! `bs build-obj` with object inputs or C sources, as upstream's
//! `flushObject` merges its Zig object with them (docs/slop/architecture.md,
//! "Relocatable links").
//!
//! The inputs stay as they are, not converted to Atoms: sections with the
//! same name (and COMDAT group) are concatenated in input order, each
//! input's piece at its alignment; symbols and relocations are renumbered
//! and moved by the pieces' offsets, so the output links as the inputs
//! would.
//!
//! - COMDAT: a group whose signature an earlier input has is dropped, with
//!   its members; their global symbols resolve to the kept copy by name.
//!   Kept groups get a `.group` section listing their members and the
//!   members' relocation sections.
//! - Symbols: each output section's section symbol, then every input's
//!   local symbols (not section symbols, which become the output
//!   section's, with the piece's offset in the relocation's addend), then
//!   the globals, one per name in first-seen order: a strong definition
//!   over a weak one over COMMON (the largest) over references; two strong
//!   definitions are an error; a reference is weak only if every
//!   reference is; the most restrictive visibility wins.
//! - .eh_frame: each input's records without zero terminators, and
//!   without the FDEs of dropped sections.
//! - Relocations against a dropped section's symbols from a debug section
//!   become relocations to nothing (value 0); from an allocated one, an
//!   error.
//! - `.llvm_addrsig` (symbol indices for identical-code folding) is
//!   dropped.

const std = @import("std");
const elf = std.elf;
const Allocator = std.mem.Allocator;
const ElfInput = @import("ElfInput.zig");
const Atom = @import("Atom.zig");

pub const Input = struct { path: []const u8, bytes: []const u8 };

pub const Error = error{ OutOfMemory, InvalidObject, DuplicateSymbol, UnsupportedObject };

const Object = ElfInput.Object;

/// An output section: the input sections placed in it.
const OutSection = struct {
    name: []const u8,
    type: u32,
    flags: u64,
    entsize: u64,
    alignment: u64 = 1,
    size: u64 = 0,
    /// The kept group whose member it is, or `no_group`.
    group: u32,
    pieces: std.ArrayList(Piece) = .empty,
    relas: std.ArrayList(elf.Elf64_Rela) = .empty,
};

const Piece = struct { object: u32, section: u32, bytes: []const u8, offset: u64 };

const no_group = std.math.maxInt(u32);
const unmapped = std.math.maxInt(u32);

const Global = struct {
    name: []const u8,
    sym: elf.Elf64_Sym,
    /// Defined: an input symbol's section, as an output section and
    /// offset (or SHN_ABS / SHN_COMMON); else undefined.
    defined: bool = false,
    weak_def: bool = false,
    common: bool = false,
    /// Some reference is strong.
    strong_ref: bool = false,
    path: []const u8,
};

/// The merged object, allocated with `gpa`. `diag` gets a message for
/// `DuplicateSymbol` and `UnsupportedObject`, allocated with `arena`.
pub fn merge(gpa: Allocator, arena: Allocator, inputs: []const Input, arch: Atom.Unwind.Arch, diag: *[]const u8) Error![]u8 {
    const objects = try arena.alloc(Object, inputs.len);
    for (objects, inputs) |*o, in| o.* = ElfInput.parseObjectFor(arena, in.path, in.bytes, arch) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => {
            diag.* = try arena.print("{s}: not an {t} ELF relocatable object", .{ in.path, arch });
            return error.InvalidObject;
        },
    };

    // COMDAT groups: the first of each signature is kept.
    const Group = struct { object: u32, section: u32, sig: u32 };
    var kept_groups: std.ArrayList(Group) = .empty;
    var signatures: std.StringHashMapUnmanaged(void) = .empty;
    const group_of = try arena.alloc([]u32, objects.len);
    for (objects, group_of, 0..) |*o, *g, oi| {
        g.* = try arena.alloc(u32, o.shdrs.len);
        @memset(g.*, no_group);
        for (o.shdrs, 0..) |sh, si| {
            if (sh.sh_type != elf.SHT_GROUP) continue;
            if (sh.sh_info >= o.syms.len or sh.sh_size < 4) return invalid(arena, diag, o, "malformed section group");
            const words = std.mem.bytesAsSlice(u32, o.bytes[@intCast(sh.sh_offset)..][0..@intCast(sh.sh_size & ~@as(u64, 3))]);
            const sig_sym = o.syms[sh.sh_info];
            const sig = if (sig_sym.st_type() == elf.STT_SECTION) o.sectionName(sig_sym.st_shndx) else o.symName(sig_sym);
            const comdat = words[0] & elf.GRP_COMDAT != 0;
            const drop = comdat and (try signatures.getOrPut(arena, sig)).found_existing;
            const index: u32 = @intCast(kept_groups.items.len);
            if (!drop) try kept_groups.append(arena, .{ .object = @intCast(oi), .section = @intCast(si), .sig = sh.sh_info });
            for (words[1..]) |m| {
                if (m >= o.shdrs.len) return invalid(arena, diag, o, "section group member out of range");
                if (drop) o.discarded[m] = true else g.*[m] = index;
            }
        }
    }

    // Output sections, by name and group, in first-seen order.
    var outs: std.ArrayList(OutSection) = .empty;
    var out_index: std.StringHashMapUnmanaged(u32) = .empty;
    // Per input section: its output section and offset there.
    const place = try arena.alloc([]u32, objects.len);
    const base = try arena.alloc([]u64, objects.len);
    // Per input .eh_frame: kept bytes' offsets (`EhMap`).
    const eh_maps = try arena.alloc([]?EhMap, objects.len);
    for (objects, place, base, eh_maps, 0..) |*o, *p, *b, *em, oi| {
        p.* = try arena.alloc(u32, o.shdrs.len);
        b.* = try arena.alloc(u64, o.shdrs.len);
        em.* = try arena.alloc(?EhMap, o.shdrs.len);
        @memset(p.*, unmapped);
        @memset(em.*, null);
        for (o.shdrs, 0..) |sh, si| {
            if (o.discarded[si] or !isContent(sh)) continue;
            const name = o.sectionName(si);
            const is_eh = std.mem.eql(u8, name, ".eh_frame");
            var bytes = o.sectionBytes(si);
            if (is_eh) {
                const m = try ehFrame(arena, o, @intCast(si), diag);
                bytes = m.bytes;
                em.*[si] = m;
            }
            const group = group_of[oi][si];
            const key = if (group == no_group) name else try arena.print("{s}\x00{d}", .{ name, group });
            const gop = try out_index.getOrPut(arena, key);
            if (!gop.found_existing) {
                gop.value_ptr.* = @intCast(outs.items.len);
                try outs.append(arena, .{
                    .name = name,
                    .type = if (is_eh and arch == .x86_64) elf.SHT_X86_64_UNWIND else sh.sh_type,
                    .flags = sh.sh_flags & ~@as(u64, elf.SHF_GROUP),
                    .entsize = sh.sh_entsize,
                    .group = group,
                });
            }
            const out = &outs.items[gop.value_ptr.*];
            if (out.type != sh.sh_type and !is_eh) {
                // .bss pieces in a PROGBITS section are zeros.
                if (out.type == elf.SHT_NOBITS and sh.sh_type == elf.SHT_PROGBITS) out.type = elf.SHT_PROGBITS else if (!(out.type == elf.SHT_PROGBITS and sh.sh_type == elf.SHT_NOBITS))
                    return unsupported("{s}: section '{s}' has type {d}, another input's {d}", arena, diag, .{ o.path, name, sh.sh_type, out.type });
            }
            const flags = sh.sh_flags & ~@as(u64, elf.SHF_GROUP);
            // Merged entries of another size are only concatenated.
            if (out.flags & elf.SHF_MERGE != 0 and (flags & elf.SHF_MERGE == 0 or out.entsize != sh.sh_entsize or (out.flags ^ flags) & elf.SHF_STRINGS != 0)) {
                out.flags &= ~@as(u64, elf.SHF_MERGE | elf.SHF_STRINGS);
                out.entsize = 0;
            }
            out.flags |= flags & ~@as(u64, elf.SHF_MERGE | elf.SHF_STRINGS);
            const alignment = @max(sh.sh_addralign, 1);
            out.alignment = @max(out.alignment, alignment);
            // .eh_frame records follow each other without padding, which
            // linkers would read as a terminator; they are 4-byte aligned.
            out.size = std.mem.alignForward(u64, out.size, if (is_eh) 4 else alignment);
            p.*[si] = gop.value_ptr.*;
            b.*[si] = out.size;
            try out.pieces.append(arena, .{ .object = @intCast(oi), .section = @intCast(si), .bytes = if (sh.sh_type == elf.SHT_NOBITS) &.{} else bytes, .offset = out.size });
            out.size += if (sh.sh_type == elf.SHT_NOBITS) sh.sh_size else bytes.len;
        }
    }

    // Symbols: section symbols, locals, then globals.
    var locals: std.ArrayList(elf.Elf64_Sym) = .empty;
    var strtab: std.ArrayList(u8) = .empty;
    try strtab.append(arena, 0);
    var globals: std.ArrayList(Global) = .empty;
    var global_index: std.StringHashMapUnmanaged(u32) = .empty;
    const sym_map = try arena.alloc([]u32, objects.len);
    // Global symbols' indices are relative to the first global until all
    // locals are known (`global_bit`).
    const global_bit: u32 = 1 << 31;
    for (objects, sym_map, 0..) |*o, *sm, oi| {
        sm.* = try arena.alloc(u32, o.syms.len);
        @memset(sm.*, 0);
        for (o.syms, 0..) |sym, s| {
            if (s == 0) continue;
            const bind = sym.st_bind();
            const shndx = sym.st_shndx;
            const in_section = shndx != elf.SHN_UNDEF and shndx < elf.SHN_LORESERVE;
            if (s < o.first_global or (bind != elf.STB_GLOBAL and bind != elf.STB_WEAK and bind != elf.STB_GNU_UNIQUE)) {
                // Section symbols map through `relocTarget`.
                if (sym.st_type() == elf.STT_SECTION) continue;
                if (in_section and place[oi][shndx] == unmapped) continue;
                var out = sym;
                out.st_name = try addString(arena, &strtab, o.symName(sym));
                if (in_section) {
                    out.st_shndx = @intCast(sectionIndex(kept_groups.items.len, place[oi][shndx]));
                    out.st_value += base[oi][shndx];
                }
                sm.*[s] = @intCast(1 + outs.items.len + locals.items.len);
                try locals.append(arena, out);
                continue;
            }
            const name = o.symName(sym);
            const gop = try global_index.getOrPut(arena, name);
            if (!gop.found_existing) {
                gop.value_ptr.* = @intCast(globals.items.len);
                try globals.append(arena, .{ .name = name, .sym = std.mem.zeroes(elf.Elf64_Sym), .path = o.path });
                globals.items[gop.value_ptr.*].sym.st_info = sym.st_info;
                globals.items[gop.value_ptr.*].sym.st_other = sym.st_other;
            }
            sm.*[s] = global_bit | gop.value_ptr.*;
            const g = &globals.items[gop.value_ptr.*];
            // The most restrictive visibility; a type a reference gives.
            const vis = sym.st_other & 3;
            const gvis = g.sym.st_other & 3;
            if (vis != 0 and (gvis == 0 or vis < gvis)) g.sym.st_other = (g.sym.st_other & ~@as(u8, 3)) | vis;
            if (g.sym.st_type() == elf.STT_NOTYPE and sym.st_type() != elf.STT_NOTYPE) g.sym.st_info = (g.sym.st_info & 0xf0) | sym.st_type();
            const undefined_here = shndx == elf.SHN_UNDEF or (in_section and place[oi][shndx] == unmapped);
            if (undefined_here) {
                if (bind == elf.STB_GLOBAL) g.strong_ref = true;
                continue;
            }
            // GCC's unique globals may repeat, as weak ones.
            const weak = bind == elf.STB_WEAK or bind == elf.STB_GNU_UNIQUE;
            if (shndx == elf.SHN_COMMON) {
                if (g.defined) continue;
                g.common = true;
                g.sym.st_shndx = elf.SHN_COMMON;
                g.sym.st_size = @max(g.sym.st_size, sym.st_size);
                g.sym.st_value = @max(g.sym.st_value, sym.st_value);
                g.sym.st_info = sym.st_info;
                continue;
            }
            if (g.defined) {
                if (!g.weak_def and !weak) return dup(arena, diag, name, g.path, o.path);
                if (!g.weak_def or weak) continue;
            }
            g.defined = true;
            g.common = false;
            g.weak_def = weak;
            g.path = o.path;
            g.sym.st_info = sym.st_info;
            g.sym.st_size = sym.st_size;
            g.sym.st_shndx = if (in_section) @intCast(sectionIndex(kept_groups.items.len, place[oi][shndx])) else shndx;
            g.sym.st_value = sym.st_value + if (in_section) base[oi][shndx] else 0;
        }
    }
    const first_global: u32 = @intCast(1 + outs.items.len + locals.items.len);
    for (globals.items) |*g| {
        g.sym.st_name = try addString(arena, &strtab, g.name);
        if (!g.defined and !g.common) {
            g.sym.st_shndx = elf.SHN_UNDEF;
            g.sym.st_value = 0;
            g.sym.st_size = 0;
            const bind: u8 = if (g.strong_ref) elf.STB_GLOBAL else elf.STB_WEAK;
            g.sym.st_info = (bind << 4) | g.sym.st_type();
        }
    }

    // Relocations, renumbered and moved.
    for (objects, 0..) |*o, oi| {
        for (o.shdrs, 0..) |sh, ri| {
            if (sh.sh_type == elf.SHT_REL) return unsupported("{s}: SHT_REL relocations", arena, diag, .{o.path});
            if (sh.sh_type != elf.SHT_RELA) continue;
            const target = sh.sh_info;
            if (target >= o.shdrs.len or place[oi][target] == unmapped) continue;
            const out = &outs.items[place[oi][target]];
            const alloc = out.flags & elf.SHF_ALLOC != 0;
            const relas = std.mem.bytesAsSlice(elf.Elf64_Rela, o.bytes[@intCast(o.shdrs[ri].sh_offset)..][0..@intCast(o.shdrs[ri].sh_size)]);
            try out.relas.ensureUnusedCapacity(arena, relas.len);
            for (relas) |r| {
                var offset = r.r_offset;
                if (eh_maps[oi][target]) |m| offset = m.map(offset) orelse continue;
                var addend = r.r_addend;
                var sym: u32 = 0;
                const s = r.r_sym();
                if (s >= o.syms.len) return invalid(arena, diag, o, "relocation against a symbol that does not exist");
                if (s != 0) {
                    const isym = o.syms[s];
                    const mapped = sym_map[oi][s];
                    if (mapped & global_bit != 0) {
                        sym = first_global + (mapped & ~global_bit);
                    } else if (mapped != 0) {
                        sym = mapped;
                    } else if (isym.st_type() == elf.STT_SECTION and isym.st_shndx < o.shdrs.len and place[oi][isym.st_shndx] != unmapped) {
                        sym = 1 + place[oi][isym.st_shndx];
                        addend += @intCast(base[oi][isym.st_shndx]);
                    } else if (!alloc) {
                        // A dropped section's: nothing.
                        addend = 0;
                    } else {
                        return unsupported("{s}: section '{s}' refers to dropped section '{s}'", arena, diag, .{ o.path, o.sectionName(target), if (isym.st_shndx < o.shdrs.len) o.sectionName(isym.st_shndx) else "?" });
                    }
                }
                out.relas.appendAssumeCapacity(.{
                    .r_offset = offset + base[oi][target],
                    .r_info = (@as(u64, sym) << 32) | r.r_type(),
                    .r_addend = addend,
                });
            }
        }
    }

    return write(gpa, arena, objects, outs.items, kept_groups.items, sym_map, locals.items, globals.items, first_global, strtab.items, arch);
}

/// Section header index of output section `i`: after the null section
/// and the groups.
fn sectionIndex(n_groups: usize, i: u32) usize {
    return 1 + n_groups + i;
}

fn write(
    gpa: Allocator,
    arena: Allocator,
    objects: []const Object,
    outs: []OutSection,
    groups: anytype,
    sym_map: []const []const u32,
    locals: []const elf.Elf64_Sym,
    globals: []const Global,
    first_global: u32,
    strtab: []const u8,
    arch: Atom.Unwind.Arch,
) Error![]u8 {
    const n_groups = groups.len;
    // Output sections with relocations get a .rela section each, after the
    // contents.
    var n_rela: usize = 0;
    for (outs) |o| n_rela += @intFromBool(o.relas.items.len != 0);
    const n_sections = 1 + n_groups + outs.len + n_rela + 3;
    if (n_sections >= elf.SHN_LORESERVE) return error.UnsupportedObject;
    const symtab_index = n_sections - 3;
    var shstrtab: std.ArrayList(u8) = .empty;
    try shstrtab.append(arena, 0);
    const shdrs = try arena.alloc(elf.Elf64_Shdr, n_sections);
    shdrs[0] = std.mem.zeroes(elf.Elf64_Shdr);

    // Each kept group: its members and their relocation sections.
    const rela_index = try arena.alloc(u32, outs.len);
    {
        var next: u32 = @intCast(1 + n_groups + outs.len);
        for (outs, rela_index) |o, *ri| {
            ri.* = 0;
            if (o.relas.items.len == 0) continue;
            ri.* = next;
            next += 1;
        }
    }
    const group_bytes = try arena.alloc([]u8, n_groups);
    for (groups, group_bytes, 0..) |g, *gb, gi| {
        var words: std.ArrayList(u32) = .empty;
        try words.append(arena, elf.GRP_COMDAT);
        for (outs, 0..) |o, i| if (o.group == gi) {
            try words.append(arena, @intCast(sectionIndex(n_groups, @intCast(i))));
            if (rela_index[i] != 0) try words.append(arena, rela_index[i]);
        };
        gb.* = std.mem.sliceAsBytes(words.items);
        const o = &objects[g.object];
        const words_in = std.mem.bytesAsSlice(u32, o.bytes[@intCast(o.shdrs[g.section].sh_offset)..][0..4]);
        words.items[0] = words_in[0];
        const sig = sym_map[g.object][g.sig];
        shdrs[1 + gi] = .{
            .sh_name = try addString(arena, &shstrtab, ".group"),
            .sh_type = elf.SHT_GROUP,
            .sh_flags = 0,
            .sh_addr = 0,
            .sh_offset = 0,
            .sh_size = gb.len,
            .sh_link = @intCast(symtab_index),
            .sh_info = if (sig & (1 << 31) != 0) first_global + (sig & ~@as(u32, 1 << 31)) else if (sig != 0) sig else 1 + @as(u32, @intCast(sectionOfGroup(outs, gi))),
            .sh_addralign = 4,
            .sh_entsize = 4,
        };
    }

    // Layout: the header, then each section's bytes at its alignment, then
    // the section headers.
    var off: u64 = @sizeOf(elf.Elf64_Ehdr);
    for (group_bytes, 0..) |gb, gi| {
        off = std.mem.alignForward(u64, off, 4);
        shdrs[1 + gi].sh_offset = off;
        off += gb.len;
    }
    for (outs, 0..) |o, i| {
        const idx = sectionIndex(n_groups, @intCast(i));
        off = std.mem.alignForward(u64, off, o.alignment);
        shdrs[idx] = .{
            .sh_name = try addString(arena, &shstrtab, o.name),
            .sh_type = o.type,
            .sh_flags = o.flags | if (o.group != no_group) @as(u64, elf.SHF_GROUP) else 0,
            .sh_addr = 0,
            .sh_offset = off,
            .sh_size = o.size,
            .sh_link = 0,
            .sh_info = 0,
            .sh_addralign = o.alignment,
            .sh_entsize = o.entsize,
        };
        if (o.type != elf.SHT_NOBITS) off += o.size;
    }
    for (outs, 0..) |o, i| {
        if (rela_index[i] == 0) continue;
        off = std.mem.alignForward(u64, off, 8);
        const name = try arena.print(".rela{s}", .{o.name});
        shdrs[rela_index[i]] = .{
            .sh_name = try addString(arena, &shstrtab, name),
            .sh_type = elf.SHT_RELA,
            .sh_flags = elf.SHF_INFO_LINK | if (o.group != no_group) @as(u64, elf.SHF_GROUP) else 0,
            .sh_addr = 0,
            .sh_offset = off,
            .sh_size = o.relas.items.len * @sizeOf(elf.Elf64_Rela),
            .sh_link = @intCast(symtab_index),
            .sh_info = @intCast(sectionIndex(n_groups, @intCast(i))),
            .sh_addralign = 8,
            .sh_entsize = @sizeOf(elf.Elf64_Rela),
        };
        off += o.relas.items.len * @sizeOf(elf.Elf64_Rela);
    }
    const n_syms = 1 + outs.len + locals.len + globals.len;
    off = std.mem.alignForward(u64, off, 8);
    shdrs[symtab_index] = .{
        .sh_name = try addString(arena, &shstrtab, ".symtab"),
        .sh_type = elf.SHT_SYMTAB,
        .sh_flags = 0,
        .sh_addr = 0,
        .sh_offset = off,
        .sh_size = n_syms * @sizeOf(elf.Elf64_Sym),
        .sh_link = @intCast(symtab_index + 1),
        .sh_info = first_global,
        .sh_addralign = 8,
        .sh_entsize = @sizeOf(elf.Elf64_Sym),
    };
    off += n_syms * @sizeOf(elf.Elf64_Sym);
    shdrs[symtab_index + 1] = .{
        .sh_name = try addString(arena, &shstrtab, ".strtab"),
        .sh_type = elf.SHT_STRTAB,
        .sh_flags = 0,
        .sh_addr = 0,
        .sh_offset = off,
        .sh_size = strtab.len,
        .sh_link = 0,
        .sh_info = 0,
        .sh_addralign = 1,
        .sh_entsize = 0,
    };
    off += strtab.len;
    const shstr_name = try addString(arena, &shstrtab, ".shstrtab");
    shdrs[symtab_index + 2] = .{
        .sh_name = shstr_name,
        .sh_type = elf.SHT_STRTAB,
        .sh_flags = 0,
        .sh_addr = 0,
        .sh_offset = off,
        .sh_size = shstrtab.items.len,
        .sh_link = 0,
        .sh_info = 0,
        .sh_addralign = 1,
        .sh_entsize = 0,
    };
    off += shstrtab.items.len;
    off = std.mem.alignForward(u64, off, 8);
    const shoff = off;
    off += n_sections * @sizeOf(elf.Elf64_Shdr);

    const out = try gpa.alloc(u8, @intCast(off));
    errdefer gpa.free(out);
    @memset(out, 0);
    const eh: elf.Elf64_Ehdr = .{
        .e_ident = .{ 0x7f, 'E', 'L', 'F', elf.ELFCLASS64, elf.ELFDATA2LSB, 1, 0 } ++ @as([8]u8, @splat(0)),
        .e_type = .REL,
        .e_machine = switch (arch) {
            .x86_64 => .X86_64,
            .aarch64 => .AARCH64,
        },
        .e_version = 1,
        .e_entry = 0,
        .e_phoff = 0,
        .e_shoff = shoff,
        .e_flags = 0,
        .e_ehsize = @sizeOf(elf.Elf64_Ehdr),
        .e_phentsize = 0,
        .e_phnum = 0,
        .e_shentsize = @sizeOf(elf.Elf64_Shdr),
        .e_shnum = @intCast(n_sections),
        .e_shstrndx = @intCast(symtab_index + 2),
    };
    @memcpy(out[0..@sizeOf(elf.Elf64_Ehdr)], std.mem.asBytes(&eh));
    for (group_bytes, 0..) |gb, gi| @memcpy(out[@intCast(shdrs[1 + gi].sh_offset)..][0..gb.len], gb);
    for (outs, 0..) |o, i| {
        if (o.type == elf.SHT_NOBITS) continue;
        const start = shdrs[sectionIndex(n_groups, @intCast(i))].sh_offset;
        for (o.pieces.items) |p| @memcpy(out[@intCast(start + p.offset)..][0..p.bytes.len], p.bytes);
    }
    for (outs, 0..) |o, i| {
        if (rela_index[i] == 0) continue;
        @memcpy(out[@intCast(shdrs[rela_index[i]].sh_offset)..][0 .. o.relas.items.len * @sizeOf(elf.Elf64_Rela)], std.mem.sliceAsBytes(o.relas.items));
    }
    var syms = std.mem.bytesAsSlice(elf.Elf64_Sym, out[@intCast(shdrs[symtab_index].sh_offset)..][0 .. n_syms * @sizeOf(elf.Elf64_Sym)]);
    syms[0] = std.mem.zeroes(elf.Elf64_Sym);
    for (outs, 1..) |_, i| syms[i] = .{
        .st_name = 0,
        .st_info = elf.STT_SECTION, // STB_LOCAL
        .st_other = 0,
        .st_shndx = @intCast(sectionIndex(n_groups, @intCast(i - 1))),
        .st_value = 0,
        .st_size = 0,
    };
    @memcpy(syms[1 + outs.len ..][0..locals.len], locals);
    for (globals, syms[first_global..]) |g, *s| s.* = g.sym;
    @memcpy(out[@intCast(shdrs[symtab_index + 1].sh_offset)..][0..strtab.len], strtab);
    @memcpy(out[@intCast(shdrs[symtab_index + 2].sh_offset)..][0..shstrtab.items.len], shstrtab.items);
    @memcpy(out[@intCast(shoff)..][0 .. n_sections * @sizeOf(elf.Elf64_Shdr)], std.mem.sliceAsBytes(shdrs));
    return out;
}

/// The first output section of group `gi`, whose section symbol stands
/// for a signature that was a dropped section's symbol.
fn sectionOfGroup(outs: []const OutSection, gi: usize) usize {
    for (outs, 0..) |o, i| if (o.group == gi) return i;
    return 0;
}

/// Whether input section `sh` is content the output keeps.
fn isContent(sh: elf.Elf64_Shdr) bool {
    return switch (sh.sh_type) {
        elf.SHT_NULL, elf.SHT_SYMTAB, elf.SHT_STRTAB, elf.SHT_RELA, elf.SHT_REL, elf.SHT_GROUP, elf.SHT_SYMTAB_SHNDX => false,
        // Symbol indices for identical-code folding, which a merge would
        // have to renumber.
        elf.SHT_LLVM_ADDRSIG => false,
        else => true,
    };
}

/// An input .eh_frame without its zero terminators and the FDEs of dropped
/// sections: the kept bytes, and where kept input offsets moved.
const EhMap = struct {
    bytes: []const u8,
    /// Kept records' input offsets and lengths, and where each moved.
    recs: []const EhRec,

    fn map(m: EhMap, offset: u64) ?u64 {
        for (m.recs) |r| if (offset >= r.off and offset < r.off + r.len) return offset - r.off + r.to;
        return null;
    }
};

const EhRec = struct { off: u64, len: u64, to: u64 };

fn ehFrame(arena: Allocator, o: *const Object, index: u32, diag: *[]const u8) Error!EhMap {
    const bytes = o.sectionBytes(index);
    const relas: []align(1) const elf.Elf64_Rela = if (o.rela_of[index] != 0)
        std.mem.bytesAsSlice(elf.Elf64_Rela, o.bytes[@intCast(o.shdrs[o.rela_of[index]].sh_offset)..][0..@intCast(o.shdrs[o.rela_of[index]].sh_size)])
    else
        &.{};
    const Rec = EhRec;
    var recs: std.ArrayList(Rec) = .empty;
    var kept: std.ArrayList(u8) = .empty;
    var off: u64 = 0;
    // Input offset of each dropped record, for CIE pointers that span them.
    var dropped: std.ArrayList(Rec) = .empty;
    while (bytes.len - off >= 4) {
        const len = std.mem.readInt(u32, bytes[@intCast(off)..][0..4], .little);
        if (len == 0) {
            off += 4;
            continue;
        }
        if (len == 0xffffffff or len > bytes.len - off - 4) return invalid(arena, diag, o, "malformed or 64-bit .eh_frame record");
        const rec_len = 4 + @as(u64, len);
        var drop = false;
        if (len >= 8 and std.mem.readInt(u32, bytes[@intCast(off + 4)..][0..4], .little) != 0) {
            // An FDE: dropped with the section its pc_begin points into.
            for (relas) |r| if (r.r_offset == off + 8) {
                if (r.r_sym() < o.syms.len) {
                    const s = o.syms[r.r_sym()];
                    if (s.st_shndx != elf.SHN_UNDEF and s.st_shndx < o.shdrs.len and o.discarded[s.st_shndx]) drop = true;
                }
                break;
            };
        }
        if (drop) {
            try dropped.append(arena, .{ .off = off, .len = rec_len, .to = 0 });
        } else {
            const to: u64 = kept.items.len;
            try kept.appendSlice(arena, bytes[@intCast(off)..][0..@intCast(rec_len)]);
            const id = std.mem.readInt(u32, bytes[@intCast(off + 4)..][0..4], .little);
            if (id != 0) {
                // The CIE pointer, minus the bytes removed between.
                if (id > off + 4) return invalid(arena, diag, o, ".eh_frame FDE points before the section");
                const cie = off + 4 - id;
                var gap: u64 = 0;
                for (dropped.items) |d| if (d.off >= cie and d.off < off) {
                    gap += d.len;
                };
                // Zero terminators removed between them count too.
                gap += zerosBetween(bytes, cie, off);
                std.mem.writeInt(u32, kept.items[@intCast(to + 4)..][0..4], @intCast(id - gap), .little);
            }
            try recs.append(arena, .{ .off = off, .len = rec_len, .to = to });
        }
        off += rec_len;
    }
    return .{ .bytes = kept.items, .recs = recs.items };
}

/// The bytes of zero terminators between records at `from` and `to`.
fn zerosBetween(bytes: []const u8, from: u64, to: u64) u64 {
    var off = from;
    var n: u64 = 0;
    while (off < to) {
        const len = std.mem.readInt(u32, bytes[@intCast(off)..][0..4], .little);
        if (len == 0) n += 4;
        off += 4 + @as(u64, len);
    }
    return n;
}

fn addString(arena: Allocator, table: *std.ArrayList(u8), s: []const u8) Allocator.Error!u32 {
    if (s.len == 0) return 0;
    const at: u32 = @intCast(table.items.len);
    try table.appendSlice(arena, s);
    try table.append(arena, 0);
    return at;
}

fn invalid(arena: Allocator, diag: *[]const u8, o: *const Object, what: []const u8) Error {
    diag.* = try arena.print("{s}: {s}", .{ o.path, what });
    return error.InvalidObject;
}

fn unsupported(comptime fmt: []const u8, arena: Allocator, diag: *[]const u8, args: anytype) Error {
    diag.* = try arena.print("bs does not merge this object yet: " ++ fmt, args);
    return error.UnsupportedObject;
}

fn dup(arena: Allocator, diag: *[]const u8, name: []const u8, a: []const u8, b: []const u8) Error {
    diag.* = try arena.print("duplicate symbol: {s}, defined in {s} and {s}", .{ name, a, b });
    return error.DuplicateSymbol;
}
