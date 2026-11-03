//! Static, non-PIE x86_64 ELF linker. Takes the whole set of Atoms, lays out
//! sections, resolves relocations, and writes the executable in one pass
//! into one buffer. Nothing is patched afterwards.
//!
//! File layout, with each segment starting on a page boundary and mapped at
//! `base_address + file offset`:
//!
//!   R   ELF header, program headers, .rodata, .eh_frame, .eh_frame_hdr
//!       (the last two present if `Options.debug` is not empty)
//!   RX  .text
//!   RW  .tdata and .tbss (thread-local, present if used), .data, then
//!       .bss (memory only)
//!       .debug_abbrev, .debug_info, .debug_line, .debug_str (not loaded;
//!       present if `Options.debug` is not empty)
//!       .symtab, .strtab, .shstrtab, section headers (not loaded)
//!
//! Debug info is DWARF 5 with one compile unit for the whole output: one
//! subprogram entry and one line-number sequence, wrapping the function's
//! own fragment, per entry of `Options.debug`. The entries come separately
//! from the atoms, so that linking without them never reads them, and with
//! them the debug passes stream through them in chunks of their own.
//!
//! Call frame information is one .eh_frame CIE and a fixed-size FDE per
//! entry with a frame (frame-pointer or outermost), indexed by a sorted .eh_frame_hdr
//! search table that PT_GNU_EH_FRAME points to, which is where std.debug's
//! unwinder looks first. Both sections are sized for every entry before
//! the debug entries are read, so entries that get no FDE leave unused
//! zero bytes after each section.
//!
//! Thread-local storage: .tdata and .tbss start the RW segment, covered by
//! a PT_TLS program header (filesz the .tdata bytes, memsz through the end
//! of .tbss, align the larger alignment), which is what the static TLS
//! setup (std.os.linux.tls.initStatic) copies each thread's block from.
//! .tbss takes room in the image, zeros in the file, so that no other
//! section's addresses overlap the TLS segment's. Only the local-exec model
//! exists (`x86_64_tpoff32`); TLS symbols' values are offsets in the TLS
//! segment, as ld writes them for executables.

const std = @import("std");
const builtin = @import("builtin");
const elf = std.elf;
const Allocator = std.mem.Allocator;
const Atom = @import("Atom.zig");
const Dwarf = @import("Dwarf.zig");
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
    /// Debug info for functions, sorted by `Atom.Debug.atom`; empty to leave
    /// debug info out.
    debug: []const Atom.Debug = &.{},
    /// The directory relative source paths in debug info are relative to
    /// (DW_AT_comp_dir).
    comp_dir: []const u8 = ".",
    /// The atoms' symbols, already numbered by the caller, so that the link
    /// looks up no keys. When set, `entry` is used only in diagnostics and
    /// `values` not at all.
    symbols: ?Symbols = null,
    /// How `link` writes the file; for tests and benchmarks.
    file_writes: FileWrites = .auto,
};

pub const FileWrites = enum {
    /// Whichever is faster in the case at hand.
    auto,
    /// Through a shared mapping of the file.
    map,
    /// With pwrite: each task builds its contiguous parts of the file in a
    /// buffer of its thread's and writes them.
    pwrite,
};

pub const Value = struct { key: SymbolKey, value: u64 };

/// Symbols numbered densely by the caller, such as the cache's manifest,
/// which keeps the numbering across builds so that a relink only numbers
/// the new atoms' targets. With them, a link does no hashing or probing:
/// every relocation target is an index into one address table.
///
/// The atoms must have distinct keys: deduplicating is the numbering's job.
/// The output is byte-identical to the key-based link of the same atoms.
/// (Not necessarily to that of a longer list with duplicates: layout works
/// in chunks of input atoms, and dropping some moves chunk boundaries.)
pub const Symbols = struct {
    /// One per atom.
    atoms: []const NumberedAtom,
    /// The numbers of the atoms' targets: `atoms[i].targets[j]` is
    /// `targets[Symbols.atoms[i].targets + j]`. Atoms can share runs, and
    /// runs need not be in atom order, so a cache can append new atoms'
    /// runs and keep the old ones.
    targets: []const u32,
    /// Where `targets` continues: an index `k >= targets.len` reads
    /// `targets_tail[k - targets.len]`. No run may straddle the two, so
    /// that a cache can pass its base mapping and its log's runs without
    /// joining them.
    targets_tail: []const u32 = &.{},
    /// Symbols whose value is a link-time integer (see the `value*`
    /// relocation kinds). An atom with the same number takes precedence.
    values: []const NumberedValue = &.{},
    entry: u32,
    /// Numbers are below this; numbers with no atom or value are
    /// undefined, which is an error only if a relocation uses one.
    len: u32,
};

pub const NumberedAtom = extern struct {
    /// The atom's own number, distinct from every other atom's.
    symbol: u32,
    /// Index in `Symbols.targets` of its first target's number.
    targets: u32,
};

pub const NumberedValue = struct { symbol: u32, value: u64 };

pub const Diagnostic = struct {
    /// Atom whose definition or relocation failed.
    atom: []const u8 = "",
    /// The undefined or overflowing target, if any.
    target: ?SymbolKey = null,
    /// The input index of the atom, the lowest one if several failed.
    index: ?usize = null,
};

pub const Error = Allocator.Error || std.Io.Cancelable || error{
    /// Two atoms share a key but differ in contents.
    DuplicateSymbol,
    UndefinedSymbol,
    RelocationOverflow,
    /// A relocation lies outside its atom, or is in a `.bss` or `.tbss`
    /// atom, or a TLS relocation targets a symbol that is not thread-local.
    InvalidRelocation,
    /// An atom's alignment is above 4 MiB.
    AlignmentTooLarge,
    /// A debug entry names no text atom, or entries are out of order.
    InvalidDebugInfo,
    /// `Options.symbols` does not fit the atoms: wrong lengths, or a
    /// number out of range.
    InvalidSymbols,
    /// Writing the output file failed, for example because the disk is
    /// full.
    WriteFailed,
    /// An input's record is malformed (see `AtomSlice.check`).
    InvalidInput,
};

/// Where `build` puts the output: a buffer holding all of it (in memory, or
/// a mapping of the file), or a file it writes with pwrite, one contiguous
/// range at a time.
const Target = union(enum) {
    memory: []u8,
    file: std.posix.fd_t,
};

/// Links `atoms` and writes the executable to `sub_path` in `dir`, each
/// byte once, into the page cache: built directly in a shared mapping of
/// the file, or built in a buffer per thread, one contiguous range of the
/// file at a time, and written with pwrite (see `ReusedOutput.target`). The
/// previous output is overwritten in place when that is safe (see
/// `ReusedOutput`), which saves the kernel allocating and zeroing every
/// page again.
pub fn link(gpa: Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, atoms: []const Atom, options: Options) !void {
    return linkInput(gpa, io, dir, sub_path, AtomSlice{ .atoms = atoms, .debug_entries = options.debug }, options);
}

/// `link` with the atoms and their debug info read from `input`, which has
/// `AtomSlice`'s declarations; `options.debug` is not used.
pub fn linkInput(gpa: Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, input: anytype, options: Options) !void {
    var out: ReusedOutput = .{ .dir = dir, .sub_path = sub_path, .writes = options.file_writes };
    defer out.close(io);
    errdefer dir.deleteFile(io, sub_path) catch {};
    try build(gpa, io, input, options, &out);
}

/// The linker's input: atoms by index in link order, and the debug entries
/// of some of them, sorted by atom. This one reads slices; any type with
/// the same declarations works, such as the cache's mapped packs, which
/// build each `Atom` from its record. Linking reads an atom several times,
/// so `atom` must be cheap, and everything it returns must stay valid until
/// the link returns.
pub const AtomSlice = struct {
    atoms: []const Atom,
    debug_entries: []const Atom.Debug,

    pub inline fn len(s: AtomSlice) usize {
        return s.atoms.len;
    }

    /// Whether atom `i`'s record is well-formed, so that `atom(i)`, and
    /// `debug(j)` for an entry of atom `i`, read only within it and give
    /// valid enum values. Called once per atom before anything else reads
    /// it; a false result fails the link with `error.InvalidInput`. Slices
    /// of `Atom` are valid by construction.
    pub inline fn check(_: AtomSlice, _: usize) bool {
        return true;
    }

    /// Atom `i`, as an `Atom` or a `*const Atom`.
    pub inline fn atom(s: AtomSlice, i: usize) *const Atom {
        return &s.atoms[i];
    }

    pub inline fn debugLen(s: AtomSlice) usize {
        return s.debug_entries.len;
    }

    /// The atom of debug entry `j`. The linker checks that these ascend and
    /// are below `len()` before it calls `debug(j)`.
    pub inline fn debugAtom(s: AtomSlice, j: usize) u32 {
        return s.debug_entries[j].atom;
    }

    /// Debug entry `j`, as an `Atom.Debug` or a `*const Atom.Debug`; its
    /// `atom` field is not used.
    pub inline fn debug(s: AtomSlice, j: usize) *const Atom.Debug {
        return &s.debug_entries[j];
    }

    /// Atom `i` is copied soon; `keys` says whether its targets' keys will
    /// be read.
    pub inline fn prefetch(s: AtomSlice, i: usize, comptime keys: bool) void {
        const n = &s.atoms[i];
        prefetchSlice(u8, n.bytes[0..@min(n.bytes.len, 64)]);
        if (keys) prefetchSlice(SymbolKey, n.targets);
        prefetchSlice(Atom.Reloc, n.relocs);
        prefetchSlice(u8, n.name);
    }

    /// Debug entry `j` is written soon.
    pub inline fn prefetchDebug(s: AtomSlice, j: usize) void {
        const n = &s.debug_entries[j];
        prefetchSlice(u8, n.lines);
        prefetchSlice(u8, n.name);
        @prefetch(&s.atoms[n.atom].bytes.len, .{});
    }
};

/// A pointer to what an input returned, given a pointer to it, whether it
/// returned a value or a pointer.
pub inline fn ref(p: anytype) switch (@typeInfo(@TypeOf(p.*))) {
    .pointer => @TypeOf(p.*),
    else => @TypeOf(p),
} {
    return switch (@typeInfo(@TypeOf(p.*))) {
        .pointer => p.*,
        else => p,
    };
}

/// Overwrites the old output in place if it is a regular executable file
/// with one link, not running (Linux refuses to open a running executable
/// for writing), and mostly in the page cache, since writing to a page that
/// is not would first read it from disk. Otherwise replaces it with a new
/// file, so that a running old executable keeps its own inode. The size
/// changes with `ftruncate`, never through 0: ext4 starts writeback of a
/// file truncated to 0 and rewritten when it is closed.
const ReusedOutput = struct {
    dir: std.Io.Dir,
    sub_path: []const u8,
    writes: FileWrites,
    file: ?std.Io.File = null,
    map: []align(std.heap.page_size_min) u8 = &.{},

    fn target(o: *ReusedOutput, io: std.Io, len: usize, threads: usize) !Target {
        const in_place = builtin.os.tag == .linux and o.reuse(io, len);
        if (!in_place) {
            o.dir.deleteFile(io, o.sub_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => |e| return e,
            };
            o.file = try o.dir.createFile(io, o.sub_path, .{ .read = true, .permissions = .executable_file });
            try o.file.?.setLength(io, len);
        }
        // Writing through the mapping pays a fault and page_mkwrite per
        // page, and zeroing each new page of a new file first. pwrite pays
        // one more copy, from the thread's buffer, and ext4 takes the inode
        // lock for each write, so threads' writes do not overlap. Both mark
        // every page dirty. Measured (docs/architecture.md): in place they
        // tie on 1 thread and the mapping wins on 4; into a new file pwrite
        // wins on 1 and 2 threads and they tie on 4.
        const writes: FileWrites = switch (o.writes) {
            .auto => if (!in_place and threads < 4) .pwrite else .map,
            else => |w| w,
        };
        if (writes == .pwrite) return .{ .file = o.file.?.handle };
        o.map = try std.posix.mmap(null, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, o.file.?.handle, 0);
        return .{ .memory = o.map };
    }

    fn reuse(o: *ReusedOutput, io: std.Io, len: usize) bool {
        const file = o.dir.openFile(io, o.sub_path, .{ .mode = .read_write, .follow_symlinks = false }) catch return false;
        const st = file.stat(io) catch return closed(io, file);
        if (st.kind != .file or st.nlink != 1 or @backingInt(st.permissions) & 0o111 == 0) return closed(io, file);
        file.setLength(io, len) catch return closed(io, file);
        const old_len = std.mem.alignBackward(usize, @min(len, st.size), std.heap.page_size_min);
        if (old_len > 0) {
            const map = std.posix.mmap(null, old_len, .{ .READ = true }, .{ .TYPE = .SHARED }, file.handle, 0) catch return closed(io, file);
            defer std.posix.munmap(map);
            if (!mostlyCached(map)) return closed(io, file);
        }
        o.file = file;
        return true;
    }

    fn closed(io: std.Io, file: std.Io.File) bool {
        file.close(io);
        return false;
    }

    /// Whether at least 7/8 of the pages of `map` are in the page cache.
    fn mostlyCached(map: []align(std.heap.page_size_min) u8) bool {
        var vec: [4096]u8 = undefined;
        var resident: usize = 0;
        var at: usize = 0;
        while (at < map.len) {
            const n = @min(vec.len, (map.len - at) / std.heap.page_size_min);
            std.posix.mincore(@alignCast(map[at..].ptr), n * std.heap.page_size_min, &vec) catch return false;
            for (vec[0..n]) |v| resident += v & 1;
            at += n * std.heap.page_size_min;
        }
        return resident * 8 >= map.len / std.heap.page_size_min * 7;
    }

    fn close(o: *ReusedOutput, io: std.Io) void {
        if (o.map.len > 0) std.posix.munmap(o.map);
        if (o.file) |f| f.close(io);
    }
};

