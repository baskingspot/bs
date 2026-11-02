//! Static, non-PIE x86_64 ELF linker. Takes the whole set of Atoms, lays out
//! sections, resolves relocations, and writes the executable in one pass
//! into one buffer. Nothing is patched afterwards.
//!
//! File layout, with each segment starting on a page boundary and mapped at
//! `base_address + file offset`:
//!
//!   R   ELF header, program headers, .rodata
//!   RX  .text
//!   RW  .data, then .bss (memory only)
//!       .symtab, .strtab, .shstrtab, section headers (not loaded)
//!
//! TLS is not implemented. `.tdata` and `.tbss` will go at the start of the
//! RW segment, before `.data`, covered by a PT_TLS program header, with
//! TP-relative relocation kinds resolved against the end of that segment.

const std = @import("std");
const builtin = @import("builtin");
const elf = std.elf;
const Allocator = std.mem.Allocator;
const Atom = @import("Atom.zig");
const SymbolKey = Atom.SymbolKey;
const Elf = @This();

comptime {
    // Structs are copied into the output as host bytes.
    std.debug.assert(builtin.cpu.arch.endian() == .little);
}

pub const Options = struct {
    entry: SymbolKey,
    /// Integers assigned by the whole compilation, for relocation targets
    /// that are not symbols (see the `value*` relocation kinds).
    values: []const Value = &.{},
    base_address: u64 = 0x200000,
    /// Threads to link with, the calling thread included; null means one
    /// per CPU. The output is the same for any number.
    threads: ?usize = null,
    /// Filled in when linking fails with a symbol-related error.
    diag: ?*Diagnostic = null,
};

pub const Value = struct { key: SymbolKey, value: u64 };

pub const Diagnostic = struct {
    /// Atom whose definition or relocation failed.
    atom: []const u8 = "",
    /// The undefined or overflowing target, if any.
    target: ?SymbolKey = null,
};

pub const Error = Allocator.Error || std.Io.Cancelable || error{
    /// Two atoms share a key but differ in contents.
    DuplicateSymbol,
    UndefinedSymbol,
    RelocationOverflow,
    /// A relocation lies outside its atom, or is in a `.bss` atom.
    InvalidRelocation,
    /// An atom's alignment is above 4 MiB.
    AlignmentTooLarge,
};

