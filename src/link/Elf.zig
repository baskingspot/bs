//! x86_64 ELF linker for static, non-PIE executables and, with
//! `Options.dynamic`, shared objects (whose dynamic sections `ElfDynamic`
//! builds; see "Position-independent code and shared libraries" in
//! docs/slop/architecture.md). Takes the whole set of Atoms, lays out sections,
//! resolves relocations, and writes the output in one pass into one
//! buffer. Nothing is patched afterwards.
//!
//! File layout, with each segment starting on a page boundary and mapped at
//! `base_address + file offset`:
//!
//!   R   ELF header, program headers, .rodata, .eh_frame, .eh_frame_hdr
//!       (the last two present if `Options.debug` is not empty)
//!       The first program header is PT_PHDR, as upstream's: a static
//!       executable's std.posix.dl_iterate_phdr finds the load bias from it.
//!   RX  .text
//!   RW  .tdata and .tbss (thread-local, present if used), .data.rel.ro
//!       (in a position-independent image, `Options.pic`, the .rodata
//!       atoms that hold absolute addresses), .data, then .bss (memory
//!       only)
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
//! Call frame information is one .eh_frame CIE and an FDE per entry whose
//! atom has a frame (`Atom.unwind`: frame-pointer, with the registers it
//! saves, or outermost), indexed by a sorted .eh_frame_hdr search table
//! that PT_GNU_EH_FRAME points to, which is where std.debug's unwinder
//! looks first. Both sections are sized for every entry, at the largest
//! FDE, before the debug entries are read, so the room FDEs do not use
//! is zero bytes after each section.
//!
//! C inputs' .eh_frame and .debug_* sections (`Options.input_sections`)
//! follow bs's part of each output section, after bs's FDEs and before
//! the terminator in .eh_frame; debug sections bs does not write follow
//! .debug_str.
//!
//! Thread-local storage: .tdata and .tbss start the RW segment, covered by
//! a PT_TLS program header (filesz the .tdata bytes, memsz through the end
//! of .tbss, align the larger alignment), which is what the static TLS
//! setup (std.os.linux.tls.initStatic) copies each thread's block from.
//! .tbss takes no room in the image or the file: the sections after it
//! overlap its addresses, as with lld, which only offsets in the TLS
//! segment use. Executables use only the
//! local-exec model (`x86_64_tpoff32`); TLS symbols' values are offsets in the TLS
//! segment, as ld writes them for executables. A position-independent
//! image (an object's) also takes local-dynamic relocations
//! (`x86_64_tlsld`, `x86_64_dtpoff32`).

const std = @import("std");
const builtin = @import("builtin");
const elf = std.elf;
const Allocator = std.mem.Allocator;
const Atom = @import("Atom.zig");
const Dwarf = @import("Dwarf.zig");
const ElfDynamic = @import("ElfDynamic.zig");
const a64 = @import("aarch64.zig");
const Encoder = @import("../codegen/x86_64/Encoder.zig");
/// DW_AT_language of the compile units: Zig, as upstream's self-hosted
/// backend (its Linux Debug default) writes it, which gdb reads.
const dwarf_language = std.dwarf.LANG.Zig;
const SymbolKey = Atom.SymbolKey;
const Elf = @This();

comptime {
    // Structs are copied into the output as host bytes.
    std.debug.assert(builtin.cpu.arch.endian() == .little);
}

pub const Options = struct {
    /// Null for no entry point (e_entry 0), as `ElfObject` builds its
    /// image.
    entry: ?SymbolKey,
    /// Integers assigned by the whole compilation, for relocation targets
    /// that are not symbols (see the `value*` relocation kinds).
    values: []const Value = &.{},
    base_address: u64 = 0x200000,
    /// The main thread's stack size, as PT_GNU_STACK's memory size, which
    /// std's start code raises the stack limit to (`--stack`; upstream's
    /// default is 16 MiB).
    stack_size: u64 = 16 * 1024 * 1024,
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
    /// to say whether there is one (`Symbols.entry` is ignored without),
    /// and `values` not at all.
    symbols: ?Symbols = null,
    /// How `link` writes the file; for tests and benchmarks.
    file_writes: FileWrites = .auto,
    /// The machine: x86_64, or aarch64 for static executables (relocation
    /// kinds, TLS variant 1, 64 KiB segment alignment, CFI registers).
    arch: Atom.Unwind.Arch = .x86_64,
    /// The image is position-independent code: .rodata atoms holding
    /// absolute addresses go to .data.rel.ro, which a loader may write, and
    /// local-dynamic TLS relocations are allowed. Executables are not.
    pic: bool = false,
    /// A shared object (ET_DYN, `bs build-lib -dynamic`): its exports,
    /// imports, and soname, from which `ElfDynamic` builds the dynamic
    /// sections. Implies `pic`; `base_address` should be 0, `entry` null,
    /// and `symbols` null.
    dynamic: ?*const ElfDynamic.Options = null,
    /// The image is an object's (`ElfObject`), whose relocations replace
    /// the fields: thread-local relocations to imports, which have no
    /// address here, leave their fields alone.
    object: bool = false,
    /// .symtab entries within atoms, after the atoms' own: the functions
    /// and objects of C inputs, whose sections are atoms. Each takes its
    /// type and section from its atom's place. Not with `symbols`.
    local_symbols: []const LocalSymbol = &.{},
    /// The unwind and debug sections of C inputs, each copied after bs's
    /// own part of its output section, in this order, with its relocations
    /// applied. Each .eh_frame FDE gets a .eh_frame_hdr entry. Not with
    /// `symbols`.
    input_sections: []const InputSection = &.{},
    /// Keys that resolve to another key's address plus an addend, for
    /// data that must not depend on what its target binds to (`Alias`).
    /// With `symbols`, `Symbols.aliases` numbers them, in this order.
    aliases: []const Alias = &.{},
    /// `-fstrip`: no debug info, neither bs's (`debug`, or the input's
    /// entries) nor the input sections', and so none of bs's FDEs, which
    /// come with its debug entries. The input sections' .eh_frame stays.
    strip: bool = false,
};

/// A key that resolves as `target` does, `addend` bytes on: to an atom's
/// address, a value, or, with an addend of 0, an import, as a reference to
/// `target` itself would. An alias of an alias, or of a key nothing
/// defines, is an error.
pub const Alias = struct { key: SymbolKey, target: SymbolKey, addend: i64 };

/// `Options.aliases[i]`'s number and its target's (`Symbols.aliases`).
pub const NumberedAlias = struct { symbol: u32, target: u32 };

pub const LocalSymbol = struct {
    name: []const u8,
    atom: SymbolKey,
    offset: u64,
    size: u64,
    /// A C global, listed STB_GLOBAL (or STB_WEAK) after every local
    /// symbol, as lld lists them. At offset 0 it also replaces its atom's
    /// own (local) symbol.
    bind: enum { local, global, weak } = .local,
};

/// An input object's section that is copied rather than made atoms of
/// (docs/slop/architecture.md, "Unwind and debug info").
pub const InputSection = struct {
    kind: InputKind,
    /// The object, for diagnostics.
    name: []const u8,
    bytes: []const u8,
    /// The atoms `relocs` address.
    targets: []const SymbolKey = &.{},
    /// Sorted by offset. In `.eh_frame`, each FDE's initial location must
    /// be a `pc32` relocation (pcrel sdata4), at offset 8 of the record.
    relocs: []const InputReloc = &.{},
};

/// The output section an `InputSection` goes to: ".eh_frame", or
/// "." ++ the tag's name.
pub const InputKind = enum(u8) {
    eh_frame,
    // The debug sections bs writes, in their output order.
    debug_abbrev,
    debug_info,
    debug_rnglists,
    debug_line,
    debug_str,
    // Those only inputs bring, after them.
    debug_ranges,
    debug_loc,
    debug_loclists,
    debug_str_offsets,
    debug_addr,
    debug_line_str,
    debug_aranges,
    debug_frame,
    debug_names,
    debug_macro,
    debug_macinfo,
    debug_pubnames,
    debug_pubtypes,
    debug_gnu_pubnames,
    debug_gnu_pubtypes,

    /// The first kind bs writes no part of.
    pub const first_extra: InputKind = .debug_ranges;

    pub fn fromName(name: []const u8) ?InputKind {
        if (name.len < 2 or name[0] != '.') return null;
        return std.meta.stringToEnum(InputKind, name[1..]);
    }
};

pub const InputReloc = extern struct {
    offset: u32,
    /// An index into `InputSection.targets`, or for `offset32` and
    /// `offset64`, into `Options.input_sections`.
    target: u32,
    addend: i64,
    kind: Kind,

    pub const Kind = enum(u8) {
        /// S + A, 32 bits checked and 64.
        abs32,
        abs64,
        /// S + A - P (.eh_frame only).
        pc32,
        /// S + A minus the start of the TLS segment, for a thread-local
        /// S (DWARF locations).
        dtpoff32,
        dtpoff64,
        /// A within the input section `target` as its output section
        /// places it: bs's part's size, the input sections of the kind
        /// before it, plus A.
        offset32,
        offset64,
        /// A, for references to what the link dropped.
        const32,
        const64,
        /// S + A - P, 64 bits (.eh_frame only).
        pc64,
    };
};