/// Links `atoms` into the bytes of an executable, owned by the caller.
pub fn emit(gpa: Allocator, io: std.Io, atoms: []const Atom, options: Options) Error![]u8 {
    return emitInput(gpa, io, AtomSlice{ .atoms = atoms, .debug_entries = options.debug }, options);
}

/// `emit` with the atoms and their debug info read from `input` (see
/// `linkInput`).
pub fn emitInput(gpa: Allocator, io: std.Io, input: anytype, options: Options) Error![]u8 {
    var out: MemoryOutput = .{ .gpa = gpa };
    errdefer gpa.free(out.buf);
    try build(gpa, io, input, options, &out);
    return out.buf;
}

pub const MemoryOutput = struct {
    gpa: Allocator,
    buf: []u8 = &.{},

    pub fn buffer(o: *MemoryOutput, _: std.Io, len: usize) Error![]u8 {
        o.buf = try o.gpa.alloc(u8, len);
        return o.buf;
    }

    fn target(o: *MemoryOutput, io: std.Io, len: usize, _: usize) Error!Target {
        return .{ .memory = try o.buffer(io, len) };
    }
};

pub const FileOutput = struct {
    file: std.Io.File,
    map: []align(std.heap.page_size_min) u8 = &.{},

    pub fn buffer(o: *FileOutput, io: std.Io, len: usize) ![]u8 {
        try o.file.setLength(io, len);
        o.map = try std.posix.mmap(null, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, o.file.handle, 0);
        return o.map;
    }
};

const page_size = 0x1000;

/// Section header index of each `Atom.Section`. The allocated sections'
/// headers come in layout order: .rodata, .text, .tdata and .tbss if
/// present, .data, .bss. Then .eh_frame and .eh_frame_hdr and the debug
/// sections, if present, then .symtab, .strtab, and .shstrtab.
fn shndxOf(has_tls: bool) [n_sections]u16 {
    const t: u16 = @intFromBool(has_tls);
    return .{ 2, 1, 3 + 2 * t, 4 + 2 * t, 3, 4 };
}
const n_sections = std.enums.values(Atom.Section).len;
/// Padding within each section: int3 in code, zeros elsewhere.
const fills = [n_sections]u8{ 0xcc, 0, 0, 0, 0, 0 };
/// Sections with no bytes in the file.
const zero_fill = [n_sections]bool{ false, false, false, true, false, true };
const sym_types = [n_sections]elf.STT{ .FUNC, .OBJECT, .OBJECT, .OBJECT, .TLS, .TLS };

/// The TLS segment's addresses [start, end), and the thread pointer, the
/// end rounded up to the segment's alignment, as if the segment were the
/// thread's TLS block (x86_64 TLS variant 2).
const Tls = struct { start: u64, end: u64, tp: u64 };
/// Where pass 1 placed an atom.
const Place = packed struct(u64) {
    /// Offset within the chunk's part of the section.
    offset: u39,
    /// Alignment padding between the previous atom of the section and this
    /// one, which the copy pass fills.
    gap: u22,
    section: u3,

    const duplicate: Place = @bitCast(@as(u64, std.math.maxInt(u64)));

    fn isDuplicate(p: Place) bool {
        return @as(u64, @bitCast(p)) == std.math.maxInt(u64);
    }
};
/// Atoms per unit of work in placement and copying.
const chunk_len = 2048;
/// Address-table entries, with numbered symbols: an atom's address minus
/// the base address, `value_tag` plus the index of a value in
/// `Symbols.values`, or `unset` for a number with neither. 32 bits keep
/// the table small, as relocations index it at random.
const unset = std.math.maxInt(u32);
const value_tag = 1 << 31;
/// Section names. Outputs without debug info keep the prefix up to the
/// names they use.
const shstrtab = "\x00.rodata\x00.text\x00.data\x00.bss\x00.symtab\x00.strtab\x00.shstrtab\x00.eh_frame\x00.eh_frame_hdr\x00.debug_abbrev\x00.debug_info\x00.debug_line\x00.debug_str\x00.tdata\x00.tbss\x00";
const shstrtab_no_tls = shstrtab[0..shName(".tdata")];
const shstrtab_no_cfi = shstrtab[0..shName(".eh_frame")];
const shstrtab_no_debug = shstrtab[0..shName(".debug_abbrev")];

fn shName(comptime name: []const u8) u32 {
    return comptime @intCast(std.mem.indexOf(u8, shstrtab, "\x00" ++ name ++ "\x00").? + 1);
}

