//! Relocatable x86_64 ELF objects (ET_REL, `zap build-obj`) from the same
//! Atoms as an executable.
//!
//! The object is the image `Elf.emit` lays out, with its section contents
//! kept in place at the same file offsets, and a new tail: a .rela section
//! per section with relocations, and the object's symbol table. The
//! executable's link path is untouched: an object pays for the image plus
//! one serial pass over the atoms and the debug info.
//!
//! - Sections: .rodata, .text, .tdata and .tbss (if used), .data, .bss,
//!   .eh_frame and the debug sections (if there is debug info), and an
//!   empty .note.GNU-stack, which marks the stack non-executable. Addresses
//!   are 0; .eh_frame_hdr and the program headers are dropped, so their
//!   bytes, like the padding between the image's segments, are unused.
//! - Symbols: one per section; one LOCAL symbol per atom, as in the
//!   executable, valued at its offset in its section; then a GLOBAL symbol
//!   per export, which replaces the atom's local symbol when the names
//!   match; then an undefined GLOBAL (or WEAK) symbol per import.
//! - Relocations (RELA, so the contents of relocated fields, the image's
//!   resolved values, do not matter): each atom relocation becomes one
//!   against its target's symbol, except for targets with a link-time
//!   value (`Options.values`), which stay resolved. Debug info becomes
//!   relocations against section symbols: addresses in .debug_info and
//!   .debug_line against .text, the units' offsets in other debug sections
//!   against those, and each FDE's pc_begin in .eh_frame against .text.
//!
//! Only x86_64 relocation kinds exist so far: R_X86_64_64, PC32 (PLT32 to
//! an import), TPOFF32 (local-exec TLS, which requires the final link to be
//! an executable), TLSLD and DTPOFF32 (local-dynamic TLS, in
//! position-independent code), and 8, 16, 32, and 64 for `value*`
//! relocations that name a symbol. Without `Options.pic`, code is not
//! position-independent: absolute addresses in .rodata need a non-PIE final
//! link. With it, .rodata atoms holding absolute addresses are in
//! .data.rel.ro, so the object links into PIEs and shared objects.

const std = @import("std");
const elf = std.elf;
const Allocator = std.mem.Allocator;
const Atom = @import("Atom.zig");
const Dwarf = @import("Dwarf.zig");
const Elf = @import("Elf.zig");
const ElfDynamic = @import("ElfDynamic.zig");
const SymbolKey = Atom.SymbolKey;

/// A symbol the object defines for other objects: the atom `key`, as
/// `name`.
pub const Export = ElfDynamic.Export;
/// A symbol the object references and another object defines. Relocations
/// name it by `key`, which no atom may have.
pub const Import = ElfDynamic.Import;

pub const Symbols = struct {
    exports: []const Export = &.{},
    imports: []const Import = &.{},
};

/// Writes the object of `atoms` to `sub_path` in `dir`, overwriting the
/// old one in place when that is safe, as `Elf.link` does.
pub fn link(gpa: Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, atoms: []const Atom, options: Elf.Options, symbols: Symbols) !void {
    const obj = try build(gpa, io, atoms, options, symbols);
    defer obj.deinit(gpa);
    var out: Elf.ReusedOutput = .{ .dir = dir, .sub_path = sub_path, .writes = .pwrite, .executable = false };
    defer out.close(io);
    errdefer dir.deleteFile(io, sub_path) catch {};
    const fd = (try out.target(io, obj.prefix.len + obj.tail.len)).file;
    try Elf.pwriteAll(fd, obj.prefix, 0);
    try Elf.pwriteAll(fd, obj.tail, obj.prefix.len);
}

/// The bytes of the object of `atoms`, owned by the caller. `options` are
/// `Elf.emit`'s, without `entry` or `symbols`; an undefined export fails
/// with `error.UndefinedSymbol`.
pub fn emit(gpa: Allocator, io: std.Io, atoms: []const Atom, options: Elf.Options, symbols: Symbols) Elf.Error![]u8 {
    const obj = try build(gpa, io, atoms, options, symbols);
    defer gpa.free(obj.tail);
    const out = try gpa.realloc(obj.image, obj.prefix.len + obj.tail.len);
    @memcpy(out[obj.prefix.len..], obj.tail);
    return out;
}