pub const FileWrites = enum {
    /// pwrite (see `ReusedOutput.target`).
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
    /// The numbers of the section bounds the linker defines, in
    /// `bound_sections` order, or `no_bound` for one nothing references.
    bounds: [bound_sections.len * 2]u32 = @splat(no_bound),
    /// With `Options.dynamic`, the numbers its key-based link finds by key:
    /// its imports', parallel to `ElfDynamic.Options.imports`, which
    /// resolve to their PLT stubs (in an executable, to stand-ins); its exports' atoms', parallel to
    /// `ElfDynamic.Options.exports`; and `_DYNAMIC`'s
    /// (`ElfDynamic.dynamic_key`), or `no_bound` if nothing references it.
    dynamic_imports: []const u32 = &.{},
    dynamic_exports: []const u32 = &.{},
    dynamic: u32 = no_bound,
    /// The numbers of `Options.aliases`, parallel to them.
    aliases: []const NumberedAlias = &.{},
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

/// The sections whose start and end the linker defines as symbols
/// (`Atom.SymbolKey.sectionBound`), which the fuzzer finds the coverage
/// arrays by (`__start___sancov_cntrs` and the others) and the start code
/// the init array (`__init_array_start` and `__init_array_end`).
pub const bound_sections = [_]Atom.Section{ .sancov_cntrs, .sancov_pcs, .preinit_array, .init_array, .fini_array };
pub const no_bound = std.math.maxInt(u32);

/// The keys of the section bounds: each section's start, then its end.
pub fn boundKeys() [bound_sections.len * 2]SymbolKey {
    var keys: [bound_sections.len * 2]SymbolKey = undefined;
    for (bound_sections, 0..) |sec, i| {
        keys[2 * i] = .sectionBound(sec, .start);
        keys[2 * i + 1] = .sectionBound(sec, .stop);
    }
    return keys;
}

pub const Diagnostic = struct {
    /// Atom whose definition or relocation failed.
    atom: []const u8 = "",
    /// The undefined or overflowing target, if any.
    target: ?SymbolKey = null,
    /// The overflowing relocation's kind and addend, if a relocation
    /// overflowed.
    reloc: ?Atom.Reloc.Kind = null,
    addend: i32 = 0,
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
    /// An input's record is malformed (see `AtomSlice.check`), or an
    /// input section's (`InputSection`).
    InvalidInput,
};

/// Where `build` puts the output: a buffer holding all of it (in memory, or
/// a mapping of the file), or a file it writes with pwrite, one contiguous
/// range at a time.
pub const Target = union(enum) {
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

/// Overwrites the old output in place if it is a regular file, executable
/// as the new output is or not, with one link, not running (Linux refuses to open a running executable
/// for writing), and mostly in the page cache, since writing to a page that
/// is not would first read it from disk. Otherwise replaces it with a new
/// file, so that a running old executable keeps its own inode. The size
/// changes with `ftruncate`, never through 0: ext4 starts writeback of a
/// file truncated to 0 and rewritten when it is closed.
pub const ReusedOutput = struct {
    dir: std.Io.Dir,
    sub_path: []const u8,
    writes: FileWrites,
    /// Whether the output is an executable; only an old output of the same
    /// kind is reused.
    executable: bool = true,
    file: ?std.Io.File = null,
    map: []align(std.heap.page_size_min) u8 = &.{},
    /// Reused with pwrite: how many of the old output's bytes the new one
    /// keeps, which the link reads back to write only the pages that
    /// changed (`Link.writeChanged`).
    old_len: u64 = 0,

    pub fn target(o: *ReusedOutput, io: std.Io, len: usize) !Target {
        const in_place = builtin.os.tag == .linux and o.reuse(io, len);
        if (!in_place) {
            o.dir.deleteFile(io, o.sub_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => |e| return e,
            };
            o.file = try o.dir.createFile(io, o.sub_path, .{ .read = true, .permissions = if (o.executable) .executable_file else .default_file });
            try o.file.?.setLength(io, len);
        }
        // Writing through the mapping pays a fault and page_mkwrite per
        // page, and zeroing each new page of a new file first. pwrite pays
        // one more copy, from the thread's buffer, and ext4 takes the inode
        // lock for each write, so threads' writes do not overlap. Both mark
        // every page dirty. Measured (docs/slop/architecture.md), pwrite wins or
        // ties everywhere but in place on 4 threads, where the two machines
        // measured disagree, and the mapping has been 1.5-4x slower in some
        // sessions on both.
        const writes: FileWrites = switch (o.writes) {
            .auto => .pwrite,
            else => |w| w,
        };
        if (writes == .pwrite) return .{ .file = o.file.?.handle };
        o.map = try std.posix.mmap(null, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, o.file.?.handle, 0);
        return .{ .memory = o.map };
    }

    fn reuse(o: *ReusedOutput, io: std.Io, len: usize) bool {
        const file = o.dir.openFile(io, o.sub_path, .{ .mode = .read_write, .follow_symlinks = false }) catch return false;
        const st = file.stat(io) catch return closed(io, file);
        if (st.kind != .file or st.nlink != 1 or (@backingInt(st.permissions) & 0o111 != 0) != o.executable) return closed(io, file);
        file.setLength(io, len) catch return closed(io, file);
        const old_len = std.mem.alignBackward(usize, @min(len, st.size), std.heap.page_size_min);
        if (old_len > 0) {
            const map = std.posix.mmap(null, old_len, .{ .READ = true }, .{ .TYPE = .SHARED }, file.handle, 0) catch return closed(io, file);
            defer std.posix.munmap(map);
            if (!mostlyCached(map)) return closed(io, file);
        }
        o.file = file;
        if (o.writes != .map) o.old_len = @min(len, st.size);
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

    pub fn close(o: *ReusedOutput, io: std.Io) void {
        if (o.map.len > 0) std.posix.munmap(o.map);
        if (o.file) |f| f.close(io);
    }
};

/// Links `atoms` into the bytes of an executable, owned by the caller.
pub fn emit(gpa: Allocator, io: std.Io, atoms: []const Atom, options: Options) Error![]u8 {
    return emitInput(gpa, io, AtomSlice{ .atoms = atoms, .debug_entries = options.debug }, options);
}

/// `emit` with the atoms and their debug info read from `input` (see
/// `linkInput`). The buffer is advised for huge pages, which can split its
/// mapping in several: free it, but do not resize it.
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

    fn target(o: *MemoryOutput, io: std.Io, len: usize) Error!Target {
        return .{ .memory = try o.buffer(io, len) };
    }
};

const page_size = 0x1000;
/// An executable's imports' stand-in addresses (see `Link.plt_start`).
const exe_import_base: u64 = 0xffff_0000_0000_0000;

/// Section header index of each output section. The allocated sections'
/// headers come in layout order: .rodata, .text, .tdata and .tbss if
/// present, .data.rel.ro if present, .preinit_array, .init_array and
/// .fini_array if any is not empty, .data, .bss, then __sancov_pcs1 and
/// __sancov_cntrs if present (`-ffuzz`; their addresses are after .rodata
/// and after .bss). Then .eh_frame and .eh_frame_hdr and the debug
/// sections, if present, then .symtab, .strtab, and .shstrtab.
fn shndxOf(has_tls: bool, has_relro: bool, has_arrays: bool) [n_sections]u16 {
    const t: u16 = @intFromBool(has_tls);
    const r: u16 = @intFromBool(has_relro);
    const a: u16 = 3 * @as(u16, @intFromBool(has_arrays));
    const d = 3 + 2 * t + r;
    // `.objc` atoms are Mach-O's only; it has no header.
    return .{ 2, 1, d + a, d + a + 1, 3, 4, d + a + 3, d + a + 2, d, d + 1, d + 2, 0, 3 + 2 * t };
}
/// Output sections: one per `Atom.Section`, with the same index, then
/// .data.rel.ro, where a position-independent image puts the .rodata atoms
/// that hold absolute addresses (`Options.pic`).
const n_sections = std.enums.values(Atom.Section).len + 1;
const data_rel_ro = n_sections - 1;
/// Padding within each section: int3 in code, zeros elsewhere.
const fills = [n_sections]u8{ 0xcc, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
/// Sections with no bytes in the file.
const zero_fill = [n_sections]bool{ false, false, false, true, false, true, true, false, false, false, false, false, false };
const sym_types = [n_sections]elf.STT{ .FUNC, .OBJECT, .OBJECT, .OBJECT, .TLS, .TLS, .OBJECT, .OBJECT, .OBJECT, .OBJECT, .OBJECT, .OBJECT, .OBJECT };

/// The TLS segment's addresses [start, end), and the thread pointer, the
/// end rounded up to the segment's alignment, as if the segment were the
/// thread's TLS block (x86_64 TLS variant 2).
const Tls = struct {
    start: u64,
    end: u64,
    tp: u64,
    /// The module's TLS GOT pair, which `x86_64_tlsld` points at, in a
    /// position-independent image; null in an executable, which rejects
    /// local-dynamic relocations. An object's image has no GOT: its value
    /// is a placeholder, since the object's relocations replace it.
    ld_got: ?u64 = null,
    /// `Options.object`.
    object: bool = false,
    /// An executable's imports' stand-ins (`Link.plt_start`): a
    /// `x86_64_tpoff64` slot for one is the loader's to write.
    imports_start: u64 = 0,
    imports_end: u64 = 0,
};
/// Where pass 1 placed an atom.
const Place = packed struct(u64) {
    /// Offset within the chunk's part of the section.
    offset: u38,
    /// Alignment padding between the previous atom of the section and this
    /// one, which the copy pass fills.
    gap: u22,
    section: u4,

    const duplicate: Place = @bitCast(@as(u64, std.math.maxInt(u64)));

    pub fn isDuplicate(p: Place) bool {
        return @as(u64, @bitCast(p)) == std.math.maxInt(u64);
    }
};
/// Atoms per unit of work in placement and copying.
const chunk_len = 2048;
const n_input_kinds = std.enums.values(InputKind).len;
/// An .eh_frame_hdr search table entry: a function's address and its
/// FDE's, relative to .eh_frame_hdr.
const HdrEntry = extern struct { pc: i32, fde: i32 };

/// The number of FDEs in .eh_frame input section `s`, or null if its
/// records are malformed or an FDE's initial location is not a `pc32`
/// relocation at offset 8.
fn inputFdes(s: *const InputSection) ?u32 {
    var off: usize = 0;
    var r: usize = 0;
    var n: u32 = 0;
    while (off < s.bytes.len) {
        if (s.bytes.len - off < 8) return null;
        const len = std.mem.readInt(u32, s.bytes[off..][0..4], .little);
        if (len < 4 or len > s.bytes.len - off - 4) return null;
        if (std.mem.readInt(u32, s.bytes[off + 4 ..][0..4], .little) != 0) {
            while (r < s.relocs.len and s.relocs[r].offset < off + 8) r += 1;
            if (r == s.relocs.len or s.relocs[r].offset != off + 8 or s.relocs[r].kind != .pc32 or s.relocs[r].target >= s.targets.len) return null;
            n += 1;
        }
        off += 4 + len;
    }
    return n;
}
/// Address-table entries, with numbered symbols: an atom's address minus
/// the base address, `value_tag` plus the index of a value in
/// `Symbols.values`, or `unset` for a number with neither. 32 bits keep
/// the table small, as relocations index it at random.
const unset = std.math.maxInt(u32);
const value_tag = 1 << 31;
/// With numbered symbols, a dynamically linked executable's `i`-th import
/// is `import_tag + i` in `addrs`, standing for its key-based stand-in
/// address (`exe_import_base`); values stay below it.
const import_tag = unset - (1 << 20);
/// Section names. Outputs without debug info keep the prefix up to the
/// names they use.
const shstrtab = "\x00.rodata\x00.text\x00.data\x00.bss\x00.symtab\x00.strtab\x00.shstrtab\x00.eh_frame\x00.eh_frame_hdr\x00.debug_abbrev\x00.debug_info\x00.debug_rnglists\x00.debug_line\x00.debug_str\x00.tdata\x00.tbss\x00__sancov_pcs1\x00__sancov_cntrs\x00.data.rel.ro\x00.dynsym\x00.dynstr\x00.hash\x00.gnu.hash\x00.rela.dyn\x00.plt\x00.dynamic\x00.got\x00.interp\x00.gnu.version\x00.gnu.version_r\x00.gnu.version_d\x00.preinit_array\x00.init_array\x00.fini_array\x00";
const shstrtab_no_arrays = shstrtab[0..shName(".preinit_array")];
const shstrtab_no_exe = shstrtab[0..shName(".interp")];
const shstrtab_no_dyn = shstrtab[0..shName(".dynsym")];
const shstrtab_no_relro = shstrtab[0..shName(".data.rel.ro")];
const shstrtab_no_sancov = shstrtab[0..shName("__sancov_pcs1")];
const shstrtab_no_tls = shstrtab[0..shName(".tdata")];
const shstrtab_no_cfi = shstrtab[0..shName(".eh_frame")];
const shstrtab_no_debug = shstrtab[0..shName(".debug_abbrev")];

fn shName(comptime name: []const u8) u32 {
    return comptime @intCast(std.mem.find(u8, shstrtab, "\x00" ++ name ++ "\x00").? + 1);
}

/// Links the atoms of `input` into `out.target(io, len)`.
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
    const cntrs = @backingInt(Atom.Section.sancov_cntrs);
    const pcs = @backingInt(Atom.Section.sancov_pcs);
    const preinit = @backingInt(Atom.Section.preinit_array);
    const init = @backingInt(Atom.Section.init_array);
    const fini = @backingInt(Atom.Section.fini_array);

    const n_chunks = std.math.divCeil(usize, n_atoms, chunk_len) catch unreachable;
    const n_threads = @max(1, @min(n_chunks, options.threads orelse std.Thread.getCpuCount() catch 1));
    // Every partition scans all atoms, so use no more than there are threads.
    const n_partitions = std.math.ceilPowerOfTwoAssert(usize, @min(n_threads, 8));

    const numbered = options.symbols;
    if (numbered) |s| if (s.atoms.len != n_atoms or (options.entry != null and s.entry >= s.len) or options.local_symbols.len != 0 or options.input_sections.len != 0) return error.InvalidSymbols;
    if (numbered) |s| if (options.dynamic) |d| if (s.dynamic_imports.len != d.imports.len or s.dynamic_exports.len != d.exports.len) return error.InvalidSymbols;
    if (numbered) |s| if (s.aliases.len != options.aliases.len) return error.InvalidSymbols;
    var symbols: SymbolTable = if (numbered == null) try .init(n_atoms, n_partitions) else .empty;
    defer symbols.deinit();
    const exe_dyn = if (options.dynamic) |d| d.executable() else false;
    // Numbered imports' entries are `import_tag + i` (`numberedAddr`).
    if (numbered != null and exe_dyn and options.dynamic.?.imports.len > unset - import_tag) return error.InvalidSymbols;
    const key_lt = struct {
        fn lt(_: void, a: SymbolKey, b: SymbolKey) bool {
            return @backingInt(a) < @backingInt(b);
        }
    }.lt;
    // An executable's imports' keys, then the aliases of imports, which
    // take their relocations.
    var exe_imports_buf: []SymbolKey = &.{};
    defer gpa.free(exe_imports_buf);
    const exe_imports: ?[]SymbolKey = if (exe_dyn) keys: {
        const imports = options.dynamic.?.imports;
        exe_imports_buf = try gpa.alloc(SymbolKey, imports.len + options.aliases.len);
        for (exe_imports_buf[0..imports.len], imports) |*k, imp| k.* = imp.key;
        std.mem.sortUnstable(SymbolKey, exe_imports_buf[0..imports.len], {}, key_lt);
        var n = imports.len;
        for (options.aliases) |al| if (LinkOf(@TypeOf(input)).isImport(exe_imports_buf[0..imports.len], al.target)) {
            if (al.addend != 0) {
                diag.* = .{ .atom = "alias", .target = al.key };
                return error.InvalidRelocation;
            }
            exe_imports_buf[n] = al.key;
            n += 1;
        };
        std.mem.sortUnstable(SymbolKey, exe_imports_buf[0..n], {}, key_lt);
        break :keys exe_imports_buf[0..n];
    } else null;
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
    const n_debug = if (options.strip) 0 else input.debugLen();
    const n_debug_chunks = std.math.divCeil(usize, n_debug, chunk_len) catch unreachable;
    const debug_chunks = try gpa.alloc(Dwarf.Chunk, n_debug_chunks);
    defer gpa.free(debug_chunks);
    @memset(debug_chunks, .empty);
    defer for (debug_chunks) |*c| c.deinit(gpa);
    const file_of = try gpa.alloc(u32, n_debug);
    defer gpa.free(file_of);
    // The input sections' places within their kinds' parts, and the FDEs
    // among them.
    const kept_inputs = try gpa.alloc(InputSection, if (options.strip) options.input_sections.len else 0);
    defer gpa.free(kept_inputs);
    const inputs = if (options.strip) kept: {
        var n: usize = 0;
        for (options.input_sections) |sec| if (sec.kind == .eh_frame) {
            kept_inputs[n] = sec;
            n += 1;
        };
        break :kept kept_inputs[0..n];
    } else options.input_sections;
    var input_sizes: [n_input_kinds]u64 = @splat(0);
    const input_offs = try gpa.alloc(u64, inputs.len);
    defer gpa.free(input_offs);
    var n_input_fdes: u32 = 0;
    for (inputs, input_offs) |*s, *off| {
        off.* = input_sizes[@backingInt(s.kind)];
        input_sizes[@backingInt(s.kind)] += s.bytes.len;
        if (s.kind == .eh_frame) n_input_fdes += inputFdes(s) orelse {
            diag.* = .{ .atom = s.name };
            return error.InvalidInput;
        };
    }
    // Atom chunks, then debug chunks, then input sections.
    const failures = try gpa.alloc(?Failure, @max(n_chunks + n_debug_chunks + inputs.len, n_partitions));
    defer gpa.free(failures);
    var unlisted: std.AutoHashMapUnmanaged(SymbolKey, void) = .empty;
    defer unlisted.deinit(gpa);
    for (options.local_symbols) |ls| if (ls.bind != .local and ls.offset == 0) try unlisted.put(gpa, ls.atom, {});
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
        .arch = options.arch,
        .pic = options.pic or (options.dynamic != null and !exe_dyn),
        .dynamic = options.dynamic != null,
        .exe_imports = exe_imports,
        .addrs = addrs,
        .places = places,
        .keys = keys,
        .chunks = chunks,
        .symbols = &symbols,
        .unlisted = &unlisted,
        .failures = failures,
        .input_sections = inputs,
        .input_offs = input_offs,
    };

    @memset(failures, null);
    if (numbered == null) {
        try parallel(&l, Link.gatherKeys, io, n_threads, n_chunks);
        try l.check(diag);
        try parallel(&l, Link.dedup, io, n_threads, n_partitions);
    }
    if (numbered == null) {
        try parallel(&l, Link.layOutKeyed, io, n_threads, n_chunks);
    } else {
        try parallel(&l, Link.layOutNumbered, io, n_threads, n_chunks);
    }
    try l.check(diag);

    // Place chunks within sections, and their symbols and names.
    var sizes: [n_sections]u64 = @splat(0);
    var aligns: [n_sections]std.mem.Alignment = @splat(.@"1");
    var n_syms: u32 = 1;
    var strtab_len: u64 = 1;
    var max_targets: usize = 0;
    var n_long_fdes: u64 = 0;
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
        n_long_fdes += c.n_long_fdes;
    }
    // The local symbols' atoms, while `symbols` maps keys to atoms.
    const local_atoms = try gpa.alloc(u32, options.local_symbols.len);
    defer gpa.free(local_atoms);
    const local_sym = n_syms;
    const local_str = strtab_len;
    // The global ones go last, after every local symbol (.symtab's sh_info).
    var n_globals: u32 = 0;
    for (options.local_symbols, local_atoms) |ls, *atom| {
        atom.* = @intCast(symbols.get(ls.atom) orelse {
            diag.* = .{ .atom = ls.name, .target = ls.atom };
            return error.UndefinedSymbol;
        });
        if (ls.offset > input.atom(atom.*).size()) {
            diag.* = .{ .atom = ls.name, .target = ls.atom };
            return error.InvalidSymbols;
        }
        n_syms = std.math.add(u32, n_syms, 1) catch return error.OutOfMemory;
        n_globals += @intFromBool(ls.bind != .local);
        strtab_len += ls.name.len + 1;
    }
    // A shared object's dynamic tables, and the atoms of its exports.
    var dyn_arena: std.heap.ArenaAllocator = .init(gpa);
    defer dyn_arena.deinit();
    const dyn_opts = options.dynamic;
    const dyn: ?ElfDynamic.Tables = if (dyn_opts) |d| try ElfDynamic.tables(dyn_arena.allocator(), d.*) else null;
    const has_dyn = dyn != null;
    // An executable's .gnu.version and .gnu.version_r, as before, and a
    // shared object's that imports versioned symbols (glibc's).
    const has_versions = exe_dyn or (if (dyn) |*t| t.versym.len > 0 else false);
    // A version script's version definitions.
    const has_verdef = if (dyn) |*t| t.verdef_count > 0 else false;
    const n_imports: u64 = if (dyn_opts) |d| d.imports.len else 0;
    var n_copies: u64 = 0;
    if (dyn_opts) |d| for (d.exports) |x| {
        n_copies += @intFromBool(x.copy != null and !x.copy.?.alias);
    };
    var dyn_exports: []u64 = &.{};
    var n_rela: u64 = 0;
    if (dyn) |*t| {
        dyn_exports = try dyn_arena.allocator().alloc(u64, t.exports.len);
        if (numbered) |s| {
            // The atoms with the exports' numbers, found in one pass. One
            // atom can have several exports (aliases).
            var atom_of: std.AutoHashMapUnmanaged(u32, u64) = .empty;
            try atom_of.ensureTotalCapacity(dyn_arena.allocator(), @intCast(t.exports.len));
            for (t.exports) |i| {
                const gop = atom_of.getOrPutAssumeCapacity(s.dynamic_exports[i]);
                gop.value_ptr.* = std.math.maxInt(u64);
            }
            for (s.atoms, 0..) |n, i| if (atom_of.getPtr(n.symbol)) |a| {
                a.* = i;
            };
            for (dyn_exports, t.exports) |*atom, i| {
                atom.* = atom_of.get(s.dynamic_exports[i]).?;
                if (atom.* == std.math.maxInt(u64)) {
                    const x = dyn_opts.?.exports[i];
                    diag.* = .{ .atom = x.name, .target = x.key };
                    return error.UndefinedSymbol;
                }
            }
        } else for (dyn_exports, t.exports) |*atom, i| {
            const x = dyn_opts.?.exports[i];
            atom.* = symbols.get(x.key) orelse {
                diag.* = .{ .atom = x.name, .target = x.key };
                return error.UndefinedSymbol;
            };
        }
        for (chunks) |*c| {
            c.rela = std.math.cast(u32, n_rela) orelse return error.OutOfMemory;
            n_rela += c.n_rela;
        }
    }
    var values: SymbolTable = .empty;
    defer values.deinit();
    if (numbered) |s| {
        // Atoms, numbered in `resolveAddrs`, take precedence over values.
        @memset(addrs, unset);
        if (s.values.len >= import_tag - value_tag) return error.InvalidSymbols;
        for (s.values, 0..) |v, i| {
            if (v.symbol >= addrs.len) return error.InvalidSymbols;
            addrs[v.symbol] = @intCast(value_tag + i);
        }
    } else {
        // The entry may also be an alias, resolved with the others
        // (an input's `_start` inside its section's atom).
        if (options.entry) |e| if (symbols.get(e) == null and for (options.aliases) |a| {
            if (a.key == e) break false;
        } else true) {
            diag.* = .{ .target = e };
            return error.UndefinedSymbol;
        };
        values = try .init(options.values.len + 2 * bound_sections.len + n_imports + 1 + options.aliases.len, 1);
        for (options.values) |v| values.getOrPut(v.key).* = .{ .key = v.key, .value = v.value, .used = true };
    }

    // Section placement, as file offsets (for .bss, address - base).
    // An executable's imports have no PLT stubs or GOT slots: its extern
    // slots are its GOT.
    // An executable's imports' stand-ins are 8 bytes apart on either arch.
    const plt_entry: u64 = if (exe_dyn) 8 else ElfDynamic.pltEntrySize(options.arch);
    const plt_size = if (exe_dyn) 0 else n_imports * plt_entry;
    const has_rx = sizes[text] > 0 or plt_size > 0;
    const has_tls = sizes[tdata] > 0 or sizes[tbss] > 0;
    // A shared object's GOT pair for x86_64's local-dynamic TLS (aarch64
    // code reaches thread-locals through descriptors, which are atoms).
    const tls_pair = has_tls and options.arch == .x86_64;
    const has_sancov = sizes[cntrs] > 0 or sizes[pcs] > 0;
    const has_relro = sizes[data_rel_ro] > 0;
    const n_arrays = @as(u64, @intFromBool(sizes[preinit] > 0)) + @intFromBool(sizes[init] > 0) + @intFromBool(sizes[fini] > 0);
    const has_arrays = n_arrays > 0;
    const has_rw = sizes[data] > 0 or sizes[bss] > 0 or has_tls or sizes[cntrs] > 0 or has_relro or has_arrays or has_dyn;
    const input_eh = input_sizes[@backingInt(InputKind.eh_frame)];
    const has_cfi = n_debug > 0 or input_eh > 0;
    // Which program headers are written, of all the linker writes, in
    // order: PHDR; the R, RX, and RW LOADs; DYNAMIC; TLS; GNU_RELRO;
    // GNU_EH_FRAME; GNU_STACK; INTERP comes second.
    const ph_present = [_]bool{ true, exe_dyn, true, has_rx, has_rw, has_dyn, has_tls, has_dyn, has_cfi, true };
    var phnum: u16 = 0;
    for (ph_present) |p| phnum += @intFromBool(p);
    const headers_end: u64 = @sizeOf(elf.Elf64.Ehdr) + phnum * @sizeOf(elf.Elf64.Phdr);
    // A shared object's read-only dynamic tables follow the headers; the
    // .rela.dyn records are the atoms' absolute relocations, in atom
    // order, then the TLS GOT pair's module, then the imports' GOT slots.
    var dynsym_off: u64 = 0;
    var dynstr_off: u64 = 0;
    var hash_off: u64 = 0;
    var gnu_hash_off: u64 = 0;
    var rela_off: u64 = 0;
    var versym_off: u64 = 0;
    var verneed_off: u64 = 0;
    var verdef_off: u64 = 0;
    const interp_off = headers_end;
    const interp_size: u64 = if (exe_dyn) dyn_opts.?.interp.?.len + 1 else 0;
    var r_tables_end = headers_end;
    if (dyn) |*t| {
        n_rela += if (exe_dyn) n_copies else @intFromBool(tls_pair) + n_imports;
        dynsym_off = std.mem.alignForward(u64, interp_off + interp_size, 8);
        dynstr_off = dynsym_off + t.dynsymSize();
        hash_off = std.mem.alignForward(u64, dynstr_off + t.dynstr.len, 8);
        gnu_hash_off = std.mem.alignForward(u64, hash_off + t.hash.len, 8);
        versym_off = std.mem.alignForward(u64, gnu_hash_off + t.gnu_hash.len, 2);
        verneed_off = std.mem.alignForward(u64, versym_off + t.versym.len, 8);
        verdef_off = std.mem.alignForward(u64, verneed_off + t.verneed.len, 8);
        rela_off = std.mem.alignForward(u64, verdef_off + t.verdef.len, 8);
        r_tables_end = rela_off + n_rela * @sizeOf(elf.Elf64.Rela);
    }
    var starts: [n_sections]u64 = undefined;
    starts[rodata] = aligns[rodata].forward(r_tables_end);
    const rodata_end = starts[rodata] + sizes[rodata];
    // `.objc` atoms are Mach-O's only: an empty section anywhere.
    starts[@backingInt(Atom.Section.objc)] = rodata_end;
    // The coverage PC table, if any, follows .rodata in the R segment.
    starts[pcs] = aligns[pcs].forward(rodata_end);
    const pcs_end = starts[pcs] + sizes[pcs];
    // Room for an FDE per debug entry, and the terminator. Each entry's
    // atom is a distinct one (`Dwarf.layOutDebug` checks that they
    // ascend), so at most `n_long_fdes` FDEs exceed the short bound.
    const eh_off = std.mem.alignForward(u64, pcs_end, 8);
    // The input sections' FDEs follow bs's.
    const eh_room = if (has_cfi) Dwarf.cie.len + n_debug * Dwarf.max_short_fde_size + @min(n_debug, n_long_fdes) * (Dwarf.maxFdeSize(options.arch) - Dwarf.max_short_fde_size) + input_eh + 4 else 0;
    const hdr_off = eh_off + eh_room;
    const hdr_room = if (has_cfi) Dwarf.eh_frame_hdr_size + (n_debug + n_input_fdes) * Dwarf.eh_frame_hdr_entry_size else 0;
    const r_end = if (has_cfi) hdr_off + hdr_room else pcs_end;
    // aarch64 Linux kernels may use pages of up to 64 KiB, which segments
    // must start on, as upstream's (lld's) aarch64 output does.
    const seg_align: u64 = if (options.arch == .aarch64) 0x10000 else page_size;
    const rx_start = if (has_rx) std.mem.alignForward(u64, r_end, seg_align) else r_end;
    const plt_off = if (has_dyn) std.mem.alignForward(u64, rx_start, 16) else rx_start;
    starts[text] = aligns[text].forward(plt_off + plt_size);
    const text_end = starts[text] + sizes[text];
    const rw_start = if (has_rw) std.mem.alignForward(u64, text_end, seg_align) else text_end;
    // The TLS segment: its start and every thread's copy are aligned to
    // its alignment, so offsets within it keep theirs.
    const tls_align = aligns[tdata].max(aligns[tbss]);
    const tls_start = tls_align.forward(rw_start);
    starts[tdata] = tls_start;
    const tdata_end = tls_start + sizes[tdata];
    starts[tbss] = aligns[tbss].forward(tdata_end);
    const tls_end = starts[tbss] + sizes[tbss];
    // .tbss takes no room in the image: what follows overlaps it, as with
    // lld, since each thread's block copies only .tdata (PT_TLS filesz).
    starts[data_rel_ro] = aligns[data_rel_ro].forward(tdata_end);
    // The init and fini arrays are read-only once loaded, like .data.rel.ro.
    starts[preinit] = aligns[preinit].forward(starts[data_rel_ro] + sizes[data_rel_ro]);
    starts[init] = aligns[init].forward(starts[preinit] + sizes[preinit]);
    starts[fini] = aligns[fini].forward(starts[init] + sizes[init]);
    const relro_end = starts[fini] + sizes[fini];
    // A shared object's .dynamic and .got end PT_GNU_RELRO, which ends
    // on a page boundary so that the loader protects all of it.
    var dynamic_off: u64 = 0;
    var got_off: u64 = 0;
    var got_size: u64 = 0;
    var data_floor = relro_end;
    if (dyn) |*t| {
        dynamic_off = std.mem.alignForward(u64, relro_end, 8);
        got_off = dynamic_off + ElfDynamic.dynamicCount(t, dyn_opts.?.*, n_arrays) * @sizeOf(elf.Elf64_Dyn);
        got_size = if (exe_dyn) 0 else 16 * @as(u64, @intFromBool(tls_pair)) + 8 * n_imports;
        data_floor = std.mem.alignForward(u64, got_off + got_size, page_size);
    }
    starts[data] = aligns[data].forward(data_floor);
    const file_end = starts[data] + sizes[data];
    starts[bss] = aligns[bss].forward(file_end);
    // The coverage counters, if any, are memory only after .bss.
    starts[cntrs] = aligns[cntrs].forward(starts[bss] + sizes[bss]);
    const mem_end = starts[cntrs] + sizes[cntrs];
    // Call frame information holds 32-bit offsets between any two parts of
    // the image.
    if (has_cfi and mem_end > std.math.maxInt(i32)) return error.OutOfMemory;

    const base = options.base_address;
    // Numbered symbols keep addresses as 31-bit offsets from the base.
    if (numbered != null and mem_end >= value_tag) return error.OutOfMemory;
    for (&l.section_addrs, starts) |*sa, st| sa.* = base + st;
    l.base = base;
    l.shndx = shndxOf(has_tls, has_relro, has_arrays);
    l.sym_bias = .{ 0, 0, 0, 0, base + tls_start, base + tls_start, 0, 0, 0, 0, 0, 0, 0 };
    // The section bounds the linker defines.
    for (bound_sections, 0..) |sec, i| {
        const start = starts[@backingInt(sec)];
        const ends = [2]u64{ start, start + sizes[@backingInt(sec)] };
        if (numbered) |s| {
            for (ends, s.bounds[2 * i ..][0..2]) |at, n| {
                if (n == no_bound) continue;
                if (n >= addrs.len) return error.InvalidSymbols;
                addrs[n] = @intCast(at);
            }
        } else for (ends, [2]SymbolKey{ .sectionBound(sec, .start), .sectionBound(sec, .stop) }) |at, key| {
            values.getOrPut(key).* = .{ .key = key, .value = base + at, .used = true };
        }
    }
    // Variant 2 (x86_64): the thread pointer is the end of the thread's
    // TLS block, whose size is the segment's rounded up to its alignment.
    // Variant 1 (aarch64): the block follows a 16-byte TCB at the thread
    // pointer, at the TCB's end rounded up to the block's alignment.
    l.tls = .{
        .start = base + tls_start,
        .end = base + tls_end,
        .tp = if (options.arch == .aarch64) base + tls_start -% tls_align.forward(16) else base + tls_start + tls_align.forward(tls_end - tls_start),
        .ld_got = if (has_dyn and !exe_dyn) base + got_off else if (options.pic) base + tls_start else null,
        .object = options.object,
    };
    if (dyn_opts) |d| {
        // An executable's imports take addresses no atom has, which only
        // tell them apart (an absolute relocation to one becomes a symbol
        // relocation; a PC-relative one overflows).
        l.plt_start = if (exe_dyn) exe_import_base else base + plt_off;
        l.plt_entry = plt_entry;
        l.plt_end = l.plt_start + n_imports * plt_entry;
        if (exe_dyn) {
            l.tls.imports_start = l.plt_start;
            l.tls.imports_end = l.plt_end;
        }
        l.rela_off = rela_off;
        // Imports resolve to their PLT stubs; absolute relocations to
        // them become symbol relocations.
        if (numbered) |s| {
            for (s.dynamic_imports, 0..) |n, i| {
                if (n >= addrs.len) return error.InvalidSymbols;
                // An executable's stand-ins lie outside the image, so not
                // at offsets from its base.
                addrs[n] = if (exe_dyn) @intCast(import_tag + i) else @intCast(plt_off + i * plt_entry);
            }
            if (s.dynamic != no_bound) {
                if (s.dynamic >= addrs.len) return error.InvalidSymbols;
                addrs[s.dynamic] = @intCast(dynamic_off);
            }
        } else {
            for (d.imports, 0..) |imp, i| values.getOrPut(imp.key).* = .{ .key = imp.key, .value = l.plt_start + i * plt_entry, .used = true };
            values.getOrPut(ElfDynamic.dynamic_key).* = .{ .key = ElfDynamic.dynamic_key, .value = base + dynamic_off, .used = true };
        }
    }
    try parallel(&l, Link.resolveAddrsAndLayOutDebug, io, n_threads, l.n_resolve_tasks + n_debug_chunks);
    try l.check(diag);
    try l.resolveAliases(options.aliases, &values, diag);
    const entry_addr = if (options.entry == null) 0 else if (numbered) |s| l.numberedAddr(addrs[s.entry]) else symbols.get(options.entry.?) orelse values.get(options.entry.?).?;
    if (entry_addr == null) {
        diag.* = .{ .target = options.entry };
        return error.UndefinedSymbol;
    }

    // Place the debug chunks, and build the file and unit tables from their
    // files and units in first-use order.
    var dwarf: Dwarf = try .place(gpa, debug_chunks, options.comp_dir, base + starts[text], dwarf_language);
    defer dwarf.deinit(gpa);
    const has_bs_debug = dwarf.present();
    // Each debug section: bs's part, then the input sections', in kind
    // order; .eh_frame's input sections follow bs's FDEs.
    var bs_parts: [n_input_kinds]u64 = @splat(0);
    if (has_bs_debug) {
        bs_parts[@backingInt(InputKind.debug_abbrev)] = Dwarf.abbrev.len;
        bs_parts[@backingInt(InputKind.debug_info)] = dwarf.info_size;
        bs_parts[@backingInt(InputKind.debug_rnglists)] = dwarf.ranges_size;
        bs_parts[@backingInt(InputKind.debug_line)] = dwarf.line_size;
        bs_parts[@backingInt(InputKind.debug_str)] = Dwarf.str.len;
    }
    var sec_offs: [n_input_kinds]u64 = undefined;
    sec_offs[@backingInt(InputKind.eh_frame)] = eh_off + Dwarf.cie.len + dwarf.frame_bytes;
    var debug_end = file_end;
    var has_input_debug = false;
    for (sec_offs[1..], bs_parts[1..], input_sizes[1..]) |*off, bs, in_size| {
        off.* = debug_end;
        debug_end += bs + in_size;
        has_input_debug = has_input_debug or in_size > 0;
    }
    const has_debug = has_bs_debug or has_input_debug;
    const sec_size = struct {
        fn f(bs: []const u64, in_sizes: []const u64, k: InputKind) u64 {
            return bs[@backingInt(k)] + in_sizes[@backingInt(k)];
        }
    }.f;
    const abbrev_off = sec_offs[@backingInt(InputKind.debug_abbrev)];
    const info_off = sec_offs[@backingInt(InputKind.debug_info)];
    const ranges_off = sec_offs[@backingInt(InputKind.debug_rnglists)];
    const line_off = sec_offs[@backingInt(InputKind.debug_line)];
    const str_off = sec_offs[@backingInt(InputKind.debug_str)];
    l.sec_offs = sec_offs;
    l.bs_parts = bs_parts;
    const symtab_off = std.mem.alignForward(u64, debug_end, 8);
    const strtab_off = symtab_off + @as(u64, n_syms) * @sizeOf(elf.Elf64.Sym);
    const shstrtab_off = strtab_off + strtab_len;
    const shstr_fixed = if (has_arrays) shstrtab else if (exe_dyn or has_versions) shstrtab_no_arrays else if (has_dyn) shstrtab_no_exe else if (has_relro) shstrtab_no_dyn else if (has_sancov) shstrtab_no_relro else if (has_tls) shstrtab_no_sancov else if (has_debug) shstrtab_no_tls else if (has_cfi) shstrtab_no_debug else shstrtab_no_cfi;
    // The names of the debug sections only inputs bring follow.
    const extra_kinds = std.enums.values(InputKind)[@backingInt(InputKind.first_extra)..];
    var extra_names: [extra_kinds.len]u32 = @splat(0);
    var shstr_len: u64 = shstr_fixed.len;
    var n_extra: u16 = 0;
    for (extra_kinds, &extra_names) |k, *name| if (input_sizes[@backingInt(k)] > 0) {
        name.* = @intCast(shstr_len);
        shstr_len += @tagName(k).len + 2;
        n_extra += 1;
    };
    const shstr = try gpa.alloc(u8, shstr_len);
    defer gpa.free(shstr);
    @memcpy(shstr[0..shstr_fixed.len], shstr_fixed);
    for (extra_kinds, extra_names) |k, name| if (name != 0) {
        shstr[name] = '.';
        @memcpy(shstr[name + 1 ..][0..@tagName(k).len], @tagName(k));
        shstr[name + 1 + @tagName(k).len] = 0;
    };
    const shoff = std.mem.alignForward(u64, shstrtab_off + shstr.len, 8);
    const shnum: u16 = 8 + 2 * @as(u16, @intFromBool(has_tls)) + @as(u16, @intFromBool(has_relro)) + 3 * @as(u16, @intFromBool(has_arrays)) + 2 * @as(u16, @intFromBool(has_sancov)) + 2 * @as(u16, @intFromBool(has_cfi)) + 5 * @as(u16, @intFromBool(has_debug)) + n_extra + 8 * @as(u16, @intFromBool(has_dyn)) + @as(u16, @intFromBool(exe_dyn)) + 2 * @as(u16, @intFromBool(has_versions)) + @as(u16, @intFromBool(has_verdef));
    l.target = try out.target(io, shoff + shnum * @sizeOf(elf.Elf64.Shdr));
    if (@hasField(@TypeOf(out.*), "old_len")) l.old_len = out.old_len;
    switch (l.target) {
        .memory => |buf| {
            adviseHugePages(buf);
            try parallel(&l, Link.populateOutput, io, n_threads, std.math.divCeil(usize, buf.len, populate_len) catch unreachable);
        },
        .file => {
            // Room for the largest task's parts of the output.
            for (chunks) |*c| {
                var len: u64 = @as(u64, c.n_syms) * @sizeOf(elf.Elf64.Sym) + c.str_len + @as(u64, c.n_rela) * @sizeOf(elf.Elf64.Rela);
                for (c.lead_gaps, c.sizes, zero_fill) |gap, size, no_bytes| {
                    if (!no_bytes) len += gap + size;
                }
                l.scratch_len = @max(l.scratch_len, len);
            }
            for (debug_chunks) |*c| {
                const fde_len = c.frame_bytes + @as(u64, c.n_frames) * Dwarf.eh_frame_hdr_entry_size;
                const lens = c.lens();
                l.scratch_len = @max(l.scratch_len, lens.info + lens.ranges + lens.line + fde_len);
            }
            for (inputs) |s| l.scratch_len = @max(l.scratch_len, s.bytes.len);
            // In huge pages where the kernel has them: a few faults instead
            // of one per page, and as few to tear down at the end.
            const scratch_len = std.mem.alignForward(usize, n_threads * l.scratch_len, SymbolTable.huge_page.toByteUnits());
            l.scratch = (std.heap.page_allocator.rawAlloc(scratch_len, SymbolTable.huge_page, @returnAddress()) orelse return error.OutOfMemory)[0..scratch_len];
            adviseHugePages(l.scratch);
        },
    }
    defer if (l.scratch.len != 0) std.heap.page_allocator.rawFree(l.scratch, SymbolTable.huge_page, @returnAddress());

    // Padding between sections; padding within a section is filled by the
    // atom or chunk after it.
    try l.fill(headers_end, starts[rodata] - headers_end);
    try l.fill(rodata_end, starts[pcs] - rodata_end);
    try l.fill(pcs_end, eh_off - pcs_end);
    try l.fill(r_end, starts[text] - r_end);
    try l.fill(text_end, tls_start - text_end);
    try l.fill(tdata_end, starts[data_rel_ro] - tdata_end);
    for ([_]usize{ data_rel_ro, preinit, init }, [_]usize{ preinit, init, fini }) |a, b| try l.fill(starts[a] + sizes[a], starts[b] - (starts[a] + sizes[a]));
    try l.fill(relro_end, starts[data] - relro_end);
    try l.fill(debug_end, symtab_off - debug_end);
    try l.fill(symtab_off, @sizeOf(elf.Elf64.Sym));
    try l.fill(strtab_off, 1);
    try l.put(shstrtab_off, shstr);
    try l.fill(shstrtab_off + shstr.len, shoff - (shstrtab_off + shstr.len));
    const eh_size = Dwarf.cie.len + dwarf.frame_bytes + input_eh + 4;
    const n_frames = dwarf.n_frames + n_input_fdes;
    const hdr_size = Dwarf.eh_frame_hdr_size + @as(u64, n_frames) * Dwarf.eh_frame_hdr_entry_size;
    if (has_cfi) {
        // The FDEs and the search table are written with the debug chunks.
        try l.put(eh_off, Dwarf.cieOf(options.arch));
        try l.fill(eh_off + eh_size - 4, hdr_off - (eh_off + eh_size - 4)); // terminator, unused room
        const eh_frame_rel: i32 = @intCast(@as(i64, @intCast(eh_off)) - @as(i64, @intCast(hdr_off + 4)));
        try l.put(hdr_off, &Dwarf.ehFrameHdr(eh_frame_rel, n_frames));
        try l.fill(hdr_off + hdr_size, r_end - (hdr_off + hdr_size));
    }
    if (dyn) |*t| {
        // The tables the copy tasks do not write, over the padding filled
        // above: the chunks write their atoms' .rela.dyn records.
        const d = dyn_opts.?;
        const a = dyn_arena.allocator();
        const defined = try a.alloc(ElfDynamic.Defined, dyn_exports.len);
        for (defined, dyn_exports, t.exports) |*def, atom, i| {
            const p = places[atom];
            const x = d.exports[i];
            def.* = .{
                .value = l.atomAddr(atom) + x.offset - l.sym_bias[p.section],
                .size = x.size orelse input.atom(atom).size(),
                .shndx = l.shndx[p.section],
                .type = sym_types[p.section],
            };
        }
        if (!exe_dyn) for (dyn_exports, t.exports, 1 + t.n_imports..) |atom, i, k| {
            const x = d.exports[i];
            if (x.visibility != .default) continue;
            _ = try l.export_syms.getOrPutValue(a, l.atomAddr(atom) + x.offset, @intCast(k));
        };
        const dynsym = try a.alloc(u8, t.dynsymSize());
        ElfDynamic.writeSymbols(dynsym, t, d.*, defined);
        try l.put(dynsym_off, dynsym);
        try l.put(dynstr_off, t.dynstr);
        try l.put(hash_off, t.hash);
        try l.put(gnu_hash_off, t.gnu_hash);
        if (exe_dyn) {
            try l.put(interp_off, d.interp.?);
            try l.fill(interp_off + interp_size - 1, 1);
        }
        if (has_versions) {
            try l.put(versym_off, t.versym);
            try l.put(verneed_off, t.verneed);
            try l.put(verdef_off, t.verdef);
        }
        const tail = try a.alloc(elf.Elf64.Rela, if (exe_dyn) n_copies else @intFromBool(tls_pair) + n_imports);
        var k: usize = 0;
        // An executable's copies of library data, which the loader fills.
        if (n_copies != 0) for (t.exports, dyn_exports, 0..) |i, atom, pos| {
            const cp = d.exports[i].copy orelse continue;
            if (cp.alias) continue;
            tail[k] = .{ .offset = l.atomAddr(atom), .info = .{ .type = if (l.arch == .aarch64) @backingInt(elf.R_AARCH64.COPY) else @backingInt(elf.R_X86_64.COPY), .sym = @intCast(1 + n_imports + pos) }, .addend = 0 };
            k += 1;
        };
        if (tls_pair and !exe_dyn) {
            tail[0] = .{ .offset = base + got_off, .info = .{ .type = @backingInt(elf.R_X86_64.DTPMOD64), .sym = 0 }, .addend = 0 };
            k = 1;
        }
        const slots = got_off + 16 * @as(u64, @intFromBool(tls_pair));
        const plt = try a.alloc(u8, plt_size);
        for (0..if (exe_dyn) 0 else n_imports) |i| {
            const slot = base + slots + 8 * i;
            tail[k + i] = .{ .offset = slot, .info = .{ .type = if (l.arch == .aarch64) @backingInt(elf.R_AARCH64.GLOB_DAT) else @backingInt(elf.R_X86_64.GLOB_DAT), .sym = @intCast(1 + i) }, .addend = 0 };
            const stub = l.plt_start + i * plt_entry;
            ElfDynamic.pltEntry(l.arch, plt[i * plt_entry ..][0..plt_entry], stub, slot);
        }
        try l.put(rela_off + (n_rela - tail.len) * @sizeOf(elf.Elf64.Rela), std.mem.sliceAsBytes(tail));
        try l.put(plt_off, plt);
        const dynamic = try a.alloc(u8, ElfDynamic.dynamicCount(t, d.*, n_arrays) * @sizeOf(elf.Elf64_Dyn));
        ElfDynamic.writeDynamic(dynamic, t, d.*, .{
            .dynsym = base + dynsym_off,
            .dynstr = base + dynstr_off,
            .hash = base + hash_off,
            .gnu_hash = base + gnu_hash_off,
            .rela = base + rela_off,
            .rela_size = n_rela * @sizeOf(elf.Elf64.Rela),
            .versym = base + versym_off,
            .verneed = base + verneed_off,
            .verdef = base + verdef_off,
            .arrays = .{
                .{ .addr = base + starts[preinit], .size = sizes[preinit] },
                .{ .addr = base + starts[init], .size = sizes[init] },
                .{ .addr = base + starts[fini], .size = sizes[fini] },
            },
        });
        try l.put(dynamic_off, dynamic);
        // The GOT is zeros until the loader fills it.
    }
    if (local_atoms.len != 0) {
        const syms = try gpa.alloc(elf.Elf64.Sym, local_atoms.len);
        defer gpa.free(syms);
        const strs = try gpa.alloc(u8, strtab_len - local_str);
        defer gpa.free(strs);
        var at: usize = 0;
        var k: usize = 0;
        for ([_]bool{ false, true }) |globals| for (options.local_symbols, local_atoms) |ls, atom| {
            if ((ls.bind != .local) != globals) continue;
            const p = places[atom];
            const sym = &syms[k];
            k += 1;
            sym.* = .{
                .name = @intCast(local_str + at),
                .info = .{ .type = sym_types[p.section], .bind = switch (ls.bind) {
                    .local => .LOCAL,
                    .global => .GLOBAL,
                    .weak => .WEAK,
                } },
                .other = .{ .visibility = .DEFAULT },
                .shndx = l.shndx[p.section],
                .value = l.atomAddr(atom) + ls.offset - l.sym_bias[p.section],
                .size = ls.size,
            };
            @memcpy(strs[at..][0..ls.name.len], ls.name);
            strs[at + ls.name.len] = 0;
            at += ls.name.len + 1;
        };
        try l.put(symtab_off + @as(u64, local_sym) * @sizeOf(elf.Elf64.Sym), std.mem.sliceAsBytes(syms));
        try l.put(strtab_off + local_str, strs);
    }
    if (has_bs_debug) {
        try l.put(abbrev_off, &Dwarf.abbrev);
        l.info_off = info_off;
        l.ranges_off = ranges_off;
        l.line_off = line_off;
        try dwarf.heads(&l, Link.putDebug);
        try l.put(str_off, Dwarf.str);
    }
    // With input FDEs, the search table is gathered and sorted after the
    // copy, since their functions can lie anywhere among bs's.
    const hdr_table = try gpa.alloc(HdrEntry, if (n_input_fdes > 0) n_frames else 0);
    defer gpa.free(hdr_table);
    l.hdr_table = hdr_table;

    const resolved = try gpa.alloc(u64, n_threads * max_targets);
    defer gpa.free(resolved);
    l.values = &values;
    l.symtab_off = symtab_off;
    l.strtab_off = strtab_off;
    l.resolved = resolved;
    l.max_targets = max_targets;
    l.eh_off = eh_off;
    l.hdr_off = hdr_off;
    try parallel(&l, Link.copyAll, io, n_threads, n_chunks + n_debug_chunks + inputs.len);
    try l.check(diag);
    if (n_input_fdes > 0) {
        const hdr_addr = base + hdr_off;
        var k: usize = dwarf.n_frames;
        for (inputs, 0..) |*s, i| {
            if (s.kind != .eh_frame) continue;
            const eh_addr = base + l.inputOff(i);
            var off: usize = 0;
            var r: usize = 0;
            while (off < s.bytes.len) {
                const len = std.mem.readInt(u32, s.bytes[off..][0..4], .little);
                if (std.mem.readInt(u32, s.bytes[off + 4 ..][0..4], .little) != 0) {
                    while (s.relocs[r].offset < off + 8) r += 1;
                    const rel = s.relocs[r];
                    const pc = (l.resolveKey(s.targets[rel.target]) orelse unreachable) +% @as(u64, @bitCast(rel.addend));
                    hdr_table[k] = .{
                        .pc = std.math.cast(i32, @as(i64, @bitCast(pc -% hdr_addr))) orelse return error.RelocationOverflow,
                        .fde = @intCast(@as(i64, @bitCast(eh_addr + off -% hdr_addr))),
                    };
                    k += 1;
                }
                off += 4 + len;
            }
        }
        std.mem.sortUnstable(HdrEntry, hdr_table, {}, struct {
            fn lt(_: void, a: HdrEntry, b: HdrEntry) bool {
                return a.pc < b.pc;
            }
        }.lt);
        try l.put(hdr_off + Dwarf.eh_frame_hdr_size, std.mem.sliceAsBytes(hdr_table));
    }

    // Headers.
    var head: [@sizeOf(elf.Elf64.Ehdr) + ph_present.len * @sizeOf(elf.Elf64.Phdr)]u8 = undefined;
    writeStruct(&head, elf.Elf64.Ehdr{
        .ident = .{ .class = .@"64", .data = .@"2LSB", .version = 1, .osabi = .NONE, .abiversion = 0 },
        .type = if (has_dyn and !exe_dyn) .DYN else .EXEC,
        .machine = if (options.arch == .aarch64) .AARCH64 else .X86_64,
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
    // In `ph_present`'s order: type, flags, offset, address, file and
    // memory sizes, alignment.
    const ph_size = phnum * @sizeOf(elf.Elf64.Phdr);
    const phdrs = [ph_present.len]struct { elf.PT, elf.PF, u64, u64, u64, u64, u64 }{
        .{ .PHDR, .{ .R = true }, @sizeOf(elf.Elf64.Ehdr), base + @sizeOf(elf.Elf64.Ehdr), ph_size, ph_size, 8 },
        .{ .INTERP, .{ .R = true }, interp_off, base + interp_off, interp_size, interp_size, 1 },
        .{ .LOAD, .{ .R = true }, 0, base, r_end, r_end, seg_align },
        .{ .LOAD, .{ .R = true, .X = true }, rx_start, base + rx_start, text_end - rx_start, text_end - rx_start, seg_align },
        .{ .LOAD, .{ .R = true, .W = true }, rw_start, base + rw_start, file_end - rw_start, mem_end - rw_start, seg_align },
        // (Absent ones may wrap.)
        .{ .DYNAMIC, .{ .R = true, .W = true }, dynamic_off, base + dynamic_off, got_off -% dynamic_off, got_off -% dynamic_off, 8 },
        .{ .TLS, .{ .R = true }, tls_start, base + tls_start, sizes[tdata], tls_end - tls_start, tls_align.toByteUnits() },
        .{ .GNU_RELRO, .{ .R = true }, rw_start, base + rw_start, got_off + got_size -% rw_start, got_off + got_size -% rw_start, 1 },
        .{ .GNU_EH_FRAME, .{ .R = true }, hdr_off, base + hdr_off, hdr_size, hdr_size, 4 },
        .{ .GNU_STACK, .{ .R = true, .W = true }, 0, 0, 0, std.mem.alignForward(u64, options.stack_size, page_size), 1 },
    };
    for (ph_present, phdrs) |present, p| if (present) {
        writeStruct(head[ph_off..], elf.Elf64.Phdr{
            .type = p[0],
            .flags = p[1],
            .offset = p[2],
            .vaddr = p[3],
            .paddr = p[3],
            .filesz = p[4],
            .memsz = p[5],
            .@"align" = p[6],
        });
        ph_off += @sizeOf(elf.Elf64.Phdr);
    };
    std.debug.assert(ph_off == headers_end);
    try l.put(0, head[0..headers_end]);

    const cfi_shdrs = [_]elf.Elf64.Shdr{
        // SHT_X86_64_UNWIND is x86_64's; other machines read the number
        // as their own processor type (binutils then cannot tell the
        // file's machine), so aarch64's is PROGBITS, as LLD writes it.
        shdr(shName(".eh_frame"), if (options.arch == .aarch64) .PROGBITS else .X86_64_UNWIND, .{ .ALLOC = true }, base, eh_off, eh_size, .@"8"),
        shdr(shName(".eh_frame_hdr"), .PROGBITS, .{ .ALLOC = true }, base, hdr_off, hdr_size, .@"4"),
    };
    const debug_shdrs = [_]elf.Elf64.Shdr{
        nonAlloc(shName(".debug_abbrev"), .PROGBITS, abbrev_off, sec_size(&bs_parts, &input_sizes, .debug_abbrev)),
        nonAlloc(shName(".debug_info"), .PROGBITS, info_off, sec_size(&bs_parts, &input_sizes, .debug_info)),
        nonAlloc(shName(".debug_rnglists"), .PROGBITS, ranges_off, sec_size(&bs_parts, &input_sizes, .debug_rnglists)),
        nonAlloc(shName(".debug_line"), .PROGBITS, line_off, sec_size(&bs_parts, &input_sizes, .debug_line)),
        nonAlloc(shName(".debug_str"), .PROGBITS, str_off, sec_size(&bs_parts, &input_sizes, .debug_str)),
    };
    var extra_shdrs: [extra_kinds.len]elf.Elf64.Shdr = undefined;
    const Present = struct { bool, usize };
    var extra_present: [extra_kinds.len]Present = undefined;
    for (&extra_shdrs, &extra_present, extra_kinds, extra_names) |*h, *p, k, name| {
        h.* = nonAlloc(name, .PROGBITS, sec_offs[@backingInt(k)], input_sizes[@backingInt(k)]);
        p.* = .{ name != 0, 1 };
    }
    const tls_shdrs = [_]elf.Elf64.Shdr{
        shdr(shName(".tdata"), .PROGBITS, .{ .ALLOC = true, .WRITE = true, .TLS = true }, base, starts[tdata], sizes[tdata], aligns[tdata]),
        shdr(shName(".tbss"), .NOBITS, .{ .ALLOC = true, .WRITE = true, .TLS = true }, base, starts[tbss], sizes[tbss], aligns[tbss]),
    };
    const array_shdrs = [_]elf.Elf64.Shdr{
        shdr(shName(".preinit_array"), .PREINIT_ARRAY, .{ .ALLOC = true, .WRITE = true }, base, starts[preinit], sizes[preinit], aligns[preinit]),
        shdr(shName(".init_array"), .INIT_ARRAY, .{ .ALLOC = true, .WRITE = true }, base, starts[init], sizes[init], aligns[init]),
        shdr(shName(".fini_array"), .FINI_ARRAY, .{ .ALLOC = true, .WRITE = true }, base, starts[fini], sizes[fini], aligns[fini]),
    };
    const sancov_shdrs = [_]elf.Elf64.Shdr{
        shdr(shName("__sancov_pcs1"), .PROGBITS, .{ .ALLOC = true }, base, starts[pcs], sizes[pcs], aligns[pcs]),
        shdr(shName("__sancov_cntrs"), .NOBITS, .{ .ALLOC = true, .WRITE = true }, base, starts[cntrs], sizes[cntrs], aligns[cntrs]),
    };
    const strtab_ndx = shnum - 2;
    // A shared object's sections go last among the allocated ones, so the
    // others keep their indices (`shndxOf`).
    const dynsym_ndx: u32 = if (has_dyn) shnum - 3 - 8 - @as(u32, @intFromBool(exe_dyn)) - 2 * @as(u32, @intFromBool(has_versions)) - @as(u32, @intFromBool(has_verdef)) else 0;
    const dyn_shdrs = blk: {
        const t = if (dyn) |*t| t else &ElfDynamic.Tables{ .exports = &.{}, .n_imports = 0, .dynstr = "", .names = &.{}, .soname = null, .hash = "", .gnu_hash = "" };
        var h = [_]elf.Elf64.Shdr{
            shdr(shName(".dynsym"), .DYNSYM, .{ .ALLOC = true }, base, dynsym_off, t.dynsymSize(), .@"8"),
            shdr(shName(".dynstr"), .STRTAB, .{ .ALLOC = true }, base, dynstr_off, t.dynstr.len, .@"1"),
            shdr(shName(".hash"), .HASH, .{ .ALLOC = true }, base, hash_off, t.hash.len, .@"8"),
            shdr(shName(".gnu.hash"), .GNU_HASH, .{ .ALLOC = true }, base, gnu_hash_off, t.gnu_hash.len, .@"8"),
            shdr(shName(".rela.dyn"), .RELA, .{ .ALLOC = true }, base, rela_off, n_rela * @sizeOf(elf.Elf64.Rela), .@"8"),
            shdr(shName(".plt"), .PROGBITS, .{ .ALLOC = true, .EXECINSTR = true }, base, plt_off, plt_size, .@"16"),
            shdr(shName(".dynamic"), .DYNAMIC, .{ .ALLOC = true, .WRITE = true }, base, dynamic_off, got_off -% dynamic_off, .@"8"),
            shdr(shName(".got"), .PROGBITS, .{ .ALLOC = true, .WRITE = true }, base, got_off, got_size, .@"8"),
        };
        h[0].link = dynsym_ndx + 1;
        h[0].info = 1;
        h[0].entsize = @sizeOf(elf.Elf64.Sym);
        h[2].link = dynsym_ndx;
        h[2].entsize = 4;
        h[3].link = dynsym_ndx;
        h[4].link = dynsym_ndx;
        h[4].entsize = @sizeOf(elf.Elf64.Rela);
        h[6].link = dynsym_ndx + 1;
        h[6].entsize = @sizeOf(elf.Elf64_Dyn);
        break :blk h;
    };
    // An executable's, after the shared object's; then the symbol
    // versions of an image that links glibc.
    const interp_shdrs = [_]elf.Elf64.Shdr{shdr(shName(".interp"), .PROGBITS, .{ .ALLOC = true }, base, interp_off, interp_size, .@"1")};
    const version_shdrs = blk: {
        const t = if (dyn) |*t| t else &ElfDynamic.Tables{ .exports = &.{}, .n_imports = 0, .dynstr = "", .names = &.{}, .soname = null, .hash = "", .gnu_hash = "" };
        var h = [_]elf.Elf64.Shdr{
            shdr(shName(".gnu.version"), .GNU_VERSYM, .{ .ALLOC = true }, base, versym_off, t.versym.len, .@"2"),
            shdr(shName(".gnu.version_r"), .GNU_VERNEED, .{ .ALLOC = true }, base, verneed_off, t.verneed.len, .@"8"),
        };
        h[0].link = dynsym_ndx;
        h[0].entsize = 2;
        h[1].link = dynsym_ndx + 1;
        h[1].info = t.verneed_count;
        break :blk h;
    };
    const verdef_shdrs = blk: {
        var h = [_]elf.Elf64.Shdr{shdr(shName(".gnu.version_d"), .GNU_VERDEF, .{ .ALLOC = true }, base, verdef_off, if (dyn) |*t| t.verdef.len else 0, .@"8")};
        h[0].link = dynsym_ndx + 1;
        h[0].info = if (dyn) |*t| t.verdef_count else 0;
        break :blk h;
    };
    const shdrs = [_]elf.Elf64.Shdr{
        std.mem.zeroes(elf.Elf64.Shdr),
        shdr(shName(".rodata"), .PROGBITS, .{ .ALLOC = true }, base, starts[rodata], sizes[rodata], aligns[rodata]),
        shdr(shName(".text"), .PROGBITS, .{ .ALLOC = true, .EXECINSTR = true }, base, starts[text], sizes[text], aligns[text]),
    } ++ tls_shdrs ++ [_]elf.Elf64.Shdr{
        shdr(shName(".data.rel.ro"), .PROGBITS, .{ .ALLOC = true, .WRITE = true }, base, starts[data_rel_ro], sizes[data_rel_ro], aligns[data_rel_ro]),
    } ++ array_shdrs ++ [_]elf.Elf64.Shdr{
        shdr(shName(".data"), .PROGBITS, .{ .ALLOC = true, .WRITE = true }, base, starts[data], sizes[data], aligns[data]),
        shdr(shName(".bss"), .NOBITS, .{ .ALLOC = true, .WRITE = true }, base, starts[bss], sizes[bss], aligns[bss]),
    } ++ sancov_shdrs ++ cfi_shdrs ++ debug_shdrs ++ extra_shdrs ++ dyn_shdrs ++ interp_shdrs ++ version_shdrs ++ verdef_shdrs ++ [_]elf.Elf64.Shdr{
        .{ .name = shName(".symtab"), .type = .SYMTAB, .flags = .{ .shf = .{} }, .addr = 0, .offset = symtab_off, .size = n_syms * @sizeOf(elf.Elf64.Sym), .link = strtab_ndx, .info = n_syms - n_globals, .addralign = 8, .entsize = @sizeOf(elf.Elf64.Sym) },
        nonAlloc(shName(".strtab"), .STRTAB, strtab_off, strtab_len),
        nonAlloc(shName(".shstrtab"), .STRTAB, shstrtab_off, shstr.len),
    };
    var sh_buf: [shdrs.len * @sizeOf(elf.Elf64.Shdr)]u8 = undefined;
    var sh_at: usize = 0;
    const present = [_]Present{ .{ true, 3 }, .{ has_tls, tls_shdrs.len }, .{ has_relro, 1 }, .{ has_arrays, array_shdrs.len }, .{ true, 2 }, .{ has_sancov, sancov_shdrs.len }, .{ has_cfi, cfi_shdrs.len }, .{ has_debug, debug_shdrs.len } } ++ extra_present ++ [_]Present{ .{ has_dyn, dyn_shdrs.len }, .{ exe_dyn, interp_shdrs.len }, .{ has_versions, version_shdrs.len }, .{ has_verdef, verdef_shdrs.len }, .{ true, 3 } };
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
    /// The atoms with code after their epilogue's `ret` or with saved
    /// aarch64 d registers, whose FDEs can exceed
    /// `Dwarf.max_short_fde_size`.
    n_long_fdes: u32,
    /// In a shared object, the atoms' absolute relocations, each of which
    /// is a dynamic relocation.
    n_rela: u32,
    // Filled in serially after `Link.layOut`.
    /// Where the chunk's atoms of each section start, within the section.
    bases: [n_sections]u64,
    /// Padding before `bases`, which the chunk fills.
    lead_gaps: [n_sections]u64,
    /// The chunk's first symbol in .symtab and first byte in .strtab.
    sym: u32,
    str: u32,
    /// The chunk's first record in .rela.dyn.
    rela: u32,
};

const Failure = struct { atom: usize, err: Error, diag: Diagnostic };

/// State shared by the threads of `build`, reading atoms from an `Input`
/// (see `AtomSlice`).
fn LinkOf(comptime Input: type) type {
    return struct {
        const Self = @This();

        gpa: Allocator,
        input: Input,
        n_atoms: usize,
        n_debug: usize,
        debug_chunks: []Dwarf.Chunk,
        /// Index into its chunk's `files` of each debug entry, or `skip`.
        file_of: []u32,
        n_partitions: usize,
        /// `resolveAddrs` tasks: partitions of `symbols`, or with numbered
        /// symbols, chunks.
        n_resolve_tasks: usize,
        numbered: ?Symbols,
        /// `Options.arch`.
        arch: Atom.Unwind.Arch,
        /// `Options.pic`.
        pic: bool,
        /// Whether `Options.dynamic` is set.
        dynamic: bool,
        /// A dynamically linked executable's imports' keys, sorted
        /// (`ElfDynamic.Options.executable`), else null: only absolute
        /// relocations to them get .rela.dyn records, and only .rodata
        /// atoms with such relocations go to .data.rel.ro.
        exe_imports: ?[]const SymbolKey = null,
        /// In a shared object: the PLT stubs' addresses, one per import in
        /// .dynsym order after the null symbol, which imports resolve to;
        /// and .rela.dyn's file offset.
        plt_start: u64 = 0,
        plt_end: u64 = 0,
        /// The distance between two imports' PLT stubs or stand-ins.
        plt_entry: u64 = 8,
        /// In a shared object: the .dynsym index of each export with
        /// default visibility, by address, for relocations against
        /// its own exports (`symType`).
        export_syms: std.AutoHashMapUnmanaged(u64, u32) = .empty,
        rela_off: u64 = 0,
        /// With numbered symbols, where each is (see `unset`).
        addrs: []u32,
        places: []Place,
        /// The atoms' keys, packed, so that every partition can scan them.
        keys: []SymbolKey,
        chunks: []Chunk,
        /// Maps a key to the index of the atom kept for it, and from
        /// `resolveAddrs` on to its address.
        symbols: *SymbolTable,
        /// The atoms a global `Options.local_symbols` entry lists instead
        /// of their own symbol.
        unlisted: *const std.AutoHashMapUnmanaged(SymbolKey, void),
        /// One slot per task. A phase reports the failure of the lowest atom,
        /// whatever the thread timing.
        failures: []?Failure,
        // Set before `copy`.
        values: *const SymbolTable = undefined,
        target: Target = undefined,
        /// With a `.file` target, the bytes of the old output it overwrites
        /// (`ReusedOutput.old_len`).
        old_len: u64 = 0,
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
        /// File offsets of .debug_info, .debug_rnglists, and .debug_line.
        info_off: u64 = undefined,
        ranges_off: u64 = undefined,
        line_off: u64 = undefined,
        /// File offsets of .eh_frame and .eh_frame_hdr.
        eh_off: u64 = undefined,
        hdr_off: u64 = undefined,
        /// `Options.input_sections`, and each one's offset within its
        /// kind's input sections.
        input_sections: []const InputSection,
        input_offs: []const u64,
        /// Per `InputKind`: the file offset of the section (for .eh_frame,
        /// of its input sections), and the size of bs's part of it.
        sec_offs: [n_input_kinds]u64 = undefined,
        bs_parts: [n_input_kinds]u64 = undefined,
        /// With input FDEs, the whole .eh_frame_hdr search table, which
        /// `copyDebug` copies bs's entries to.
        hdr_table: []HdrEntry = &.{},

        fn check(l: *Self, diag: *Diagnostic) Error!void {
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

        pub fn fail(l: *Self, task: usize, atom: usize, err: Error, diag: Diagnostic) void {
            if (l.failures[task] == null) l.failures[task] = .{ .atom = atom, .err = err, .diag = diag };
        }

        fn atomAddr(l: *const Self, index: u64) u64 {
            const p = l.places[index];
            return l.section_addrs[p.section] + l.chunks[index / chunk_len].bases[p.section] + p.offset;
        }

        /// Replaces atom indices with addresses in one partition of `symbols`,
        /// so that resolving a relocation target is one lookup. With numbered
        /// symbols, sets the addresses of one chunk's atoms' numbers instead.
        fn resolveAddrs(l: *Self, task: usize, _: usize) void {
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

        /// Gives each alias its target's address or value plus its addend,
        /// after `resolveAddrs`: in `addrs`, or as a value. All targets are
        /// looked up before any alias is added, so an alias of an alias is
        /// undefined.
        fn resolveAliases(l: *Self, aliases: []const Alias, values: *const SymbolTable, diag: *Diagnostic) Error!void {
            if (aliases.len == 0) return;
            const resolved = try l.gpa.alloc(u64, aliases.len);
            defer l.gpa.free(resolved);
            for (aliases, resolved, 0..) |al, *out, i| {
                const fail_diag: Diagnostic = .{ .atom = "alias", .target = al.target };
                const v: u64 = if (l.numbered) |s| v: {
                    const n = s.aliases[i];
                    if (n.symbol >= l.addrs.len or n.target >= l.addrs.len) return error.InvalidSymbols;
                    if (l.addrs[n.symbol] != unset) {
                        diag.* = .{ .atom = "alias", .target = al.key };
                        return error.DuplicateSymbol;
                    }
                    const e = l.addrs[n.target];
                    if (e == unset) {
                        diag.* = fail_diag;
                        return error.UndefinedSymbol;
                    }
                    // Values and an executable's imports are table entries
                    // an addend cannot move.
                    if (e >= value_tag) {
                        if (al.addend != 0) {
                            diag.* = fail_diag;
                            return error.InvalidRelocation;
                        }
                        out.* = e;
                        continue;
                    }
                    break :v l.base + e;
                } else v: {
                    if (l.symbols.get(al.key) != null or values.get(al.key) != null) {
                        diag.* = .{ .atom = "alias", .target = al.key };
                        return error.DuplicateSymbol;
                    }
                    break :v l.symbols.get(al.target) orelse values.get(al.target) orelse {
                        diag.* = fail_diag;
                        return error.UndefinedSymbol;
                    };
                };
                // An import's stub or stand-in: its relocations name it.
                if (al.addend != 0 and v >= l.plt_start and v < l.plt_end) {
                    diag.* = fail_diag;
                    return error.InvalidRelocation;
                }
                const sum = @as(i128, v) + al.addend;
                if (l.numbered != null) {
                    const off = sum - l.base;
                    if (off < 0 or off >= value_tag) return error.RelocationOverflow;
                    out.* = @intCast(off);
                } else out.* = @truncate(@as(u128, @bitCast(sum)));
            }
            for (aliases, resolved, 0..) |al, v, i| {
                if (l.numbered) |s| {
                    l.addrs[s.aliases[i].symbol] = @intCast(v);
                } else values.getOrPut(al.key).* = .{ .key = al.key, .value = v, .used = true };
            }
        }

        /// The address or value an `addrs` entry stands for.
        fn numberedAddr(l: *const Self, e: u32) ?u64 {
            if (e < value_tag) return l.base + e;
            if (e == unset) return null;
            if (e >= import_tag) return l.plt_start + (e - import_tag) * l.plt_entry;
            return l.numbered.?.values[e - value_tag].value;
        }

        fn populateOutput(l: *Self, part: usize, _: usize) void {
            const buf = l.target.memory;
            const begin = part * populate_len;
            populate(buf[begin..@min(buf.len, begin + populate_len)]);
        }

        /// Writes `bytes` at `offset` of the output.
        fn put(l: *Self, offset: u64, bytes: []const u8) Error!void {
            switch (l.target) {
                .memory => |buf| @memcpy(buf[offset..][0..bytes.len], bytes),
                .file => |fd| try l.writeChanged(fd, bytes, offset),
            }
        }

        /// Writes `len` zero bytes at `offset` of the output.
        fn fill(l: *Self, offset: u64, len: u64) Error!void {
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
        fn parts(l: *Self, thread: usize, comptime n: usize, offsets: [n]u64, lens: [n]u64) [n][]u8 {
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

        fn writeParts(l: *Self, task: usize, atom: usize, comptime n: usize, offsets: [n]u64, bufs: [n][]u8) void {
            const fd = switch (l.target) {
                .memory => return,
                .file => |fd| fd,
            };
            for (offsets, bufs) |off, b| l.writeChanged(fd, b, off) catch return l.fail(task, atom, error.WriteFailed, .{});
        }

        /// Writes `bytes` at `offset` of the file, skipping the pages the
        /// old output it overwrites already has the same: an edit's relink
        /// leaves most of them as they were, and pwrite dirties every page
        /// it writes under the inode lock, which serializes the threads.
        /// The old bytes are read back with pread, which maps nothing that
        /// would have to be torn down.
        fn writeChanged(l: *const Self, fd: std.posix.fd_t, bytes: []const u8, offset: u64) Error!void {
            var old: [16 * page_size]u8 = undefined;
            var at: usize = 0;
            var run: ?usize = null;
            while (at < bytes.len and offset + at < l.old_len) {
                // A block of whole file pages, as far as the old output goes.
                const off = offset + at;
                const block_end: usize = @intCast(@min(bytes.len, l.old_len - offset, (off / page_size + 16) * page_size - offset));
                const n = preadAll(fd, old[0 .. block_end - at], off) catch 0;
                var p = at;
                while (p < block_end) {
                    const next: usize = @intCast(@min(block_end, ((offset + p) / page_size + 1) * page_size - offset));
                    const same = next - at <= n and std.mem.eql(u8, bytes[p..next], old[p - at .. next - at]);
                    if (!same) {
                        if (run == null) run = p;
                    } else if (run) |r| {
                        try pwriteAll(fd, bytes[r..p], offset + r);
                        run = null;
                    }
                    p = next;
                }
                at = block_end;
            }
            const r = run orelse at;
            if (r < bytes.len) try pwriteAll(fd, bytes[r..], offset + r);
        }

        fn gatherKeys(l: *Self, chunk: usize, _: usize) void {
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
        fn dedup(l: *Self, partition: usize, _: usize) void {
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
        fn layOutKeyed(l: *Self, chunk: usize, _: usize) void {
            l.layOut(chunk, false, true);
        }

        /// A relink of a pic or shared image is rare; the static one keeps
        /// its loop free of their checks.
        fn layOutNumbered(l: *Self, chunk: usize, _: usize) void {
            if (l.pic or l.dynamic) l.layOut(chunk, true, true) else l.layOut(chunk, true, false);
        }

        /// The key-based and numbered paths are compiled apart, so that each
        /// is as tight as if it were the only one.
        fn layOut(l: *Self, chunk: usize, comptime numbered: bool, comptime pic_or_dynamic: bool) void {
            const begin = chunk * chunk_len;
            const end = @min(l.n_atoms, begin + chunk_len);
            var c: Chunk = .{
                .sizes = @splat(0),
                .aligns = @splat(.@"1"),
                .n_syms = 0,
                .str_len = 0,
                .max_targets = 0,
                .n_long_fdes = 0,
                .n_rela = 0,
                .bases = undefined,
                .lead_gaps = undefined,
                .sym = undefined,
                .str = undefined,
                .rela = undefined,
            };
            defer l.chunks[chunk] = c;
            // Locals: the loop writes through pointers that could alias `l`.
            const pic = pic_or_dynamic and l.pic;
            const dynamic = pic_or_dynamic and l.dynamic;
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
                const s = if (a.section == .rodata and ((pic and hasAbs(a)) or (dynamic and l.hasImportAbs(a)))) data_rel_ro else @backingInt(a.section);
                const off = a.alignment.forward(c.sizes[s]);
                p.* = .{
                    .offset = std.math.cast(u38, off) orelse {
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
                if (l.listed(a)) {
                    c.n_syms += 1;
                    c.str_len += @intCast(a.name.len + 1);
                }
                c.max_targets = @max(c.max_targets, @as(u32, @intCast(a.targets.len)));
                c.n_long_fdes += @intFromBool(a.unwind.epilogue > 1 or a.unwind.saved & 0xf00 != 0);
                if (dynamic) {
                    for (a.relocs) |r| c.n_rela += @intFromBool(l.needsDynamicReloc(a, r));
                }
                // Non-PIE code (`x86_64_abs32`/`abs32s`) needs a fixed address.
                if (pic) for (a.relocs) |r| if (r.info.kind == .x86_64_abs32 or r.info.kind == .x86_64_abs32s) {
                    l.fail(chunk, i, error.InvalidRelocation, .{ .atom = a.name, .target = a.targets[r.info.target] });
                    break;
                };
            }
        }

        /// Whether absolute relocation `r` of `a` needs the loader: in a
        /// shared object every one, in an executable those to imports,
        /// and an executable's thread-pointer offsets of imports.
        fn needsDynamicReloc(l: *const Self, a: *const Atom, r: Atom.Reloc) bool {
            switch (r.info.kind) {
                .x86_64_abs64, .aarch64_abs64 => {},
                .x86_64_tpoff64, .aarch64_tprel64 => return isImport(l.exe_imports orelse return false, a.targets[r.info.target]),
                // A shared object's module ID, for `__tls_get_addr`, and
                // its TLS descriptors.
                .x86_64_dtpmod64, .x86_64_tlsdesc, .x86_64_dtpmod64_sym, .x86_64_dtpoff64_sym, .x86_64_tlsdesc_sym, .aarch64_tlsdesc, .aarch64_tlsdesc_sym => return l.exe_imports == null,
                // A shared object's references to its own exports.
                .x86_64_abs64_sym, .aarch64_abs64_sym => return l.exe_imports == null,
                // Every image's indirect functions.
                .x86_64_irelative, .aarch64_irelative => return true,
                else => return false,
            }
            const imports = l.exe_imports orelse return true;
            return isImport(imports, a.targets[r.info.target]);
        }

        /// In an executable, whether `a` holds an absolute address or a
        /// thread-pointer offset of an import, which the loader writes.
        fn hasImportAbs(l: *const Self, a: *const Atom) bool {
            const imports = l.exe_imports orelse return false;
            for (a.relocs) |r| {
                const abs = switch (r.info.kind) {
                    .x86_64_abs64, .x86_64_tpoff64, .aarch64_abs64, .aarch64_tprel64 => true,
                    else => false,
                };
                if (abs and isImport(imports, a.targets[r.info.target])) return true;
            }
            return false;
        }

        fn isImport(imports: []const SymbolKey, key: SymbolKey) bool {
            return std.sort.binarySearch(SymbolKey, imports, key, struct {
                fn order(k: SymbolKey, item: SymbolKey) std.math.Order {
                    return std.math.order(@backingInt(k), @backingInt(item));
                }
            }.order) != null;
        }

        fn resolveAddrsAndLayOutDebug(l: *Self, task: usize, thread: usize) void {
            if (task < l.n_resolve_tasks) l.resolveAddrs(task, thread) else l.layOutDebug(task - l.n_resolve_tasks);
        }

        /// Sizes one chunk's debug entries and collects their files.
        fn layOutDebug(l: *Self, chunk: usize) void {
            Dwarf.layOutChunk(l, chunk, l.chunks.len + chunk, @backingInt(Atom.Section.text));
        }

        fn copyAll(l: *Self, task: usize, thread: usize) void {
            if (task >= l.chunks.len + l.debug_chunks.len) return l.copyInput(task - l.chunks.len - l.debug_chunks.len, thread);
            // The debug chunks first: they take longer than the atom chunks,
            // so starting them first leaves less of the phase to one thread.
            if (task < l.debug_chunks.len) return l.copyDebug(task, thread);
            return l.copyChunk(task - l.debug_chunks.len, thread);
        }

        fn copyChunk(l: *Self, task: usize, thread: usize) void {
            if (l.dynamic) return l.copyDynamic(task, thread);
            if (l.numbered == null) l.copy(task, thread, false, false) else l.copyNumbered(task, thread);
        }

        /// Writes one chunk's subprogram entries, line sequences, FDEs, and
        /// search table entries.
        noinline fn copyDebug(l: *Self, chunk: usize, thread: usize) void {
            const begin = chunk * chunk_len;
            const end = @min(l.n_debug, begin + chunk_len);
            const c = &l.debug_chunks[chunk];
            const task = l.chunks.len + chunk;
            const offsets = [2]u64{
                l.eh_off + Dwarf.cie.len + c.frame_off,
                l.hdr_off + Dwarf.eh_frame_hdr_size + @as(u64, c.frame_base) * Dwarf.eh_frame_hdr_entry_size,
            };
            const lens = [2]u64{ c.frame_bytes, @as(u64, c.n_frames) * Dwarf.eh_frame_hdr_entry_size };
            const out = l.parts(thread, 2, offsets, lens);
            // Each unit's part of the subprogram entries, range lists, and
            // line sequences: in place, or in the scratch after `out`.
            const units = c.units.values();
            const n_u = units.len;
            const pieces = l.gpa.alloc([]u8, 6 * n_u) catch return l.fail(task, begin, error.OutOfMemory, .{});
            defer l.gpa.free(pieces);
            const info = pieces[0..n_u];
            const ranges = pieces[n_u..][0..n_u];
            const line = pieces[2 * n_u ..][0..n_u];
            {
                var at: usize = thread * l.scratch_len + lens[0] + lens[1];
                for (units, info, ranges, line) |u, *i, *r, *ln| {
                    const piece_lens = [3]u64{ u.info_len, u.n_runs * Dwarf.range_len, u.line_len };
                    switch (l.target) {
                        .memory => |buf| {
                            i.* = buf[l.info_off + u.info_off ..][0..piece_lens[0]];
                            r.* = buf[l.ranges_off + u.ranges_off ..][0..piece_lens[1]];
                            ln.* = buf[l.line_off + u.line_off ..][0..piece_lens[2]];
                        },
                        .file => {
                            i.* = l.scratch[at..][0..piece_lens[0]];
                            r.* = l.scratch[at + piece_lens[0] ..][0..piece_lens[1]];
                            ln.* = l.scratch[at + piece_lens[0] + piece_lens[1] ..][0..piece_lens[2]];
                            at += piece_lens[0] + piece_lens[1] + piece_lens[2];
                        },
                    }
                }
            }
            @memcpy(pieces[3 * n_u ..], pieces[0 .. 3 * n_u]);
            var w: Dwarf.ChunkWriter = .{ .c = c, .info = pieces[3 * n_u ..][0..n_u], .ranges = pieces[4 * n_u ..][0..n_u], .line = pieces[5 * n_u ..][0..n_u], .aranges = &.{}, .text_addr = l.section_addrs[@backingInt(Atom.Section.text)] };
            // A local copy: writes to `out` could alias `l`.
            const input = l.input;
            var fde = c.frame_base;
            var fde_at: u32 = 0;
            const hdr_addr: i64 = @intCast(l.base + l.hdr_off);
            for (l.file_of[begin..end], begin..) |file_of, j| {
                // The entries stream; their fragments, names, and atoms do not.
                if (j + 12 < end) {
                    input.prefetchDebug(j + 12);
                    @prefetch(&l.places[input.debugAtom(j + 12)], .{});
                }
                if (file_of == Dwarf.skip) continue;
                const debug = input.debug(j);
                const d = ref(&debug);
                const atom = input.debugAtom(j);
                const addr = l.atomAddr(atom);
                const a = input.atom(atom);
                const size = a.bytes.len;
                w.entry(d, a.name, addr, size, file_of);
                const unwind = ref(&a).unwind;
                if (unwind.kind != .none) {
                    const fde_off: u32 = @intCast(Dwarf.cie.len + c.frame_off + fde_at);
                    const fde_addr: i64 = @intCast(l.base + l.eh_off + fde_off);
                    const fn_addr: i64 = @intCast(addr);
                    const k = fde - c.frame_base;
                    const fde_len = Dwarf.fdeSize(l.arch, unwind, size);
                    Dwarf.writeFde(l.arch, out[0][fde_at..][0..fde_len], unwind, fde_off, @intCast(fn_addr - (fde_addr + 8)), @intCast(size));
                    fde_at += fde_len;
                    const entry = out[1][@as(usize, k) * Dwarf.eh_frame_hdr_entry_size ..][0..8];
                    std.mem.writeInt(i32, entry[0..4], @intCast(fn_addr - hdr_addr), .little);
                    std.mem.writeInt(i32, entry[4..8], @intCast(fde_addr - hdr_addr), .little);
                    fde += 1;
                }
            }
            w.finish();
            if (l.hdr_table.len != 0) @memcpy(std.mem.sliceAsBytes(l.hdr_table[c.frame_base..][0..c.n_frames]), out[1]);
            l.writeParts(task, begin, 2, offsets, out);
            if (l.target == .file) for (units, info, ranges, line) |u, i, r, ln| {
                l.writeParts(task, begin, 3, .{ l.info_off + u.info_off, l.ranges_off + u.ranges_off, l.line_off + u.line_off }, .{ i, r, ln });
            };
        }

        /// The file offset of input section `i`.
        fn inputOff(l: *const Self, i: usize) u64 {
            const k = @backingInt(l.input_sections[i].kind);
            return l.sec_offs[k] + l.bs_parts[k] + l.input_offs[i];
        }

        /// The address or value of `key`, after `resolveAddrs`.
        fn resolveKey(l: *const Self, key: SymbolKey) ?u64 {
            return l.symbols.get(key) orelse l.values.get(key);
        }

        /// Copies input section `i` and applies its relocations.
        noinline fn copyInput(l: *Self, i: usize, thread: usize) void {
            const s = &l.input_sections[i];
            const task = l.chunks.len + l.debug_chunks.len + i;
            const off = l.inputOff(i);
            const out = l.parts(thread, 1, .{off}, .{s.bytes.len});
            @memcpy(out[0], s.bytes);
            for (s.relocs) |r| l.inputReloc(s, r, out[0], l.base + off) catch |err| {
                const target = if (r.kind == .offset32 or r.kind == .offset64 or r.target >= s.targets.len) null else s.targets[r.target];
                return l.fail(task, l.n_atoms + i, err, .{ .atom = s.name, .target = target });
            };
            l.writeParts(task, l.n_atoms + i, 1, .{off}, out);
        }

        fn inputReloc(l: *const Self, s: *const InputSection, r: InputReloc, dst: []u8, p_base: u64) Error!void {
            const wide = switch (r.kind) {
                .abs64, .pc64, .dtpoff64, .offset64, .const64 => true,
                .abs32, .pc32, .dtpoff32, .offset32, .const32 => false,
            };
            if (@as(u64, r.offset) + @as(u64, if (wide) 8 else 4) > dst.len) return error.InvalidInput;
            const v: i128 = switch (r.kind) {
                .offset32, .offset64 => v: {
                    if (r.target >= l.input_sections.len) return error.InvalidInput;
                    const k = @backingInt(l.input_sections[r.target].kind);
                    break :v @as(i128, l.bs_parts[k] + l.input_offs[r.target]) + r.addend;
                },
                .const32, .const64 => r.addend,
                else => v: {
                    if (r.target >= s.targets.len) return error.InvalidInput;
                    const t = l.resolveKey(s.targets[r.target]) orelse return error.UndefinedSymbol;
                    break :v switch (r.kind) {
                        .abs32, .abs64 => @as(i128, t) + r.addend,
                        .pc32, .pc64 => if (s.kind == .eh_frame) @as(i128, t) + r.addend - (p_base + r.offset) else return error.InvalidInput,
                        .dtpoff32, .dtpoff64 => if (t >= l.tls.start and t < l.tls.end) @as(i128, t - l.tls.start) + r.addend else return error.InvalidRelocation,
                        else => unreachable,
                    };
                },
            };
            const f = dst[r.offset..];
            if (wide) {
                std.mem.writeInt(u64, f[0..8], @truncate(@as(u128, @bitCast(v))), .little);
            } else switch (r.kind) {
                .pc32, .dtpoff32 => std.mem.writeInt(i32, f[0..4], std.math.cast(i32, v) orelse return error.RelocationOverflow, .little),
                .const32 => std.mem.writeInt(u32, f[0..4], @truncate(@as(u128, @bitCast(v))), .little),
                else => std.mem.writeInt(u32, f[0..4], std.math.cast(u32, v) orelse return error.RelocationOverflow, .little),
            }
        }

        /// Writes `bytes` at `offset` of a debug section.
        fn putDebug(l: *Self, section: Dwarf.Section, offset: u64, bytes: []const u8) Error!void {
            switch (section) {
                .info => try l.put(l.info_off + offset, bytes),
                .ranges => try l.put(l.ranges_off + offset, bytes),
                .line => try l.put(l.line_off + offset, bytes),
                .aranges => {},
            }
        }

        /// Sets `res` to the addresses or values of the targets of `a`, atom
        /// `i`, from `addrs`.
        /// Whether atom `a` has its own symbol.
        fn listed(l: *const Self, a: *const Atom) bool {
            return listedAtom(a) and (l.unlisted.count() == 0 or !l.unlisted.contains(a.key));
        }

        fn resolveNumbered(l: *Self, a: *const Atom, i: usize, chunk: usize, res: []u64) bool {
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
        noinline fn copyNumbered(l: *Self, chunk: usize, thread: usize) void {
            l.copy(chunk, thread, true, false);
        }

        /// A shared object's, which also writes a .rela.dyn record per
        /// absolute relocation; out of line, as `copyNumbered`.
        noinline fn copyDynamic(l: *Self, chunk: usize, thread: usize) void {
            if (l.numbered == null) l.copy(chunk, thread, false, true) else l.copy(chunk, thread, true, true);
        }

        fn copy(l: *Self, chunk: usize, thread: usize, comptime numbered: bool, comptime dynamic: bool) void {
            const c = &l.chunks[chunk];
            const resolved = l.resolved[thread * l.max_targets ..][0..l.max_targets];
            // The chunk's part of each section with file contents, from the
            // padding before it, then its symbols and their names, and in a
            // shared object its .rela.dyn records. Sections without file
            // contents get empty parts.
            const n_parts = n_sections + 2 + @intFromBool(dynamic);
            var offsets: [n_parts]u64 = @splat(0);
            var lens: [n_parts]u64 = @splat(0);
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
            const rela = n_sections + 2;
            if (dynamic) {
                offsets[rela] = l.rela_off + @as(u64, c.rela) * @sizeOf(elf.Elf64.Rela);
                lens[rela] = @as(u64, c.n_rela) * @sizeOf(elf.Elf64.Rela);
            }
            var rela_at: usize = 0;
            const out = l.parts(thread, n_parts, offsets, lens);
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
                    @memset(section_out[start - place.gap .. start], if (l.arch == .aarch64) 0 else fills[place.section]);
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
                    if (dynamic) for (a.relocs) |r| {
                        if (!l.needsDynamicReloc(a, r)) continue;
                        // Code must not need the loader to write it.
                        if (place.section == @backingInt(Atom.Section.text)) return l.fail(chunk, i, error.InvalidRelocation, .{ .atom = a.name, .target = a.targets[r.info.target] });
                        const t = res[r.info.target];
                        const v = t +% @as(u64, @bitCast(@as(i64, r.addend)));
                        const rec: elf.Elf64.Rela = if (symType(r.info.kind)) |ty| rec: {
                            // Against the export, which the loader may
                            // bind to another module's definition.
                            const sym = l.export_syms.get(v) orelse return l.fail(chunk, i, error.InvalidRelocation, .{ .atom = a.name, .target = a.targets[r.info.target] });
                            const addend = if (r.info.kind == .x86_64_abs64_sym or r.info.kind == .aarch64_abs64_sym) std.mem.readInt(i64, a.bytes[r.offset..][0..8], .little) else 0;
                            break :rec .{ .offset = addr + r.offset, .info = .{ .type = ty, .sym = sym }, .addend = addend };
                        } else if (r.info.kind == .x86_64_dtpmod64)
                            .{ .offset = addr + r.offset, .info = .{ .type = @backingInt(elf.R_X86_64.DTPMOD64), .sym = 0 }, .addend = 0 }
                        else if (r.info.kind == .x86_64_tlsdesc)
                            .{ .offset = addr + r.offset, .info = .{ .type = @backingInt(elf.R_X86_64.TLSDESC), .sym = 0 }, .addend = @bitCast(v -% l.tls.start) }
                        else if (r.info.kind == .aarch64_tlsdesc)
                            .{ .offset = addr + r.offset, .info = .{ .type = @backingInt(elf.R_AARCH64.TLSDESC), .sym = 0 }, .addend = @bitCast(v -% l.tls.start) }
                        else if (r.info.kind == .x86_64_irelative)
                            .{ .offset = addr + r.offset, .info = .{ .type = @backingInt(elf.R_X86_64.IRELATIVE), .sym = 0 }, .addend = @bitCast(v) }
                        else if (r.info.kind == .aarch64_irelative)
                            .{ .offset = addr + r.offset, .info = .{ .type = @backingInt(elf.R_AARCH64.IRELATIVE), .sym = 0 }, .addend = @bitCast(v) }
                        else if (t >= l.plt_start and t < l.plt_end)
                            .{ .offset = addr + r.offset, .info = .{ .type = switch (r.info.kind) {
                                .x86_64_tpoff64 => @backingInt(elf.R_X86_64.TPOFF64),
                                .aarch64_abs64 => @backingInt(elf.R_AARCH64.ABS64),
                                .aarch64_tprel64 => @backingInt(elf.R_AARCH64.TLS_TPREL),
                                else => @backingInt(elf.R_X86_64.@"64"),
                            }, .sym = @intCast(1 + (t - l.plt_start) / l.plt_entry) }, .addend = r.addend }
                        else
                            .{ .offset = addr + r.offset, .info = .{ .type = if (l.arch == .aarch64) @backingInt(elf.R_AARCH64.RELATIVE) else @backingInt(elf.R_X86_64.RELATIVE), .sym = 0 }, .addend = @bitCast(v) };
                        writeStruct(out[rela][rela_at..], rec);
                        rela_at += @sizeOf(elf.Elf64.Rela);
                    };
                }
                if (!l.listed(a)) continue;
                const name = c.str + @as(u32, @intCast(str_off));
                @memcpy(out[strtab][str_off..][0..a.name.len], a.name);
                out[strtab][str_off + a.name.len] = 0;
                str_off += a.name.len + 1;
                writeStruct(out[symtab][sym_off..], elf.Elf64.Sym{
                    .name = name,
                    // Local, as upstream writes them: names can repeat
                    // (generic instances), and nothing links against an
                    // executable's symbols.
                    .info = .{ .type = sym_types[place.section], .bind = .LOCAL },
                    .other = .{ .visibility = .DEFAULT },
                    .shndx = l.shndx[place.section],
                    .value = addr - l.sym_bias[place.section],
                    .size = a.size(),
                });
                sym_off += @sizeOf(elf.Elf64.Sym);
            }
            l.writeParts(chunk, begin, n_parts, offsets, out);
        }
    };
}

/// Runs `task(ctx, i, thread)` for every i < n_tasks on up to `n_threads`
/// threads, the calling thread included.
pub fn parallel(ctx: anytype, comptime task: fn (@TypeOf(ctx), usize, usize) void, io: std.Io, n_threads: usize, n_tasks: usize) std.Io.Cancelable!void {
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
    // An object can have no atoms, and so no tasks.
    for (1..@max(1, @min(n_threads, n_tasks))) |t| group.async(io, Worker.work, .{ ctx, &next, n_tasks, t });
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
    if (begin < end) std.posix.madvise(@ptrFromInt(begin), end - begin, std.posix.MADV.HUGEPAGE) catch {}; // ziglint-ignore: Z026 -- only a hint to the kernel
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
    const madv_populate_write = 23; // Linux 5.14; older kernels just fault.
    if (begin < end) std.posix.madvise(@ptrFromInt(begin), end - begin, madv_populate_write) catch {}; // ziglint-ignore: Z026 -- only a hint to the kernel
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
        // `rawAlloc`: `Allocator.alloc` fills the memory with undefined
        // bytes in safe builds, and `used` must start false.
        const bytes = std.heap.page_allocator.rawAlloc(len * @sizeOf(Entry), huge_page, @returnAddress()) orelse return error.OutOfMemory;
        const entries: []Entry = @as([*]Entry, @ptrCast(@alignCast(bytes)))[0..len];
        adviseHugePages(std.mem.sliceAsBytes(entries));
        return .{
            .entries = entries,
            .partition_shift = @as(u8, 128) - std.math.log2_int(usize, n_partitions),
            .slot_mask = slots - 1,
        };
    }

    pub fn deinit(t: *SymbolTable) void {
        if (t.entries.len != 0) std.heap.page_allocator.rawFree(std.mem.sliceAsBytes(t.entries), huge_page, @returnAddress());
        t.* = undefined;
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

/// Reads up to `buf.len` bytes at `offset` of `fd`; returns how many,
/// fewer at the end of the file.
fn preadAll(fd: std.posix.fd_t, buf: []u8, offset: u64) error{ReadFailed}!usize {
    var at: usize = 0;
    while (at < buf.len) {
        const sys = std.posix.system;
        const rc = sys.pread(fd, buf[at..].ptr, buf.len - at, @intCast(offset + at));
        switch (sys.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) break;
                at += @intCast(rc);
            },
            .INTR => {},
            else => return error.ReadFailed,
        }
    }
    return at;
}

pub fn pwriteAll(fd: std.posix.fd_t, bytes: []const u8, offset: u64) Error!void {
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
        a.targets.len != b.targets.len or a.relocs.len != b.relocs.len or
        !std.meta.eql(a.unwind, b.unwind)) return false;
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
            // The resolver's address until the loader calls it, as
            // upstream writes it.
            .x86_64_abs64, .x86_64_irelative, .aarch64_abs64, .aarch64_irelative => {
                const f = try relocField(a, dst, r.offset, 8, diag);
                std.mem.writeInt(u64, f, s +% @as(u64, @bitCast(@as(i64, r.addend))), .little);
            },
            .x86_64_abs32 => {
                const f = try relocField(a, dst, r.offset, 4, diag);
                std.mem.writeInt(u32, f, std.math.cast(u32, @as(i128, s) + r.addend) orelse return overflow(a, r, diag), .little);
            },
            .aarch64_prel32 => {
                const f = try relocField(a, dst, r.offset, 4, diag);
                const v = @as(i64, @bitCast(s -% (p_base + r.offset))) +% r.addend;
                std.mem.writeInt(i32, f, std.math.cast(i32, v) orelse return overflow(a, r, diag), .little);
            },
            .aarch64_prel64 => {
                const f = try relocField(a, dst, r.offset, 8, diag);
                std.mem.writeInt(u64, f, s -% (p_base + r.offset) +% @as(u64, @bitCast(@as(i64, r.addend))), .little);
            },
            .aarch64_abs32 => {
                const f = try relocField(a, dst, r.offset, 4, diag);
                const v = @as(i128, s) + r.addend;
                if (v < std.math.minInt(i32) or v > std.math.maxInt(u32)) return overflow(a, r, diag);
                std.mem.writeInt(u32, f, @truncate(@as(u128, @bitCast(v))), .little);
            },
            .x86_64_abs32s => {
                const f = try relocField(a, dst, r.offset, 4, diag);
                std.mem.writeInt(i32, f, std.math.cast(i32, @as(i128, s) + r.addend) orelse return overflow(a, r, diag), .little);
            },
            .x86_64_tpoff32 => try tpoff32(a, r, dst, s, tls, diag),
            .x86_64_tpoff64, .aarch64_tprel64 => try tpoff64(a, r, dst, s, tls, diag),
            // The loader's (`needsDynamicReloc`).
            .x86_64_dtpmod64, .x86_64_dtpmod64_sym, .x86_64_dtpoff64_sym, .x86_64_abs64_sym, .aarch64_abs64_sym => @memset(try relocField(a, dst, r.offset, 8, diag), 0),
            .x86_64_tlsdesc_sym, .aarch64_tlsdesc_sym => @memset(try relocField(a, dst, r.offset, 16, diag), 0),
            .x86_64_tlsdesc, .aarch64_tlsdesc => {
                if (s < tls.start or s >= tls.end) return invalidReloc(a, diag);
                @memset(try relocField(a, dst, r.offset, 16, diag), 0);
            },
            .x86_64_tlsld, .x86_64_dtpoff32 => try tlsDynamic(a, r, dst, p_base, s, tls, diag),
            // Only objects reach another module's thread-locals.
            .x86_64_gottpoff, .x86_64_tlsgd, .aarch64_tlsdesc_page21, .aarch64_tlsdesc_ld64_lo12, .aarch64_tlsdesc_add_lo12, .aarch64_tlsdesc_call, .aarch64_gottprel_page21, .aarch64_gottprel_lo12 => if (!tls.object) return invalidReloc(a, diag),
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
            .aarch64_branch26, .aarch64_page21, .aarch64_pageoff12, .aarch64_got_load_page21, .aarch64_got_load_pageoff12, .aarch64_movw_value16, .aarch64_tprel_hi12, .aarch64_tprel_lo12_nc, .aarch64_tprel_g1, .aarch64_tprel_g0_nc => try aarch64Reloc(a, r, dst, p_base, s, tls, diag),
            else => return invalidReloc(a, diag),
        }
    }
}

/// Out of line: thread-locals are rare, and the relocation loop keeps its
/// registers for the common kinds.
noinline fn tpoff32(a: *const Atom, r: Atom.Reloc, dst: []u8, s: u64, tls: *const Tls, diag: *Diagnostic) Error!void {
    const f = try relocField(a, dst, r.offset, 4, diag);
    if (s < tls.start or s >= tls.end) {
        // An object's import (`extern threadlocal`).
        if (tls.object) return;
        diag.* = .{ .atom = a.name, .target = a.targets[r.info.target] };
        return error.InvalidRelocation;
    }
    const v = @as(i64, @bitCast(s -% tls.tp)) +% r.addend;
    std.mem.writeInt(i32, f, std.math.cast(i32, v) orelse return overflow(a, r, diag), .little);
}

/// An executable's slot for initial-exec code: the image's own thread-local
/// has its offset now; an import's is the loader's (`needsDynamicReloc`).
noinline fn tpoff64(a: *const Atom, r: Atom.Reloc, dst: []u8, s: u64, tls: *const Tls, diag: *Diagnostic) Error!void {
    const f = try relocField(a, dst, r.offset, 8, diag);
    if (s >= tls.start and s < tls.end and !tls.object) {
        std.mem.writeInt(i64, f, @as(i64, @bitCast(s -% tls.tp)) +% r.addend, .little);
    } else if (s >= tls.imports_start and s < tls.imports_end and r.addend == 0) {
        @memset(f, 0);
    } else {
        diag.* = .{ .atom = a.name, .target = a.targets[r.info.target] };
        return error.InvalidRelocation;
    }
}

/// An aarch64 instruction's relocation, in a static executable, where
/// every target is defined: GOT loads become the target's address.
noinline fn aarch64Reloc(a: *const Atom, r: Atom.Reloc, dst: []u8, p_base: u64, s: u64, tls: *const Tls, diag: *Diagnostic) Error!void {
    const f = try relocField(a, dst, r.offset, 4, diag);
    const insn = std.mem.readInt(u32, f, .little);
    const p = p_base + r.offset;
    const target = s +% @as(u64, @bitCast(@as(i64, r.addend)));
    const v: u32 = switch (r.info.kind) {
        .aarch64_branch26 => v: {
            const delta: i64 = @bitCast(target -% p);
            if (delta & 3 != 0 or delta < -(1 << 27) or delta >= 1 << 27) return overflow(a, r, diag);
            break :v (insn & 0xfc000000) | @as(u32, @truncate(@as(u64, @bitCast(delta >> 2)) & 0x3ffffff));
        },
        .aarch64_page21, .aarch64_got_load_page21 => v: {
            const pages = a64.pageDelta(target, p);
            if (pages < -(1 << 20) or pages >= 1 << 20) return overflow(a, r, diag);
            break :v a64.patchAdrp(insn, pages);
        },
        .aarch64_pageoff12 => v: {
            const off: u32 = @truncate(target & 0xfff);
            const scale = a64.pageOffScale(insn) orelse return invalidReloc(a, diag);
            if (off & ((@as(u32, 1) << scale) - 1) != 0) return overflow(a, r, diag);
            break :v a64.patchImm12(insn, off >> scale);
        },
        // ldr xt, [xn, #got_lo12] becomes add xt, xn, #lo12.
        .aarch64_got_load_pageoff12 => if (insn & 0xffc00000 != 0xf9400000)
            return invalidReloc(a, diag)
        else
            0x91000000 | (insn & 0x3ff) | @as(u32, @truncate(target & 0xfff)) << 10,
        // movz or movk, w or x.
        .aarch64_movw_value16 => if (insn & 0x5f800000 != 0x52800000)
            return invalidReloc(a, diag)
        else
            (insn & ~@as(u32, 0xffff << 5)) | @as(u32, std.math.cast(u16, @as(i128, s) + r.addend) orelse return overflow(a, r, diag)) << 5,
        .aarch64_tprel_hi12, .aarch64_tprel_lo12_nc => v: {
            // add xd, xn, #imm
            if (insn & 0xff800000 != 0x91000000 or s < tls.start or s >= tls.end) return invalidReloc(a, diag);
            const off = target -% tls.tp;
            if (r.info.kind == .aarch64_tprel_lo12_nc) break :v a64.patchImm12(insn, @truncate(off & 0xfff));
            if (off >= 1 << 24) return overflow(a, r, diag);
            break :v a64.patchImm12(insn, @truncate(off >> 12));
        },
        .aarch64_tprel_g1, .aarch64_tprel_g0_nc => v: {
            // movz or movk, x
            if (insn & 0xdf800000 != 0xd2800000 or s < tls.start or s >= tls.end) return invalidReloc(a, diag);
            const off = target -% tls.tp;
            if (r.info.kind == .aarch64_tprel_g0_nc) break :v (insn & ~@as(u32, 0xffff << 5)) | @as(u32, @truncate(off & 0xffff)) << 5;
            if (off >= 1 << 32) return overflow(a, r, diag);
            break :v (insn & ~@as(u32, 0xffff << 5)) | @as(u32, @truncate(off >> 16)) << 5;
        },
        else => unreachable,
    };
    std.mem.writeInt(u32, f, v, .little);
}

/// Whether `a` holds an absolute address, which a position-independent
/// image's loader must write.
/// The dynamic relocation type of a relocation against an export, or null
/// for another kind.
fn symType(kind: Atom.Reloc.Kind) ?u32 {
    return switch (kind) {
        .x86_64_dtpmod64_sym => @backingInt(elf.R_X86_64.DTPMOD64),
        .x86_64_dtpoff64_sym => @backingInt(elf.R_X86_64.DTPOFF64),
        .x86_64_tlsdesc_sym => @backingInt(elf.R_X86_64.TLSDESC),
        .x86_64_abs64_sym => @backingInt(elf.R_X86_64.@"64"),
        .aarch64_tlsdesc_sym => @backingInt(elf.R_AARCH64.TLSDESC),
        .aarch64_abs64_sym => @backingInt(elf.R_AARCH64.ABS64),
        else => null,
    };
}

/// Whether atom `a` has a symbol-table entry: not if it has no name or a
/// section's (`.data`), as `ElfInput` names a C object's section that no
/// one symbol covers, whose symbols it lists instead (`local_symbols`).
fn listedAtom(a: *const Atom) bool {
    return a.name.len > 0 and a.name[0] != '.';
}

fn hasAbs(a: *const Atom) bool {
    for (a.relocs) |r| switch (r.info.kind) {
        .x86_64_abs64, .x86_64_abs64_sym, .aarch64_abs64, .aarch64_abs64_sym, .aarch64_tlsdesc, .aarch64_tlsdesc_sym => return true,
        else => {},
    };
    return false;
}

/// Local-dynamic TLS: the GOT pair's PC-relative address, or `s`'s offset in
/// the module's TLS block. Out of line, as `tpoff32`.
noinline fn tlsDynamic(a: *const Atom, r: Atom.Reloc, dst: []u8, p_base: u64, s: u64, tls: *const Tls, diag: *Diagnostic) Error!void {
    const f = try relocField(a, dst, r.offset, 4, diag);
    const got = tls.ld_got orelse return invalidReloc(a, diag);
    if (s < tls.start or s >= tls.end) {
        diag.* = .{ .atom = a.name, .target = a.targets[r.info.target] };
        return error.InvalidRelocation;
    }
    const v = @as(i64, @bitCast(if (r.info.kind == .x86_64_tlsld) got -% (p_base + r.offset) else s -% tls.start)) +% r.addend;
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
    diag.* = .{ .atom = a.name, .target = a.targets[r.info.target], .reloc = r.info.kind, .addend = r.addend };
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
        return std.mem.findScalar(usize, t.bad, i) == null;
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

    const msg_text = "Hello from bs!\n";
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
        for (a.targets) |t| try targets.append(gpa, @intCast(std.mem.findScalar(SymbolKey, &numbering, t).?));
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
        // An old output that is mostly the new one, with one wrong byte
        // and longer, or cut short: the pages pwrite skips as unchanged
        // must really be.
        const longer = try std.mem.concat(gpa, u8, &.{ bytes, garbage[0..4096] });
        defer gpa.free(longer);
        longer[bytes.len / 2] ^= 1;
        for ([_][]const u8{ longer, bytes[0 .. bytes.len / 2 + 1] }) |old| {
            try tmp.dir.writeFile(io, .{ .sub_path = "hello", .data = old, .flags = .{ .permissions = .executable_file } });
            try link(gpa, io, tmp.dir, "hello", &atoms, file_options);
            const fixed = try tmp.dir.readFileAlloc(io, "hello", gpa, .unlimited);
            defer gpa.free(fixed);
            try std.testing.expectEqualSlices(u8, bytes, fixed);
        }
    }
    const path = try gpa.print(".zig-cache/tmp/{s}/hello", .{tmp.sub_path});
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

    // Symbols within atoms (`local_symbols`) are at their atom's address
    // plus their offset, and leave the rest of the image alone.
    var with_locals = options;
    with_locals.local_symbols = &.{
        .{ .name = "write_msg_tail", .atom = write_msg, .offset = 5, .size = 3 },
        .{ .name = "status_hi", .atom = status, .offset = 2, .size = 2 },
    };
    const local_bytes = try emit(gpa, io, &atoms, with_locals);
    defer gpa.free(local_bytes);
    try std.testing.expectEqual(testSymbolAddr(local_bytes, "write_msg").? + 5, testSymbolAddr(local_bytes, "write_msg_tail").?);
    try std.testing.expectEqual(testSymbolAddr(local_bytes, "status").? + 2, testSymbolAddr(local_bytes, "status_hi").?);
    try std.testing.expectEqual(testSymbolAddr(bytes, "write_msg").?, testSymbolAddr(local_bytes, "write_msg").?);
    const text_sh = testSection(bytes, ".text").?;
    try std.testing.expectEqualSlices(u8, bytes[text_sh.offset..][0..text_sh.size], local_bytes[text_sh.offset..][0..text_sh.size]);
    with_locals.local_symbols = &.{.{ .name = "past_end", .atom = status, .offset = 5, .size = 0 }};
    try std.testing.expectError(error.InvalidSymbols, emit(gpa, io, &atoms, with_locals));

    // An atom named after its C section, or not at all, has no symbol of
    // its own; the symbols within it do.
    const sect: SymbolKey = .fromName("sect");
    const unnamed = atoms ++ [_]Atom{
        .{ .key = sect, .name = ".data", .section = .data, .bytes = "abcdefgh" },
        .{ .key = .fromName("anon"), .name = "", .section = .rodata, .bytes = "z" },
    };
    with_locals.local_symbols = &.{.{ .name = "in_sect", .atom = sect, .offset = 4, .size = 4 }};
    const unnamed_bytes = try emit(gpa, io, &unnamed, with_locals);
    defer gpa.free(unnamed_bytes);
    try std.testing.expectEqual(null, testSymbolAddr(unnamed_bytes, ".data"));
    const symtab = testSection(unnamed_bytes, ".symtab").?;
    // The null symbol, the five distinct named atoms, and `in_sect`.
    try std.testing.expectEqual(7 * @sizeOf(elf.Elf64.Sym), symtab.size);
    const in_sect = testSymbolAddr(unnamed_bytes, "in_sect").?;
    try std.testing.expectEqualStrings("efgh", unnamed_bytes[in_sect - testSectionAddr(unnamed_bytes, ".data") + testSection(unnamed_bytes, ".data").?.offset ..][0..4]);

    // Global ones (a C-only program's, as lld lists them) come after every
    // local symbol, where .symtab's sh_info points; one at offset 0
    // replaces its atom's own symbol.
    with_locals.local_symbols = &.{
        .{ .name = "status", .atom = status, .offset = 0, .size = 4, .bind = .global },
        .{ .name = "in_sect", .atom = sect, .offset = 4, .size = 4 },
        .{ .name = "sect_weak", .atom = sect, .offset = 1, .size = 1, .bind = .weak },
    };
    const global_bytes = try emit(gpa, io, &unnamed, with_locals);
    defer gpa.free(global_bytes);
    const gsymtab = testSection(global_bytes, ".symtab").?;
    const gstrtab = testSection(global_bytes, ".strtab").?;
    const gsyms = std.mem.bytesAsSlice(elf.Elf64.Sym, global_bytes[gsymtab.offset..][0..gsymtab.size]);
    // The null symbol, four named atoms (not `status`), `in_sect`, then the
    // two global ones.
    try std.testing.expectEqual(8, gsyms.len);
    try std.testing.expectEqual(6, gsymtab.info);
    for (gsyms[6..], [_][]const u8{ "status", "sect_weak" }, [_]elf.STB{ .GLOBAL, .WEAK }) |sym, name, bind| {
        try std.testing.expectEqualStrings(name, std.mem.sliceTo(global_bytes[gstrtab.offset + sym.name ..], 0));
        try std.testing.expectEqual(bind, sym.info.bind);
    }
    for (gsyms[0..6]) |sym| try std.testing.expectEqual(elf.STB.LOCAL, sym.info.bind);
    try std.testing.expectEqual(testSymbolAddr(unnamed_bytes, "status").?, gsyms[6].value);
}

test "a shared object links the same with numbered symbols" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const f: SymbolKey = .fromName("f");
    const tv: SymbolKey = .fromName("tv");
    const ptrs: SymbolKey = .fromName("ptrs");
    const table: SymbolKey = .fromName("table");
    const g: SymbolKey = .fromName("import.g");
    const get_addr: SymbolKey = .fromName("import.__tls_get_addr");
    // `call g; lea rax, [rip + _DYNAMIC]`, the local-dynamic sequence for
    // `tv`, `ret`: every symbol kind a shared object's code reaches.
    const code = "\xe8\x00\x00\x00\x00" ++ "\x48\x8d\x05\x00\x00\x00\x00" ++ "\x48\x8d\x3d\x00\x00\x00\x00" ++
        "\xe8\x00\x00\x00\x00" ++ "\x48\x8d\x80\x00\x00\x00\x00" ++ "\xc3";
    const zeros: [16]u8 = @splat(0);
    const atoms = [_]Atom{
        .{ .key = f, .name = "f", .section = .text, .alignment = .@"16", .bytes = code, .targets = &.{ g, ElfDynamic.dynamic_key, tv, get_addr }, .relocs = &.{
            .init(1, .x86_64_pc32, 0, -4),
            .init(8, .x86_64_pc32, 1, -4),
            .init(15, .x86_64_tlsld, 2, -4),
            .init(20, .x86_64_pc32, 3, -4),
            .init(27, .x86_64_dtpoff32, 2, 0),
        } },
        .{ .key = tv, .name = "tv", .section = .tdata, .alignment = .@"4", .bytes = zeros[0..4] },
        // An address of the object's own (RELATIVE) and of an import's.
        .{ .key = ptrs, .name = "ptrs", .section = .data, .alignment = .@"8", .bytes = &zeros, .targets = &.{ f, g }, .relocs = &.{
            .init(0, .x86_64_abs64, 0, 0),
            .init(8, .x86_64_abs64, 1, 0),
        } },
        // In .data.rel.ro.
        .{ .key = table, .name = "table", .section = .rodata, .alignment = .@"8", .bytes = zeros[0..8], .targets = &.{f}, .relocs = &.{
            .init(0, .x86_64_abs64, 0, 0),
        } },
    };
    const dynamic: ElfDynamic.Options = .{
        // `f` twice, as two `@export`s of one function give.
        .exports = &.{ .{ .key = tv, .name = "tv" }, .{ .key = f, .name = "f" }, .{ .key = f, .name = "f_alias" } },
        .imports = &.{ .{ .key = g, .name = "g" }, .{ .key = get_addr, .name = "__tls_get_addr" } },
        .soname = "libt.so",
    };
    const options: Options = .{ .entry = null, .base_address = 0, .pic = true, .dynamic = &dynamic };
    const bytes = try emit(gpa, io, &atoms, options);
    defer gpa.free(bytes);
    try std.testing.expectEqual(elf.ET.DYN, @as(elf.ET, @fromBackingInt(@intCast(std.mem.readInt(u16, bytes[16..18], .little)))));

    // Numbers: the atoms in order, then g, __tls_get_addr, and _DYNAMIC.
    const numbering = [_]SymbolKey{ f, tv, ptrs, table, g, get_addr, ElfDynamic.dynamic_key };
    var numbered_atoms: [atoms.len]NumberedAtom = undefined;
    var targets: std.ArrayList(u32) = .empty;
    defer targets.deinit(gpa);
    for (atoms, &numbered_atoms, 0..) |a, *n, i| {
        n.* = .{ .symbol = @intCast(i), .targets = @intCast(targets.items.len) };
        for (a.targets) |t| try targets.append(gpa, @intCast(std.mem.findScalar(SymbolKey, &numbering, t).?));
    }
    var symbols: Symbols = .{
        .atoms = &numbered_atoms,
        .targets = targets.items,
        .dynamic_imports = &.{ 4, 5 },
        .dynamic_exports = &.{ 1, 0, 0 },
        .dynamic = 6,
        .entry = 0,
        .len = numbering.len,
    };
    var numbered_options = options;
    numbered_options.symbols = symbols;
    const numbered = try emit(gpa, io, &atoms, numbered_options);
    defer gpa.free(numbered);
    try std.testing.expectEqualSlices(u8, bytes, numbered);
    // The same at a nonzero base: numbered addresses are offsets from it.
    var based_options = options;
    based_options.base_address = 0x1000000;
    const based = try emit(gpa, io, &atoms, based_options);
    defer gpa.free(based);
    try std.testing.expect(!std.mem.eql(u8, bytes, based));
    based_options.symbols = symbols;
    const based_numbered = try emit(gpa, io, &atoms, based_options);
    defer gpa.free(based_numbered);
    try std.testing.expectEqualSlices(u8, based, based_numbered);

    // An export's number must be an atom's.
    var diag: Diagnostic = .{};
    symbols.dynamic_exports = &.{ 1, 4, 0 };
    numbered_options.symbols = symbols;
    numbered_options.diag = &diag;
    try std.testing.expectError(error.UndefinedSymbol, emit(gpa, io, &atoms, numbered_options));
    try std.testing.expectEqualStrings("f", diag.atom);
}

test "a dynamically linked executable links the same with numbered symbols and runs" {
    if (builtin.cpu.arch != .x86_64 or builtin.os.tag != .linux) return error.SkipZigTest;
    // Only where glibc's loader is (as `-lc` executables need).
    std.Io.Dir.cwd().access(std.testing.io, "/lib64/ld-linux-x86-64.so.2", .{}) catch return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const start: SymbolKey = .fromName("_start");
    const msg: SymbolKey = .fromName("msg");
    const puts: SymbolKey = .fromName("import.puts");
    const exit: SymbolKey = .fromName("import.exit");
    const puts_slot: SymbolKey = .fromName("extern.puts");
    const exit_slot: SymbolKey = .fromName("extern.exit");
    const own: SymbolKey = .fromName("own");
    // `lea rdi, [rip + msg]; call [rip + puts]; mov edi, 42; call [rip +
    // exit]`, through the imports' slots, as Zig code calls externs.
    const code = "\x48\x8d\x3d\x00\x00\x00\x00" ++ "\xff\x15\x00\x00\x00\x00" ++ "\xbf\x2a\x00\x00\x00" ++ "\xff\x15\x00\x00\x00\x00";
    const zeros: [8]u8 = @splat(0);
    const atoms = [_]Atom{
        .{ .key = start, .name = "_start", .section = .text, .bytes = code, .targets = &.{ msg, puts_slot, exit_slot }, .relocs = &.{
            .init(3, .x86_64_pc32, 0, -4),
            .init(9, .x86_64_pc32, 1, -4),
            .init(20, .x86_64_pc32, 2, -4),
        } },
        .{ .key = msg, .name = "msg", .section = .rodata, .bytes = "hi from ld.so\x00" },
        // The slots, in .rodata, move to .data.rel.ro for the loader.
        .{ .key = puts_slot, .name = "extern.puts", .section = .rodata, .alignment = .@"8", .bytes = &zeros, .targets = &.{puts}, .relocs = &.{.init(0, .x86_64_abs64, 0, 0)} },
        .{ .key = exit_slot, .name = "extern.exit", .section = .rodata, .alignment = .@"8", .bytes = &zeros, .targets = &.{exit}, .relocs = &.{.init(0, .x86_64_abs64, 0, 0)} },
        // An address of the image's own stays static.
        .{ .key = own, .name = "own", .section = .data, .alignment = .@"8", .bytes = &zeros, .targets = &.{msg}, .relocs = &.{.init(0, .x86_64_abs64, 0, 0)} },
    };
    const dynamic: ElfDynamic.Options = .{
        .imports = &.{
            .{ .key = exit, .name = "exit", .version = "GLIBC_2.2.5", .library = 0 },
            .{ .key = puts, .name = "puts", .version = "GLIBC_2.2.5", .library = 0 },
        },
        .interp = "/lib64/ld-linux-x86-64.so.2",
        .needed = &.{"libc.so.6"},
    };
    const options: Options = .{ .entry = start, .dynamic = &dynamic };
    const bytes = try emit(gpa, io, &atoms, options);
    defer gpa.free(bytes);
    try std.testing.expectEqual(elf.ET.EXEC, @as(elf.ET, @fromBackingInt(@intCast(std.mem.readInt(u16, bytes[16..18], .little)))));

    // Numbers: the atoms in order, then exit and puts.
    const numbering = [_]SymbolKey{ start, msg, puts_slot, exit_slot, own, exit, puts };
    var numbered_atoms: [atoms.len]NumberedAtom = undefined;
    var targets: std.ArrayList(u32) = .empty;
    defer targets.deinit(gpa);
    for (atoms, &numbered_atoms, 0..) |a, *n, i| {
        n.* = .{ .symbol = @intCast(i), .targets = @intCast(targets.items.len) };
        for (a.targets) |t| try targets.append(gpa, @intCast(std.mem.findScalar(SymbolKey, &numbering, t).?));
    }
    var numbered_options = options;
    numbered_options.symbols = .{
        .atoms = &numbered_atoms,
        .targets = targets.items,
        .dynamic_imports = &.{ 5, 6 },
        .entry = 0,
        .len = numbering.len,
    };
    const numbered = try emit(gpa, io, &atoms, numbered_options);
    defer gpa.free(numbered);
    try std.testing.expectEqualSlices(u8, bytes, numbered);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "dyn", .data = numbered, .flags = .{ .permissions = .executable_file } });
    const path = try gpa.print(".zig-cache/tmp/{s}/dyn", .{tmp.sub_path});
    defer gpa.free(path);
    const result = try std.process.run(gpa, io, .{ .argv = &.{path} });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqualStrings("hi from ld.so\n", result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 42 }, result.term);
}