/// Links the atoms of `input` into `out.target(io, len, threads)`.
///
/// Work is split three ways, each spread over threads; the output does not
/// depend on the thread count:
///  1. Deduplicate: the symbol table is partitioned by key, and each
///     partition takes its keys in input order, so the first atom with a key
///     is the one kept. With `Options.symbols`, there is nothing to do, and
///     step 2 records addresses by symbol number instead of by key.
///  2. Place: each chunk of consecutive atoms lays out its own atoms within
///     each section. A short serial step then places the chunks, so atoms
///     keep their input order within a section.
///  3. Copy: each chunk copies its atoms' bytes, applies their relocations,
///     and writes their symbols; chunks write disjoint parts of the output.
fn build(gpa: Allocator, io: std.Io, input: anytype, options: Options, out: anytype) !void {
    const Link = LinkOf(@TypeOf(input));
    const n_atoms = input.len();
    var unused_diag: Diagnostic = .{};
    const diag = options.diag orelse &unused_diag;
    const text = @backingInt(Atom.Section.text);
    const rodata = @backingInt(Atom.Section.rodata);
    const data = @backingInt(Atom.Section.data);
    const bss = @backingInt(Atom.Section.bss);
    const tdata = @backingInt(Atom.Section.tdata);
    const tbss = @backingInt(Atom.Section.tbss);

    const n_chunks = std.math.divCeil(usize, n_atoms, chunk_len) catch unreachable;
    const n_threads = @max(1, @min(n_chunks, options.threads orelse std.Thread.getCpuCount() catch 1));
    // Every partition scans all atoms, so use no more than there are threads.
    const n_partitions = std.math.ceilPowerOfTwoAssert(usize, @min(n_threads, 8));

    const numbered = options.symbols;
    if (numbered) |s| if (s.atoms.len != n_atoms or s.entry >= s.len) return error.InvalidSymbols;
    var symbols: SymbolTable = if (numbered == null) try .init(n_atoms, n_partitions) else .empty;
    defer symbols.deinit();
    // With numbered symbols, each number's address or value.
    const addrs = try gpa.alloc(u32, if (numbered) |s| s.len else 0);
    defer gpa.free(addrs);
    const places = try gpa.alloc(Place, n_atoms);
    defer gpa.free(places);
    const keys = try gpa.alloc(SymbolKey, if (numbered == null) n_atoms else 0);
    defer gpa.free(keys);
    populate(std.mem.sliceAsBytes(places));
    populate(std.mem.sliceAsBytes(keys));
    const chunks = try gpa.alloc(Chunk, n_chunks);
    defer gpa.free(chunks);
    const n_debug = input.debugLen();
    const n_debug_chunks = std.math.divCeil(usize, n_debug, chunk_len) catch unreachable;
    const debug_chunks = try gpa.alloc(DebugChunk, n_debug_chunks);
    defer gpa.free(debug_chunks);
    for (debug_chunks) |*c| c.files = .empty;
    defer for (debug_chunks) |*c| c.files.deinit(gpa);
    const file_of = try gpa.alloc(u32, n_debug);
    defer gpa.free(file_of);
    // Atom chunks, then debug chunks.
    const failures = try gpa.alloc(?Failure, @max(n_chunks + n_debug_chunks, n_partitions));
    defer gpa.free(failures);
    var l: Link = .{
        .gpa = gpa,
        .input = input,
        .n_atoms = n_atoms,
        .n_debug = n_debug,
        .debug_chunks = debug_chunks,
        .file_of = file_of,
        .n_partitions = n_partitions,
        .n_resolve_tasks = if (numbered == null) n_partitions else n_chunks,
        .numbered = numbered,
        .addrs = addrs,
        .places = places,
        .keys = keys,
        .chunks = chunks,
        .symbols = &symbols,
        .failures = failures,
    };

    @memset(failures, null);
    if (numbered == null) {
        try parallel(io, n_threads, n_chunks, &l, Link.gatherKeys);
        try l.check(diag);
        try parallel(io, n_threads, n_partitions, &l, Link.dedup);
    }
    if (numbered == null) {
        try parallel(io, n_threads, n_chunks, &l, Link.layOutKeyed);
    } else {
        try parallel(io, n_threads, n_chunks, &l, Link.layOutNumbered);
    }
    try l.check(diag);

    // Place chunks within sections, and their symbols and names.
    var sizes: [n_sections]u64 = @splat(0);
    var aligns: [n_sections]std.mem.Alignment = @splat(.@"1");
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
    var values: SymbolTable = .empty;
    defer values.deinit();
    if (numbered) |s| {
        // Atoms, numbered in `resolveAddrs`, take precedence over values.
        @memset(addrs, unset);
        if (s.values.len >= unset - value_tag) return error.InvalidSymbols;
        for (s.values, 0..) |v, i| {
            if (v.symbol >= addrs.len) return error.InvalidSymbols;
            addrs[v.symbol] = @intCast(value_tag + i);
        }
    } else {
        if (symbols.get(options.entry) == null) {
            diag.* = .{ .target = options.entry };
            return error.UndefinedSymbol;
        }
        values = try .init(options.values.len, 1);
        for (options.values) |v| values.getOrPut(v.key).* = .{ .key = v.key, .value = v.value, .used = true };
    }

    // Section placement, as file offsets (for .bss, address - base).
    const has_rx = sizes[text] > 0;
    const has_tls = sizes[tdata] > 0 or sizes[tbss] > 0;
    const has_rw = sizes[data] > 0 or sizes[bss] > 0 or has_tls;
    const has_cfi = n_debug > 0;
    const phnum: u16 = 2 + @as(u16, @intFromBool(has_rx)) + @intFromBool(has_rw) + @intFromBool(has_cfi) + @intFromBool(has_tls);
    const headers_end: u64 = @sizeOf(elf.Elf64.Ehdr) + phnum * @sizeOf(elf.Elf64.Phdr);
    var starts: [n_sections]u64 = undefined;
    starts[rodata] = aligns[rodata].forward(headers_end);
    const rodata_end = starts[rodata] + sizes[rodata];
    // Room for an FDE per debug entry, and the terminator.
    const eh_off = std.mem.alignForward(u64, rodata_end, 8);
    const eh_room = if (has_cfi) Dwarf.cie.len + n_debug * Dwarf.fde_size + 4 else 0;
    const hdr_off = eh_off + eh_room;
    const hdr_room = if (has_cfi) Dwarf.eh_frame_hdr_size + n_debug * Dwarf.eh_frame_hdr_entry_size else 0;
    const r_end = if (has_cfi) hdr_off + hdr_room else rodata_end;
    const rx_start = if (has_rx) std.mem.alignForward(u64, r_end, page_size) else r_end;
    starts[text] = aligns[text].forward(rx_start);
    const text_end = starts[text] + sizes[text];
    const rw_start = if (has_rw) std.mem.alignForward(u64, text_end, page_size) else text_end;
    // The TLS segment: its start and every thread's copy are aligned to
    // its alignment, so offsets within it keep theirs.
    const tls_align = aligns[tdata].max(aligns[tbss]);
    const tls_start = tls_align.forward(rw_start);
    starts[tdata] = tls_start;
    const tdata_end = tls_start + sizes[tdata];
    starts[tbss] = aligns[tbss].forward(tdata_end);
    const tls_end = starts[tbss] + sizes[tbss];
    starts[data] = aligns[data].forward(tls_end);
    const file_end = starts[data] + sizes[data];
    starts[bss] = aligns[bss].forward(file_end);
    const mem_end = starts[bss] + sizes[bss];
    // Call frame information holds 32-bit offsets between any two parts of
    // the image.
    if (has_cfi and mem_end > std.math.maxInt(i32)) return error.OutOfMemory;

    const base = options.base_address;
    // Numbered symbols keep addresses as 31-bit offsets from the base.
    if (numbered != null and mem_end >= value_tag) return error.OutOfMemory;
    for (&l.section_addrs, starts) |*sa, st| sa.* = base + st;
    l.base = base;
    l.shndx = shndxOf(has_tls);
    l.sym_bias = .{ 0, 0, 0, 0, base + tls_start, base + tls_start };
    // Variant 2: the thread pointer is the end of the thread's TLS block,
    // whose size is the segment's rounded up to its alignment.
    l.tls = .{ .start = base + tls_start, .end = base + tls_end, .tp = base + tls_start + tls_align.forward(tls_end - tls_start) };
    try parallel(io, n_threads, l.n_resolve_tasks + n_debug_chunks, &l, Link.resolveAddrsAndLayOutDebug);
    try l.check(diag);
    const entry_addr = if (numbered) |s| l.numberedAddr(addrs[s.entry]) else symbols.get(options.entry).?;
    if (entry_addr == null) {
        diag.* = .{ .target = options.entry };
        return error.UndefinedSymbol;
    }

    // Place the debug chunks, and build the file table from their files in
    // first-use order.
    var info_len: u64 = 0;
    var line_len: u64 = 0;
    var n_chunk_files: usize = 0;
    var n_fdes: u32 = 0;
    for (debug_chunks) |*c| {
        c.info_off = info_len;
        c.line_off = line_len;
        c.fde_base = n_fdes;
        info_len += c.info_len;
        line_len += c.line_len;
        n_fdes += c.n_fdes;
        n_chunk_files += c.files.count();
    }
    var files: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer files.deinit(gpa);
    const file_map = try gpa.alloc(u32, n_chunk_files);
    defer gpa.free(file_map);
    {
        var at: usize = 0;
        for (debug_chunks) |*c| {
            c.file_map = file_map[at..][0..c.files.count()];
            at += c.files.count();
            for (c.files.keys(), c.file_map) |f, *global| {
                global.* = @intCast((try files.getOrPut(gpa, f)).index);
            }
        }
    }
    // The set_file operand is a fixed-width ULEB128.
    if (files.count() >= 1 << 21) return error.OutOfMemory;
    var dwarf: Dwarf = if (files.count() > 0) try .init(gpa, files.keys(), options.comp_dir) else .{};
    defer dwarf.deinit(gpa);

    const has_debug = files.count() > 0;
    const abbrev_off = file_end;
    const info_off = abbrev_off + if (has_debug) Dwarf.abbrev.len else 0;
    const info_size = if (has_debug) dwarf.info_header.len + info_len + 1 else 0;
    const line_off = info_off + info_size;
    const line_size = if (has_debug) dwarf.line_header.len + line_len else 0;
    const str_off = line_off + line_size;
    const str_size = if (has_debug) Dwarf.str.len else 0;
    const symtab_off = std.mem.alignForward(u64, str_off + str_size, 8);
    const strtab_off = symtab_off + @as(u64, n_syms) * @sizeOf(elf.Elf64.Sym);
    const shstrtab_off = strtab_off + strtab_len;
    const shstr = if (has_tls) shstrtab else if (has_debug) shstrtab_no_tls else if (has_cfi) shstrtab_no_debug else shstrtab_no_cfi;
    const shoff = std.mem.alignForward(u64, shstrtab_off + shstr.len, 8);
    const shnum: u16 = 8 + 2 * @as(u16, @intFromBool(has_tls)) + 2 * @as(u16, @intFromBool(has_cfi)) + 4 * @as(u16, @intFromBool(has_debug));
    l.target = try out.target(io, shoff + shnum * @sizeOf(elf.Elf64.Shdr), n_threads);
    switch (l.target) {
        .memory => |buf| {
            adviseHugePages(buf);
            try parallel(io, n_threads, std.math.divCeil(usize, buf.len, populate_len) catch unreachable, &l, Link.populateOutput);
        },
        .file => {
            // Room for the largest task's parts of the output.
            for (chunks) |*c| {
                var len: u64 = @as(u64, c.n_syms) * @sizeOf(elf.Elf64.Sym) + c.str_len;
                for (c.lead_gaps, c.sizes, zero_fill) |gap, size, no_bytes| {
                    if (!no_bytes) len += gap + size;
                }
                l.scratch_len = @max(l.scratch_len, len);
            }
            for (debug_chunks) |*c| {
                const fde_len = @as(u64, c.n_fdes) * (Dwarf.fde_size + Dwarf.eh_frame_hdr_entry_size);
                l.scratch_len = @max(l.scratch_len, c.info_len + c.line_len + fde_len);
            }
            l.scratch = try gpa.alloc(u8, n_threads * l.scratch_len);
        },
    }
    defer gpa.free(l.scratch);

    // Padding between sections; padding within a section is filled by the
    // atom or chunk after it.
    try l.fill(headers_end, starts[rodata] - headers_end);
    try l.fill(rodata_end, eh_off - rodata_end);
    try l.fill(r_end, starts[text] - r_end);
    try l.fill(text_end, tls_start - text_end);
    // .tbss's room in the file is zeros.
    try l.fill(tdata_end, starts[data] - tdata_end);
    try l.fill(str_off + str_size, symtab_off - (str_off + str_size));
    try l.fill(symtab_off, @sizeOf(elf.Elf64.Sym));
    try l.fill(strtab_off, 1);
    try l.put(shstrtab_off, shstr);
    try l.fill(shstrtab_off + shstr.len, shoff - (shstrtab_off + shstr.len));
    const eh_size = Dwarf.cie.len + @as(u64, n_fdes) * Dwarf.fde_size + 4;
    const hdr_size = Dwarf.eh_frame_hdr_size + @as(u64, n_fdes) * Dwarf.eh_frame_hdr_entry_size;
    if (has_cfi) {
        // The FDEs and the search table are written with the debug chunks.
        try l.put(eh_off, &Dwarf.cie);
        try l.fill(eh_off + eh_size - 4, hdr_off - (eh_off + eh_size - 4)); // terminator, unused room
        const eh_frame_rel: i32 = @intCast(@as(i64, @intCast(eh_off)) - @as(i64, @intCast(hdr_off + 4)));
        try l.put(hdr_off, &Dwarf.ehFrameHdr(eh_frame_rel, n_fdes));
        try l.fill(hdr_off + hdr_size, r_end - (hdr_off + hdr_size));
    }
    if (has_debug) {
        // Debug info covers all of .text, so atoms without `debug` resolve to
        // the compile unit but to no function or line.
        const text_addr = base + starts[text];
        try l.put(abbrev_off, &Dwarf.abbrev);
        dwarf.finishInfoHeader(info_size, text_addr, sizes[text]);
        try l.put(info_off, dwarf.info_header);
        try l.fill(info_off + info_size - 1, 1); // end of the unit's children
        dwarf.finishLineHeader(line_size);
        try l.put(line_off, dwarf.line_header);
        try l.put(str_off, Dwarf.str);
    }

    const resolved = try gpa.alloc(u64, n_threads * max_targets);
    defer gpa.free(resolved);
    l.values = &values;
    l.symtab_off = symtab_off;
    l.strtab_off = strtab_off;
    l.resolved = resolved;
    l.max_targets = max_targets;
    l.info_off = info_off + dwarf.info_header.len;
    l.line_off = line_off + dwarf.line_header.len;
    l.eh_off = eh_off;
    l.hdr_off = hdr_off;
    try parallel(io, n_threads, n_chunks + n_debug_chunks, &l, Link.copyAll);
    try l.check(diag);

    // Headers.
    var head: [@sizeOf(elf.Elf64.Ehdr) + 6 * @sizeOf(elf.Elf64.Phdr)]u8 = undefined;
    writeStruct(&head, elf.Elf64.Ehdr{
        .ident = .{ .class = .@"64", .data = .@"2LSB", .version = 1, .osabi = .NONE, .abiversion = 0 },
        .type = .EXEC,
        .machine = .X86_64,
        .version = 1,
        .entry = entry_addr.?,
        .phoff = @sizeOf(elf.Elf64.Ehdr),
        .shoff = shoff,
        .flags = .{ .int = 0 },
        .ehsize = @sizeOf(elf.Elf64.Ehdr),
        .phentsize = @sizeOf(elf.Elf64.Phdr),
        .phnum = phnum,
        .shentsize = @sizeOf(elf.Elf64.Shdr),
        .shnum = shnum,
        .shstrndx = shnum - 1,
    });
    var ph_off: usize = @sizeOf(elf.Elf64.Ehdr);
    const phdrs = [_]struct { bool, elf.PT, elf.PF, u64, u64, u64, u64 }{
        .{ true, .LOAD, .{ .R = true }, 0, r_end, r_end, page_size },
        .{ has_rx, .LOAD, .{ .R = true, .X = true }, rx_start, text_end - rx_start, text_end - rx_start, page_size },
        .{ has_rw, .LOAD, .{ .R = true, .W = true }, rw_start, file_end - rw_start, mem_end - rw_start, page_size },
        .{ has_tls, .TLS, .{ .R = true }, tls_start, sizes[tdata], tls_end - tls_start, tls_align.toByteUnits() },
    };
    for (phdrs) |p| if (p[0]) {
        writeStruct(head[ph_off..], elf.Elf64.Phdr{
            .type = p[1],
            .flags = p[2],
            .offset = p[3],
            .vaddr = base + p[3],
            .paddr = base + p[3],
            .filesz = p[4],
            .memsz = p[5],
            .@"align" = p[6],
        });
        ph_off += @sizeOf(elf.Elf64.Phdr);
    };
    if (has_cfi) {
        writeStruct(head[ph_off..], elf.Elf64.Phdr{
            .type = .GNU_EH_FRAME,
            .flags = .{ .R = true },
            .offset = hdr_off,
            .vaddr = base + hdr_off,
            .paddr = base + hdr_off,
            .filesz = hdr_size,
            .memsz = hdr_size,
            .@"align" = 4,
        });
        ph_off += @sizeOf(elf.Elf64.Phdr);
    }
    writeStruct(head[ph_off..], elf.Elf64.Phdr{
        .type = .GNU_STACK,
        .flags = .{ .R = true, .W = true },
        .offset = 0,
        .vaddr = 0,
        .paddr = 0,
        .filesz = 0,
        .memsz = 0,
        .@"align" = 16,
    });
    ph_off += @sizeOf(elf.Elf64.Phdr);
    std.debug.assert(ph_off == headers_end);
    try l.put(0, head[0..headers_end]);

    const cfi_shdrs = [_]elf.Elf64.Shdr{
        shdr(shName(".eh_frame"), .X86_64_UNWIND, .{ .ALLOC = true }, base, eh_off, eh_size, .@"8"),
        shdr(shName(".eh_frame_hdr"), .PROGBITS, .{ .ALLOC = true }, base, hdr_off, hdr_size, .@"4"),
    };
    const debug_shdrs = [_]elf.Elf64.Shdr{
        nonAlloc(shName(".debug_abbrev"), .PROGBITS, abbrev_off, Dwarf.abbrev.len),
        nonAlloc(shName(".debug_info"), .PROGBITS, info_off, info_size),
        nonAlloc(shName(".debug_line"), .PROGBITS, line_off, line_size),
        nonAlloc(shName(".debug_str"), .PROGBITS, str_off, str_size),
    };
    const tls_shdrs = [_]elf.Elf64.Shdr{
        shdr(shName(".tdata"), .PROGBITS, .{ .ALLOC = true, .WRITE = true, .TLS = true }, base, starts[tdata], sizes[tdata], aligns[tdata]),
        shdr(shName(".tbss"), .NOBITS, .{ .ALLOC = true, .WRITE = true, .TLS = true }, base, starts[tbss], sizes[tbss], aligns[tbss]),
    };
    const strtab_ndx = shnum - 2;
    const shdrs = [_]elf.Elf64.Shdr{
        std.mem.zeroes(elf.Elf64.Shdr),
        shdr(shName(".rodata"), .PROGBITS, .{ .ALLOC = true }, base, starts[rodata], sizes[rodata], aligns[rodata]),
        shdr(shName(".text"), .PROGBITS, .{ .ALLOC = true, .EXECINSTR = true }, base, starts[text], sizes[text], aligns[text]),
    } ++ tls_shdrs ++ [_]elf.Elf64.Shdr{
        shdr(shName(".data"), .PROGBITS, .{ .ALLOC = true, .WRITE = true }, base, starts[data], sizes[data], aligns[data]),
        shdr(shName(".bss"), .NOBITS, .{ .ALLOC = true, .WRITE = true }, base, starts[bss], sizes[bss], aligns[bss]),
    } ++ cfi_shdrs ++ debug_shdrs ++ [_]elf.Elf64.Shdr{
        .{ .name = shName(".symtab"), .type = .SYMTAB, .flags = .{ .shf = .{} }, .addr = 0, .offset = symtab_off, .size = n_syms * @sizeOf(elf.Elf64.Sym), .link = strtab_ndx, .info = 1, .addralign = 8, .entsize = @sizeOf(elf.Elf64.Sym) },
        nonAlloc(shName(".strtab"), .STRTAB, strtab_off, strtab_len),
        nonAlloc(shName(".shstrtab"), .STRTAB, shstrtab_off, shstr.len),
    };
    var sh_buf: [shdrs.len * @sizeOf(elf.Elf64.Shdr)]u8 = undefined;
    var sh_at: usize = 0;
    const present = [_]struct { bool, usize }{ .{ true, 3 }, .{ has_tls, tls_shdrs.len }, .{ true, 2 }, .{ has_cfi, cfi_shdrs.len }, .{ has_debug, debug_shdrs.len }, .{ true, 3 } };
    var group: usize = 0;
    var group_end: usize = present[0][1];
    for (shdrs, 0..) |s, i| {
        if (i == group_end) {
            group += 1;
            group_end += present[group][1];
        }
        if (!present[group][0]) continue;
        writeStruct(sh_buf[sh_at..], s);
        sh_at += @sizeOf(elf.Elf64.Shdr);
    }
    std.debug.assert(sh_at == shnum * @sizeOf(elf.Elf64.Shdr));
    try l.put(shoff, sh_buf[0..sh_at]);
}