/// The object: the start of the image `Elf.emit` built, then `tail`.
const Object = struct {
    image: []u8,
    prefix: []u8,
    tail: []u8,

    fn deinit(o: Object, gpa: Allocator) void {
        gpa.free(o.image);
        gpa.free(o.tail);
    }
};

fn build(gpa: Allocator, io: std.Io, atoms: []const Atom, options: Elf.Options, symbols: Symbols) Elf.Error!Object {
    std.debug.assert(options.symbols == null);
    var unused_diag: Elf.Diagnostic = .{};
    const diag = options.diag orelse &unused_diag;

    // The image, with imports resolved to 0 for now.
    const values = try gpa.alloc(Elf.Value, options.values.len + symbols.imports.len);
    defer gpa.free(values);
    @memcpy(values[0..options.values.len], options.values);
    for (values[options.values.len..], symbols.imports) |*v, imp| v.* = .{ .key = imp.key, .value = 0 };
    var image_options = options;
    image_options.entry = null;
    image_options.values = values;
    image_options.diag = diag;
    const image = try Elf.emit(gpa, io, atoms, image_options);
    errdefer gpa.free(image);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var c: Converter = try .init(arena, image);

    // The image's symbols are the kept atoms, in input order.
    const n_syms = c.image_symtab.len;
    var sym_of: std.HashMapUnmanaged(SymbolKey, u32, KeyContext, 80) = .empty;
    try sym_of.ensureTotalCapacity(arena, @intCast(atoms.len));
    const atom_of = try arena.alloc(u32, n_syms);
    var next: u32 = 1;
    for (atoms, 0..) |*a, i| {
        const gop = sym_of.getOrPutAssumeCapacity(a.key);
        if (gop.found_existing) continue;
        gop.value_ptr.* = next;
        atom_of[next] = @intCast(i);
        next += 1;
    }
    std.debug.assert(next == n_syms);

    // Symbol indices: sections, locals, exports, imports.
    const index = try arena.alloc(u32, n_syms);
    @memset(index, 0);
    const export_syms = try arena.alloc(u32, symbols.exports.len);
    for (symbols.exports, export_syms) |x, *s| {
        s.* = sym_of.get(x.key) orelse {
            diag.* = .{ .atom = x.name, .target = x.key };
            return error.UndefinedSymbol;
        };
        // Marks the local symbol as replaced. In position-independent
        // code the local symbol stays, and the object's own references
        // name it: a reference to a global symbol of default visibility
        // could be preempted, so a shared object's link would refuse it
        // PC-relative, and the object's code binds to its own definitions
        // (as upstream's does).
        if (!options.pic and std.mem.eql(u8, atoms[atom_of[s.*]].name, x.name)) index[s.*] = std.math.maxInt(u32);
    }
    next = @intCast(1 + c.sections.items.len);
    for (index[1..]) |*x| {
        if (x.* != 0) continue;
        x.* = next;
        next += 1;
    }
    const n_locals = next;
    var import_index: std.HashMapUnmanaged(SymbolKey, u32, KeyContext, 80) = .empty;
    try import_index.ensureTotalCapacity(arena, @intCast(symbols.imports.len));

    // The symbol table, with the image's names, then the exports' and
    // imports'.
    const n_out_syms = n_locals + symbols.exports.len + symbols.imports.len;
    const symtab = try arena.alloc(elf.Elf64.Sym, n_out_syms);
    var strtab: std.ArrayList(u8) = .empty;
    try strtab.appendSlice(arena, c.image_strtab);
    symtab[0] = std.mem.zeroes(elf.Elf64.Sym);
    for (c.sections.items, 1..) |_, k| symtab[k] = .{
        .name = 0,
        .info = .{ .type = .SECTION, .bind = .LOCAL },
        .other = .{ .visibility = .DEFAULT },
        .shndx = @intCast(k),
        .value = 0,
        .size = 0,
    };
    for (c.image_symtab[1..], index[1..]) |s, x| {
        if (x == std.math.maxInt(u32)) continue;
        symtab[x] = c.localSym(s);
    }
    for (symbols.exports, export_syms) |x, s| {
        var sym = c.localSym(c.image_symtab[s]);
        sym.name = @intCast(strtab.items.len);
        sym.info.bind = if (x.weak) .WEAK else .GLOBAL;
        sym.other.visibility = switch (x.visibility) {
            .default => .DEFAULT,
            .hidden => .HIDDEN,
            .protected => .PROTECTED,
        };
        try strtab.appendSlice(arena, x.name);
        try strtab.append(arena, 0);
        if (index[s] == std.math.maxInt(u32)) index[s] = next;
        symtab[next] = sym;
        next += 1;
    }
    for (symbols.imports) |imp| {
        symtab[next] = .{
            .name = @intCast(strtab.items.len),
            .info = .{ .type = .NOTYPE, .bind = if (imp.weak) .WEAK else .GLOBAL },
            .other = .{ .visibility = .DEFAULT },
            .shndx = elf.SHN_UNDEF,
            .value = 0,
            .size = 0,
        };
        try strtab.appendSlice(arena, imp.name);
        try strtab.append(arena, 0);
        import_index.putAssumeCapacity(imp.key, next);
        next += 1;
    }

    // The atoms' relocations.
    for (c.image_symtab[1..], atom_of[1..]) |s, i| {
        const a = &atoms[i];
        if (a.relocs.len == 0) continue;
        const k = c.section_of[s.shndx];
        const relas = &c.sections.items[k - 1].relas;
        const base = c.sectionOffset(s);
        for (a.relocs) |r| {
            const t = a.targets[r.info.target];
            const local = sym_of.get(t);
            const sym = if (local) |ts| index[ts] else import_index.get(t) orelse continue;
            const ty: elf.R_X86_64 = switch (r.info.kind) {
                .x86_64_abs64, .value64 => .@"64",
                // An import reached PC-relative is a call (to
                // `__tls_get_addr`; other imports are read from slots),
                // which a shared object makes through its PLT.
                .x86_64_pc32 => if (local == null) .PLT32 else .PC32,
                .x86_64_tpoff32 => .TPOFF32,
                .x86_64_tlsld => .TLSLD,
                .x86_64_dtpoff32 => .DTPOFF32,
                .value32 => .@"32",
                .value16 => .@"16",
                .value8 => .@"8",
                else => unreachable, // the image's link rejected it
            };
            try relas.append(arena, .{ .offset = base + r.offset, .info = .{ .type = @backingInt(ty), .sym = sym }, .addend = r.addend });
        }
    }

    // Debug info's and call frame information's.
    if (DebugCtx.init(&c, arena)) |d| try Dwarf.relocatableFields(c.contents(d.info), c.contents(d.line), d, DebugCtx.add);
    if (c.find(".eh_frame")) |eh_k| {
        const eh = c.sections.items[eh_k - 1].shdr;
        const text = c.find(".text").?;
        const text_addr = c.image_addr.items[text - 1];
        const bytes = c.contents(eh_k);
        const relas = &c.sections.items[eh_k - 1].relas;
        // FDEs follow the CIE up to the 0 terminator.
        var off: u64 = Dwarf.cie.len;
        while (off + 4 < eh.size) : (off += 4 + std.mem.readInt(u32, bytes[off..][0..4], .little)) {
            const field = off + 8;
            const target = c.image_addr.items[eh_k - 1] + field +% @as(u64, @bitCast(@as(i64, std.mem.readInt(i32, bytes[field..][0..4], .little))));
            try relas.append(arena, .{ .offset = field, .info = .{ .type = @backingInt(elf.R_X86_64.PC32), .sym = @intCast(text) }, .addend = @intCast(target - text_addr) });
        }
    }

    // The tail: relocation sections, .symtab, .strtab, .shstrtab, then the
    // section headers.
    var shdrs: std.ArrayList(elf.Elf64.Shdr) = .empty;
    var shstrtab: std.ArrayList(u8) = .empty;
    try shstrtab.append(arena, 0);
    try shdrs.append(arena, std.mem.zeroes(elf.Elf64.Shdr));
    for (c.sections.items) |s| {
        var h = s.shdr;
        h.name = @intCast(shstrtab.items.len);
        try shstrtab.appendSlice(arena, s.name);
        try shstrtab.append(arena, 0);
        try shdrs.append(arena, h);
    }
    const n_rela_sections = blk: {
        var n: u16 = 0;
        for (c.sections.items) |s| n += @intFromBool(s.relas.items.len > 0);
        break :blk n;
    };
    const symtab_ndx: u32 = @intCast(shdrs.items.len + n_rela_sections);
    var at: u64 = std.mem.alignForward(u64, c.tail_start, 8);
    for (c.sections.items, 1..) |s, k| {
        if (s.relas.items.len == 0) continue;
        const name: u32 = @intCast(shstrtab.items.len);
        try shstrtab.print(arena, ".rela{s}\x00", .{s.name});
        const size = s.relas.items.len * @sizeOf(elf.Elf64.Rela);
        try shdrs.append(arena, .{ .name = name, .type = .RELA, .flags = .{ .shf = .{ .INFO_LINK = true } }, .addr = 0, .offset = at, .size = size, .link = symtab_ndx, .info = @intCast(k), .addralign = 8, .entsize = @sizeOf(elf.Elf64.Rela) });
        at += size;
    }
    const symtab_off = at;
    const strtab_off = symtab_off + n_out_syms * @sizeOf(elf.Elf64.Sym);
    const shstrtab_off = strtab_off + strtab.items.len;
    try shdrs.append(arena, .{ .name = @intCast(shstrtab.items.len), .type = .SYMTAB, .flags = .{ .shf = .{} }, .addr = 0, .offset = symtab_off, .size = n_out_syms * @sizeOf(elf.Elf64.Sym), .link = symtab_ndx + 1, .info = n_locals, .addralign = 8, .entsize = @sizeOf(elf.Elf64.Sym) });
    try shstrtab.appendSlice(arena, ".symtab\x00");
    try shdrs.append(arena, .{ .name = @intCast(shstrtab.items.len), .type = .STRTAB, .flags = .{ .shf = .{} }, .addr = 0, .offset = strtab_off, .size = strtab.items.len, .link = 0, .info = 0, .addralign = 1, .entsize = 0 });
    try shstrtab.appendSlice(arena, ".strtab\x00");
    try shdrs.append(arena, .{ .name = @intCast(shstrtab.items.len), .type = .STRTAB, .flags = .{ .shf = .{} }, .addr = 0, .offset = shstrtab_off, .size = 0, .link = 0, .info = 0, .addralign = 1, .entsize = 0 });
    try shstrtab.appendSlice(arena, ".shstrtab\x00");
    shdrs.items[shdrs.items.len - 1].size = shstrtab.items.len;
    const shoff = std.mem.alignForward(u64, shstrtab_off + shstrtab.items.len, 8);
    const total = shoff + shdrs.items.len * @sizeOf(elf.Elf64.Shdr);

    // The tail, at file offset `tail_start`.
    const tail_start = c.tail_start;
    const tail = try gpa.alloc(u8, total - tail_start);
    errdefer gpa.free(tail);
    @memset(tail, 0);
    at = std.mem.alignForward(u64, tail_start, 8) - tail_start;
    for (c.sections.items) |s| {
        const bytes = std.mem.sliceAsBytes(s.relas.items);
        @memcpy(tail[at..][0..bytes.len], bytes);
        at += bytes.len;
    }
    @memcpy(tail[symtab_off - tail_start .. strtab_off - tail_start], std.mem.sliceAsBytes(symtab));
    @memcpy(tail[strtab_off - tail_start .. shstrtab_off - tail_start], strtab.items);
    @memcpy(tail[shstrtab_off - tail_start ..][0..shstrtab.items.len], shstrtab.items);
    @memcpy(tail[shoff - tail_start ..], std.mem.sliceAsBytes(shdrs.items));
    // The program headers' room.
    @memset(image[@sizeOf(elf.Elf64.Ehdr)..c.headers_end], 0);
    Elf.writeStruct(image, elf.Elf64.Ehdr{
        .ident = .{ .class = .@"64", .data = .@"2LSB", .version = 1, .osabi = .NONE, .abiversion = 0 },
        .type = .REL,
        .machine = .X86_64,
        .version = 1,
        .entry = 0,
        .phoff = 0,
        .shoff = shoff,
        .flags = .{ .int = 0 },
        .ehsize = @sizeOf(elf.Elf64.Ehdr),
        .phentsize = 0,
        .phnum = 0,
        .shentsize = @sizeOf(elf.Elf64.Shdr),
        .shnum = @intCast(shdrs.items.len),
        .shstrndx = @intCast(shdrs.items.len - 1),
    });
    return .{ .image = image, .prefix = image[0..tail_start], .tail = tail };
}