test "an alias links as a reference to its target, with numbered symbols too" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const start: SymbolKey = .fromName("_start");
    const msg: SymbolKey = .fromName("msg");
    const puts: SymbolKey = .fromName("import.puts");
    const v: SymbolKey = .fromName("value");
    const msg_alias: SymbolKey = .fromName("extaddr.msg");
    const puts_alias: SymbolKey = .fromName("extaddr.puts");
    const v_alias: SymbolKey = .fromName("extaddr.value");
    const zeros: [24]u8 = @splat(0);
    // A constant holding an address inside `msg`, an import's address
    // (a symbol relocation for the loader), and a value: through aliases,
    // then directly.
    const via: []const SymbolKey = &.{ msg_alias, puts_alias, v_alias };
    const direct: []const SymbolKey = &.{ msg, puts, v };
    const relocs = [2][3]Atom.Reloc{
        .{ .init(0, .x86_64_abs64, 0, 1), .init(8, .x86_64_abs64, 1, 0), .init(16, .x86_64_abs64, 2, 0) },
        .{ .init(0, .x86_64_abs64, 0, 4), .init(8, .x86_64_abs64, 1, 0), .init(16, .x86_64_abs64, 2, 0) },
    };
    var atoms: [2][3]Atom = undefined;
    for (&atoms, [_][]const SymbolKey{ via, direct }, &relocs) |*set, targets, *set_relocs| set.* = .{
        .{ .key = start, .name = "_start", .section = .text, .bytes = "\xcc" },
        .{ .key = msg, .name = "msg", .section = .rodata, .bytes = "hi from ld.so\x00" },
        .{ .key = .fromName("table"), .name = "table", .section = .rodata, .alignment = .@"8", .bytes = &zeros, .targets = targets, .relocs = set_relocs },
    };
    const dynamic: ElfDynamic.Options = .{
        .imports = &.{.{ .key = puts, .name = "puts", .version = "GLIBC_2.2.5", .library = 0 }},
        .interp = "/lib64/ld-linux-x86-64.so.2",
        .needed = &.{"libc.so.6"},
    };
    const aliases = [_]Alias{
        .{ .key = msg_alias, .target = msg, .addend = 3 },
        .{ .key = puts_alias, .target = puts, .addend = 0 },
        .{ .key = v_alias, .target = v, .addend = 0 },
    };
    const values = [_]Value{.{ .key = v, .value = 5 }};
    const want = try emit(gpa, io, &atoms[1], .{ .entry = start, .dynamic = &dynamic, .values = &values });
    defer gpa.free(want);
    const got = try emit(gpa, io, &atoms[0], .{ .entry = start, .dynamic = &dynamic, .values = &values, .aliases = &aliases });
    defer gpa.free(got);
    try std.testing.expectEqualSlices(u8, want, got);

    // Numbers: the atoms, the import, the value, then the aliases.
    const numbering = [_]SymbolKey{ start, msg, .fromName("table"), puts, v, msg_alias, puts_alias, v_alias };
    var numbered_atoms: [3]NumberedAtom = undefined;
    var targets: std.ArrayList(u32) = .empty;
    defer targets.deinit(gpa);
    for (atoms[0], &numbered_atoms, 0..) |a, *n, i| {
        n.* = .{ .symbol = @intCast(i), .targets = @intCast(targets.items.len) };
        for (a.targets) |t| try targets.append(gpa, @intCast(std.mem.findScalar(SymbolKey, &numbering, t).?));
    }
    const numbered = try emit(gpa, io, &atoms[0], .{ .entry = start, .dynamic = &dynamic, .aliases = &aliases, .symbols = .{
        .atoms = &numbered_atoms,
        .targets = targets.items,
        .values = &.{.{ .symbol = 4, .value = 5 }},
        .dynamic_imports = &.{3},
        .aliases = &.{ .{ .symbol = 5, .target = 1 }, .{ .symbol = 6, .target = 3 }, .{ .symbol = 7, .target = 4 } },
        .entry = 0,
        .len = numbering.len,
    } });
    defer gpa.free(numbered);
    try std.testing.expectEqualSlices(u8, want, numbered);

    // An import's address cannot be moved, and an alias needs a target.
    var moved = aliases;
    moved[1].addend = 8;
    try std.testing.expectError(error.InvalidRelocation, emit(gpa, io, &atoms[0], .{ .entry = start, .dynamic = &dynamic, .values = &values, .aliases = &moved }));
    var dangling = aliases;
    dangling[0].target = .fromName("nothing");
    try std.testing.expectError(error.UndefinedSymbol, emit(gpa, io, &atoms[0], .{ .entry = start, .dynamic = &dynamic, .values = &values, .aliases = &dangling }));
}