/// One `chunk_len` run of consecutive atoms.
const Chunk = struct {
    // Filled in by `Link.layOut`.
    sizes: [n_sections]u64,
    aligns: [n_sections]std.mem.Alignment,
    n_syms: u32,
    str_len: u32,
    max_targets: u32,
    // Filled in serially after `Link.layOut`.
    /// Where the chunk's atoms of each section start, within the section.
    bases: [n_sections]u64,
    /// Padding before `bases`, which the chunk fills.
    lead_gaps: [n_sections]u64,
    /// The chunk's first symbol in .symtab and first byte in .strtab.
    sym: u32,
    str: u32,
};

/// One `chunk_len` run of consecutive debug entries.
const DebugChunk = struct {
    // Filled in by `Link.layOutDebug`.
    /// Bytes of the chunk's subprogram entries and line sequences.
    info_len: u64,
    line_len: u64,
    n_fdes: u32,
    /// Source files of the chunk's entries, in first-use order;
    /// `Link.file_of` indexes it.
    files: std.StringArrayHashMapUnmanaged(void),
    // Filled in serially after `Link.layOutDebug`.
    /// Where the chunk's entries and sequences start, after the headers.
    info_off: u64,
    line_off: u64,
    /// The chunk's first FDE, counting from the first after the CIE.
    fde_base: u32,
    /// Index in the output's file table of each of `files`.
    file_map: []u32,
};

const Failure = struct { atom: usize, err: Error, diag: Diagnostic };