const KeyContext = struct {
    // Keys are already uniformly distributed hashes.
    pub fn hash(_: KeyContext, k: SymbolKey) u64 {
        return @truncate(@backingInt(k));
    }
    pub fn eql(_: KeyContext, a: SymbolKey, b: SymbolKey) bool {
        return a == b;
    }
};

/// The image's sections and symbols, and the object's sections.
const Converter = struct {
    image: []const u8,
    /// The object's sections after the null one, in image order, with
    /// their relocations; index k + 1 in the object is `sections[k]`.
    sections: std.ArrayList(Section) = .empty,
    /// Each section's image address.
    image_addr: std.ArrayList(u64) = .empty,
    /// The object's index of each of the image's sections, or 0.
    section_of: []u16,
    image_symtab: []align(1) const elf.Elf64.Sym,
    image_strtab: []const u8,
    /// Where the image's TLS symbol values start from: .tdata's address.
    tls_start: u64 = 0,
    /// The end of the program headers, and the start of the image's
    /// symbol table, which the tail replaces.
    headers_end: u64,
    tail_start: u64,

    const Section = struct {
        name: []const u8,
        shdr: elf.Elf64.Shdr,
        relas: std.ArrayList(elf.Elf64.Rela) = .empty,
    };

    fn init(arena: Allocator, image: []const u8) !Converter {
        const ehdr = std.mem.bytesAsValue(elf.Elf64.Ehdr, image[0..@sizeOf(elf.Elf64.Ehdr)]);
        const shdrs = std.mem.bytesAsSlice(elf.Elf64.Shdr, image[ehdr.shoff..][0 .. @as(usize, ehdr.shnum) * @sizeOf(elf.Elf64.Shdr)]);
        const shstr = image[shdrs[ehdr.shstrndx].offset..];
        var c: Converter = .{
            .image = image,
            .section_of = try arena.alloc(u16, shdrs.len),
            .image_symtab = undefined,
            .image_strtab = undefined,
            .headers_end = @sizeOf(elf.Elf64.Ehdr) + @as(u64, ehdr.phnum) * @sizeOf(elf.Elf64.Phdr),
            .tail_start = undefined,
        };
        @memset(c.section_of, 0);
        for (shdrs[1..], 1..) |h, i| {
            const name = std.mem.sliceTo(shstr[h.name..], 0);
            if (h.type == .SYMTAB) {
                c.image_symtab = std.mem.bytesAsSlice(elf.Elf64.Sym, image[h.offset..][0..h.size]);
                c.image_strtab = image[shdrs[h.link].offset..][0..shdrs[h.link].size];
                c.tail_start = h.offset;
                continue;
            }
            if (h.type == .STRTAB or std.mem.eql(u8, name, ".eh_frame_hdr")) continue;
            if (std.mem.eql(u8, name, ".tdata")) c.tls_start = h.addr;
            var o = h;
            o.addr = 0;
            // As compilers mark it, so that linkers merge it with other
            // objects' strings; upstream's linker mis-sizes the output's
            // .debug_str otherwise.
            if (std.mem.eql(u8, name, ".debug_str")) {
                o.flags.shf.MERGE = true;
                o.flags.shf.STRINGS = true;
                o.entsize = 1;
            }
            try c.sections.append(arena, .{ .name = name, .shdr = o });
            try c.image_addr.append(arena, h.addr);
            c.section_of[i] = @intCast(c.sections.items.len);
        }
        try c.sections.append(arena, .{ .name = ".note.GNU-stack", .shdr = .{ .name = 0, .type = .PROGBITS, .flags = .{ .shf = .{} }, .addr = 0, .offset = c.tail_start, .size = 0, .link = 0, .info = 0, .addralign = 1, .entsize = 0 } });
        try c.image_addr.append(arena, 0);
        return c;
    }

    /// The object's index of the section named `name`.
    fn find(c: *const Converter, name: []const u8) ?u32 {
        for (c.sections.items, 1..) |s, k| if (std.mem.eql(u8, s.name, name)) return @intCast(k);
        return null;
    }

    fn contents(c: *const Converter, k: u32) []const u8 {
        const h = c.sections.items[k - 1].shdr;
        return c.image[h.offset..][0..h.size];
    }

    /// The offset of image symbol `s` in its section.
    fn sectionOffset(c: *const Converter, s: elf.Elf64.Sym) u64 {
        const k = c.section_of[s.shndx];
        const addr = if (s.info.type == .TLS) s.value + c.tls_start else s.value;
        return addr - c.image_addr.items[k - 1];
    }

    /// Image symbol `s` as the object's local symbol.
    fn localSym(c: *const Converter, s: elf.Elf64.Sym) elf.Elf64.Sym {
        var o = s;
        o.shndx = c.section_of[s.shndx];
        o.value = c.sectionOffset(s);
        return o;
    }
};