test "thread-locals in .tdata and .tbss read back after static TLS setup" {
    if (builtin.cpu.arch != .x86_64 or builtin.os.tag != .linux) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
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
    // PT_PHDR comes first and lies in the first, read-only PT_LOAD, as
    // upstream's: std.posix.dl_iterate_phdr finds the load bias from it.
    try std.testing.expectEqual(elf.PT.PHDR, phdrs[0].type);
    try std.testing.expectEqual(0x40, phdrs[0].offset);
    try std.testing.expectEqual(@as(u64, @intCast(base)) + 0x40, phdrs[0].vaddr);
    try std.testing.expectEqual(ehdr.phnum * @sizeOf(elf.Elf64.Phdr), phdrs[0].filesz);
    try std.testing.expectEqual(phdrs[0].filesz, phdrs[0].memsz);
    try std.testing.expectEqual(8, phdrs[0].@"align");
    try std.testing.expect(phdrs[1].type == .LOAD and phdrs[1].offset == 0 and phdrs[1].filesz >= phdrs[0].offset + phdrs[0].filesz);
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
    // .tbss takes no room: .data starts after .tdata, at 24, within
    // .tbss's addresses, and the RW segment holds no zeros for it.
    try std.testing.expectEqual(rw.?.vaddr + 24, testSymbolAddr(bytes, "counter").?);
    try std.testing.expectEqual(rw.?.filesz, 24 + 8);
    // The first lea's displacement: a's offset minus 96.
    const lea_a = std.mem.find(u8, e.code.items, &.{ 0x48, 0x8d, 0x80 }).? + 3;
    const text_off = ehdr.entry - @as(u64, @intCast(base));
    try std.testing.expectEqual(-96, std.mem.readInt(i32, bytes[text_off + lea_a ..][0..4], .little));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try link(gpa, io, tmp.dir, "tls", &atoms, .{ .entry = start });
    const path = try gpa.print(".zig-cache/tmp/{s}/tls", .{tmp.sub_path});
    defer gpa.free(path);
    const result = try std.process.run(gpa, io, .{ .argv = &.{path} });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 42 }, result.term);

    // A TLS relocation to a symbol that is not thread-local. (One whose
    // address lies among .tbss's, which later sections overlap, passes.)
    var diag: Diagnostic = .{};
    var bad = atoms;
    var be: Encoder = .init(arena);
    try be.leaThreadLocal(.rax, start);
    be.finish();
    bad[0] = .{ .key = start, .name = "_start", .section = .text, .bytes = be.code.items, .targets = be.refs.targets.keys(), .relocs = be.refs.relocs.items };
    try std.testing.expectError(error.InvalidRelocation, emit(gpa, io, &bad, .{ .entry = start, .diag = &diag }));
    try std.testing.expectEqual(start, diag.target.?);
}