/// State shared by the threads of `build`, reading atoms from an `Input`
/// (see `AtomSlice`).
fn LinkOf(comptime Input: type) type {
    return struct {
        const Link = @This();

        gpa: Allocator,
        input: Input,
        n_atoms: usize,
        n_debug: usize,
        debug_chunks: []DebugChunk,
        /// Index into its chunk's `files` of each debug entry, or `skip`.
        file_of: []u32,
        n_partitions: usize,
        /// `resolveAddrs` tasks: partitions of `symbols`, or with numbered
        /// symbols, chunks.
        n_resolve_tasks: usize,
        numbered: ?Symbols,
        /// With numbered symbols, where each is (see `unset`).
        addrs: []u32,
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
        target: Target = undefined,
        /// With a `.file` target, `scratch_len` bytes per thread for the parts
        /// of the output a task writes.
        scratch: []u8 = &.{},
        scratch_len: usize = 0,
        base: u64 = undefined,
        section_addrs: [n_sections]u64 = undefined,
        /// The TLS segment's addresses, and the thread pointer's place
        /// relative to them.
        tls: Tls = undefined,
        shndx: [n_sections]u16 = undefined,
        /// Subtracted from addresses for symbol values: thread-locals' values
        /// are offsets in the TLS segment.
        sym_bias: [n_sections]u64 = undefined,
        symtab_off: u64 = undefined,
        strtab_off: u64 = undefined,
        /// `max_targets` addresses per thread.
        resolved: []u64 = undefined,
        max_targets: usize = undefined,
        /// Where the chunks' subprogram entries and line sequences start.
        info_off: u64 = undefined,
        line_off: u64 = undefined,
        /// File offsets of .eh_frame and .eh_frame_hdr.
        eh_off: u64 = undefined,
        hdr_off: u64 = undefined,

        fn check(l: *Link, diag: *Diagnostic) Error!void {
            var first: ?Failure = null;
            for (l.failures) |f| if (f) |failure| {
                if (first == null or failure.atom < first.?.atom) first = failure;
            };
            @memset(l.failures, null);
            const failure = first orelse return;
            diag.* = failure.diag;
            if (failure.atom < l.n_atoms) diag.index = failure.atom;
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
        /// so that resolving a relocation target is one lookup. With numbered
        /// symbols, sets the addresses of one chunk's atoms' numbers instead.
        fn resolveAddrs(l: *Link, task: usize, _: usize) void {
            const s = l.numbered orelse {
                for (l.symbols.partitionEntries(task)) |*e| {
                    if (e.used) e.value = l.atomAddr(e.value);
                }
                return;
            };
            const begin = task * chunk_len;
            const end = @min(l.n_atoms, begin + chunk_len);
            for (s.atoms[begin..end], begin..) |n, i| {
                if (n.symbol >= l.addrs.len) return l.fail(task, i, error.InvalidSymbols, .{ .atom = l.input.atom(i).name });
                l.addrs[n.symbol] = @intCast(l.atomAddr(i) - l.base);
            }
        }

        /// The address or value an `addrs` entry stands for.
        fn numberedAddr(l: *const Link, e: u32) ?u64 {
            if (e < value_tag) return l.base + e;
            if (e == unset) return null;
            return l.numbered.?.values[e - value_tag].value;
        }

        fn populateOutput(l: *Link, part: usize, _: usize) void {
            const buf = l.target.memory;
            const begin = part * populate_len;
            populate(buf[begin..@min(buf.len, begin + populate_len)]);
        }

        /// Writes `bytes` at `offset` of the output.
        fn put(l: *Link, offset: u64, bytes: []const u8) Error!void {
            switch (l.target) {
                .memory => |buf| @memcpy(buf[offset..][0..bytes.len], bytes),
                .file => |fd| try pwriteAll(fd, bytes, offset),
            }
        }

        /// Writes `len` zero bytes at `offset` of the output.
        fn fill(l: *Link, offset: u64, len: u64) Error!void {
            switch (l.target) {
                .memory => |buf| @memset(buf[offset..][0..len], 0),
                .file => |fd| {
                    const zeroes: [4096]u8 = @splat(0);
                    var at: u64 = 0;
                    while (at < len) : (at += zeroes.len) try pwriteAll(fd, zeroes[0..@min(zeroes.len, len - at)], offset + at);
                },
            }
        }

        /// Buffers for a task's parts of the output, each the contiguous
        /// range of `lens[k]` bytes at `offsets[k]`: the output itself, or
        /// with a `.file` target, the thread's scratch, which `writeParts`
        /// writes out.
        fn parts(l: *Link, thread: usize, comptime n: usize, offsets: [n]u64, lens: [n]u64) [n][]u8 {
            var out: [n][]u8 = undefined;
            switch (l.target) {
                .memory => |buf| for (&out, offsets, lens) |*o, off, len| {
                    o.* = buf[off..][0..len];
                },
                .file => {
                    var at: usize = thread * l.scratch_len;
                    for (&out, lens) |*o, len| {
                        o.* = l.scratch[at..][0..len];
                        at += len;
                    }
                },
            }
            return out;
        }

        fn writeParts(l: *Link, task: usize, atom: usize, comptime n: usize, offsets: [n]u64, bufs: [n][]u8) void {
            const fd = switch (l.target) {
                .memory => return,
                .file => |fd| fd,
            };
            for (offsets, bufs) |off, b| pwriteAll(fd, b, off) catch return l.fail(task, atom, error.WriteFailed, .{});
        }

        fn gatherKeys(l: *Link, chunk: usize, _: usize) void {
            const begin = chunk * chunk_len;
            const end = @min(l.n_atoms, begin + chunk_len);
            for (l.keys[begin..end], begin..) |*k, i| {
                // The key path's first read of each atom.
                if (!l.input.check(i)) return l.fail(chunk, i, error.InvalidInput, .{});
                k.* = l.input.atom(i).key;
            }
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
        fn layOutKeyed(l: *Link, chunk: usize, _: usize) void {
            l.layOut(chunk, false);
        }

        fn layOutNumbered(l: *Link, chunk: usize, _: usize) void {
            l.layOut(chunk, true);
        }

        /// The key-based and numbered paths are compiled apart, so that each
        /// is as tight as if it were the only one.
        fn layOut(l: *Link, chunk: usize, comptime numbered: bool) void {
            const begin = chunk * chunk_len;
            const end = @min(l.n_atoms, begin + chunk_len);
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
            defer l.chunks[chunk] = c;
            for (l.places[begin..end], begin..) |*p, i| {
                // The numbered path's first read of each atom; the key
                // path checked them in `gatherKeys`.
                if (numbered and !l.input.check(i)) {
                    l.fail(chunk, i, error.InvalidInput, .{});
                    continue;
                }
                const atom = l.input.atom(i);
                const a = ref(&atom);
                if (!numbered) {
                    if (i + 16 < l.keys.len) l.symbols.prefetch(l.keys[i + 16]);
                    const kept = l.symbols.get(l.keys[i]).?;
                    if (kept != i) {
                        const kept_atom = l.input.atom(kept);
                        if (!identical(ref(&kept_atom), a)) l.fail(chunk, i, error.DuplicateSymbol, .{ .atom = a.name, .target = a.key });
                        p.* = .duplicate;
                        continue;
                    }
                }
                if (a.section.isZeroFill() and (a.bytes.len != 0 or a.relocs.len != 0)) {
                    l.fail(chunk, i, error.InvalidRelocation, .{ .atom = a.name });
                    continue;
                }
                const s = @backingInt(a.section);
                const off = a.alignment.forward(c.sizes[s]);
                p.* = .{
                    .offset = std.math.cast(u39, off) orelse {
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
        }

        const skip = std.math.maxInt(u32);

        fn resolveAddrsAndLayOutDebug(l: *Link, task: usize, thread: usize) void {
            if (task < l.n_resolve_tasks) l.resolveAddrs(task, thread) else l.layOutDebug(task - l.n_resolve_tasks);
        }

        /// Sizes one chunk's debug entries and collects their files. Entries
        /// for atoms that were deduplicated away are skipped.
        fn layOutDebug(l: *Link, chunk: usize) void {
            const begin = chunk * chunk_len;
            const end = @min(l.n_debug, begin + chunk_len);
            const c = &l.debug_chunks[chunk];
            c.info_len = 0;
            c.line_len = 0;
            c.n_fdes = 0;
            // Functions from one file usually share its path's bytes, so a
            // table by address saves hashing the path for most entries.
            var by_addr: FilesByAddr = .{};
            const task = l.chunks.len + chunk;
            for (l.file_of[begin..end], begin..) |*file_of, j| {
                file_of.* = skip;
                // Checked before `debug(j)` reads anything of the atom's.
                const atom = l.input.debugAtom(j);
                if (atom >= l.n_atoms or (j > 0 and l.input.debugAtom(j - 1) >= atom)) {
                    return l.fail(task, @min(atom, l.n_atoms), error.InvalidDebugInfo, .{});
                }
                const place = l.places[atom];
                if (place.isDuplicate()) continue;
                if (place.section != @backingInt(Atom.Section.text)) {
                    return l.fail(task, atom, error.InvalidDebugInfo, .{ .atom = l.input.atom(atom).name });
                }
                const debug = l.input.debug(j);
                const d = ref(&debug);
                file_of.* = by_addr.get(d.file) orelse index: {
                    const gop = c.files.getOrPut(l.gpa, d.file) catch return l.fail(task, atom, error.OutOfMemory, .{});
                    by_addr.put(d.file, @intCast(gop.index));
                    break :index @intCast(gop.index);
                };
                c.info_len += Dwarf.subprogramSize(d);
                c.line_len += Dwarf.sequenceSize(d);
                c.n_fdes += @intFromBool(d.frame != .none);
            }
        }

        /// Open addressing from a path's address and length to its index in a
        /// chunk's `files`. Holds up to 3/4 of its slots; paths past that are
        /// looked up by contents every time.
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

        fn copyAll(l: *Link, task: usize, thread: usize) void {
            if (task >= l.chunks.len) return l.copyDebug(task - l.chunks.len, thread);
            if (l.numbered == null) l.copy(task, thread, false) else l.copyNumbered(task, thread);
        }

        /// Writes one chunk's subprogram entries, line sequences, FDEs, and
        /// search table entries.
        noinline fn copyDebug(l: *Link, chunk: usize, thread: usize) void {
            const begin = chunk * chunk_len;
            const end = @min(l.n_debug, begin + chunk_len);
            const c = &l.debug_chunks[chunk];
            const offsets = [4]u64{
                l.info_off + c.info_off,
                l.line_off + c.line_off,
                l.eh_off + Dwarf.cie.len + @as(u64, c.fde_base) * Dwarf.fde_size,
                l.hdr_off + Dwarf.eh_frame_hdr_size + @as(u64, c.fde_base) * Dwarf.eh_frame_hdr_entry_size,
            };
            const out = l.parts(thread, 4, offsets, .{ c.info_len, c.line_len, @as(u64, c.n_fdes) * Dwarf.fde_size, @as(u64, c.n_fdes) * Dwarf.eh_frame_hdr_entry_size });
            defer l.writeParts(l.chunks.len + chunk, begin, 4, offsets, out);
            // A local copy: writes to `out` could alias `l`.
            const input = l.input;
            var info_off: usize = 0;
            var line_off: usize = 0;
            var fde = c.fde_base;
            const hdr_addr: i64 = @intCast(l.base + l.hdr_off);
            for (l.file_of[begin..end], begin..) |file_of, j| {
                // The entries stream; their fragments, names, and atoms do not.
                if (j + 12 < end) {
                    input.prefetchDebug(j + 12);
                    @prefetch(&l.places[input.debugAtom(j + 12)], .{});
                }
                if (file_of == skip) continue;
                const debug = input.debug(j);
                const d = ref(&debug);
                const atom = input.debugAtom(j);
                const addr = l.atomAddr(atom);
                const size = input.atom(atom).bytes.len;
                const file = c.file_map[file_of];
                info_off += Dwarf.writeSubprogram(out[0][info_off..], d, addr, size, file);
                line_off += Dwarf.writeSequence(out[1][line_off..], d, addr, size, file);
                if (d.frame != .none) {
                    const fde_off: u32 = @intCast(Dwarf.cie.len + @as(u64, fde) * Dwarf.fde_size);
                    const fde_addr: i64 = @intCast(l.base + l.eh_off + fde_off);
                    const fn_addr: i64 = @intCast(addr);
                    const k = fde - c.fde_base;
                    Dwarf.writeFde(out[2][@as(usize, k) * Dwarf.fde_size ..][0..Dwarf.fde_size], d.frame, fde_off, @intCast(fn_addr - (fde_addr + 8)), @intCast(size));
                    const entry = out[3][@as(usize, k) * Dwarf.eh_frame_hdr_entry_size ..][0..8];
                    std.mem.writeInt(i32, entry[0..4], @intCast(fn_addr - hdr_addr), .little);
                    std.mem.writeInt(i32, entry[4..8], @intCast(fde_addr - hdr_addr), .little);
                    fde += 1;
                }
            }
        }

        /// Sets `res` to the addresses or values of the targets of `a`, atom
        /// `i`, from `addrs`.
        fn resolveNumbered(l: *Link, a: *const Atom, i: usize, chunk: usize, res: []u64) bool {
            const s = l.numbered.?;
            const first = s.atoms[i].targets;
            // A run lies wholly in `targets` or wholly in `targets_tail`.
            const runs, const at = if (first < s.targets.len) .{ s.targets, first } else .{ s.targets_tail, first - s.targets.len };
            if (at > runs.len or runs.len - at < a.targets.len) {
                l.fail(chunk, i, error.InvalidSymbols, .{ .atom = a.name });
                return false;
            }
            for (runs[at..][0..a.targets.len], res, a.targets) |n, *r, t| {
                if (n >= l.addrs.len) {
                    l.fail(chunk, i, error.InvalidSymbols, .{ .atom = a.name, .target = t });
                    return false;
                }
                const e = l.addrs[n];
                r.* = if (e < value_tag) l.base + e else l.numberedAddr(e) orelse {
                    l.fail(chunk, i, error.UndefinedSymbol, .{ .atom = a.name, .target = t });
                    return false;
                };
            }
            return true;
        }

        /// Copies one chunk's atoms, applies their relocations, and writes
        /// their symbols.
        /// Out of line, so that the key-based `copy` compiles as if alone.
        noinline fn copyNumbered(l: *Link, chunk: usize, thread: usize) void {
            l.copy(chunk, thread, true);
        }

        fn copy(l: *Link, chunk: usize, thread: usize, comptime numbered: bool) void {
            const c = &l.chunks[chunk];
            const resolved = l.resolved[thread * l.max_targets ..][0..l.max_targets];
            // The chunk's part of each section with file contents, from the
            // padding before it, then its symbols and their names. Sections
            // without file contents get empty parts.
            var offsets: [n_sections + 2]u64 = @splat(0);
            var lens: [n_sections + 2]u64 = @splat(0);
            for (offsets[0..n_sections], lens[0..n_sections], c.lead_gaps, c.bases, c.sizes, l.section_addrs, zero_fill) |*off, *len, gap, chunk_base, size, sa, no_bytes| {
                if (no_bytes) continue;
                off.* = sa - l.base + chunk_base - gap;
                len.* = gap + size;
            }
            const symtab = n_sections;
            const strtab = n_sections + 1;
            offsets[symtab] = l.symtab_off + @as(u64, c.sym) * @sizeOf(elf.Elf64.Sym);
            lens[symtab] = @as(u64, c.n_syms) * @sizeOf(elf.Elf64.Sym);
            offsets[strtab] = l.strtab_off + c.str;
            lens[strtab] = c.str_len;
            const out = l.parts(thread, n_sections + 2, offsets, lens);
            for (out[0..n_sections], c.lead_gaps, fills, zero_fill) |o, gap, byte, no_bytes| {
                if (!no_bytes) @memset(o[0..gap], byte);
            }
            const begin = chunk * chunk_len;
            const end = @min(l.n_atoms, begin + chunk_len);
            var sym_off: usize = 0;
            var str_off: usize = 0;
            for (l.places[begin..end], begin..) |place, i| {
                // An atom's bytes, targets, relocations, and name, and its
                // targets' `symbols` entries, are scattered in memory; start
                // those misses a few atoms ahead.
                if (i + 4 < l.n_atoms) l.input.prefetch(i + 4, !numbered);
                if (i + 2 < l.n_atoms) {
                    if (!numbered) for (l.input.atom(i + 2).targets) |t| l.symbols.prefetch(t);
                }
                if (place.isDuplicate()) continue;
                const atom = l.input.atom(i);
                const a = ref(&atom);
                const addr = l.section_addrs[place.section] + c.bases[place.section] + place.offset;
                if (!zero_fill[place.section]) {
                    const section_out = out[place.section];
                    const start = addr - l.base - offsets[place.section];
                    @memset(section_out[start - place.gap .. start], fills[place.section]);
                    const dst = section_out[start..][0..a.bytes.len];
                    @memcpy(dst, a.bytes);
                    const res = resolved[0..a.targets.len];
                    if (numbered) {
                        if (!l.resolveNumbered(a, i, chunk, res)) return;
                    } else for (a.targets, res) |t, *r| {
                        r.* = l.symbols.get(t) orelse l.values.get(t) orelse {
                            l.fail(chunk, i, error.UndefinedSymbol, .{ .atom = a.name, .target = t });
                            return;
                        };
                    }
                    var diag: Diagnostic = .{};
                    applyRelocs(a, dst, addr, res, &l.tls, &diag) catch |err| return l.fail(chunk, i, err, diag);
                }
                var name: u32 = 0;
                if (a.name.len > 0) {
                    name = c.str + @as(u32, @intCast(str_off));
                    @memcpy(out[strtab][str_off..][0..a.name.len], a.name);
                    out[strtab][str_off + a.name.len] = 0;
                    str_off += a.name.len + 1;
                }
                writeStruct(out[symtab][sym_off..], elf.Elf64.Sym{
                    .name = name,
                    .info = .{ .type = sym_types[place.section], .bind = .GLOBAL },
                    .other = .{ .visibility = .DEFAULT },
                    .shndx = l.shndx[place.section],
                    .value = addr - l.sym_bias[place.section],
                    .size = a.size(),
                });
                sym_off += @sizeOf(elf.Elf64.Sym);
            }
            l.writeParts(chunk, begin, n_sections + 2, offsets, out);
        }
    };
}

/// Runs `task(ctx, i, thread)` for every i < n_tasks on up to `n_threads`
/// threads, the calling thread included.
pub fn parallel(io: std.Io, n_threads: usize, n_tasks: usize, ctx: anytype, comptime task: fn (@TypeOf(ctx), usize, usize) void) std.Io.Cancelable!void {
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

pub fn prefetchSlice(comptime T: type, slice: []const T) void {
    const bytes = std.mem.sliceAsBytes(slice);
    var off: usize = 0;
    while (off < bytes.len) : (off += 64) @prefetch(bytes.ptr + off, .{});
}

/// Open-addressing hash table from symbol key to a u64, with key and value
/// in one entry so that a lookup costs one cache miss. Keys are already
/// uniformly distributed: their top bits pick a partition, so that threads
/// can fill partitions independently, and their low bits the slot within
/// it.
pub const SymbolTable = struct {
    entries: []Entry,
    partition_shift: u8,
    slot_mask: usize,

    pub const Entry = struct { key: SymbolKey, value: u64, used: bool };

    /// Holds nothing; for links that look up no keys.
    pub const empty: SymbolTable = .{ .entries = &.{}, .partition_shift = 128, .slot_mask = 0 };

    /// Mapped directly, so it starts zeroed (all entries unused) and can ask
    /// for huge pages: lookups are random, and with 4 KiB pages most of them
    /// would also miss the TLB. See `populate`.
    pub fn init(max_count: usize, n_partitions: usize) Allocator.Error!SymbolTable {
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

    pub fn deinit(t: *SymbolTable) void {
        std.heap.page_allocator.free(t.entries);
    }

    /// Faults in a partition's pages, writable, before it is used. Otherwise
    /// the first lookups map the shared zero page and the first insert
    /// replaces it, and that replacement flushes the TLB of every CPU
    /// running the other threads. Threads populate their own partitions, so
    /// the kernel zeroes them in parallel.
    pub fn populate(t: *const SymbolTable, partition_index: usize) void {
        Elf.populate(std.mem.sliceAsBytes(t.partitionEntries(partition_index)));
    }

    pub fn partitionEntries(t: *const SymbolTable, partition_index: usize) []Entry {
        return t.entries[partition_index * (t.slot_mask + 1) ..][0 .. t.slot_mask + 1];
    }

    const huge_page: std.mem.Alignment = .fromByteUnits(2 << 20);

    pub fn partition(t: *const SymbolTable, key: SymbolKey) usize {
        return if (t.partition_shift == 128) 0 else @intCast(@backingInt(key) >> @intCast(t.partition_shift));
    }

    fn home(t: *const SymbolTable, key: SymbolKey) usize {
        return t.partition(key) * (t.slot_mask + 1) + (@as(usize, @truncate(@backingInt(key))) & t.slot_mask);
    }

    /// The entry for `key`: used if `key` is present, else the free slot to
    /// fill in.
    pub fn getOrPut(t: *const SymbolTable, key: SymbolKey) *Entry {
        const first = t.partition(key) * (t.slot_mask + 1);
        var slot: usize = @as(usize, @truncate(@backingInt(key))) & t.slot_mask;
        while (true) : (slot = (slot + 1) & t.slot_mask) {
            const e = &t.entries[first + slot];
            if (!e.used or e.key == key) return e;
        }
    }

    pub fn prefetch(t: *const SymbolTable, key: SymbolKey) void {
        @prefetch(&t.entries[t.home(key)], .{});
    }

    pub fn get(t: *const SymbolTable, key: SymbolKey) ?u64 {
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

fn nonAlloc(name: u32, ty: elf.SHT, offset: u64, size: u64) elf.Elf64.Shdr {
    return .{ .name = name, .type = ty, .flags = .{ .shf = .{} }, .addr = 0, .offset = offset, .size = size, .link = 0, .info = 0, .addralign = 1, .entsize = 0 };
}

fn pwriteAll(fd: std.posix.fd_t, bytes: []const u8, offset: u64) Error!void {
    var at: usize = 0;
    while (at < bytes.len) {
        const sys = std.posix.system;
        const rc = sys.pwrite(fd, bytes[at..].ptr, bytes.len - at, @intCast(offset + at));
        switch (sys.errno(rc)) {
            .SUCCESS => at += @intCast(rc),
            .INTR => {},
            else => return error.WriteFailed,
        }
    }
}

pub fn writeStruct(dst: []u8, s: anytype) void {
    @memcpy(dst[0..@sizeOf(@TypeOf(s))], std.mem.asBytes(&s));
}

pub fn identical(a: *const Atom, b: *const Atom) bool {
    if (a.section != b.section or a.alignment != b.alignment or a.size() != b.size() or
        a.targets.len != b.targets.len or a.relocs.len != b.relocs.len) return false;
    if (!std.mem.eql(u8, a.bytes, b.bytes)) return false;
    if (!std.mem.eql(SymbolKey, a.targets, b.targets)) return false;
    return std.mem.eql(u8, std.mem.sliceAsBytes(a.relocs), std.mem.sliceAsBytes(b.relocs));
}

/// Applies `a`'s relocations to its copy `dst` at address `p_base`, with
/// `resolved` holding the address or value of each of `a.targets`.
inline fn applyRelocs(a: *const Atom, dst: []u8, p_base: u64, resolved: []const u64, tls: *const Tls, diag: *Diagnostic) Error!void {
    // One dispatch per relocation: each arm checks its own field width, and
    // another architecture's kind falls through to the error.
    for (a.relocs) |r| {
        if (r.info.target >= resolved.len) return invalidReloc(a, diag);
        const s = resolved[r.info.target];
        switch (r.info.kind) {
            .x86_64_pc32 => {
                const f = try relocField(a, dst, r.offset, 4, diag);
                const v = @as(i64, @bitCast(s -% (p_base + r.offset))) +% r.addend;
                std.mem.writeInt(i32, f, std.math.cast(i32, v) orelse return overflow(a, r, diag), .little);
            },
            .x86_64_abs64 => {
                const f = try relocField(a, dst, r.offset, 8, diag);
                std.mem.writeInt(u64, f, s +% @as(u64, @bitCast(@as(i64, r.addend))), .little);
            },
            .x86_64_tpoff32 => try tpoff32(a, r, dst, s, tls, diag),
            .value32 => {
                const f = try relocField(a, dst, r.offset, 4, diag);
                std.mem.writeInt(u32, f, std.math.cast(u32, @as(i128, s) + r.addend) orelse return overflow(a, r, diag), .little);
            },
            .value64 => {
                const f = try relocField(a, dst, r.offset, 8, diag);
                std.mem.writeInt(u64, f, std.math.cast(u64, @as(i128, s) + r.addend) orelse return overflow(a, r, diag), .little);
            },
            .value16 => {
                const f = try relocField(a, dst, r.offset, 2, diag);
                std.mem.writeInt(u16, f, std.math.cast(u16, @as(i128, s) + r.addend) orelse return overflow(a, r, diag), .little);
            },
            .value8 => {
                const f = try relocField(a, dst, r.offset, 1, diag);
                f[0] = std.math.cast(u8, @as(i128, s) + r.addend) orelse return overflow(a, r, diag);
            },
            else => return invalidReloc(a, diag),
        }
    }
}

/// Out of line: thread-locals are rare, and the relocation loop keeps its
/// registers for the common kinds.
noinline fn tpoff32(a: *const Atom, r: Atom.Reloc, dst: []u8, s: u64, tls: *const Tls, diag: *Diagnostic) Error!void {
    const f = try relocField(a, dst, r.offset, 4, diag);
    if (s < tls.start or s >= tls.end) {
        diag.* = .{ .atom = a.name, .target = a.targets[r.info.target] };
        return error.InvalidRelocation;
    }
    const v = @as(i64, @bitCast(s -% tls.tp)) +% r.addend;
    std.mem.writeInt(i32, f, std.math.cast(i32, v) orelse return overflow(a, r, diag), .little);
}

inline fn relocField(a: *const Atom, dst: []u8, offset: u32, comptime width: comptime_int, diag: *Diagnostic) Error!*[width]u8 {
    if (@as(u64, offset) + width > dst.len) return invalidReloc(a, diag);
    return dst[offset..][0..width];
}

fn invalidReloc(a: *const Atom, diag: *Diagnostic) Error {
    diag.* = .{ .atom = a.name };
    return error.InvalidRelocation;
}

fn overflow(a: *const Atom, r: Atom.Reloc, diag: *Diagnostic) Error {
    diag.* = .{ .atom = a.name, .target = a.targets[r.info.target] };
    return error.RelocationOverflow;
}

/// For tests: an input that returns records by value, as a cache's pack
/// does, and asserts that the linker checks each atom before it reads it.
pub const TestInput = struct {
    slice: AtomSlice,
    checked: []std.atomic.Value(bool),
    /// Atoms whose check fails.
    bad: []const usize = &.{},

    pub fn len(t: TestInput) usize {
        return t.slice.len();
    }

    pub fn check(t: TestInput, i: usize) bool {
        t.checked[i].store(true, .monotonic);
        return std.mem.indexOfScalar(usize, t.bad, i) == null;
    }

    pub fn atom(t: TestInput, i: usize) Atom {
        std.debug.assert(t.checked[i].load(.monotonic));
        return t.slice.atoms[i];
    }

    pub fn debugLen(t: TestInput) usize {
        return t.slice.debugLen();
    }

    pub fn debugAtom(t: TestInput, j: usize) u32 {
        return t.slice.debugAtom(j);
    }

    pub fn debug(t: TestInput, j: usize) Atom.Debug {
        var d = t.slice.debug_entries[j];
        std.debug.assert(t.checked[d.atom].load(.monotonic));
        d.atom = undefined;
        return d;
    }

    pub fn prefetch(t: TestInput, i: usize, comptime keys: bool) void {
        t.slice.prefetch(i, keys);
    }

    pub fn prefetchDebug(t: TestInput, j: usize) void {
        t.slice.prefetchDebug(j);
    }
};

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

    // Numbered symbols give the same bytes for the atoms kept above.
    const kept = atoms[0..5];
    const numbering = [_]SymbolKey{ start, msg, write_msg, status, msg_ptr, exit_code };
    var numbered_atoms: [kept.len]NumberedAtom = undefined;
    var targets: std.ArrayList(u32) = .empty;
    defer targets.deinit(gpa);
    for (kept, &numbered_atoms, 0..) |a, *n, i| {
        n.* = .{ .symbol = @intCast(i), .targets = @intCast(targets.items.len) };
        for (a.targets) |t| try targets.append(gpa, @intCast(std.mem.indexOfScalar(SymbolKey, &numbering, t).?));
    }
    var symbols: Symbols = .{ .atoms = &numbered_atoms, .targets = targets.items, .values = &.{.{ .symbol = 5, .value = 42 }}, .entry = 0, .len = 6 };
    const numbered = try emit(gpa, io, kept, .{ .entry = start, .symbols = symbols });
    defer gpa.free(numbered);
    try std.testing.expectEqualSlices(u8, bytes, numbered);

    // An input returning records by value, with the runs split between
    // `targets` and `targets_tail`, gives the same bytes.
    var checked: [kept.len]std.atomic.Value(bool) = @splat(.init(false));
    const input: TestInput = .{ .slice = .{ .atoms = kept, .debug_entries = &.{} }, .checked = &checked };
    var split = symbols;
    split.targets = targets.items[0..numbered_atoms[2].targets];
    split.targets_tail = targets.items[numbered_atoms[2].targets..];
    const from_input = try emitInput(gpa, io, input, .{ .entry = start, .symbols = split });
    defer gpa.free(from_input);
    try std.testing.expectEqualSlices(u8, bytes, from_input);
    var diag: Diagnostic = .{};
    var bad = input;
    bad.bad = &.{ 3, 1 };
    try std.testing.expectError(error.InvalidInput, emitInput(gpa, io, bad, .{ .entry = start, .symbols = split, .diag = &diag }));
    try std.testing.expectEqual(1, diag.index.?);
    // A run may not straddle the two.
    try std.testing.expect(kept[0].targets.len >= 2);
    split.targets = targets.items[0..1];
    split.targets_tail = targets.items[1..];
    try std.testing.expectError(error.InvalidSymbols, emitInput(gpa, io, input, .{ .entry = start, .symbols = split }));

    symbols.values = &.{};
    try std.testing.expectError(error.UndefinedSymbol, emit(gpa, io, kept, .{ .entry = start, .symbols = symbols, .diag = &diag }));
    try std.testing.expectEqual(exit_code, diag.target.?);
    symbols.len = 5;
    try std.testing.expectError(error.InvalidSymbols, emit(gpa, io, kept, .{ .entry = start, .symbols = symbols }));

    // An old output is overwritten in place, every byte of it, and a new
    // file gets the same bytes, through a mapping or with pwrite.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const garbage = try gpa.alloc(u8, bytes.len + 3 * 4096 + 5);
    defer gpa.free(garbage);
    @memset(garbage, 0xa5);
    for ([_]FileWrites{ .map, .pwrite }) |writes| {
        var file_options = options;
        file_options.file_writes = writes;
        try tmp.dir.writeFile(io, .{ .sub_path = "hello", .data = garbage, .flags = .{ .permissions = .executable_file } });
        const old_inode = (try tmp.dir.statFile(io, "hello", .{})).inode;
        try link(gpa, io, tmp.dir, "hello", &atoms, file_options);
        try std.testing.expectEqual(old_inode, (try tmp.dir.statFile(io, "hello", .{})).inode);
        const written = try tmp.dir.readFileAlloc(io, "hello", gpa, .unlimited);
        defer gpa.free(written);
        try std.testing.expectEqualSlices(u8, bytes, written);
        try tmp.dir.deleteFile(io, "hello");
        try link(gpa, io, tmp.dir, "hello", &atoms, file_options);
        const created = try tmp.dir.readFileAlloc(io, "hello", gpa, .unlimited);
        defer gpa.free(created);
        try std.testing.expectEqualSlices(u8, bytes, created);
    }
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/hello", .{tmp.sub_path});
    defer gpa.free(path);
    const result = try std.process.run(gpa, io, .{ .argv = &.{path} });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqualStrings(msg_text, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 42 }, result.term);

    // The same key with different contents is a conflict, not a duplicate.
    const conflicting = [_]Atom{ atoms[0], .{ .key = start, .name = "other", .section = .text, .bytes = "\xc3" } };
    try std.testing.expectError(error.DuplicateSymbol, emit(gpa, io, &conflicting, .{ .entry = start, .diag = &diag }));
    try std.testing.expectEqualStrings("other", diag.atom);
}

test "thread-locals in .tdata and .tbss read back after static TLS setup" {
    if (builtin.cpu.arch != .x86_64 or builtin.os.tag != .linux) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const Encoder = @import("../codegen/x86_64/Encoder.zig");
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Thread-locals with mixed alignments, so the TLS segment's size is
    // not a multiple of its alignment and the TP offsets depend on the
    // rounding: a: u32 = 0x11223344, c: u8 align(16) = 7, b: u64 = 0,
    // d: u32 align(32) = 0.
    const a: SymbolKey = .fromName("a");
    const b: SymbolKey = .fromName("b");
    const c: SymbolKey = .fromName("c");
    const d: SymbolKey = .fromName("d");
    const area: SymbolKey = .fromName("tls_area");
    const start: SymbolKey = .fromName("_start");
    const base: i32 = @intCast((Options{ .entry = start }).base_address);

    // _start does what std.os.linux.tls.initStatic does: find PT_TLS among
    // the program headers (non-PIE, so at base + e_phoff), copy the
    // initialization image to an aligned area, point fs at the end of the
    // block rounded up to the alignment, which holds a pointer to itself.
    var e: Encoder = .init(arena);
    const found = try e.newLabel();
    const next = try e.newLabel();
    const fail = try e.newLabel();
    try e.mov(.dword, .{ .reg = .rsi }, .{ .imm = base + @sizeOf(elf.Elf64.Ehdr) });
    try e.movzx(.dword, .rcx, .word, .{ .mem = .{ .disp = base + @offsetOf(elf.Elf64.Ehdr, "phnum") } });
    e.bind(next);
    try e.alu(.cmp, .dword, .{ .mem = .at(.rsi, 0) }, .{ .imm = @backingInt(elf.PT.TLS) });
    try e.jcc(.e, .{ .label = found });
    try e.alu(.add, .qword, .{ .reg = .rsi }, .{ .imm = @sizeOf(elf.Elf64.Phdr) });
    try e.alu(.sub, .dword, .{ .reg = .rcx }, .{ .imm = 1 });
    try e.jcc(.ne, .{ .label = next });
    try e.ud2();
    e.bind(found);
    try e.mov(.qword, .{ .reg = .r8 }, .{ .mem = .at(.rsi, @offsetOf(elf.Elf64.Phdr, "memsz")) });
    try e.mov(.qword, .{ .reg = .r9 }, .{ .mem = .at(.rsi, @offsetOf(elf.Elf64.Phdr, "align")) });
    try e.lea(.qword, .r8, .{ .base = .{ .reg = .r8 }, .index = .{ .reg = .r9 }, .disp = -1 });
    try e.unary(.neg, .qword, .{ .reg = .r9 });
    try e.alu(.@"and", .qword, .{ .reg = .r8 }, .{ .reg = .r9 }); // block size
    try e.mov(.qword, .{ .reg = .rcx }, .{ .mem = .at(.rsi, @offsetOf(elf.Elf64.Phdr, "filesz")) });
    try e.mov(.qword, .{ .reg = .rsi }, .{ .mem = .at(.rsi, @offsetOf(elf.Elf64.Phdr, "vaddr")) });
    try e.lea(.qword, .rdi, .sym(area, 0));
    try e.repMovsb(); // .tbss is the zeros already in the area
    try e.lea(.qword, .rdi, .sym(area, 0));
    try e.alu(.add, .qword, .{ .reg = .rdi }, .{ .reg = .r8 });
    try e.mov(.qword, .{ .mem = .at(.rdi, 0) }, .{ .reg = .rdi });
    try e.mov(.qword, .{ .reg = .rsi }, .{ .reg = .rdi });
    try e.mov(.dword, .{ .reg = .rdi }, .{ .imm = 0x1002 }); // ARCH_SET_FS
    try e.mov(.dword, .{ .reg = .rax }, .{ .imm = @backingInt(std.os.linux.SYS.arch_prctl) });
    try e.syscall();
    // Initial values, then writes read back through new lookups.
    try e.leaThreadLocal(.rax, a);
    try e.alu(.cmp, .dword, .{ .mem = .at(.rax, 0) }, .{ .imm = 0x11223344 });
    try e.jcc(.ne, .{ .label = fail });
    try e.mov(.dword, .{ .mem = .at(.rax, 0) }, .{ .imm = 0x55 });
    try e.leaThreadLocal(.rbx, c);
    try e.alu(.cmp, .byte, .{ .mem = .at(.rbx, 0) }, .{ .imm = 7 });
    try e.jcc(.ne, .{ .label = fail });
    try e.alu(.add, .byte, .{ .mem = .at(.rbx, 0) }, .{ .imm = 1 });
    try e.leaThreadLocal(.r12, b);
    try e.alu(.cmp, .qword, .{ .mem = .at(.r12, 0) }, .{ .imm = 0 });
    try e.jcc(.ne, .{ .label = fail });
    try e.mov(.qword, .{ .mem = .at(.r12, 0) }, .{ .imm = -2 });
    try e.leaThreadLocal(.rdx, d);
    try e.alu(.cmp, .dword, .{ .mem = .at(.rdx, 0) }, .{ .imm = 0 });
    try e.jcc(.ne, .{ .label = fail });
    try e.mov(.dword, .{ .mem = .at(.rdx, 0) }, .{ .imm = 9 });
    // Each thread-local's own block address, aligned as declared.
    try e.@"test"(.byte, .{ .reg = .rbx }, .{ .imm = 15 });
    try e.jcc(.ne, .{ .label = fail });
    try e.@"test"(.byte, .{ .reg = .rdx }, .{ .imm = 31 });
    try e.jcc(.ne, .{ .label = fail });
    try e.leaThreadLocal(.rax, a);
    try e.alu(.cmp, .dword, .{ .mem = .at(.rax, 0) }, .{ .imm = 0x55 });
    try e.jcc(.ne, .{ .label = fail });
    try e.leaThreadLocal(.rax, c);
    try e.alu(.cmp, .byte, .{ .mem = .at(.rax, 0) }, .{ .imm = 8 });
    try e.jcc(.ne, .{ .label = fail });
    try e.leaThreadLocal(.rax, b);
    try e.alu(.cmp, .qword, .{ .mem = .at(.rax, 0) }, .{ .imm = -2 });
    try e.jcc(.ne, .{ .label = fail });
    try e.leaThreadLocal(.rax, d);
    try e.alu(.cmp, .dword, .{ .mem = .at(.rax, 0) }, .{ .imm = 9 });
    try e.jcc(.ne, .{ .label = fail });
    // The writes went to the thread's copy, not the initialization image.
    try e.movAbsSym(.rax, a, 0);
    try e.alu(.cmp, .dword, .{ .mem = .at(.rax, 0) }, .{ .imm = 0x11223344 });
    try e.jcc(.ne, .{ .label = fail });
    try e.mov(.dword, .{ .reg = .rdi }, .{ .imm = 42 });
    try e.mov(.dword, .{ .reg = .rax }, .{ .imm = 60 });
    try e.syscall();
    e.bind(fail);
    try e.mov(.dword, .{ .reg = .rdi }, .{ .imm = 1 });
    try e.mov(.dword, .{ .reg = .rax }, .{ .imm = 60 });
    try e.syscall();
    e.finish();

    const atoms = [_]Atom{
        .{ .key = start, .name = "_start", .section = .text, .bytes = e.code.items, .targets = e.refs.targets.keys(), .relocs = e.refs.relocs.items },
        .{ .key = a, .name = "a", .section = .tdata, .alignment = .@"4", .bytes = &.{ 0x44, 0x33, 0x22, 0x11 } },
        .{ .key = b, .name = "b", .section = .tbss, .alignment = .@"8", .zero_fill = 8 },
        .{ .key = c, .name = "c", .section = .tdata, .alignment = .@"16", .bytes = &.{7} },
        .{ .key = d, .name = "d", .section = .tbss, .alignment = .@"32", .zero_fill = 4 },
        .{ .key = .fromName("counter"), .name = "counter", .section = .data, .alignment = .@"8", .bytes = &@as([8]u8, @splat(0xab)) },
        .{ .key = area, .name = "tls_area", .section = .bss, .alignment = .@"64", .zero_fill = 4096 },
    };
    const bytes = try emit(gpa, io, &atoms, .{ .entry = start });
    defer gpa.free(bytes);

    // PT_TLS: .tdata is a (0..4) and c (16..17); .tbss, aligned to 32, is
    // b (32..40) and d (64..68), so filesz 17, memsz 68, align 32, and the
    // thread pointer is 96 bytes past the segment's start. Symbols' values
    // are their offsets in the segment.
    const ehdr = std.mem.bytesAsValue(elf.Elf64.Ehdr, bytes[0..@sizeOf(elf.Elf64.Ehdr)]);
    const phdrs = std.mem.bytesAsSlice(elf.Elf64.Phdr, bytes[ehdr.phoff..][0 .. ehdr.phnum * @sizeOf(elf.Elf64.Phdr)]);
    var tls: ?elf.Elf64.Phdr = null;
    var rw: ?elf.Elf64.Phdr = null;
    for (phdrs) |ph| {
        if (ph.type == .TLS) tls = ph;
        if (ph.type == .LOAD and ph.flags.W) rw = ph;
    }
    try std.testing.expectEqual(17, tls.?.filesz);
    try std.testing.expectEqual(68, tls.?.memsz);
    try std.testing.expectEqual(32, tls.?.@"align");
    try std.testing.expectEqual(rw.?.vaddr, tls.?.vaddr);
    try std.testing.expectEqual(0, tls.?.vaddr % 32);
    try std.testing.expectEqualSlices(u8, &([_]u8{ 0x44, 0x33, 0x22, 0x11 } ++ @as([12]u8, @splat(0)) ++ [_]u8{7}), bytes[tls.?.offset..][0..17]);
    for ([_][]const u8{ "a", "c", "b", "d" }, [_]u64{ 0, 16, 32, 64 }) |name, offset| {
        try std.testing.expectEqual(offset, testSymbolAddr(bytes, name).?);
    }
    // The first lea's displacement: a's offset minus 96.
    const lea_a = std.mem.indexOf(u8, e.code.items, &.{ 0x48, 0x8d, 0x80 }).? + 3;
    const text_off = ehdr.entry - @as(u64, @intCast(base));
    try std.testing.expectEqual(-96, std.mem.readInt(i32, bytes[text_off + lea_a ..][0..4], .little));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try link(gpa, io, tmp.dir, "tls", &atoms, .{ .entry = start });
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/tls", .{tmp.sub_path});
    defer gpa.free(path);
    const result = try std.process.run(gpa, io, .{ .argv = &.{path} });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 42 }, result.term);

    // A TLS relocation to a symbol that is not thread-local.
    var diag: Diagnostic = .{};
    var bad = atoms;
    var be: Encoder = .init(arena);
    try be.leaThreadLocal(.rax, area);
    be.finish();
    bad[0] = .{ .key = start, .name = "_start", .section = .text, .bytes = be.code.items, .targets = be.refs.targets.keys(), .relocs = be.refs.relocs.items };
    try std.testing.expectError(error.InvalidRelocation, emit(gpa, io, &bad, .{ .entry = start, .diag = &diag }));
    try std.testing.expectEqual(area, diag.target.?);
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
    var debug: std.ArrayList(Atom.Debug) = .empty;
    var expected: u32 = 0;
    const files = [_][]const u8{ "a.zig", "dir/b.zig", "/abs/c.zig", "dir/d.zig" };
    for (0..n) |i| {
        var e: Encoder = .init(arena);
        try e.line(0, 0);
        try e.alu(.add, .dword, .{ .reg = .rbx }, .{ .mem = .sym(constants[i % 50].key, 0) });
        try e.line(1, 4);
        if (i + 1 < n) {
            try e.call(.{ .sym = fkey(i + 1) });
            try e.ret();
        } else {
            try e.jmp(.{ .sym = finish });
        }
        e.finish();
        expected +%= @intCast(i % 50 + 1);
        const alignments = [_]std.mem.Alignment{ .@"1", .@"16", .@"64" };
        // Files change every 1000 functions, so chunks share some.
        const name = try std.fmt.allocPrint(arena, "f{d}", .{i});
        try debug.append(arena, .{ .atom = @intCast(atoms.items.len), .file = files[i / 1000 % files.len], .name = name, .base_line = @intCast(i), .lines = e.lines.bytes.items, .frame = .frame_pointer });
        try atoms.append(arena, .{ .key = fkey(i), .name = name, .section = .text, .alignment = alignments[i % 3], .bytes = e.code.items, .targets = e.refs.targets.keys(), .relocs = e.refs.relocs.items });
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

    const one = try emit(gpa, io, atoms.items, .{ .entry = start, .threads = 1, .debug = debug.items, .comp_dir = "/w" });
    defer gpa.free(one);
    const four = try emit(gpa, io, atoms.items, .{ .entry = start, .threads = 4, .debug = debug.items, .comp_dir = "/w" });
    defer gpa.free(four);
    try std.testing.expectEqualSlices(u8, one, four);

    // So does an input returning records by value, which the linker checks
    // before reading. Of several invalid records, the lowest is reported.
    const checked = try arena.alloc(std.atomic.Value(bool), atoms.items.len);
    @memset(checked, .init(false));
    const input: TestInput = .{ .slice = .{ .atoms = atoms.items, .debug_entries = debug.items }, .checked = checked };
    const from_input = try emitInput(gpa, io, input, .{ .entry = start, .threads = 4, .comp_dir = "/w" });
    defer gpa.free(from_input);
    try std.testing.expectEqualSlices(u8, one, from_input);
    var bad = input;
    bad.bad = &.{ n - 1, 2500, 1500 };
    var diag: Diagnostic = .{};
    try std.testing.expectError(error.InvalidInput, emitInput(gpa, io, bad, .{ .entry = start, .threads = 4, .comp_dir = "/w", .diag = &diag }));
    try std.testing.expectEqual(1500, diag.index.?);

    // Functions in every chunk resolve to their names and rows: the second
    // instruction of f_i is on line i + 2, column 5, of its file.
    var ef = try testElfFile(io, one);
    defer ef.deinit(std.debug.getDebugInfoAllocator());
    const di = &ef.dwarf.?;
    for ([_]usize{ 0, 997, 1994, 2991, 3988, n - 1 }) |index| {
        const name = try std.fmt.allocPrint(arena, "f{d}", .{index});
        const addr = testSymbolAddr(one, name).?;
        const loc = try testSymbolize(di, arena, addr + 7);
        try std.testing.expectEqualStrings(name, loc.name);
        try std.testing.expectEqual(index + 2, loc.line);
        try std.testing.expectEqual(5, loc.column);
        const file = files[index / 1000 % files.len];
        if (file[0] == '/') {
            try std.testing.expectEqualStrings(file, loc.file);
        } else {
            try std.testing.expectEqualStrings(try std.fmt.allocPrint(arena, "/w/{s}", .{file}), loc.file);
        }
        try std.testing.expectEqual(index + 1, (try testSymbolize(di, arena, addr)).line);
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_]FileWrites{ .map, .pwrite }) |writes| {
        try link(gpa, io, tmp.dir, "chunks", atoms.items, .{ .entry = start, .threads = 3, .debug = debug.items, .comp_dir = "/w", .file_writes = writes });
        const written = try tmp.dir.readFileAlloc(io, "chunks", gpa, .unlimited);
        defer gpa.free(written);
        try std.testing.expectEqualSlices(u8, one, written);
    }
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/chunks", .{tmp.sub_path});
    defer gpa.free(path);
    const result = try std.process.run(gpa, io, .{ .argv = &.{path} });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqualStrings(msg_text, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = @truncate(expected) }, result.term);
}

test "line programs decode with std.debug.Dwarf" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Rows that need each encoding: special opcodes, const_add_pc,
    // advance_pc, advance_line both ways, and a replaced row.
    const rows = [_]struct { offset: u32, line: u32, column: u32 }{
        .{ .offset = 0, .line = 0, .column = 0 },
        .{ .offset = 4, .line = 1, .column = 4 },
        .{ .offset = 25, .line = 2, .column = 4 }, // const_add_pc
        .{ .offset = 25, .line = 3, .column = 8 }, // replaces the row above
        .{ .offset = 330, .line = 120, .column = 0 }, // advance_pc, advance_line
        .{ .offset = 331, .line = 4, .column = 12 }, // advance_line back
        .{ .offset = 340, .line = 1, .column = 2 }, // special opcode, line - 3
    };
    var lp: Atom.LineProgram = .{};
    for (rows) |r| try lp.addRow(arena, r.offset, r.line, r.column);
    const code: [400]u8 = @splat(0xcc);
    const key: SymbolKey = .fromName("f");
    const atoms = [_]Atom{
        .{ .key = .fromName("no debug"), .name = "h", .section = .text, .bytes = &.{ 0xc3, 0xc3, 0xc3 } },
        .{ .key = key, .name = "root:f", .section = .text, .alignment = .@"16", .bytes = &code },
        .{ .key = .fromName("g"), .name = "root:g", .section = .text, .bytes = &.{0xc3} },
        .{ .key = .fromName("g"), .name = "root:g", .section = .text, .bytes = &.{0xc3} },
    };
    const debug = [_]Atom.Debug{
        .{ .atom = 1, .file = "src/f.zig", .name = "f", .base_line = 1000, .lines = lp.bytes.items, .frame = .frame_pointer },
        .{ .atom = 2, .file = "g.zig", .name = "g", .base_line = 0, .lines = &.{}, .frame = .none },
        // The duplicate's entry goes with it.
        .{ .atom = 3, .file = "g.zig", .name = "g again", .base_line = 0, .lines = &.{}, .frame = .frame_pointer },
    };
    const out = try emit(gpa, io, &atoms, .{ .entry = key, .debug = &debug, .comp_dir = "/work" });
    defer gpa.free(out);

    var ef = try testElfFile(io, out);
    defer ef.deinit(std.debug.getDebugInfoAllocator());
    const di = &ef.dwarf.?;
    const f_addr = testSectionAddr(out, ".text") + 16;
    const expected = [_]struct { offset: u32, line: u64, column: u64 }{
        .{ .offset = 0, .line = 1001, .column = 1 },
        .{ .offset = 3, .line = 1001, .column = 1 },
        .{ .offset = 4, .line = 1002, .column = 5 },
        .{ .offset = 25, .line = 1004, .column = 9 },
        .{ .offset = 329, .line = 1004, .column = 9 },
        .{ .offset = 330, .line = 1121, .column = 1 },
        .{ .offset = 331, .line = 1005, .column = 13 },
        .{ .offset = 399, .line = 1002, .column = 3 },
    };
    for (expected) |e| {
        const loc = try testSymbolize(di, arena, f_addr + e.offset);
        try std.testing.expectEqualStrings("f", loc.name);
        try std.testing.expectEqualStrings("/work/src/f.zig", loc.file);
        try std.testing.expectEqual(e.line, loc.line);
        try std.testing.expectEqual(e.column, loc.column);
    }
    // A function with no rows still names its address range.
    const g = try testSymbolize(di, arena, f_addr + code.len);
    try std.testing.expectEqualStrings("g", g.name);

    try std.testing.expectError(error.InvalidDebugInfo, emit(gpa, io, &atoms, .{ .entry = key, .debug = &.{ debug[1], debug[0] } }));
    const stripped = try emit(gpa, io, &atoms, .{ .entry = key });
    defer gpa.free(stripped);
    try std.testing.expect(std.mem.indexOf(u8, stripped, ".debug_") == null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, ".eh_frame") == null);
}

test "std.debug unwinds frame-pointer frames through .eh_frame_hdr and stops at the outermost frame" {
    if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    const gpa = std.debug.getDebugInfoAllocator();
    const io = std.testing.io;
    const code: [64]u8 = @splat(0xcc);
    const key: SymbolKey = .fromName("f");
    const atoms = [_]Atom{
        .{ .key = .fromName("no debug"), .name = "h", .section = .text, .bytes = &.{ 0xc3, 0xc3, 0xc3 } },
        .{ .key = key, .name = "f", .section = .text, .alignment = .@"16", .bytes = &code },
        .{ .key = .fromName("naked"), .name = "naked", .section = .text, .bytes = &.{ 0xcc, 0xcc } },
        .{ .key = .fromName("f"), .name = "f", .section = .text, .alignment = .@"16", .bytes = &code },
        .{ .key = .fromName("g"), .name = "g", .section = .text, .alignment = .@"16", .bytes = &code },
        .{ .key = .fromName("_start"), .name = "_start", .section = .text, .alignment = .@"16", .bytes = &code },
    };
    const debug = [_]Atom.Debug{
        .{ .atom = 1, .file = "a.zig", .name = "f", .base_line = 0, .lines = &.{}, .frame = .frame_pointer },
        .{ .atom = 2, .file = "a.zig", .name = "naked", .base_line = 0, .lines = &.{}, .frame = .none },
        .{ .atom = 3, .file = "a.zig", .name = "f", .base_line = 0, .lines = &.{}, .frame = .frame_pointer },
        .{ .atom = 4, .file = "a.zig", .name = "g", .base_line = 0, .lines = &.{}, .frame = .frame_pointer },
        .{ .atom = 5, .file = "a.zig", .name = "_start", .base_line = 0, .lines = &.{}, .frame = .outermost },
    };
    const out = try emit(gpa, io, &atoms, .{ .entry = key, .debug = &debug });
    defer gpa.free(out);
    const text = testSectionAddr(out, ".text");
    const f = text + 16;
    const naked = f + code.len;
    const g = text + 96;
    const start = g + code.len;
    // Three FDEs; the duplicate and the naked function leave their room
    // unused.
    try std.testing.expectEqual(Dwarf.cie.len + 3 * Dwarf.fde_size + 4, testSection(out, ".eh_frame").?.size);
    try std.testing.expectEqual(Dwarf.eh_frame_hdr_size + 3 * Dwarf.eh_frame_hdr_entry_size, testSection(out, ".eh_frame_hdr").?.size);

    // Set up the way std.debug.SelfInfo does from PT_GNU_EH_FRAME.
    const base = 0x200000;
    const ehdr = std.mem.bytesToValue(elf.Elf64.Ehdr, out[0..@sizeOf(elf.Elf64.Ehdr)]);
    const phdr = for (0..ehdr.phnum) |i| {
        const ph = std.mem.bytesToValue(elf.Elf64.Phdr, out[ehdr.phoff + i * @sizeOf(elf.Elf64.Phdr) ..][0..@sizeOf(elf.Elf64.Phdr)]);
        if (ph.type == elf.PT.GNU_EH_FRAME) break ph;
    } else return error.TestUnexpectedResult;
    const Unwind = std.debug.Dwarf.Unwind;
    const header: Unwind.EhFrameHeader = try .parse(phdr.vaddr, out[phdr.offset..][0..phdr.filesz], 8, .little);
    try std.testing.expectEqual(testSectionAddr(out, ".eh_frame"), header.eh_frame_vaddr);
    try std.testing.expectEqual(3, header.search_table.?.fde_count);
    // Through the search table, and through the FDEs sorted while parsing
    // all of .eh_frame, which is what std.debug.SelfInfo asks for.
    for ([_]bool{ false, true }) |sort_fdes| {
        var unwind: Unwind = .initEhFrameHdr(header, phdr.vaddr, out[header.eh_frame_vaddr - base ..].ptr);
        defer unwind.deinit(gpa);
        try unwind.prepare(gpa, 8, .little, sort_fdes, false);

        // A fake stack: saved rbp, then the return address.
        var stack: [6]u64 = .{ 0, 0, 0x1111, 0x2222, 0, 0 };
        const at = struct {
            fn addr(s: *[6]u64, i: usize) u64 {
                return @intFromPtr(&s[i]);
            }
        }.addr;
        const cases = [_]struct { pc: u64, rsp: u64, rbp: u64, new_rbp: u64 }{
            // Entry: only the return address is pushed.
            .{ .pc = f, .rsp = at(&stack, 3), .rbp = 0x5555, .new_rbp = 0x5555 },
            // After `push rbp`.
            .{ .pc = f + 1, .rsp = at(&stack, 2), .rbp = 0x5555, .new_rbp = 0x1111 },
            // In the body, with rsp anywhere below the frame.
            .{ .pc = f + 4, .rsp = at(&stack, 0), .rbp = at(&stack, 2), .new_rbp = 0x1111 },
            .{ .pc = f + code.len - 1, .rsp = at(&stack, 0), .rbp = at(&stack, 2), .new_rbp = 0x1111 },
            .{ .pc = g + 20, .rsp = at(&stack, 1), .rbp = at(&stack, 2), .new_rbp = 0x1111 },
        };
        for (cases) |c| {
            var ctx: std.debug.cpu_context.Native = .{ .gprs = .initFill(0) };
            ctx.gprs.set(.rip, c.pc);
            ctx.gprs.set(.rsp, c.rsp);
            ctx.gprs.set(.rbp, c.rbp);
            var unwinder: std.debug.Dwarf.SelfUnwinder = .init(&ctx);
            defer unwinder.deinit();
            const rules = try unwinder.computeRules(gpa, &unwind, 0, null);
            try std.testing.expectEqual(0x2222, try unwinder.next(gpa, &rules));
            try std.testing.expectEqual(at(&stack, 4), unwinder.cpu_state.gprs.get(.rsp));
            try std.testing.expectEqual(c.new_rbp, unwinder.cpu_state.gprs.get(.rbp));
        }
        // The outermost frame ends the stack: no return address.
        for ([_]u64{ start, start + 1, start + code.len - 1 }) |pc| {
            var start_stack: [2]u64 = .{ 0x3333, 0 };
            var ctx: std.debug.cpu_context.Native = .{ .gprs = .initFill(0) };
            ctx.gprs.set(.rip, pc);
            ctx.gprs.set(.rsp, @intFromPtr(&start_stack));
            var unwinder: std.debug.Dwarf.SelfUnwinder = .init(&ctx);
            defer unwinder.deinit();
            const rules = try unwinder.computeRules(gpa, &unwind, 0, null);
            try std.testing.expectEqual(0, try unwinder.next(gpa, &rules));
        }
        // No FDE covers a function without debug info or a naked one.
        for ([_]u64{ text, naked, naked + 1 }) |pc| {
            var ctx: std.debug.cpu_context.Native = .{ .gprs = .initFill(0) };
            ctx.gprs.set(.rip, pc);
            var unwinder: std.debug.Dwarf.SelfUnwinder = .init(&ctx);
            defer unwinder.deinit();
            try std.testing.expectError(error.MissingDebugInfo, unwinder.computeRules(gpa, &unwind, 0, null));
        }
    }
}

/// Loads `elf_bytes` the way std.debug does for stack traces.
fn testElfFile(io: std.Io, elf_bytes: []const u8) !std.debug.ElfFile {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "exe", .data = elf_bytes });
    const file = try tmp.dir.openFile(io, "exe", .{});
    defer file.close(io);
    const gpa = std.debug.getDebugInfoAllocator();
    var ef = try std.debug.ElfFile.load(gpa, io, file, null, &.none);
    errdefer ef.deinit(gpa);
    const di = if (ef.dwarf) |*di| di else return error.MissingDebugInfo;
    try di.open(gpa, .little);
    return ef;
}