const DebugCtx = struct {
    c: *Converter,
    arena: Allocator,
    /// The object's indices of .debug_info and .debug_line, and of the
    /// sections their fields point into.
    info: u32,
    line: u32,
    text: u32,
    abbrev: u32,
    str: u32,
    ranges: u32,

    fn init(c: *Converter, arena: Allocator) ?DebugCtx {
        return .{
            .c = c,
            .arena = arena,
            .info = c.find(".debug_info") orelse return null,
            .line = c.find(".debug_line").?,
            .text = c.find(".text").?,
            .abbrev = c.find(".debug_abbrev").?,
            .str = c.find(".debug_str").?,
            .ranges = c.find(".debug_rnglists").?,
        };
    }

    fn add(d: DebugCtx, section: enum { info, line }, offset: usize, field: Dwarf.Field) !void {
        const c = d.c;
        const k = if (section == .info) d.info else d.line;
        const bytes = c.contents(k);
        const rela: elf.Elf64.Rela = switch (field) {
            .addr => .{
                .offset = offset,
                .info = .{ .type = @backingInt(elf.R_X86_64.@"64"), .sym = d.text },
                .addend = @intCast(std.mem.readInt(u64, bytes[offset..][0..8], .little) - c.image_addr.items[d.text - 1]),
            },
            .abbrev, .str, .line, .ranges => |f| .{
                .offset = offset,
                .info = .{ .type = @backingInt(elf.R_X86_64.@"32"), .sym = switch (f) {
                    .abbrev => d.abbrev,
                    .str => d.str,
                    .line => d.line,
                    .ranges => d.ranges,
                    .addr => unreachable,
                } },
                .addend = std.mem.readInt(u32, bytes[offset..][0..4], .little),
            },
        };
        try c.sections.items[k - 1].relas.append(d.arena, rela);
    }
};