test "links many chunks of atoms the same way on any number of threads" {
    if (builtin.cpu.arch != .x86_64 or builtin.os.tag != .linux) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
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
            return .fromName(std.mem.print(&buf, "f{d}", .{i}) catch unreachable);
        }
    }.f;

    var atoms: std.ArrayList(Atom) = .empty;
    var debug: std.ArrayList(Atom.Debug) = .empty;
    var expected: u32 = 0;
    const files = [_][]const u8{ "a.zig", "dir/b.zig", "/abs/c.zig", "dir/d.zig" };
    // Units are named after their root files; "" is the unit of the
    // first file.
    const units = [_][]const u8{ "src/root.zig", "/zig/lib/std/std.zig", "" };
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
        // Files change every 1000 functions, so chunks share some, and
        // units every 300, so units have several ranges in a chunk and
        // span chunks.
        const name = try arena.print("f{d}", .{i});
        try debug.append(arena, .{ .atom = @intCast(atoms.items.len), .file = files[i / 1000 % files.len], .name = name, .base_line = @intCast(i), .lines = e.lines.bytes.items, .unit = units[i / 300 % units.len] });
        try atoms.append(arena, .{ .key = fkey(i), .name = name, .section = .text, .alignment = alignments[i % 3], .bytes = e.code.items, .targets = e.refs.targets.keys(), .relocs = e.refs.relocs.items, .unwind = .frame_pointer });
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
        const name = try arena.print("f{d}", .{index});
        const addr = testSymbolAddr(one, name).?;
        const loc = try testSymbolize(di, arena, addr + 7);
        try std.testing.expectEqualStrings(name, loc.name);
        const unit = units[index / 300 % units.len];
        try std.testing.expectEqualStrings(if (unit.len > 0) std.Io.Dir.path.basenamePosix(unit) else files[0], loc.unit);
        try std.testing.expectEqual(index + 2, loc.line);
        try std.testing.expectEqual(5, loc.column);
        const file = files[index / 1000 % files.len];
        if (file[0] == '/') {
            try std.testing.expectEqualStrings(file, loc.file);
        } else {
            try std.testing.expectEqualStrings(try arena.print("/w/{s}", .{file}), loc.file);
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
    const path = try gpa.print(".zig-cache/tmp/{s}/chunks", .{tmp.sub_path});
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
        .{ .key = key, .name = "root:f", .section = .text, .alignment = .@"16", .bytes = &code, .unwind = .frame_pointer },
        .{ .key = .fromName("g"), .name = "root:g", .section = .text, .bytes = &.{0xc3} },
        .{ .key = .fromName("g"), .name = "root:g", .section = .text, .bytes = &.{0xc3} },
    };
    const debug = [_]Atom.Debug{
        .{ .atom = 1, .file = "src/f.zig", .name = "f", .base_line = 1000, .lines = lp.bytes.items },
        .{ .atom = 2, .file = "g.zig", .name = "g", .base_line = 0, .lines = &.{} },
        // The duplicate's entry goes with it.
        .{ .atom = 3, .file = "g.zig", .name = "g again", .base_line = 0, .lines = &.{} },
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
    // Subprogram entries carry the atom's name as DW_AT_linkage_name,
    // after DW_AT_name.
    const info_sh = testSection(out, ".debug_info").?;
    try std.testing.expect(std.mem.find(u8, out[info_sh.offset..][0..info_sh.size], "f\x00root:f\x00") != null);
    // Every symbol is local, as upstream writes them: names can repeat.
    const symtab = testSection(out, ".symtab").?;
    try std.testing.expectEqual(symtab.size / @sizeOf(elf.Elf64.Sym), symtab.info);
    for (std.mem.bytesAsSlice(elf.Elf64.Sym, out[symtab.offset..][0..symtab.size])) |sym| try std.testing.expectEqual(elf.STB.LOCAL, sym.info.bind);

    try std.testing.expectError(error.InvalidDebugInfo, emit(gpa, io, &atoms, .{ .entry = key, .debug = &.{ debug[1], debug[0] } }));

    // Units and inline calls. `main` (unit src/main.zig) inlines
    // `callMain` from start.zig at offsets 8..40, which inlines `inner`
    // from mem.zig at 16..24; `g` is in unit /zig/std/std.zig, and `k` in
    // src/main.zig again. As upstream's traces print them, an address
    // takes the name of its innermost inline call and the line of the
    // inlined code.
    var mp: Atom.LineProgram = .{};
    try mp.addRow(arena, 0, 0, 0); // main.zig:11:1
    try mp.addRow(arena, 4, 2, 4); // main.zig:13:5
    try mp.switchTo(arena, 1, 1);
    try mp.addRow(arena, 8, 88, 63); // start.zig:789:64
    try mp.switchTo(arena, 2, 2);
    try mp.addRow(arena, 16, 5, 8); // mem.zig:56:9
    try mp.switchTo(arena, 1, 1);
    try mp.addRow(arena, 24, 89, 4); // start.zig:790:5
    try mp.switchTo(arena, 0, 0);
    try mp.addRow(arena, 40, 4, 4); // main.zig:15:5
    const inlines = [_]Atom.Debug.Inline{
        .{ .name_off = 0, .name_len = 8, .file = 1, .base_line = 700, .call_line = 2, .call_column = 4, .low = 8, .high = 40, .parent = Atom.Debug.Inline.none },
        .{ .name_off = 8, .name_len = 5, .file = 2, .base_line = 50, .call_line = 88, .call_column = 62, .low = 16, .high = 24, .parent = 0 },
    };
    const code64: [64]u8 = @splat(0xcc);
    const main_key: SymbolKey = .fromName("main");
    const atoms2 = [_]Atom{
        .{ .key = .fromName("no debug"), .name = "h", .section = .text, .bytes = &.{ 0xc3, 0xc3, 0xc3 } },
        .{ .key = main_key, .name = "main", .section = .text, .alignment = .@"16", .bytes = &code64, .unwind = .frame_pointer },
        .{ .key = .fromName("g"), .name = "g", .section = .text, .bytes = &.{0xc3} },
        .{ .key = .fromName("k"), .name = "k", .section = .text, .bytes = &.{0xc3} },
    };
    const debug2 = [_]Atom.Debug{
        .{ .atom = 1, .file = "src/main.zig", .name = "main", .base_line = 10, .lines = mp.bytes.items, .unit = "src/main.zig", .files = "/zig/std/start.zig\x00/zig/std/mem.zig\x00", .inlines = &inlines, .inline_names = "callMaininner", .patches = mp.patches.items },
        .{ .atom = 2, .file = "/zig/std/start.zig", .name = "g", .base_line = 0, .lines = &.{Atom.LineProgram.opcode_base - Atom.LineProgram.line_base}, .unit = "/zig/std/std.zig" },
        .{ .atom = 3, .file = "src/main.zig", .name = "k", .base_line = 30, .lines = &.{}, .unit = "src/main.zig" },
    };
    const out2 = try emit(gpa, io, &atoms2, .{ .entry = main_key, .debug = &debug2, .comp_dir = "/work" });
    defer gpa.free(out2);
    var ef2 = try testElfFile(io, out2);
    defer ef2.deinit(std.debug.getDebugInfoAllocator());
    const di2 = &ef2.dwarf.?;
    const main_addr = testSymbolAddr(out2, "main").?;
    const expected2 = [_]struct { offset: u32, name: []const u8, file: []const u8, line: u64, column: u64 }{
        .{ .offset = 4, .name = "main", .file = "/work/src/main.zig", .line = 13, .column = 5 },
        .{ .offset = 10, .name = "callMain", .file = "/zig/std/start.zig", .line = 789, .column = 64 },
        .{ .offset = 18, .name = "inner", .file = "/zig/std/mem.zig", .line = 56, .column = 9 },
        .{ .offset = 30, .name = "callMain", .file = "/zig/std/start.zig", .line = 790, .column = 5 },
        .{ .offset = 50, .name = "main", .file = "/work/src/main.zig", .line = 15, .column = 5 },
    };
    for (expected2) |e| {
        const loc = try testSymbolize(di2, arena, main_addr + e.offset);
        try std.testing.expectEqualStrings(e.name, loc.name);
        try std.testing.expectEqualStrings("main.zig", loc.unit);
        try std.testing.expectEqualStrings(e.file, loc.file);
        try std.testing.expectEqual(e.line, loc.line);
        try std.testing.expectEqual(e.column, loc.column);
    }
    // Each unit is named after its root file, in that file's directory,
    // with a line program of its own files and functions.
    const g2 = try testSymbolize(di2, arena, testSymbolAddr(out2, "g").?);
    try std.testing.expectEqualStrings("std.zig", g2.unit);
    try std.testing.expectEqualStrings("/zig/std/start.zig", g2.file);
    try std.testing.expectEqual(1, g2.line);
    try std.testing.expectEqualStrings("main.zig", (try testSymbolize(di2, arena, testSymbolAddr(out2, "k").?)).unit);
    const cus = try testUnits(arena, out2);
    try std.testing.expectEqual(2, cus.len);
    try std.testing.expectEqualStrings("main.zig", cus[0].name);
    try std.testing.expectEqualStrings("/work/src", cus[0].dir);
    try std.testing.expectEqualStrings("std.zig", cus[1].name);
    try std.testing.expectEqualStrings("/zig/std", cus[1].dir);
    try std.testing.expect(cus[0].stmt_list != cus[1].stmt_list);
    // Code before the first function with debug info is in no unit.
    var no_unit: std.ArrayList(std.debug.Symbol) = .empty;
    try std.testing.expectError(error.MissingDebugInfo, di2.getSymbols(arena, arena, .little, testSymbolAddr(out2, "h").?, false, &no_unit));
    // Malformed inline calls and patches are rejected.
    for ([_]Atom.Debug{
        .{ .atom = 1, .file = "m.zig", .name = "m", .base_line = 0, .lines = mp.bytes.items, .files = debug2[0].files, .inlines = &.{ inlines[1], inlines[0] }, .inline_names = debug2[0].inline_names, .patches = mp.patches.items },
        .{ .atom = 1, .file = "m.zig", .name = "m", .base_line = 0, .lines = mp.bytes.items, .files = debug2[0].files, .inlines = &inlines, .inline_names = debug2[0].inline_names, .patches = &.{1} },
        .{ .atom = 1, .file = "m.zig", .name = "m", .base_line = 0, .lines = mp.bytes.items, .files = "/zig/std/start.zig\x00", .inlines = &inlines, .inline_names = debug2[0].inline_names, .patches = mp.patches.items },
        .{ .atom = 1, .file = "m.zig", .name = "m", .base_line = 0, .lines = mp.bytes.items, .files = debug2[0].files, .inlines = inlines[0..1], .inline_names = debug2[0].inline_names, .patches = mp.patches.items },
        // Paths must end with a 0 byte, and names must be in `inline_names`.
        .{ .atom = 1, .file = "m.zig", .name = "m", .base_line = 0, .lines = mp.bytes.items, .files = debug2[0].files[0 .. debug2[0].files.len - 1], .inlines = &inlines, .inline_names = debug2[0].inline_names, .patches = mp.patches.items },
        .{ .atom = 1, .file = "m.zig", .name = "m", .base_line = 0, .lines = mp.bytes.items, .files = debug2[0].files, .inlines = &inlines, .inline_names = "callMain", .patches = mp.patches.items },
    }) |bad| try std.testing.expectError(error.InvalidDebugInfo, emit(gpa, io, &atoms2, .{ .entry = main_key, .debug = &.{bad} }));

    const stripped = try emit(gpa, io, &atoms, .{ .entry = key });
    defer gpa.free(stripped);
    try std.testing.expect(std.mem.find(u8, stripped, ".debug_") == null);
    try std.testing.expect(std.mem.find(u8, stripped, ".eh_frame") == null);
}