/// Links `atoms` and writes the executable to `sub_path` in `dir`. The
/// output is built directly in a shared mapping of the new file, so its
/// bytes are written once, into the page cache.
pub fn link(gpa: Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, atoms: []const Atom, options: Options) !void {
    // Replace rather than truncate the old file: ext4 starts writeback of a
    // truncated and rewritten file on close, and a running old executable
    // keeps its own inode.
    dir.deleteFile(io, sub_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
    var out: FileOutput = .{ .file = try dir.createFile(io, sub_path, .{ .read = true, .permissions = .executable_file }) };
    defer out.file.close(io);
    errdefer dir.deleteFile(io, sub_path) catch {};
    defer if (out.map.len > 0) std.posix.munmap(out.map);
    try build(gpa, io, atoms, options, &out);
}

/// Links `atoms` into the bytes of an executable, owned by the caller.
pub fn emit(gpa: Allocator, io: std.Io, atoms: []const Atom, options: Options) Error![]u8 {
    var out: MemoryOutput = .{ .gpa = gpa };
    errdefer gpa.free(out.buf);
    try build(gpa, io, atoms, options, &out);
    return out.buf;
}

const MemoryOutput = struct {
    gpa: Allocator,
    buf: []u8 = &.{},

    fn buffer(o: *MemoryOutput, _: std.Io, len: usize) Error![]u8 {
        o.buf = try o.gpa.alloc(u8, len);
        return o.buf;
    }
};

const FileOutput = struct {
    file: std.Io.File,
    map: []align(std.heap.page_size_min) u8 = &.{},

    fn buffer(o: *FileOutput, io: std.Io, len: usize) ![]u8 {
        try o.file.setLength(io, len);
        o.map = try std.posix.mmap(null, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, o.file.handle, 0);
        return o.map;
    }
};

const page_size = 0x1000;

/// Section header indices; the order is the layout order.
const Shndx = enum(u16) { null, rodata, text, data, bss, symtab, strtab, shstrtab };
const shnum = std.enums.values(Shndx).len;
/// Section header of each `Atom.Section`.
const shndx_of = [4]Shndx{ .text, .rodata, .data, .bss };
/// Where pass 1 placed an atom.
const Place = packed struct(u64) {
    /// Offset within the chunk's part of the section.
    offset: u40,
    /// Alignment padding between the previous atom of the section and this
    /// one, which the copy pass fills.
    gap: u22,
    section: u2,

    const duplicate: Place = @bitCast(@as(u64, std.math.maxInt(u64)));

    fn isDuplicate(p: Place) bool {
        return @as(u64, @bitCast(p)) == std.math.maxInt(u64);
    }
};
/// Atoms per unit of work in placement and copying.
const chunk_len = 2048;
const shstrtab = "\x00.rodata\x00.text\x00.data\x00.bss\x00.symtab\x00.strtab\x00.shstrtab\x00";

/// Links `atoms` into the buffer `out.buffer(io, len)` returns.
///
/// Work is split three ways, each spread over threads; the output does not
/// depend on the thread count:
///  1. Deduplicate: the symbol table is partitioned by key, and each
///     partition takes its keys in input order, so the first atom with a key
///     is the one kept.
///  2. Place: each chunk of consecutive atoms lays out its own atoms within
///     each section. A short serial step then places the chunks, so atoms
///     keep their input order within a section.
///  3. Copy: each chunk copies its atoms' bytes, applies their relocations,
///     and writes their symbols; chunks write disjoint parts of the output.
fn build(gpa: Allocator, io: std.Io, atoms: []const Atom, options: Options, out: anytype) !void {
    var unused_diag: Diagnostic = .{};
    const diag = options.diag orelse &unused_diag;
    const text = @backingInt(Atom.Section.text);
    const rodata = @backingInt(Atom.Section.rodata);
    const data = @backingInt(Atom.Section.data);
    const bss = @backingInt(Atom.Section.bss);

    const n_chunks = std.math.divCeil(usize, atoms.len, chunk_len) catch unreachable;
    const n_threads = @max(1, @min(n_chunks, options.threads orelse std.Thread.getCpuCount() catch 1));
    // Every partition scans all atoms, so use no more than there are threads.
    const n_partitions = std.math.ceilPowerOfTwoAssert(usize, @min(n_threads, 8));

    var symbols: SymbolTable = try .init(atoms.len, n_partitions);
    defer symbols.deinit();
    const places = try gpa.alloc(Place, atoms.len);
    defer gpa.free(places);
    const keys = try gpa.alloc(SymbolKey, atoms.len);
    defer gpa.free(keys);
    populate(std.mem.sliceAsBytes(places));
    populate(std.mem.sliceAsBytes(keys));
    const chunks = try gpa.alloc(Chunk, n_chunks);
    defer gpa.free(chunks);
    const failures = try gpa.alloc(?Failure, @max(n_chunks, n_partitions));
    defer gpa.free(failures);
    var l: Link = .{
        .atoms = atoms,
        .places = places,
        .keys = keys,
        .chunks = chunks,
        .symbols = &symbols,
        .failures = failures,
    };

    @memset(failures, null);
    try parallel(io, n_threads, n_chunks, &l, Link.gatherKeys);
    try parallel(io, n_threads, n_partitions, &l, Link.dedup);
    try parallel(io, n_threads, n_chunks, &l, Link.layOut);
    try l.check(diag);

    // Place chunks within sections, and their symbols and names.
    var sizes: [4]u64 = @splat(0);
    var aligns: [4]std.mem.Alignment = @splat(.@"1");
    var n_syms: u32 = 1;
    var strtab_len: u64 = 1;
    var max_targets: usize = 0;
    for (chunks) |*c| {
        for (&sizes, &aligns, &c.bases, &c.lead_gaps, c.sizes, c.aligns) |*size, *alignment, *chunk_base, *lead_gap, chunk_size, chunk_align| {
            chunk_base.* = chunk_align.forward(size.*);
            lead_gap.* = chunk_base.* - size.*;
            size.* = chunk_base.* + chunk_size;
            alignment.* = alignment.max(chunk_align);
        }
        c.sym = n_syms;
        c.str = std.math.cast(u32, strtab_len) orelse return error.OutOfMemory;
        n_syms += c.n_syms;
        strtab_len += c.str_len;
        max_targets = @max(max_targets, c.max_targets);
    }
    if (symbols.get(options.entry) == null) {
        diag.* = .{ .target = options.entry };
        return error.UndefinedSymbol;
    }

    var values: SymbolTable = try .init(options.values.len, 1);
    defer values.deinit();
    for (options.values) |v| values.getOrPut(v.key).* = .{ .key = v.key, .value = v.value, .used = true };

    // Section placement, as file offsets (for .bss, address - base).
    const has_rx = sizes[text] > 0;
    const has_rw = sizes[data] > 0 or sizes[bss] > 0;
    const phnum: u16 = 2 + @as(u16, @intFromBool(has_rx)) + @intFromBool(has_rw);
    const headers_end: u64 = @sizeOf(elf.Elf64.Ehdr) + phnum * @sizeOf(elf.Elf64.Phdr);
    var starts: [4]u64 = undefined;
    starts[rodata] = aligns[rodata].forward(headers_end);
    const r_end = starts[rodata] + sizes[rodata];
    const rx_start = if (has_rx) std.mem.alignForward(u64, r_end, page_size) else r_end;
    starts[text] = aligns[text].forward(rx_start);
    const text_end = starts[text] + sizes[text];
    const rw_start = if (has_rw) std.mem.alignForward(u64, text_end, page_size) else text_end;
    starts[data] = aligns[data].forward(rw_start);
    const file_end = starts[data] + sizes[data];
    starts[bss] = aligns[bss].forward(file_end);
    const mem_end = starts[bss] + sizes[bss];

    const base = options.base_address;
    for (&l.section_addrs, starts) |*sa, st| sa.* = base + st;
    l.base = base;
    try parallel(io, n_threads, n_partitions, &l, Link.resolveAddrs);

    const symtab_off = std.mem.alignForward(u64, file_end, 8);
    const strtab_off = symtab_off + @as(u64, n_syms) * @sizeOf(elf.Elf64.Sym);
    const shstrtab_off = strtab_off + strtab_len;
    const shoff = std.mem.alignForward(u64, shstrtab_off + shstrtab.len, 8);
    const buf = try out.buffer(io, shoff + shnum * @sizeOf(elf.Elf64.Shdr));
    l.buf = buf;
    adviseHugePages(buf);
    try parallel(io, n_threads, std.math.divCeil(usize, buf.len, populate_len) catch unreachable, &l, Link.populateOutput);

    // Padding between sections; padding within a section is filled by the
    // atom or chunk after it.
    @memset(buf[headers_end..starts[rodata]], 0);
    @memset(buf[r_end..starts[text]], 0);
    @memset(buf[text_end..starts[data]], 0);
    @memset(buf[file_end..symtab_off], 0);
    @memset(buf[symtab_off..][0..@sizeOf(elf.Elf64.Sym)], 0);
    buf[strtab_off] = 0;
    @memcpy(buf[shstrtab_off..][0..shstrtab.len], shstrtab);
    @memset(buf[shstrtab_off + shstrtab.len .. shoff], 0);

    const resolved = try gpa.alloc(u64, n_threads * max_targets);
    defer gpa.free(resolved);
    l.values = &values;
    l.symtab_off = symtab_off;
    l.strtab_off = strtab_off;
    l.resolved = resolved;
    l.max_targets = max_targets;
    try parallel(io, n_threads, n_chunks, &l, Link.copy);
    try l.check(diag);

    // Headers.
    writeStruct(buf, elf.Elf64.Ehdr{
        .ident = .{ .class = .@"64", .data = .@"2LSB", .version = 1, .osabi = .NONE, .abiversion = 0 },
        .type = .EXEC,
        .machine = .X86_64,
        .version = 1,
        .entry = symbols.get(options.entry).?,
        .phoff = @sizeOf(elf.Elf64.Ehdr),
        .shoff = shoff,
        .flags = .{ .int = 0 },
        .ehsize = @sizeOf(elf.Elf64.Ehdr),
        .phentsize = @sizeOf(elf.Elf64.Phdr),
        .phnum = phnum,
        .shentsize = @sizeOf(elf.Elf64.Shdr),
        .shnum = shnum,
        .shstrndx = @backingInt(Shndx.shstrtab),
    });
    var ph_off: usize = @sizeOf(elf.Elf64.Ehdr);
    const phdrs = [_]struct { bool, elf.PF, u64, u64, u64 }{
        .{ true, .{ .R = true }, 0, r_end, r_end },
        .{ has_rx, .{ .R = true, .X = true }, rx_start, text_end - rx_start, text_end - rx_start },
        .{ has_rw, .{ .R = true, .W = true }, rw_start, file_end - rw_start, mem_end - rw_start },
    };
    for (phdrs) |p| if (p[0]) {
        writeStruct(buf[ph_off..], elf.Elf64.Phdr{
            .type = .LOAD,
            .flags = p[1],
            .offset = p[2],
            .vaddr = base + p[2],
            .paddr = base + p[2],
            .filesz = p[3],
            .memsz = p[4],
            .@"align" = page_size,
        });
        ph_off += @sizeOf(elf.Elf64.Phdr);
    };
    writeStruct(buf[ph_off..], elf.Elf64.Phdr{
        .type = .GNU_STACK,
        .flags = .{ .R = true, .W = true },
        .offset = 0,
        .vaddr = 0,
        .paddr = 0,
        .filesz = 0,
        .memsz = 0,
        .@"align" = 16,
    });

    const shdrs = [_]elf.Elf64.Shdr{
        std.mem.zeroes(elf.Elf64.Shdr),
        shdr(1, .PROGBITS, .{ .ALLOC = true }, base, starts[rodata], sizes[rodata], aligns[rodata]),
        shdr(9, .PROGBITS, .{ .ALLOC = true, .EXECINSTR = true }, base, starts[text], sizes[text], aligns[text]),
        shdr(15, .PROGBITS, .{ .ALLOC = true, .WRITE = true }, base, starts[data], sizes[data], aligns[data]),
        shdr(21, .NOBITS, .{ .ALLOC = true, .WRITE = true }, base, starts[bss], sizes[bss], aligns[bss]),
        .{ .name = 26, .type = .SYMTAB, .flags = .{ .shf = .{} }, .addr = 0, .offset = symtab_off, .size = n_syms * @sizeOf(elf.Elf64.Sym), .link = @backingInt(Shndx.strtab), .info = 1, .addralign = 8, .entsize = @sizeOf(elf.Elf64.Sym) },
        .{ .name = 34, .type = .STRTAB, .flags = .{ .shf = .{} }, .addr = 0, .offset = strtab_off, .size = strtab_len, .link = 0, .info = 0, .addralign = 1, .entsize = 0 },
        .{ .name = 42, .type = .STRTAB, .flags = .{ .shf = .{} }, .addr = 0, .offset = shstrtab_off, .size = shstrtab.len, .link = 0, .info = 0, .addralign = 1, .entsize = 0 },
    };
    for (shdrs, 0..) |s, i| writeStruct(buf[shoff + i * @sizeOf(elf.Elf64.Shdr) ..], s);
}

/// One `chunk_len` run of consecutive atoms.
const Chunk = struct {
    // Filled in by `Link.layOut`.
    sizes: [4]u64,
    aligns: [4]std.mem.Alignment,
    n_syms: u32,
    str_len: u32,
    max_targets: u32,
    // Filled in serially after `Link.layOut`.
    /// Where the chunk's atoms of each section start, within the section.
    bases: [4]u64,
    /// Padding before `bases`, which the chunk fills.
    lead_gaps: [4]u64,
    /// The chunk's first symbol in .symtab and first byte in .strtab.
    sym: u32,
    str: u32,
};

const Failure = struct { atom: usize, err: Error, diag: Diagnostic };

/// State shared by the threads of `emit`.
const Link = struct {
    atoms: []const Atom,
    places: []Place,
    /// The atoms' keys, packed, so that every partition can scan them.
    keys: []SymbolKey,
    chunks: []Chunk,
    /// Maps a key to the index of the atom kept for it, and from
    /// `resolveAddrs` on to its address.
    symbols: *SymbolTable,
    /// One slot per task. A phase reports the failure of the lowest atom,
    /// whatever the thread timing.
    failures: []?Failure,
    // Set before `copy`.
    values: *const SymbolTable = undefined,
    buf: []u8 = undefined,
    base: u64 = undefined,
    section_addrs: [4]u64 = undefined,
    symtab_off: u64 = undefined,
    strtab_off: u64 = undefined,
    /// `max_targets` addresses per thread.
    resolved: []u64 = undefined,
    max_targets: usize = undefined,

    fn check(l: *Link, diag: *Diagnostic) Error!void {
        var first: ?Failure = null;
        for (l.failures) |f| if (f) |failure| {
            if (first == null or failure.atom < first.?.atom) first = failure;
        };
        @memset(l.failures, null);
        const failure = first orelse return;
        diag.* = failure.diag;
        return failure.err;
    }

    fn fail(l: *Link, task: usize, atom: usize, err: Error, diag: Diagnostic) void {
        if (l.failures[task] == null) l.failures[task] = .{ .atom = atom, .err = err, .diag = diag };
    }

    fn atomAddr(l: *const Link, index: u64) u64 {
        const p = l.places[index];
        return l.section_addrs[p.section] + l.chunks[index / chunk_len].bases[p.section] + p.offset;
    }

    /// Replaces atom indices with addresses in one partition of `symbols`,
    /// so that resolving a relocation target is one lookup.
    fn resolveAddrs(l: *Link, partition: usize, _: usize) void {
        for (l.symbols.partitionEntries(partition)) |*e| {
            if (e.used) e.value = l.atomAddr(e.value);
        }
    }

    fn populateOutput(l: *Link, part: usize, _: usize) void {
        const begin = part * populate_len;
        populate(l.buf[begin..@min(l.buf.len, begin + populate_len)]);
    }

    fn gatherKeys(l: *Link, chunk: usize, _: usize) void {
        const begin = chunk * chunk_len;
        const atoms = l.atoms[begin..@min(l.atoms.len, begin + chunk_len)];
        for (atoms, l.keys[begin..][0..atoms.len]) |*a, *k| k.* = a.key;
    }

    /// Inserts the keys of one partition, in input order, so the first atom
    /// with a key is the one kept. Writes nothing but the partition, which
    /// keeps threads off each other's cache lines.
    fn dedup(l: *Link, partition: usize, _: usize) void {
        l.symbols.populate(partition);
        const keys = l.keys;
        for (keys, 0..) |key, i| {
            if (i + 16 < keys.len and l.symbols.partition(keys[i + 16]) == partition) l.symbols.prefetch(keys[i + 16]);
            if (l.symbols.partition(key) != partition) continue;
            const e = l.symbols.getOrPut(key);
            if (!e.used) e.* = .{ .key = key, .value = i, .used = true };
        }
    }

    /// Lays out one chunk's atoms within each section, as if the chunk's
    /// part of every section started at 0.
    fn layOut(l: *Link, chunk: usize, _: usize) void {
        const begin = chunk * chunk_len;
        const atoms = l.atoms[begin..@min(l.atoms.len, begin + chunk_len)];
        var c: Chunk = .{
            .sizes = @splat(0),
            .aligns = @splat(.@"1"),
            .n_syms = 0,
            .str_len = 0,
            .max_targets = 0,
            .bases = undefined,
            .lead_gaps = undefined,
            .sym = undefined,
            .str = undefined,
        };
        for (atoms, l.places[begin..][0..atoms.len], begin..) |*a, *p, i| {
            if (i + 16 < l.keys.len) l.symbols.prefetch(l.keys[i + 16]);
            const kept = l.symbols.get(l.keys[i]).?;
            if (kept != i) {
                if (!identical(&l.atoms[kept], a)) l.fail(chunk, i, error.DuplicateSymbol, .{ .atom = a.name, .target = a.key });
                p.* = .duplicate;
                continue;
            }
            if (a.section == .bss and (a.bytes.len != 0 or a.relocs.len != 0)) {
                l.fail(chunk, i, error.InvalidRelocation, .{ .atom = a.name });
                continue;
            }
            const s = @backingInt(a.section);
            const off = a.alignment.forward(c.sizes[s]);
            p.* = .{
                .offset = std.math.cast(u40, off) orelse {
                    l.fail(chunk, i, error.OutOfMemory, .{ .atom = a.name });
                    continue;
                },
                .gap = std.math.cast(u22, off - c.sizes[s]) orelse {
                    l.fail(chunk, i, error.AlignmentTooLarge, .{ .atom = a.name });
                    continue;
                },
                .section = @intCast(s),
            };
            c.sizes[s] = off + a.size();
            c.aligns[s] = c.aligns[s].max(a.alignment);
            c.n_syms += 1;
            if (a.name.len > 0) c.str_len += @intCast(a.name.len + 1);
            c.max_targets = @max(c.max_targets, @as(u32, @intCast(a.targets.len)));
        }
        l.chunks[chunk] = c;
    }

    /// Copies one chunk's atoms, applies their relocations, and writes
    /// their symbols.
    fn copy(l: *Link, chunk: usize, thread: usize) void {
        const fills: [3]u8 = .{ 0xcc, 0, 0 };
        const c = &l.chunks[chunk];
        const resolved = l.resolved[thread * l.max_targets ..][0..l.max_targets];
        for (c.lead_gaps[0..3], c.bases[0..3], l.section_addrs[0..3], fills) |gap, chunk_base, sa, fill| {
            const start = sa - l.base + chunk_base;
            @memset(l.buf[start - gap .. start], fill);
        }
        const begin = chunk * chunk_len;
        const atoms = l.atoms[begin..@min(l.atoms.len, begin + chunk_len)];
        var sym_off = l.symtab_off + @as(u64, c.sym) * @sizeOf(elf.Elf64.Sym);
        var str_off = c.str;
        for (atoms, l.places[begin..][0..atoms.len], begin..) |*a, place, i| {
            // An atom's bytes, targets, relocations, and name, and its
            // targets' `symbols` entries, are scattered in memory; start
            // those misses a few atoms ahead.
            if (i + 4 < l.atoms.len) {
                const n = &l.atoms[i + 4];
                prefetchSlice(u8, n.bytes[0..@min(n.bytes.len, 64)]);
                prefetchSlice(SymbolKey, n.targets);
                prefetchSlice(Atom.Reloc, n.relocs);
                prefetchSlice(u8, n.name);
            }
            if (i + 2 < l.atoms.len) for (l.atoms[i + 2].targets) |t| l.symbols.prefetch(t);
            if (place.isDuplicate()) continue;
            const addr = l.section_addrs[place.section] + c.bases[place.section] + place.offset;
            if (place.section != @backingInt(Atom.Section.bss)) {
                const start = addr - l.base;
                @memset(l.buf[start - place.gap .. start], fills[place.section]);
                const dst = l.buf[start..][0..a.bytes.len];
                @memcpy(dst, a.bytes);
                const res = resolved[0..a.targets.len];
                for (a.targets, res) |t, *r| {
                    r.* = l.symbols.get(t) orelse l.values.get(t) orelse {
                        l.fail(chunk, i, error.UndefinedSymbol, .{ .atom = a.name, .target = t });
                        return;
                    };
                }
                var diag: Diagnostic = .{};
                applyRelocs(a, dst, addr, res, &diag) catch |err| return l.fail(chunk, i, err, diag);
            }
            var name: u32 = 0;
            if (a.name.len > 0) {
                name = str_off;
                @memcpy(l.buf[l.strtab_off + str_off ..][0..a.name.len], a.name);
                l.buf[l.strtab_off + str_off + a.name.len] = 0;
                str_off += @intCast(a.name.len + 1);
            }
            writeStruct(l.buf[sym_off..], elf.Elf64.Sym{
                .name = name,
                .info = .{ .type = if (a.section == .text) .FUNC else .OBJECT, .bind = .GLOBAL },
                .other = .{ .visibility = .DEFAULT },
                .shndx = @backingInt(shndx_of[place.section]),
                .value = addr,
                .size = a.size(),
            });
            sym_off += @sizeOf(elf.Elf64.Sym);
        }
    }
};

/// Runs `task(ctx, i, thread)` for every i < n_tasks on up to `n_threads`
/// threads, the calling thread included.
fn parallel(io: std.Io, n_threads: usize, n_tasks: usize, ctx: anytype, comptime task: fn (@TypeOf(ctx), usize, usize) void) std.Io.Cancelable!void {
    const Ctx = @TypeOf(ctx);
    const Worker = struct {
        fn work(c: Ctx, next: *std.atomic.Value(usize), total: usize, thread: usize) void {
            while (true) {
                const i = next.fetchAdd(1, .monotonic);
                if (i >= total) return;
                task(c, i, thread);
            }
        }
    };
    var next: std.atomic.Value(usize) = .init(0);
    var group: std.Io.Group = .init;
    for (1..@min(n_threads, n_tasks)) |t| group.async(io, Worker.work, .{ ctx, &next, n_tasks, t });
    Worker.work(ctx, &next, n_tasks, 0);
    try group.await(io);
}

/// Units of `Link.populateOutput`.
const populate_len = 4 << 20;

/// Asks for huge pages for the 2 MiB-aligned part of `bytes`. Call once per
/// buffer from one thread: it takes the address-space lock exclusively.
pub fn adviseHugePages(bytes: []u8) void {
    if (builtin.os.tag != .linux) return;
    const huge = 2 << 20;
    const begin = std.mem.alignForward(usize, @intFromPtr(bytes.ptr), huge);
    const end = std.mem.alignBackward(usize, @intFromPtr(bytes.ptr) + bytes.len, huge);
    if (begin < end) std.posix.madvise(@ptrFromInt(begin), end - begin, std.posix.MADV.HUGEPAGE) catch {};
}

/// Faults in fresh memory, writable, ahead of use. Faulting it on first
/// write instead serializes threads on page table locks, and a read before
/// the first write maps the zero page, whose replacement flushes the TLB of
/// every CPU running a thread of the process. Threads can populate disjoint
/// parts at once.
pub fn populate(bytes: []u8) void {
    if (builtin.os.tag != .linux) return;
    const begin = std.mem.alignForward(usize, @intFromPtr(bytes.ptr), std.heap.page_size_min);
    const end = std.mem.alignBackward(usize, @intFromPtr(bytes.ptr) + bytes.len, std.heap.page_size_min);
    const MADV_POPULATE_WRITE = 23; // Linux 5.14; older kernels just fault.
    if (begin < end) std.posix.madvise(@ptrFromInt(begin), end - begin, MADV_POPULATE_WRITE) catch {};
}

fn prefetchSlice(comptime T: type, slice: []const T) void {
    const bytes = std.mem.sliceAsBytes(slice);
    var off: usize = 0;
    while (off < bytes.len) : (off += 64) @prefetch(bytes.ptr + off, .{});
}

/// Open-addressing hash table from symbol key to a u64, with key and value
/// in one entry so that a lookup costs one cache miss. Keys are already
/// uniformly distributed: their top bits pick a partition, so that threads
/// can fill partitions independently, and their low bits the slot within
/// it.
const SymbolTable = struct {
    entries: []Entry,
    partition_shift: u8,
    slot_mask: usize,

    const Entry = struct { key: SymbolKey, value: u64, used: bool };

    /// Mapped directly, so it starts zeroed (all entries unused) and can ask
    /// for huge pages: lookups are random, and with 4 KiB pages most of them
    /// would also miss the TLB. See `populate`.
    fn init(max_count: usize, n_partitions: usize) Allocator.Error!SymbolTable {
        // Partitions fill unevenly; the slack keeps small ones from filling
        // up, and hashed keys make a partition twice its expected size
        // practically impossible for large ones.
        const slots = std.math.ceilPowerOfTwoAssert(usize, 64 + max_count * 2 / n_partitions);
        const len = slots * n_partitions;
        const entries = try std.heap.page_allocator.alignedAlloc(Entry, huge_page, len);
        adviseHugePages(std.mem.sliceAsBytes(entries));
        return .{
            .entries = entries,
            .partition_shift = @as(u8, 128) - std.math.log2_int(usize, n_partitions),
            .slot_mask = slots - 1,
        };
    }

    fn deinit(t: *SymbolTable) void {
        std.heap.page_allocator.free(t.entries);
    }

    /// Faults in a partition's pages, writable, before it is used. Otherwise
    /// the first lookups map the shared zero page and the first insert
    /// replaces it, and that replacement flushes the TLB of every CPU
    /// running the other threads. Threads populate their own partitions, so
    /// the kernel zeroes them in parallel.
    fn populate(t: *const SymbolTable, partition_index: usize) void {
        Elf.populate(std.mem.sliceAsBytes(t.partitionEntries(partition_index)));
    }

    fn partitionEntries(t: *const SymbolTable, partition_index: usize) []Entry {
        return t.entries[partition_index * (t.slot_mask + 1) ..][0 .. t.slot_mask + 1];
    }

    const huge_page: std.mem.Alignment = .fromByteUnits(2 << 20);

    fn partition(t: *const SymbolTable, key: SymbolKey) usize {
        return if (t.partition_shift == 128) 0 else @intCast(@backingInt(key) >> @intCast(t.partition_shift));
    }

    fn home(t: *const SymbolTable, key: SymbolKey) usize {
        return t.partition(key) * (t.slot_mask + 1) + (@as(usize, @truncate(@backingInt(key))) & t.slot_mask);
    }

    /// The entry for `key`: used if `key` is present, else the free slot to
    /// fill in.
    fn getOrPut(t: *const SymbolTable, key: SymbolKey) *Entry {
        const first = t.partition(key) * (t.slot_mask + 1);
        var slot: usize = @as(usize, @truncate(@backingInt(key))) & t.slot_mask;
        while (true) : (slot = (slot + 1) & t.slot_mask) {
            const e = &t.entries[first + slot];
            if (!e.used or e.key == key) return e;
        }
    }

    fn prefetch(t: *const SymbolTable, key: SymbolKey) void {
        @prefetch(&t.entries[t.home(key)], .{});
    }

    fn get(t: *const SymbolTable, key: SymbolKey) ?u64 {
        const e = t.getOrPut(key);
        return if (e.used) e.value else null;
    }
};

fn shdr(name: u32, ty: elf.SHT, flags: elf.SHF, base: u64, offset: u64, size: u64, alignment: std.mem.Alignment) elf.Elf64.Shdr {
    return .{
        .name = name,
        .type = ty,
        .flags = .{ .shf = flags },
        .addr = base + offset,
        .offset = offset,
        .size = size,
        .link = 0,
        .info = 0,
        .addralign = alignment.toByteUnits(),
        .entsize = 0,
    };
}

fn writeStruct(dst: []u8, s: anytype) void {
    @memcpy(dst[0..@sizeOf(@TypeOf(s))], std.mem.asBytes(&s));
}

fn identical(a: *const Atom, b: *const Atom) bool {
    if (a.section != b.section or a.alignment != b.alignment or a.size() != b.size() or
        a.targets.len != b.targets.len or a.relocs.len != b.relocs.len) return false;
    if (!std.mem.eql(u8, a.bytes, b.bytes)) return false;
    if (!std.mem.eql(SymbolKey, a.targets, b.targets)) return false;
    return std.mem.eql(u8, std.mem.sliceAsBytes(a.relocs), std.mem.sliceAsBytes(b.relocs));
}

/// Applies `a`'s relocations to its copy `dst` at address `p_base`, with
/// `resolved` holding the address or value of each of `a.targets`.
fn applyRelocs(a: *const Atom, dst: []u8, p_base: u64, resolved: []const u64, diag: *Diagnostic) Error!void {
    for (a.relocs) |r| {
        const width: u4 = switch (r.info.kind) {
            .x86_64_abs64, .value64 => 8,
            .x86_64_pc32, .value32 => 4,
            .value16 => 2,
            .value8 => 1,
        };
        if (r.offset + @as(u64, width) > dst.len or r.info.target >= resolved.len) {
            diag.* = .{ .atom = a.name };
            return error.InvalidRelocation;
        }
        const field = dst[r.offset..];
        const s = resolved[r.info.target];
        switch (r.info.kind) {
            .x86_64_abs64 => std.mem.writeInt(u64, field[0..8], s +% @as(u64, @bitCast(@as(i64, r.addend))), .little),
            .x86_64_pc32 => {
                const v = @as(i64, @bitCast(s -% (p_base + r.offset))) +% r.addend;
                std.mem.writeInt(i32, field[0..4], std.math.cast(i32, v) orelse return overflow(a, r, diag), .little);
            },
            .value8, .value16, .value32, .value64 => {
                const v = @as(i128, s) + r.addend;
                switch (r.info.kind) {
                    .value8 => field[0] = std.math.cast(u8, v) orelse return overflow(a, r, diag),
                    .value16 => std.mem.writeInt(u16, field[0..2], std.math.cast(u16, v) orelse return overflow(a, r, diag), .little),
                    .value32 => std.mem.writeInt(u32, field[0..4], std.math.cast(u32, v) orelse return overflow(a, r, diag), .little),
                    .value64 => std.mem.writeInt(u64, field[0..8], std.math.cast(u64, v) orelse return overflow(a, r, diag), .little),
                    else => unreachable,
                }
            },
        }
    }
}

fn overflow(a: *const Atom, r: Atom.Reloc, diag: *Diagnostic) Error {
    diag.* = .{ .atom = a.name, .target = a.targets[r.info.target] };
    return error.RelocationOverflow;
}

test "links and runs a program that writes from rodata and exits with 42" {
    if (builtin.cpu.arch != .x86_64 or builtin.os.tag != .linux) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const Encoder = @import("../codegen/x86_64/Encoder.zig");

    const msg_text = "Hello from zap!\n";
    const msg: SymbolKey = .fromContents(.rodata, .@"1", msg_text, &.{}, &.{});
    const msg_ptr: SymbolKey = .fromName("msg_ptr");
    const status: SymbolKey = .fromName("status");
    const write_msg: SymbolKey = .fromName("write_msg");
    const start: SymbolKey = .fromName("_start");
    const exit_code: SymbolKey = .fromName("exit_code");

    // write(1, msg_ptr.*, len); the string is reached through an absolute
    // pointer in .data.
    var w: Encoder = .init(gpa);
    defer w.deinit();
    try w.mov(.dword, .{ .reg = .rax }, .{ .imm = 1 });
    try w.mov(.dword, .{ .reg = .rdi }, .{ .imm = 1 });
    try w.mov(.qword, .{ .reg = .rsi }, .{ .mem = .sym(msg_ptr, 0) });
    try w.mov(.dword, .{ .reg = .rdx }, .{ .imm = msg_text.len });
    try w.syscall();
    try w.ret();
    w.finish();

    // status = exit_code (a link-time value); exit(status) if it is 42.
    var s: Encoder = .init(gpa);
    defer s.deinit();
    try s.call(.{ .sym = write_msg });
    try s.mov(.dword, .{ .mem = .sym(status, 0) }, .{ .imm = 0 });
    try s.refs.append(gpa, @intCast(s.code.items.len - 4), .value32, exit_code, 0);
    try s.mov(.dword, .{ .reg = .rdi }, .{ .mem = .sym(status, 0) });
    try s.alu(.cmp, .dword, .{ .reg = .rdi }, .{ .imm = 42 });
    const ok = try s.newLabel();
    try s.jcc(.e, .{ .label = ok });
    try s.ud2();
    s.bind(ok);
    try s.mov(.dword, .{ .reg = .rax }, .{ .imm = 60 });
    try s.syscall();
    s.finish();

    const msg_atom: Atom = .{ .key = msg, .name = "__anon_msg", .section = .rodata, .bytes = msg_text };
    const atoms = [_]Atom{
        .{ .key = start, .name = "_start", .section = .text, .alignment = .@"16", .bytes = s.code.items, .targets = s.refs.targets.keys(), .relocs = s.refs.relocs.items },
        msg_atom,
        .{ .key = write_msg, .name = "write_msg", .section = .text, .alignment = .@"16", .bytes = w.code.items, .targets = w.refs.targets.keys(), .relocs = w.refs.relocs.items },
        .{ .key = status, .name = "status", .section = .bss, .alignment = .@"4", .zero_fill = 4 },
        .{ .key = msg_ptr, .name = "msg_ptr", .section = .data, .alignment = .@"8", .bytes = &@as([8]u8, @splat(0)), .targets = &.{msg}, .relocs = &.{
            .init(0, .x86_64_abs64, 0, 0),
        } },
        // A second function's copy of the same constant.
        msg_atom,
    };
    const options: Options = .{ .entry = start, .values = &.{.{ .key = exit_code, .value = 42 }} };

    const bytes = try emit(gpa, io, &atoms, options);
    defer gpa.free(bytes);
    try std.testing.expectEqual(1, std.mem.count(u8, bytes, msg_text));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try link(gpa, io, tmp.dir, "hello", &atoms, options);
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/hello", .{tmp.sub_path});
    defer gpa.free(path);
    const result = try std.process.run(gpa, io, .{ .argv = &.{path} });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqualStrings(msg_text, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 42 }, result.term);

    // The same key with different contents is a conflict, not a duplicate.
    var diag: Diagnostic = .{};
    const conflicting = [_]Atom{ atoms[0], .{ .key = start, .name = "other", .section = .text, .bytes = "\xc3" } };
    try std.testing.expectError(error.DuplicateSymbol, emit(gpa, io, &conflicting, .{ .entry = start, .diag = &diag }));
    try std.testing.expectEqualStrings("other", diag.atom);
}