fn testSection(elf_bytes: []const u8, name: []const u8) ?elf.Elf64.Shdr {
    const eh = std.mem.bytesToValue(elf.Elf64.Ehdr, elf_bytes[0..@sizeOf(elf.Elf64.Ehdr)]);
    const shdrs = elf_bytes[eh.shoff..][0 .. eh.shnum * @sizeOf(elf.Elf64.Shdr)];
    const strtab = std.mem.bytesToValue(elf.Elf64.Shdr, shdrs[eh.shstrndx * @sizeOf(elf.Elf64.Shdr) ..][0..@sizeOf(elf.Elf64.Shdr)]);
    for (0..eh.shnum) |i| {
        const sh = std.mem.bytesToValue(elf.Elf64.Shdr, shdrs[i * @sizeOf(elf.Elf64.Shdr) ..][0..@sizeOf(elf.Elf64.Shdr)]);
        if (std.mem.eql(u8, std.mem.sliceTo(elf_bytes[strtab.offset + sh.name ..], 0), name)) return sh;
    }
    return null;
}

fn testSectionAddr(elf_bytes: []const u8, name: []const u8) u64 {
    return testSection(elf_bytes, name).?.addr;
}

fn testSymbolAddr(elf_bytes: []const u8, name: []const u8) ?u64 {
    const symtab = testSection(elf_bytes, ".symtab").?;
    const strtab = testSection(elf_bytes, ".strtab").?;
    var off = symtab.offset;
    while (off < symtab.offset + symtab.size) : (off += @sizeOf(elf.Elf64.Sym)) {
        const sym = std.mem.bytesToValue(elf.Elf64.Sym, elf_bytes[off..][0..@sizeOf(elf.Elf64.Sym)]);
        if (std.mem.eql(u8, std.mem.sliceTo(elf_bytes[strtab.offset + sym.name ..], 0), name)) return sym.value;
    }
    return null;
}

fn testSymbolize(di: *std.debug.Dwarf, arena: Allocator, addr: u64) !struct { name: []const u8, file: []const u8, line: u64, column: u64 } {
    var symbols: std.ArrayList(std.debug.Symbol) = .empty;
    try di.getSymbols(arena, arena, .little, addr, false, &symbols);
    const sym = symbols.items[0];
    const loc = sym.source_location orelse return error.MissingDebugInfo;
    return .{ .name = sym.name orelse return error.MissingDebugInfo, .file = loc.file_name, .line = loc.line, .column = loc.column };
}