test "input sections follow bs's parts, relocated, and their FDEs join the sorted search table" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const code: [16]u8 = @splat(0xcc);
    const f: SymbolKey = .fromName("f");
    const c: SymbolKey = .fromName("c");
    // A C function between two of bs's, whose search table entry must
    // land between theirs.
    const atoms = [_]Atom{
        .{ .key = f, .name = "f", .section = .text, .alignment = .@"16", .bytes = &code, .unwind = .frame_pointer },
        .{ .key = c, .name = "c", .section = .text, .alignment = .@"16", .bytes = &code },
        .{ .key = .fromName("g"), .name = "g", .section = .text, .alignment = .@"16", .bytes = &code, .unwind = .frame_pointer },
    };
    const debug = [_]Atom.Debug{
        .{ .atom = 0, .file = "a.zig", .name = "f", .base_line = 0, .lines = &.{} },
        .{ .atom = 2, .file = "a.zig", .name = "g", .base_line = 0, .lines = &.{} },
    };
    // A CIE (version 1, "zR", pcrel sdata4) and an FDE for `c`.
    const eh = [_]u8{ 0x14, 0, 0, 0, 0, 0, 0, 0, 1, 'z', 'R', 0, 1, 0x78, 0x10, 1, 0x1b, 0x0c, 0x07, 0x08, 0x90, 0x01, 0, 0 } ++
        [_]u8{ 0x10, 0, 0, 0, 0x1c, 0, 0, 0, 0, 0, 0, 0, 16, 0, 0, 0, 0, 0, 0, 0 };
    const info: [12]u8 = @splat(0xaa);
    const inputs = [_]InputSection{
        .{ .kind = .eh_frame, .name = "c.o", .bytes = &eh, .targets = &.{c}, .relocs = &.{.{ .offset = 32, .target = 0, .addend = 0, .kind = .pc32 }} },
        .{ .kind = .debug_str, .name = "c.o", .bytes = "c.c\x00c\x00" },
        .{ .kind = .debug_info, .name = "c.o", .bytes = &info, .targets = &.{c}, .relocs = &.{
            .{ .offset = 0, .target = 1, .addend = 4, .kind = .offset32 },
            .{ .offset = 4, .target = 0, .addend = 2, .kind = .abs64 },
        } },
        .{ .kind = .debug_ranges, .name = "c.o", .bytes = &(@as([8]u8, @splat(0xbb)) ++ @as([8]u8, @splat(0))), .relocs = &.{.{ .offset = 0, .target = 0, .addend = 1, .kind = .const64 }} },
    };
    const out = try emit(gpa, io, &atoms, .{ .entry = f, .debug = &debug, .input_sections = &inputs });
    defer gpa.free(out);
    const text = testSectionAddr(out, ".text");

    // bs's CIE and two FDEs, then the input records, then the terminator.
    const eh_sh = testSection(out, ".eh_frame").?;
    try std.testing.expectEqual(Dwarf.cie.len + 2 * Dwarf.fde_size + eh.len + 4, eh_sh.size);
    const fde_off = eh_sh.offset + Dwarf.cie.len + 2 * Dwarf.fde_size + 24;
    try std.testing.expectEqual(text + 16, eh_sh.addr + (fde_off - eh_sh.offset) + 8 + @as(u64, @bitCast(@as(i64, std.mem.readInt(i32, out[fde_off + 8 ..][0..4], .little)))));
    const hdr = testSection(out, ".eh_frame_hdr").?;
    try std.testing.expectEqual(3, std.mem.readInt(u32, out[hdr.offset + 8 ..][0..4], .little));
    for ([_]u64{ text, text + 16, text + 32 }, 0..) |pc, i| {
        const entry = out[hdr.offset + Dwarf.eh_frame_hdr_size + 8 * i ..][0..8];
        try std.testing.expectEqual(pc, hdr.addr +% @as(u64, @bitCast(@as(i64, std.mem.readInt(i32, entry[0..4], .little)))));
        if (pc == text + 16) try std.testing.expectEqual(eh_sh.addr + (fde_off - eh_sh.offset), hdr.addr +% @as(u64, @bitCast(@as(i64, std.mem.readInt(i32, entry[4..8], .little)))));
    }

    // Each debug section: bs's part, then the input's, relocated.
    const str_sh = testSection(out, ".debug_str").?;
    try std.testing.expectEqual(Dwarf.str.len + 6, str_sh.size);
    try std.testing.expectEqualStrings("c.c\x00c\x00", out[str_sh.offset + Dwarf.str.len ..][0..6]);
    const info_sh = testSection(out, ".debug_info").?;
    const in_info = out[info_sh.offset + info_sh.size - info.len ..][0..info.len];
    try std.testing.expectEqual(Dwarf.str.len + 4, std.mem.readInt(u32, in_info[0..4], .little));
    try std.testing.expectEqual(text + 16 + 2, std.mem.readInt(u64, in_info[4..12], .little));
    // A section bs does not write gets a header and a name.
    const ranges_sh = testSection(out, ".debug_ranges").?;
    try std.testing.expectEqual(16, ranges_sh.size);
    try std.testing.expectEqual(1, std.mem.readInt(u64, out[ranges_sh.offset..][0..8], .little));
    // An FDE without its initial location's relocation is malformed.
    var bad = inputs;
    bad[0].relocs = &.{};
    try std.testing.expectError(error.InvalidInput, emit(gpa, io, &atoms, .{ .entry = f, .debug = &debug, .input_sections = &bad }));
}