test "an object's symbols and relocations" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const start: SymbolKey = .fromName("_start");
    const helper: SymbolKey = .fromName("helper");
    const code: SymbolKey = .fromName("error.Code");
    const ext: SymbolKey = .fromName("import.ext");
    const ptr: SymbolKey = .fromName("ptr");
    // call helper; mov eax, <code>; helper: ret. ptr: .quad ext + 8.
    const atoms = [_]Atom{
        .{ .key = start, .name = "_start", .section = .text, .bytes = &.{ 0xe8, 0, 0, 0, 0, 0xb8, 0, 0, 0, 0 }, .targets = &.{ helper, code }, .relocs = &.{
            .init(1, .x86_64_pc32, 0, -4), .init(6, .value32, 1, 0),
        } },
        .{ .key = helper, .name = "helper", .section = .text, .bytes = &.{0xc3} },
        .{ .key = ptr, .name = "ptr", .section = .data, .alignment = .@"8", .bytes = &@as([8]u8, @splat(0)), .targets = &.{ext}, .relocs = &.{.init(0, .x86_64_abs64, 0, 8)} },
    };
    const bytes = try emit(gpa, io, &atoms, .{ .entry = null, .values = &.{.{ .key = code, .value = 7 }} }, .{
        .exports = &.{ .{ .key = start, .name = "_start" }, .{ .key = helper, .name = "helper_alias" } },
        .imports = &.{.{ .key = ext, .name = "ext", .weak = true }},
    });
    defer gpa.free(bytes);

    const ehdr = std.mem.bytesToValue(elf.Elf64.Ehdr, bytes[0..@sizeOf(elf.Elf64.Ehdr)]);
    try std.testing.expectEqual(elf.ET.REL, ehdr.type);
    try std.testing.expectEqual(0, ehdr.phnum);
    const shdrs = std.mem.bytesAsSlice(elf.Elf64.Shdr, bytes[ehdr.shoff..][0 .. @as(usize, ehdr.shnum) * @sizeOf(elf.Elf64.Shdr)]);
    const shstr = bytes[shdrs[ehdr.shstrndx].offset..];
    const Section = struct { h: elf.Elf64.Shdr, index: usize };
    const section = struct {
        fn f(all: @TypeOf(shdrs), names: []const u8, name: []const u8) ?Section {
            for (all, 0..) |h, i| if (std.mem.eql(u8, std.mem.sliceTo(names[h.name..], 0), name)) return .{ .h = h, .index = i };
            return null;
        }
    }.f;
    const symtab = section(shdrs, shstr, ".symtab").?.h;
    const syms = std.mem.bytesAsSlice(elf.Elf64.Sym, bytes[symtab.offset..][0..symtab.size]);
    const strtab = bytes[shdrs[symtab.link].offset..];
    const text = section(shdrs, shstr, ".text").?.index;

    // Locals (sections, then atoms other than the exported _start), then
    // the exports and the import.
    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(gpa);
    for (syms[1..], 1..) |s, i| {
        if (s.info.type == .SECTION) continue;
        try names.print(gpa, "{s}:{t}:{d}:{d} ", .{ std.mem.sliceTo(strtab[s.name..], 0), s.info.bind, s.shndx, s.value });
        try std.testing.expectEqual(i >= symtab.info, s.info.bind != .LOCAL);
    }
    const expected = try std.fmt.allocPrint(gpa, "helper:LOCAL:{0d}:10 ptr:LOCAL:{1d}:0 _start:GLOBAL:{0d}:0 helper_alias:GLOBAL:{0d}:10 ext:WEAK:0:0 ", .{ text, section(shdrs, shstr, ".data").?.index });
    defer gpa.free(expected);
    try std.testing.expectEqualStrings(expected, names.items);

    // The call against helper's local symbol; the error code stays
    // resolved, with no relocation; the pointer against the import.
    const Rela = struct { offset: u64, ty: u32, name: []const u8, addend: i64 };
    const relas = struct {
        fn f(b: []const u8, h: elf.Elf64.Shdr, s: @TypeOf(syms), str: []const u8, out: []Rela) []Rela {
            const rs = std.mem.bytesAsSlice(elf.Elf64.Rela, b[h.offset..][0..h.size]);
            for (rs, out[0..rs.len]) |r, *o| o.* = .{ .offset = r.offset, .ty = r.info.type, .name = std.mem.sliceTo(str[s[r.info.sym].name..], 0), .addend = r.addend };
            return out[0..rs.len];
        }
    }.f;
    var buf: [4]Rela = undefined;
    const rela_text = section(shdrs, shstr, ".rela.text").?.h;
    try std.testing.expectEqual(text, rela_text.info);
    try std.testing.expectEqualDeep(&[_]Rela{.{ .offset = 1, .ty = @backingInt(elf.R_X86_64.PC32), .name = "helper", .addend = -4 }}, relas(bytes, rela_text, syms, strtab, &buf));
    try std.testing.expectEqual(7, std.mem.readInt(u32, bytes[section(shdrs, shstr, ".text").?.h.offset + 6 ..][0..4], .little));
    try std.testing.expectEqualDeep(&[_]Rela{.{ .offset = 0, .ty = @backingInt(elf.R_X86_64.@"64"), .name = "ext", .addend = 8 }}, relas(bytes, section(shdrs, shstr, ".rela.data").?.h, syms, strtab, &buf));
}

test "an object with no atoms" {
    // A root with nothing exported, as most compile-error cases are.
    const gpa = std.testing.allocator;
    const bytes = try emit(gpa, std.testing.io, &.{}, .{ .entry = null }, .{});
    defer gpa.free(bytes);
    const ehdr = std.mem.bytesToValue(elf.Elf64.Ehdr, bytes[0..@sizeOf(elf.Elf64.Ehdr)]);
    try std.testing.expectEqual(elf.ET.REL, ehdr.type);
    const shdrs = std.mem.bytesAsSlice(elf.Elf64.Shdr, bytes[ehdr.shoff..][0 .. @as(usize, ehdr.shnum) * @sizeOf(elf.Elf64.Shdr)]);
    for (shdrs) |h| {
        try std.testing.expect(h.type != .RELA);
        // Only section symbols, after the null one.
        if (h.type == .SYMTAB) try std.testing.expectEqual(h.size / @sizeOf(elf.Elf64.Sym), h.info);
    }
}