test "links many chunks of atoms the same way on any number of threads" {
    if (builtin.cpu.arch != .x86_64 or builtin.os.tag != .linux) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const Encoder = @import("../codegen/x86_64/Encoder.zig");
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // f_i adds the 4-byte constant c_(i % 50) = i % 50 + 1 to ebx and calls
    // f_(i+1); the last one jumps to `finish`, which writes a message reached
    // through a pointer in .data and exits with ebx. Each function is
    // followed by its own copy of its constant, so most constants are
    // duplicates, many in other chunks; alignments vary to leave padding.
    const n = 2 * chunk_len + 300;
    const msg_text = "chunks ok\n";
    const msg: SymbolKey = .fromContents(.rodata, .@"1", msg_text, &.{}, &.{});
    const msg_ptr: SymbolKey = .fromName("msg_ptr");
    const finish: SymbolKey = .fromName("finish");
    const start: SymbolKey = .fromName("_start");
    var constants: [50]Atom = undefined;
    for (&constants, 0..) |*c, j| {
        const bytes = try arena.dupe(u8, std.mem.asBytes(&@as(u32, @intCast(j + 1))));
        c.* = .{ .key = .fromContents(.rodata, .@"4", bytes, &.{}, &.{}), .name = "", .section = .rodata, .alignment = .@"4", .bytes = bytes };
    }
    const fkey = struct {
        fn f(i: usize) SymbolKey {
            var buf: [16]u8 = undefined;
            return .fromName(std.fmt.bufPrint(&buf, "f{d}", .{i}) catch unreachable);
        }
    }.f;

    var atoms: std.ArrayList(Atom) = .empty;
    var expected: u32 = 0;
    for (0..n) |i| {
        var e: Encoder = .init(arena);
        try e.alu(.add, .dword, .{ .reg = .rbx }, .{ .mem = .sym(constants[i % 50].key, 0) });
        if (i + 1 < n) {
            try e.call(.{ .sym = fkey(i + 1) });
            try e.ret();
        } else {
            try e.jmp(.{ .sym = finish });
        }
        e.finish();
        expected +%= @intCast(i % 50 + 1);
        const alignments = [_]std.mem.Alignment{ .@"1", .@"16", .@"64" };
        try atoms.append(arena, .{ .key = fkey(i), .name = try std.fmt.allocPrint(arena, "f{d}", .{i}), .section = .text, .alignment = alignments[i % 3], .bytes = e.code.items, .targets = e.refs.targets.keys(), .relocs = e.refs.relocs.items });
        try atoms.append(arena, constants[i % 50]);
        if (i % 7 == 0) try atoms.append(arena, .{ .key = fkey(n + i), .name = "pad", .section = .bss, .alignment = .@"8", .zero_fill = i % 13 });
    }

    var f: Encoder = .init(arena);
    try f.mov(.dword, .{ .reg = .rax }, .{ .imm = 1 });
    try f.mov(.dword, .{ .reg = .rdi }, .{ .imm = 1 });
    try f.mov(.qword, .{ .reg = .rsi }, .{ .mem = .sym(msg_ptr, 0) });
    try f.mov(.dword, .{ .reg = .rdx }, .{ .imm = msg_text.len });
    try f.syscall();
    try f.movzx(.dword, .rdi, .byte, .{ .reg = .rbx });
    try f.mov(.dword, .{ .reg = .rax }, .{ .imm = 60 });
    try f.syscall();
    f.finish();
    try atoms.append(arena, .{ .key = finish, .name = "finish", .section = .text, .bytes = f.code.items, .targets = f.refs.targets.keys(), .relocs = f.refs.relocs.items });
    try atoms.append(arena, .{ .key = msg, .name = "msg", .section = .rodata, .bytes = msg_text });
    try atoms.append(arena, .{ .key = msg_ptr, .name = "msg_ptr", .section = .data, .alignment = .@"8", .bytes = &@as([8]u8, @splat(0)), .targets = &.{msg}, .relocs = &.{.init(0, .x86_64_abs64, 0, 0)} });
    var s: Encoder = .init(arena);
    try s.alu(.xor, .dword, .{ .reg = .rbx }, .{ .reg = .rbx });
    try s.call(.{ .sym = fkey(0) });
    s.finish();
    try atoms.append(arena, .{ .key = start, .name = "_start", .section = .text, .bytes = s.code.items, .targets = s.refs.targets.keys(), .relocs = s.refs.relocs.items });

    const one = try emit(gpa, io, atoms.items, .{ .entry = start, .threads = 1 });
    defer gpa.free(one);
    const four = try emit(gpa, io, atoms.items, .{ .entry = start, .threads = 4 });
    defer gpa.free(four);
    try std.testing.expectEqualSlices(u8, one, four);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try link(gpa, io, tmp.dir, "chunks", atoms.items, .{ .entry = start, .threads = 3 });
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/chunks", .{tmp.sub_path});
    defer gpa.free(path);
    const result = try std.process.run(gpa, io, .{ .argv = &.{path} });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqualStrings(msg_text, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = @truncate(expected) }, result.term);
}