test "std.debug unwinds frame-pointer frames through .eh_frame_hdr and stops at the outermost frame" {
    if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    const gpa = std.debug.getDebugInfoAllocator();
    const io = std.testing.io;
    const code: [64]u8 = @splat(0xcc);
    const key: SymbolKey = .fromName("f");
    const atoms = [_]Atom{
        .{ .key = .fromName("no debug"), .name = "h", .section = .text, .bytes = &.{ 0xc3, 0xc3, 0xc3 } },
        .{ .key = key, .name = "f", .section = .text, .alignment = .@"16", .bytes = &code, .unwind = .frame_pointer },
        .{ .key = .fromName("naked"), .name = "naked", .section = .text, .bytes = &.{ 0xcc, 0xcc } },
        .{ .key = .fromName("f"), .name = "f", .section = .text, .alignment = .@"16", .bytes = &code, .unwind = .frame_pointer },
        // Saves rbx, r13, and r15: `push rbx` at 4, `push r13` at 5, and
        // `push r15` at 7, after `push rbp; mov rbp, rsp`; ends with its
        // epilogue's `ret`.
        .{ .key = .fromName("g"), .name = "g", .section = .text, .alignment = .@"16", .bytes = &code, .unwind = .{ .kind = .frame_pointer, .epilogue = 1, .saved = 0x15 } },
        .{ .key = .fromName("_start"), .name = "_start", .section = .text, .alignment = .@"16", .bytes = &code, .unwind = .outermost },
        // Saves rbx and r12 (prologue ends at 7); its `ret` is at 40, then
        // frameless stubs until 50, then 14 bytes of stack probes.
        .{ .key = .fromName("k"), .name = "k", .section = .text, .alignment = .@"16", .bytes = &code, .unwind = .{ .kind = .frame_pointer, .epilogue = 24, .probes = 14, .saved = 0x3 } },
    };
    const debug = [_]Atom.Debug{
        .{ .atom = 1, .file = "a.zig", .name = "f", .base_line = 0, .lines = &.{} },
        .{ .atom = 2, .file = "a.zig", .name = "naked", .base_line = 0, .lines = &.{} },
        .{ .atom = 3, .file = "a.zig", .name = "f", .base_line = 0, .lines = &.{} },
        .{ .atom = 4, .file = "a.zig", .name = "g", .base_line = 0, .lines = &.{} },
        .{ .atom = 5, .file = "a.zig", .name = "_start", .base_line = 0, .lines = &.{} },
        .{ .atom = 6, .file = "a.zig", .name = "k", .base_line = 0, .lines = &.{} },
    };
    const out = try emit(gpa, io, &atoms, .{ .entry = key, .debug = &debug });
    defer gpa.free(out);
    const text = testSectionAddr(out, ".text");
    const f = text + 16;
    const naked = f + code.len;
    const g = text + 96;
    const start = g + code.len;
    const k = start + code.len;
    // Four FDEs, g's with its three saved registers and its epilogue, k's
    // with its stubs' and probes' rows; the duplicate and the naked
    // function leave their room unused.
    try std.testing.expectEqual(40, Dwarf.fdeSize(.x86_64, atoms[4].unwind, code.len));
    try std.testing.expectEqual(48, Dwarf.fdeSize(.x86_64, atoms[6].unwind, code.len));
    try std.testing.expectEqual(Dwarf.cie.len + 2 * Dwarf.fde_size + 40 + 48 + 4, testSection(out, ".eh_frame").?.size);
    try std.testing.expectEqual(Dwarf.eh_frame_hdr_size + 4 * Dwarf.eh_frame_hdr_entry_size, testSection(out, ".eh_frame_hdr").?.size);

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
    try std.testing.expectEqual(4, header.search_table.?.fde_count);
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
        // g's saved registers, each from the end of its push: below the
        // saved rbp, rbx, r13, then r15.
        var g_stack: [6]u64 = .{ 0xf15, 0xf13, 0xfb, 0x1111, 0x2222, 0 };
        const g_cases = [_]struct { pc: u64, rbx: u64, r13: u64, r15: u64 }{
            .{ .pc = g + 4, .rbx = 0xb, .r13 = 0x13, .r15 = 0x15 },
            .{ .pc = g + 5, .rbx = 0xfb, .r13 = 0x13, .r15 = 0x15 },
            .{ .pc = g + 6, .rbx = 0xfb, .r13 = 0x13, .r15 = 0x15 },
            .{ .pc = g + 7, .rbx = 0xfb, .r13 = 0xf13, .r15 = 0x15 },
            .{ .pc = g + 9, .rbx = 0xfb, .r13 = 0xf13, .r15 = 0xf15 },
            .{ .pc = g + code.len - 2, .rbx = 0xfb, .r13 = 0xf13, .r15 = 0xf15 },
        };
        for (g_cases) |c| {
            var ctx: std.debug.cpu_context.Native = .{ .gprs = .initFill(0) };
            ctx.gprs.set(.rip, c.pc);
            ctx.gprs.set(.rsp, at(&g_stack, 0));
            ctx.gprs.set(.rbp, at(&g_stack, 3));
            ctx.gprs.set(.rbx, 0xb);
            ctx.gprs.set(.r13, 0x13);
            ctx.gprs.set(.r15, 0x15);
            var unwinder: std.debug.Dwarf.SelfUnwinder = .init(&ctx);
            defer unwinder.deinit();
            const rules = try unwinder.computeRules(gpa, &unwind, 0, null);
            try std.testing.expectEqual(0x2222, try unwinder.next(gpa, &rules));
            try std.testing.expectEqual(at(&g_stack, 5), unwinder.cpu_state.gprs.get(.rsp));
            try std.testing.expectEqual(0x1111, unwinder.cpu_state.gprs.get(.rbp));
            try std.testing.expectEqual(c.rbx, unwinder.cpu_state.gprs.get(.rbx));
            try std.testing.expectEqual(c.r13, unwinder.cpu_state.gprs.get(.r13));
            try std.testing.expectEqual(c.r15, unwinder.cpu_state.gprs.get(.r15));
        }
        // At g's `ret`, after the epilogue's pops: the CFA is rsp + 8, and
        // the registers' slots below rsp still hold their values.
        {
            var ctx: std.debug.cpu_context.Native = .{ .gprs = .initFill(0) };
            ctx.gprs.set(.rip, g + code.len - 1);
            ctx.gprs.set(.rsp, at(&g_stack, 4));
            ctx.gprs.set(.rbp, 0x1111);
            var unwinder: std.debug.Dwarf.SelfUnwinder = .init(&ctx);
            defer unwinder.deinit();
            const rules = try unwinder.computeRules(gpa, &unwind, 0, null);
            try std.testing.expectEqual(0x2222, try unwinder.next(gpa, &rules));
            try std.testing.expectEqual(at(&g_stack, 5), unwinder.cpu_state.gprs.get(.rsp));
            try std.testing.expectEqual(0x1111, unwinder.cpu_state.gprs.get(.rbp));
            try std.testing.expectEqual(0xfb, unwinder.cpu_state.gprs.get(.rbx));
            try std.testing.expectEqual(0xf13, unwinder.cpu_state.gprs.get(.r13));
            try std.testing.expectEqual(0xf15, unwinder.cpu_state.gprs.get(.r15));
        }
        // k: in the body and its probes, the saved registers are in their
        // slots; at its `ret` too, just below rsp; in a stub, rsp is deeper
        // and they hold the frame's own values (rbp the frame's, not its
        // caller's), which unwinding a stub must keep.
        var k_stack: [6]u64 = .{ 0xfc, 0xfb, 0x1111, 0x2222, 0, 0 };
        var stub_stack: [8]u64 = .{ 0x3333, 0xdead, 0xdead, 0xdead, 0xdead, 0xdead, 0xdead, 0xdead };
        const k_cases = [_]struct { pc: u64, rsp: u64, rbp: u64, ra: u64, new_rsp: u64, new_rbp: u64, rbx: u64, r12: u64 }{
            .{ .pc = k + 20, .rsp = at(&k_stack, 0), .rbp = at(&k_stack, 2), .ra = 0x2222, .new_rsp = at(&k_stack, 4), .new_rbp = 0x1111, .rbx = 0xfb, .r12 = 0xfc },
            .{ .pc = k + 40, .rsp = at(&k_stack, 3), .rbp = 0x1111, .ra = 0x2222, .new_rsp = at(&k_stack, 4), .new_rbp = 0x1111, .rbx = 0xfb, .r12 = 0xfc },
            .{ .pc = k + 41, .rsp = @intFromPtr(&stub_stack), .rbp = at(&k_stack, 2), .ra = 0x3333, .new_rsp = @intFromPtr(&stub_stack[1]), .new_rbp = at(&k_stack, 2), .rbx = 0xb, .r12 = 0xc },
            .{ .pc = k + 49, .rsp = @intFromPtr(&stub_stack), .rbp = at(&k_stack, 2), .ra = 0x3333, .new_rsp = @intFromPtr(&stub_stack[1]), .new_rbp = at(&k_stack, 2), .rbx = 0xb, .r12 = 0xc },
            .{ .pc = k + 50, .rsp = at(&k_stack, 0) - 64, .rbp = at(&k_stack, 2), .ra = 0x2222, .new_rsp = at(&k_stack, 4), .new_rbp = 0x1111, .rbx = 0xfb, .r12 = 0xfc },
            .{ .pc = k + code.len - 1, .rsp = at(&k_stack, 0), .rbp = at(&k_stack, 2), .ra = 0x2222, .new_rsp = at(&k_stack, 4), .new_rbp = 0x1111, .rbx = 0xfb, .r12 = 0xfc },
        };
        for (k_cases) |c| {
            var ctx: std.debug.cpu_context.Native = .{ .gprs = .initFill(0) };
            ctx.gprs.set(.rip, c.pc);
            ctx.gprs.set(.rsp, c.rsp);
            ctx.gprs.set(.rbp, c.rbp);
            ctx.gprs.set(.rbx, if (c.pc == k + 40) 0xfb else 0xb);
            ctx.gprs.set(.r12, if (c.pc == k + 40) 0xfc else 0xc);
            var unwinder: std.debug.Dwarf.SelfUnwinder = .init(&ctx);
            defer unwinder.deinit();
            const rules = try unwinder.computeRules(gpa, &unwind, 0, null);
            try std.testing.expectEqual(c.ra, try unwinder.next(gpa, &rules));
            try std.testing.expectEqual(c.new_rsp, unwinder.cpu_state.gprs.get(.rsp));
            try std.testing.expectEqual(c.new_rbp, unwinder.cpu_state.gprs.get(.rbp));
            try std.testing.expectEqual(c.rbx, unwinder.cpu_state.gprs.get(.rbx));
            try std.testing.expectEqual(c.r12, unwinder.cpu_state.gprs.get(.r12));
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

const TestUnit = struct { name: []const u8, dir: []const u8, stmt_list: u32 };

/// The units' names, directories, and line program offsets, read from
/// the layout `Dwarf` writes.
fn testUnits(arena: Allocator, elf_bytes: []const u8) ![]const TestUnit {
    const info_sh = testSection(elf_bytes, ".debug_info").?;
    const info = elf_bytes[info_sh.offset..][0..info_sh.size];
    var units: std.ArrayList(TestUnit) = .empty;
    var off: usize = 0;
    while (off < info.len) {
        const len = std.mem.readInt(u32, info[off..][0..4], .little);
        const name = std.mem.sliceTo(info[off + 19 ..], 0);
        const dir = std.mem.sliceTo(info[off + 19 + name.len + 1 ..], 0);
        const stmt_list = std.mem.readInt(u32, info[off + 19 + name.len + 1 + dir.len + 1 ..][0..4], .little);
        try units.append(arena, .{ .name = name, .dir = dir, .stmt_list = stmt_list });
        off += 4 + len;
    }
    return units.items;
}

fn testSymbolize(di: *std.debug.Dwarf, arena: Allocator, addr: u64) !struct { name: []const u8, unit: []const u8, file: []const u8, line: u64, column: u64 } {
    var symbols: std.ArrayList(std.debug.Symbol) = .empty;
    try di.getSymbols(arena, arena, .little, addr, false, &symbols);
    const sym = symbols.items[0];
    const loc = sym.source_location orelse return error.MissingDebugInfo;
    return .{ .name = sym.name orelse return error.MissingDebugInfo, .unit = sym.compile_unit_name.?, .file = loc.file_name, .line = loc.line, .column = loc.column };
}

test "an aarch64 branch out of range reports its caller, target and kind" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const main: SymbolKey = .fromName("main");
    const far: SymbolKey = .fromName("far");
    // `bl far+8`, with far 8 GiB up: beyond branch26's ±128 MiB.
    const atoms = [_]Atom{
        .{ .key = main, .name = "main", .section = .text, .alignment = .@"4", .bytes = &.{ 0, 0, 0, 0x94 }, .targets = &.{far}, .relocs = &.{.init(0, .aarch64_branch26, 0, 8)} },
    };
    var diag: Diagnostic = .{};
    try std.testing.expectError(error.RelocationOverflow, emit(gpa, io, &atoms, .{ .entry = main, .arch = .aarch64, .values = &.{.{ .key = far, .value = 1 << 33 }}, .diag = &diag }));
    try std.testing.expectEqualStrings("main", diag.atom);
    try std.testing.expectEqual(far, diag.target.?);
    try std.testing.expectEqual(.aarch64_branch26, diag.reloc.?);
    try std.testing.expectEqual(8, diag.addend);
}
