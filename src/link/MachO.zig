//! arm64 Mach-O linker: a position-independent executable dynamically linked
//! against libSystem and ad-hoc code signed. Takes the whole set of Atoms,
//! lays out sections, resolves relocations, and writes the executable in one
//! pass into one buffer, like `Elf.zig`, whose thread pool, symbol table,
//! and output buffers it shares.
//!
//! File layout, with every segment starting on a 16 KiB page and the
//! loaded segments mapped at `base_address + file offset`:
//!
//!   __PAGEZERO    4 GiB, no access, not in the file
//!   __TEXT        r-x  header and load commands, __text, __stubs, __const,
//!                      __unwind_info (with debug info)
//!   __DATA_CONST  rw-, read-only after fixups  __got, __const
//!   __DATA        rw-  __data, __thread_vars, __thread_data, then memory
//!                      only: __thread_bss, __bss
//!   __LINKEDIT    r--  chained fixups, exports trie, function starts,
//!                      symbol table, indirect symbol table, string table,
//!                      code signature
//!
//! `.rodata` atoms without absolute addresses go to __TEXT,__const; those
//! with `aarch64_abs64` relocations go to __DATA_CONST,__const, because the
//! loader must slide the addresses. Every import gets a GOT slot, bound by
//! dyld, and a 12-byte stub (adrp, ldr, br through x16) for branches.
//! Absolute addresses become chained fixups (`DYLD_CHAINED_PTR_64_OFFSET`
//! rebases and binds, the format ld64 emits for arm64 since macOS 12), so
//! there are no rebase or bind opcodes and dyld walks each page's chain.
//!
//! Atom and import names are platform-neutral (`main`, `write`,
//! `widgets.TextInput.update`); the symbol table and the imports' names
//! get Darwin's leading underscore, and DW_AT_linkage_name leaves it out,
//! as LLVM and ld64 write them. Atom symbols are local.
//!
//! The code signature is the one ld64 emits by default ("linker-signed"):
//! one CodeDirectory with a SHA-256 hash per 4 KiB page of everything
//! before it, flagged ad hoc, which is all Apple Silicon needs to run the
//! file. The UUID is derived from the same page hashes.
//!
//! Debug info (`Options.debug`) goes where macOS's tools look for it. The
//! DWARF, the same compile unit, subprograms, and line sequences as ELF's
//! (`Dwarf.zig`), goes in a dSYM bundle next to the executable, matched to
//! it by UUID, which lldb and std.debug read; `__TEXT,__unwind_info` holds
//! compact unwind entries from each entry's `frame`, which libunwind, lldb,
//! and std.debug's unwinder read. There is no __eh_frame: the frames zap
//! describes all have compact encodings, as LLVM and ld64 emit them.
//!
//! Thread-locals work as with ld64: `.tdata` and `.tbss` atoms make up the
//! template dyld copies for each thread (`__thread_data`, then the zero
//! fill `__thread_bss`), and each gets a descriptor in `__thread_vars`,
//! a thunk bound to libSystem's `__tlv_bootstrap`, a key, and the atom's
//! offset in the template. A thread-local's symbol is its descriptor, so
//! code reaches it with `adrp x0, desc; add x0, x0, desc@pageoff` (the
//! tlvp relocations), then calls the thunk, which returns the variable's
//! address for the calling thread in x0.

const std = @import("std");
const builtin = @import("builtin");
const macho = std.macho;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Atom = @import("Atom.zig");
const Dwarf = @import("Dwarf.zig");
/// DW_AT_language of the compile units: C99, as upstream's LLVM backend
/// (its macOS Debug default) writes it, since lldb has no Zig type system
/// and shows no functions or inlined frames for DW_LANG_Zig units.
const dwarf_language = std.dwarf.LANG.C99;
const Elf = @import("Elf.zig");
const SymbolKey = Atom.SymbolKey;
const SymbolTable = Elf.SymbolTable;
const parallel = Elf.parallel;
const writeStruct = Elf.writeStruct;

comptime {
    // Structs are copied into the output as host bytes.
    std.debug.assert(builtin.cpu.arch.endian() == .little);
}

pub const Options = struct {
    /// Called as `main(argc, argv, envp, apple)` by dyld (LC_MAIN); returning
    /// from it exits with its result.
    entry: SymbolKey,
    /// Symbols imported from libSystem. An atom with the same key overrides
    /// the import.
    imports: []const Import = &.{},
    /// Integers assigned by the whole compilation, for `value*` relocations.
    values: []const Value = &.{},
    /// Code signing identifier; `link` defaults it to the output's file name.
    identifier: ?[]const u8 = null,
    /// LC_BUILD_VERSION minimum macOS, also recorded as the SDK version.
    /// Zig 0.17.1's default minimum for aarch64-macos is 15.0.
    min_os: std.SemanticVersion = .{ .major = 15, .minor = 0, .patch = 0 },
    /// Threads to link with, the calling thread included; null means one
    /// per CPU. The output is the same for any number.
    threads: ?usize = null,
    /// Filled in when linking fails with a symbol-related error.
    diag: ?*Diagnostic = null,
    /// The symbols, already numbered by the caller, so that the link
    /// looks up no keys (see `Elf.Symbols`). When set, `entry` is used only
    /// in diagnostics and `values` not at all; `imports` still gives the
    /// imports' names, in the order of `Symbols.imports`.
    symbols: ?Symbols = null,
    /// Debug info for functions, ordered by `Atom.Debug.atom`, as for
    /// `Elf.Options.debug`: DWARF in a dSYM bundle next to the executable
    /// (see `link`), and `__unwind_info` from each entry's `frame`.
    debug: []const Atom.Debug = &.{},
    /// The compilation directory that relative `Atom.Debug.file` paths are
    /// relative to (DW_AT_comp_dir).
    comp_dir: []const u8 = ".",
    /// As `Elf.Options.aliases`; with `symbols`, `Symbols.aliases` numbers
    /// them.
    aliases: []const Elf.Alias = &.{},
};

/// `Elf.Symbols` with the imports numbered too.
pub const Symbols = struct {
    /// One per atom.
    atoms: []const Elf.NumberedAtom,
    /// The numbers of the atoms' targets, as for `Elf.Symbols.targets`.
    targets: []const u32,
    /// As for `Elf.Symbols.targets_tail`.
    targets_tail: []const u32 = &.{},
    values: []const Elf.NumberedValue = &.{},
    /// The number of each of `Options.imports`. An atom with the same
    /// number takes precedence over an import, as a key does, and an import
    /// over a value; of imports with the same number the first wins.
    imports: []const u32 = &.{},
    /// The numbers of `Options.aliases`, parallel to them.
    aliases: []const Elf.NumberedAlias = &.{},
    entry: u32,
    /// Numbers are below this; numbers with no atom, import, or value are
    /// undefined, which is an error only if a relocation uses one.
    len: u32,
};

pub const Import = struct {
    key: SymbolKey,
    /// The symbol's name without Darwin's leading underscore, which the
    /// linker adds, as it does to atoms' names: `write`.
    name: []const u8,
};

pub const Value = Elf.Value;
pub const Diagnostic = Elf.Diagnostic;
/// As for ELF; `InvalidRelocation` also covers relocation kinds of another
/// architecture, absolute addresses in code, misaligned fixups,
/// addresses taken of imports other than through the GOT, and thread-local
/// atoms, which are not supported yet.
pub const Error = Elf.Error;

/// Links `atoms` and writes the executable to `sub_path` in `dir`: built in
/// memory, signed there, and written into a new file with pwrite. The old
/// file is replaced, not truncated: the kernel caches the code signature of
/// a file it has run, and rewriting that file in place gets the next run
/// killed. With `options.debug`, the DWARF goes to `<sub_path>.dSYM/
/// Contents/Resources/DWARF/<file name>`, where lldb and std.debug look for
/// it, with the executable's UUID.
///
/// Building in a shared mapping of the file instead costs about twice as
/// much on macOS (12.5 ms against 6 ms for the 27 MiB bench-link output on
/// an M4 Max): first-touch faults on the file's pages are slow, and the
/// mapping must be invalidated with msync(MS_INVALIDATE) before exec, or
/// the kernel kills every run of the file (golang/go#42684), which costs
/// another 4 ms.
pub fn link(gpa: Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, atoms: []const Atom, options: Options) !void {
    return linkInput(gpa, io, dir, sub_path, Elf.AtomSlice{ .atoms = atoms, .debug_entries = options.debug }, options);
}

/// `link` with the atoms and their debug info read from `input`, which has
/// `Elf.AtomSlice`'s declarations; `options.debug` is not used.
pub fn linkInput(gpa: Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, input: anytype, options: Options) !void {
    var o = options;
    if (o.identifier == null) o.identifier = std.fs.path.basename(sub_path);
    var out: Elf.MemoryOutput = .{ .gpa = gpa };
    defer gpa.free(out.buf);
    if (input.debugLen() == 0) {
        try build(gpa, io, input, o, &out, {});
    } else {
        const dsym_dir = try std.fmt.allocPrint(gpa, "{s}.dSYM/Contents/Resources/DWARF", .{sub_path});
        defer gpa.free(dsym_dir);
        var dsym_parent = try dir.createDirPathOpen(io, dsym_dir, .{});
        defer dsym_parent.close(io);
        // A debugger may have the old file mapped, so it is replaced, not
        // overwritten.
        const dsym_name = std.fs.path.basename(sub_path);
        dsym_parent.deleteFile(io, dsym_name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        };
        var dsym: DsymFile = .{ .file = try dsym_parent.createFile(io, dsym_name, .{}) };
        defer dsym.file.close(io);
        errdefer dsym_parent.deleteFile(io, dsym_name) catch {};
        try build(gpa, io, input, o, &out, &dsym);
    }
    dir.deleteFile(io, sub_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
    const file = try dir.createFile(io, sub_path, .{ .permissions = .executable_file });
    defer file.close(io);
    errdefer dir.deleteFile(io, sub_path) catch {};
    try file.writePositionalAll(io, out.buf, 0);
}

/// Links `atoms` into the bytes of an executable, owned by the caller,
/// the same as `link` writes; the dSYM is not built.
pub fn emit(gpa: Allocator, io: std.Io, atoms: []const Atom, options: Options) Error![]u8 {
    return emitInput(gpa, io, Elf.AtomSlice{ .atoms = atoms, .debug_entries = options.debug }, options);
}

/// `emit` with the atoms read from `input` (see `linkInput`).
pub fn emitInput(gpa: Allocator, io: std.Io, input: anytype, options: Options) Error![]u8 {
    var out: Elf.MemoryOutput = .{ .gpa = gpa };
    errdefer gpa.free(out.buf);
    try build(gpa, io, input, options, &out, {});
    return out.buf;
}

/// The dSYM's DWARF file, written with pwrite from a buffer per thread, one
/// contiguous range at a time, as `Elf.link` writes, rather than through a
/// mapping, which would fault in and zero every page of the new file.
const DsymFile = struct { file: std.Io.File };

/// An executable and its dSYM's DWARF file, owned by the caller.
pub const Emitted = struct { exe: []u8, dsym: []u8 };

/// `emit`, and the DWARF file that `link` writes into the dSYM bundle
/// (empty without debug info).
pub fn emitWithDsym(gpa: Allocator, io: std.Io, atoms: []const Atom, options: Options) Error!Emitted {
    const input: Elf.AtomSlice = .{ .atoms = atoms, .debug_entries = options.debug };
    var out: Elf.MemoryOutput = .{ .gpa = gpa };
    errdefer gpa.free(out.buf);
    var dsym: Elf.MemoryOutput = .{ .gpa = gpa };
    errdefer gpa.free(dsym.buf);
    if (options.debug.len == 0) {
        try build(gpa, io, input, options, &out, {});
    } else {
        try build(gpa, io, input, options, &out, &dsym);
    }
    return .{ .exe = out.buf, .dsym = dsym.buf };
}

pub const base_address = 0x1_0000_0000;
/// Segment alignment: arm64 macOS uses 16 KiB pages.
const page_size = 0x4000;
/// Code signature hash pages.
const sig_page_size = 0x1000;
const stub_size = 12;

/// Output sections, in layout order.
const Sect = enum(u4) { text, stubs, text_const, unwind_info, got, data_const, data, thread_vars, thread_data, thread_bss, bss };
const n_sects = 11;
const Seg = enum(u2) { text, data_const, data };
const sect_info = [n_sects]struct { seg: Seg, name: []const u8, flags: u32 }{
    .{ .seg = .text, .name = "__text", .flags = macho.S_REGULAR | macho.S_ATTR_PURE_INSTRUCTIONS | macho.S_ATTR_SOME_INSTRUCTIONS },
    .{ .seg = .text, .name = "__stubs", .flags = macho.S_SYMBOL_STUBS | macho.S_ATTR_PURE_INSTRUCTIONS | macho.S_ATTR_SOME_INSTRUCTIONS },
    .{ .seg = .text, .name = "__const", .flags = macho.S_REGULAR },
    .{ .seg = .text, .name = "__unwind_info", .flags = macho.S_REGULAR },
    .{ .seg = .data_const, .name = "__got", .flags = macho.S_NON_LAZY_SYMBOL_POINTERS },
    .{ .seg = .data_const, .name = "__const", .flags = macho.S_REGULAR },
    .{ .seg = .data, .name = "__data", .flags = macho.S_REGULAR },
    .{ .seg = .data, .name = "__thread_vars", .flags = macho.S_THREAD_LOCAL_VARIABLES },
    .{ .seg = .data, .name = "__thread_data", .flags = macho.S_THREAD_LOCAL_REGULAR },
    .{ .seg = .data, .name = "__thread_bss", .flags = macho.S_THREAD_LOCAL_ZEROFILL },
    .{ .seg = .data, .name = "__bss", .flags = macho.S_ZEROFILL },
};
const seg_names = [3][]const u8{ "__TEXT", "__DATA_CONST", "__DATA" };

const text = @backingInt(Sect.text);
const stubs = @backingInt(Sect.stubs);
const text_const = @backingInt(Sect.text_const);
const unwind_info = @backingInt(Sect.unwind_info);
const got = @backingInt(Sect.got);
const data_const = @backingInt(Sect.data_const);
const data = @backingInt(Sect.data);
const thread_vars = @backingInt(Sect.thread_vars);
const thread_data = @backingInt(Sect.thread_data);
const thread_bss = @backingInt(Sect.thread_bss);
const bss = @backingInt(Sect.bss);

/// A thread-local variable's descriptor (`struct tlv_descriptor`): the
/// thunk, bound to `__tlv_bootstrap`, a key dyld fills in, and the
/// variable's offset in the template.
const tlv_descriptor_size = 24;

fn zeroFill(s: usize) bool {
    return s == bss or s == thread_bss;
}

/// Where pass 1 placed an atom. A thread-local atom's place is its
/// descriptor's, in `__thread_vars`; `copy` places its bytes in the
/// template again, in the same order as `layOut`.
const Place = packed struct(u64) {
    /// Offset within the chunk's part of the section.
    offset: u39,
    /// Alignment padding between the previous atom of the section and this
    /// one, which the copy pass fills.
    gap: u21,
    section: u4,

    const duplicate: Place = @bitCast(@as(u64, std.math.maxInt(u64)));

    pub fn isDuplicate(p: Place) bool {
        return @as(u64, @bitCast(p)) == std.math.maxInt(u64);
    }
};
/// Atoms per unit of work in placement and copying.
const chunk_len = 2048;
/// Address-table entries, with numbered symbols: an atom's address minus
/// `base_address`, `value_tag` plus the index of a value in
/// `Symbols.values`, `value_tag` plus the number of values plus the index
/// of an import, or `unset`.
const unset = std.math.maxInt(u32);
const value_tag = 1 << 31;
const dylinker_path = "/usr/lib/dyld";
const libsystem_path = "/usr/lib/libSystem.B.dylib";
const mh_execute_header = "__mh_execute_header";

/// Links `atoms` into the buffer `out.buffer(io, len)` returns. The phases
/// are those of `Elf.build`: deduplicate, place per chunk, place chunks,
/// resolve addresses, then copy and relocate per chunk, each spread over
/// threads. Mach-O adds a serial pass that writes the GOT and stubs and
/// links fixups into per-page chains, and a parallel pass that hashes
/// pages for the code signature.
fn build(gpa: Allocator, io: std.Io, input: anytype, options: Options, out: anytype, dsym_out: anytype) !void {
    const Link = LinkOf(@TypeOf(input));
    var unused_diag: Diagnostic = .{};
    const diag = options.diag orelse &unused_diag;

    const n_atoms = input.len();
    const n_chunks = std.math.divCeil(usize, n_atoms, chunk_len) catch unreachable;
    const n_threads = @max(1, @min(n_chunks, options.threads orelse std.Thread.getCpuCount() catch 1));
    const n_partitions = std.math.ceilPowerOfTwoAssert(usize, @min(n_threads, 8));

    const numbered = options.symbols;
    if (numbered) |s| if (s.atoms.len != n_atoms or s.entry >= s.len or s.imports.len != options.imports.len or s.aliases.len != options.aliases.len) return error.InvalidSymbols;
    var symbols: SymbolTable = if (numbered == null) try .init(n_atoms + options.aliases.len, n_partitions) else .empty;
    defer symbols.deinit();
    // With numbered symbols, each number's address, import, or value.
    const addrs = try gpa.alloc(u32, if (numbered) |s| s.len else 0);
    defer gpa.free(addrs);
    const places = try gpa.alloc(Place, n_atoms);
    defer gpa.free(places);
    const keys = try gpa.alloc(SymbolKey, if (numbered == null) n_atoms else 0);
    defer gpa.free(keys);
    const chunks = try gpa.alloc(Chunk, n_chunks);
    defer gpa.free(chunks);
    const n_debug = input.debugLen();
    const n_debug_chunks = std.math.divCeil(usize, n_debug, Dwarf.chunk_len) catch unreachable;
    const debug_chunks = try gpa.alloc(Dwarf.Chunk, n_debug_chunks);
    defer gpa.free(debug_chunks);
    @memset(debug_chunks, .empty);
    defer for (debug_chunks) |*c| c.deinit(gpa);
    const file_of = try gpa.alloc(u32, n_debug);
    defer gpa.free(file_of);
    const unwind_pages = try gpa.alloc(UnwindPage, n_debug_chunks);
    defer gpa.free(unwind_pages);
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
        .unwind_pages = unwind_pages,
        .places = places,
        .keys = keys,
        .chunks = chunks,
        .symbols = &symbols,
        .failures = failures,
        .numbered = numbered,
        .addrs = addrs,
    };

    @memset(failures, null);
    if (numbered == null) {
        try parallel(io, n_threads, n_chunks, &l, Link.gatherKeys);
        try parallel(io, n_threads, n_partitions, &l, Link.dedup);
        try parallel(io, n_threads, n_chunks, &l, Link.layOutKeyed);
    } else {
        try parallel(io, n_threads, n_chunks, &l, Link.layOutNumbered);
    }
    try l.check(diag);
    // Size the debug chunks, which needs only where atoms went.
    if (n_debug > 0) {
        try parallel(io, n_threads, n_debug_chunks, &l, Link.layOutDebug);
        try l.check(diag);
    }

    // Place chunks within sections, and their symbols, names, and fixups.
    var sizes: [n_sects]u64 = @splat(0);
    var aligns: [n_sects]std.mem.Alignment = @splat(.@"1");
    var n_atom_syms: u32 = 0;
    var strtab_len: u64 = 1;
    var max_targets: usize = 0;
    const n_imports: u32 = std.math.cast(u32, options.imports.len) orelse return error.OutOfMemory;
    // Fixups in address order: GOT slots, then __DATA_CONST,__const, then
    // __data, the descriptors' binds, and __thread_data, each section's in
    // chunk order.
    var n_fixups: [n_sects]u64 = @splat(0);
    n_fixups[got] = n_imports;
    for (chunks) |*c| {
        for (&sizes, &aligns, &c.bases, &c.lead_gaps, c.sizes, c.aligns) |*size, *alignment, *chunk_base, *lead_gap, chunk_size, chunk_align| {
            chunk_base.* = chunk_align.forward(size.*);
            lead_gap.* = chunk_base.* - size.*;
            size.* = chunk_base.* + chunk_size;
            alignment.* = alignment.max(chunk_align);
        }
        for (&c.fixups, &n_fixups, c.n_fixups) |*first, *total, n| {
            first.* = total.*;
            total.* += n;
        }
        c.sym = n_atom_syms;
        c.str = std.math.cast(u32, strtab_len) orelse return error.OutOfMemory;
        n_atom_syms += c.n_syms;
        strtab_len += c.str_len;
        max_targets = @max(max_targets, c.max_targets);
    }
    // Make the per-chunk fixup indices global.
    var sect_fixups: [n_sects]u64 = undefined;
    var total_fixups: u64 = 0;
    for (&sect_fixups, n_fixups) |*first, n| {
        first.* = total_fixups;
        total_fixups += n;
    }
    for (chunks) |*c| {
        for (&c.fixups, sect_fixups) |*first, sect_first| first.* += sect_first;
    }
    // Thread-locals' thunks bind to `__tlv_bootstrap`, an import after the
    // caller's with no GOT slot or stub.
    const has_tlv = sizes[thread_vars] > 0;
    const bind_imports = try gpa.alloc(Import, n_imports + @intFromBool(has_tlv));
    defer gpa.free(bind_imports);
    @memcpy(bind_imports[0..n_imports], options.imports);
    if (has_tlv) bind_imports[n_imports] = .{ .key = .fromName("_tlv_bootstrap"), .name = "_tlv_bootstrap" };
    const n_bind_imports: u32 = @intCast(bind_imports.len);
    // Offsets in the template keep their alignment only if the template's
    // start has the largest.
    aligns[thread_data] = aligns[thread_data].max(aligns[thread_bss]);

    // With numbered symbols, the entry's atom is found while resolving
    // addresses.
    var entry_index: usize = undefined;
    if (numbered == null) {
        entry_index = symbols.get(options.entry) orelse {
            diag.* = .{ .target = options.entry };
            return error.UndefinedSymbol;
        };
        try checkEntry(&l, entry_index, options.entry, diag);
    }

    var values: SymbolTable = .empty;
    defer values.deinit();
    var imports: SymbolTable = .empty;
    defer imports.deinit();
    for (bind_imports) |imp| strtab_len += 1 + imp.name.len + 1;
    if (numbered) |s| {
        // Atoms, numbered in `resolveAddrs`, take precedence over imports,
        // and imports over values.
        @memset(addrs, unset);
        if (s.values.len + s.imports.len >= unset - value_tag) return error.InvalidSymbols;
        for (s.values, 0..) |v, i| {
            if (v.symbol >= addrs.len) return error.InvalidSymbols;
            addrs[v.symbol] = @intCast(value_tag + i);
        }
        var i = s.imports.len;
        while (i > 0) {
            i -= 1;
            if (s.imports[i] >= addrs.len) return error.InvalidSymbols;
            addrs[s.imports[i]] = @intCast(value_tag + s.values.len + i);
        }
    } else {
        values = try .init(options.values.len + options.aliases.len, 1);
        for (options.values) |v| values.getOrPut(v.key).* = .{ .key = v.key, .value = v.value, .used = true };
        imports = try .init(options.imports.len + options.aliases.len, 1);
        for (options.imports, 0..) |imp, i| {
            const e = imports.getOrPut(imp.key);
            if (!e.used) e.* = .{ .key = imp.key, .value = i, .used = true };
        }
    }
    strtab_len += mh_execute_header.len + 1;
    sizes[stubs] = @as(u64, n_imports) * stub_size;
    aligns[stubs] = .@"4";
    sizes[got] = @as(u64, n_imports) * 8;
    aligns[got] = .@"8";
    if (n_debug > 0) {
        var at = unwindPagesOff(n_debug_chunks) + unwind_lead_page_size;
        for (unwind_pages) |*p| {
            p.off = at;
            if (p.count > 0) at += unwind_page_header_size + @as(u64, p.count) * unwind_entry_size;
        }
        sizes[unwind_info] = at;
    }
    aligns[unwind_info] = .@"4";

    // Which sections and segments exist. __text always does: it holds the
    // entry point.
    var present: [n_sects]bool = undefined;
    for (&present, sizes) |*p, size| p.* = size > 0;
    present[text] = true;
    var seg_present: [3]bool = @splat(false);
    var seg_nsects: [3]u32 = @splat(0);
    var sect_index: [n_sects]u8 = @splat(0);
    var next_index: u8 = 1;
    for (present, sect_info, &sect_index) |p, info, *index| if (p) {
        seg_present[@backingInt(info.seg)] = true;
        seg_nsects[@backingInt(info.seg)] += 1;
        index.* = next_index;
        next_index += 1;
    };
    // Segments in the file, including __PAGEZERO and __LINKEDIT.
    var n_segs: u32 = 2;
    for (seg_present) |p| n_segs += @intFromBool(p);

    // Load commands.
    const dylinker_cmd_size = std.mem.alignForward(u32, @sizeOf(macho.dylinker_command) + dylinker_path.len + 1, 8);
    const dylib_cmd_size = std.mem.alignForward(u32, @sizeOf(macho.dylib_command) + libsystem_path.len + 1, 8);
    var sizeofcmds: u32 = 2 * @sizeOf(macho.segment_command_64) + // __PAGEZERO, __LINKEDIT
        2 * @sizeOf(macho.linkedit_data_command) + // chained fixups, exports trie
        @sizeOf(macho.symtab_command) + @sizeOf(macho.dysymtab_command) + dylinker_cmd_size +
        @sizeOf(macho.uuid_command) + @sizeOf(macho.build_version_command) + @sizeOf(macho.entry_point_command) +
        dylib_cmd_size + 2 * @sizeOf(macho.linkedit_data_command); // function starts, code signature
    var ncmds: u32 = 13;
    for (seg_present, seg_nsects) |p, n| if (p) {
        sizeofcmds += @sizeOf(macho.segment_command_64) + n * @sizeOf(macho.section_64);
        ncmds += 1;
    };
    const cmds_end: u64 = @sizeOf(macho.mach_header_64) + sizeofcmds;

    // Section placement, as file offsets, which equal address - base for
    // all loaded segments (for __bss, memory only).
    var starts: [n_sects]u64 = undefined;
    var seg_start: [3]u64 = undefined;
    var seg_file_end: [3]u64 = undefined;
    var seg_mem_end: [3]u64 = undefined;
    {
        // Room for post-link tools to add load commands, as ld64's default
        // -headerpad leaves.
        var at: u64 = cmds_end + header_pad;
        for (sect_info, 0..) |info, s| {
            const seg = @backingInt(info.seg);
            if (s == 0 or sect_info[s - 1].seg != info.seg) {
                // A new segment starts on a page, except __TEXT at 0.
                if (s != 0) at = std.mem.alignForward(u64, at, page_size);
                seg_start[seg] = if (s == 0) 0 else at;
            }
            starts[s] = aligns[s].forward(at);
            at = starts[s] + sizes[s];
            if (!zeroFill(s)) seg_file_end[seg] = at;
            seg_mem_end[seg] = at;
        }
    }
    for (&seg_file_end, seg_start, seg_present) |*end, start, p| {
        end.* = if (p) std.mem.alignForward(u64, end.*, page_size) else start;
    }
    // __DATA's file part ends where its last section with contents ends,
    // rounded to a page; the zero-fill sections follow in memory.
    {
        var end = seg_start[@backingInt(Seg.data)];
        for ([_]usize{ data, thread_vars, thread_data }) |s| {
            if (sizes[s] > 0) end = starts[s] + sizes[s];
        }
        seg_file_end[@backingInt(Seg.data)] = std.mem.alignForward(u64, end, page_size);
    }
    for (&seg_mem_end, seg_start, seg_present) |*end, start, p| {
        end.* = if (p) std.mem.alignForward(u64, end.*, page_size) else start;
    }
    const last_seg: usize = if (seg_present[2]) 2 else if (seg_present[1]) 1 else 0;
    const linkedit_off = seg_file_end[last_seg];
    const linkedit_vm = seg_mem_end[last_seg];

    // __LINKEDIT contents.
    const fixups_seg = [3]bool{ false, n_fixups[got] + n_fixups[data_const] > 0, n_fixups[data] + n_fixups[thread_vars] + n_fixups[thread_data] > 0 };
    const cf = ChainedFixupsLayout.init(n_segs, seg_present, fixups_seg, seg_start, seg_mem_end, bind_imports);
    const fixups_off = linkedit_off;
    const trie_off = fixups_off + cf.size;
    // Function starts: ULEB128 deltas between the file offsets of
    // successive functions, from 0, then a 0 and padding to 8 bytes.
    // Without them lldb takes the binary for stripped and does not unwind
    // by emulating instructions, which a fault in a prologue needs.
    const func_starts_off = trie_off + exports_trie.len;
    var func_starts_len: u64 = 0;
    {
        var prev: u64 = 0;
        for (chunks) |*c| {
            c.starts_off = func_starts_off + func_starts_len;
            c.prev_func = prev;
            if (c.first_func == Chunk.no_func) continue;
            const first = starts[text] + c.bases[text] + c.first_func;
            func_starts_len += ulebLen(first - prev) + c.starts_len;
            prev = starts[text] + c.bases[text] + c.last_func;
        }
    }
    const func_starts_size = std.mem.alignForward(u64, func_starts_len + 1, 8);
    const symtab_off = func_starts_off + func_starts_size;
    const n_syms: u32 = n_atom_syms + 1 + n_bind_imports;
    const indirect_off = symtab_off + @as(u64, n_syms) * @sizeOf(macho.nlist_64);
    const n_indirect = 2 * n_imports;
    const strtab_off = indirect_off + @as(u64, n_indirect) * 4;
    const strtab_end = strtab_off + strtab_len;
    const sig_off = std.mem.alignForward(u64, strtab_end, 16);
    const identifier = options.identifier orelse "a.out";
    const n_code_slots = std.math.divCeil(u64, sig_off, sig_page_size) catch unreachable;
    const cd_size = @sizeOf(macho.CodeDirectory) + identifier.len + 1 + n_code_slots * Sha256.digest_length;
    const sig_size = @sizeOf(macho.SuperBlob) + @sizeOf(macho.BlobIndex) + cd_size;
    const file_len = sig_off + sig_size;
    if (sig_off > std.math.maxInt(u32)) return error.OutOfMemory;

    const base = base_address;
    // Numbered symbols keep addresses as 31-bit offsets from the base.
    if (numbered != null and linkedit_vm >= value_tag) return error.OutOfMemory;
    for (&l.section_addrs, starts) |*sa, st| sa.* = base + st;
    if (numbered != null) {
        try parallel(io, n_threads, n_chunks, &l, Link.resolveAddrsNumbered);
    } else {
        try parallel(io, n_threads, n_partitions, &l, Link.resolveAddrsKeyed);
    }
    try l.check(diag);
    try l.resolveAliases(options.aliases, &values, &imports, diag);
    if (numbered != null) {
        entry_index = l.entry_atom orelse {
            diag.* = .{ .target = options.entry };
            return error.UndefinedSymbol;
        };
        try checkEntry(&l, entry_index, options.entry, diag);
    }

    // The dSYM's DWARF file: header, load commands (see `writeDsymHeader`),
    // then the __DWARF segment's sections from a 4 KiB boundary.
    const has_dsym = @TypeOf(dsym_out) != void;
    var dwarf: Dwarf = .{};
    defer dwarf.deinit(gpa);
    var dsym_layout: DsymLayout = undefined;
    if (has_dsym) {
        dwarf = try .place(gpa, debug_chunks, options.comp_dir, base + starts[text], dwarf_language);
        var segs_size: u32 = @sizeOf(macho.segment_command_64); // __PAGEZERO
        for (seg_present, seg_nsects) |p, n| if (p) {
            segs_size += @sizeOf(macho.segment_command_64) + n * @sizeOf(macho.section_64);
        };
        dsym_layout = .init(n_segs - 1, segs_size, &dwarf);
        l.has_dsym = true;
        if (@TypeOf(dsym_out) == *Elf.MemoryOutput) {
            l.dsym = .{ .memory = try dsym_out.buffer(io, dsym_layout.len) };
        } else {
            try dsym_out.file.setLength(io, dsym_layout.len);
            l.dsym = .{ .file = dsym_out.file.handle };
            for (debug_chunks) |*c| {
                const lens = c.lens();
                l.dsym_scratch_len = @max(l.dsym_scratch_len, lens.info + lens.ranges + lens.aranges + lens.line);
            }
            l.dsym_scratch = try gpa.alloc(u8, n_threads * l.dsym_scratch_len);
        }
        l.dsym_info_off = dsym_layout.info_off;
        l.dsym_ranges_off = dsym_layout.ranges_off;
        l.dsym_aranges_off = dsym_layout.aranges_off;
        l.dsym_line_off = dsym_layout.line_off;
    }
    defer gpa.free(l.dsym_scratch);

    const buf = try out.buffer(io, file_len);
    l.buf = buf;
    Elf.adviseHugePages(buf);

    // Zero everything the passes below do not write: padding between
    // sections and segments and within __LINKEDIT. Padding within a section
    // is filled by the atom or chunk after it.
    {
        const written = [_][2]u64{
            .{ 0, cmds_end },
            .{ starts[text], starts[text] + sizes[text] },
            .{ starts[stubs], starts[stubs] + sizes[stubs] },
            .{ starts[text_const], starts[text_const] + sizes[text_const] },
            .{ starts[unwind_info], starts[unwind_info] + sizes[unwind_info] },
            .{ starts[got], starts[got] + sizes[got] },
            .{ starts[data_const], starts[data_const] + sizes[data_const] },
            .{ starts[data], starts[data] + sizes[data] },
            .{ starts[thread_vars], starts[thread_vars] + sizes[thread_vars] },
            .{ starts[thread_data], starts[thread_data] + sizes[thread_data] },
            .{ fixups_off, func_starts_off + func_starts_len },
            .{ symtab_off, strtab_end },
            .{ sig_off, file_len },
        };
        var at: u64 = 0;
        for (written) |w| {
            if (w[1] == w[0]) continue;
            if (w[0] > at) @memset(buf[at..w[0]], 0);
            at = @max(at, w[1]);
        }
    }

    const fixups = try gpa.alloc(u64, total_fixups);
    defer gpa.free(fixups);
    const resolved = try gpa.alloc(Resolved, n_threads * max_targets);
    defer gpa.free(resolved);
    l.values = &values;
    l.imports = &imports;
    l.symtab_off = symtab_off;
    l.strtab_off = strtab_off;
    l.resolved = resolved;
    l.max_targets = max_targets;
    l.fixups = fixups;
    l.sect_index = sect_index;
    l.stubs_addr = base + starts[stubs];
    l.got_addr = base + starts[got];
    l.tlv_template = base + if (sizes[thread_data] > 0) starts[thread_data] else starts[thread_bss];
    l.tlv_bootstrap = @intCast(n_imports);
    l.unwind_off = starts[unwind_info];
    if (n_debug > 0) {
        try parallel(io, n_threads, n_chunks + n_debug_chunks, &l, Link.copyAll);
    } else if (numbered == null) {
        try parallel(io, n_threads, n_chunks, &l, Link.copyKeyed);
    } else {
        try parallel(io, n_threads, n_chunks, &l, Link.copyNumbered);
    }
    try l.check(diag);
    if (n_debug > 0) writeUnwindIndex(buf[starts[unwind_info]..][0..sizes[unwind_info]], unwind_pages, @intCast(starts[text]), @intCast(starts[text] + sizes[text]));

    // GOT slots: one bind per import. Stubs: load the slot and jump.
    for (0..n_imports) |i| {
        const off = starts[got] + 8 * i;
        std.mem.writeInt(u64, buf[off..][0..8], bindPointer(@intCast(i), 0), .little);
        fixups[i] = off;
        const stub = buf[starts[stubs] + stub_size * i ..][0..stub_size];
        const p = base + starts[stubs] + stub_size * i;
        const slot = base + off;
        std.mem.writeInt(u32, stub[0..4], patchAdrp(0x90000010, pageDelta(slot, p)), .little); // adrp x16, slot@PAGE
        std.mem.writeInt(u32, stub[4..8], 0xf9400210 | @as(u32, @intCast((slot & 0xfff) >> 3)) << 10, .little); // ldr x16, [x16, slot@PAGEOFF]
        std.mem.writeInt(u32, stub[8..12], 0xd61f0200, .little); // br x16
    }

    // Chained fixups: header, per-segment page starts with each page's
    // fixups linked into a chain, imports, and their names.
    cf.write(buf, fixups_off, fixups, bind_imports);
    @memcpy(buf[trie_off..][0..exports_trie.len], exports_trie);

    // Symbols after the atoms': __mh_execute_header (exported), then the
    // imports (undefined), and their names.
    {
        var sym_off = symtab_off + @as(u64, n_atom_syms) * @sizeOf(macho.nlist_64);
        var str_off = strtab_len - (mh_execute_header.len + 1);
        for (bind_imports) |imp| str_off -= 1 + imp.name.len + 1;
        buf[strtab_off] = 0;
        writeStruct(buf[sym_off..], nlist(@intCast(str_off), macho.N_SECT | macho.N_EXT, 1, macho.REFERENCED_DYNAMICALLY, base));
        sym_off += @sizeOf(macho.nlist_64);
        @memcpy(buf[strtab_off + str_off ..][0..mh_execute_header.len], mh_execute_header);
        buf[strtab_off + str_off + mh_execute_header.len] = 0;
        str_off += mh_execute_header.len + 1;
        for (bind_imports, 0..) |imp, i| {
            // Two-level namespace: library ordinal 1, libSystem.
            writeStruct(buf[sym_off..], nlist(@intCast(str_off), macho.N_UNDF | macho.N_EXT, 0, 1 << 8, 0));
            sym_off += @sizeOf(macho.nlist_64);
            buf[strtab_off + str_off] = '_';
            @memcpy(buf[strtab_off + str_off + 1 ..][0..imp.name.len], imp.name);
            buf[strtab_off + str_off + 1 + imp.name.len] = 0;
            str_off += 1 + imp.name.len + 1;
            // Indirect symbols: the stubs' entries, then the GOT's.
            if (i == n_imports) break;
            const sym_index = n_atom_syms + 1 + @as(u32, @intCast(i));
            std.mem.writeInt(u32, buf[indirect_off + 4 * i ..][0..4], sym_index, .little);
            std.mem.writeInt(u32, buf[indirect_off + 4 * (n_imports + i) ..][0..4], sym_index, .little);
        }
    }

    // Header and load commands.
    var w: CmdWriter = .{ .buf = buf, .at = @sizeOf(macho.mach_header_64) };
    writeStruct(buf, macho.mach_header_64{
        .cputype = macho.CPU_TYPE_ARM64,
        .cpusubtype = macho.CPU_SUBTYPE_ARM_ALL,
        .filetype = macho.MH_EXECUTE,
        .ncmds = ncmds,
        .sizeofcmds = sizeofcmds,
        .flags = macho.MH_NOUNDEFS | macho.MH_DYLDLINK | macho.MH_TWOLEVEL | macho.MH_PIE | @as(u32, if (has_tlv) macho.MH_HAS_TLV_DESCRIPTORS else 0),
    });
    w.put(macho.segment_command_64{ .cmdsize = @sizeOf(macho.segment_command_64), .segname = name16("__PAGEZERO"), .vmsize = base });
    for (seg_present, 0..) |p, seg| if (p) {
        const rx: macho.vm_prot_t = .{ .READ = true, .EXEC = true };
        const rw: macho.vm_prot_t = .{ .READ = true, .WRITE = true };
        w.put(macho.segment_command_64{
            .cmdsize = @sizeOf(macho.segment_command_64) + seg_nsects[seg] * @sizeOf(macho.section_64),
            .segname = name16(seg_names[seg]),
            .vmaddr = base + seg_start[seg],
            .vmsize = seg_mem_end[seg] - seg_start[seg],
            .fileoff = seg_start[seg],
            .filesize = seg_file_end[seg] - seg_start[seg],
            .maxprot = if (seg == 0) rx else rw,
            .initprot = if (seg == 0) rx else rw,
            .nsects = seg_nsects[seg],
            .flags = if (seg == @backingInt(Seg.data_const)) macho.SG_READ_ONLY else 0,
        });
        for (sect_info, 0..) |info, s| if (present[s] and @backingInt(info.seg) == seg) {
            w.put(macho.section_64{
                .sectname = name16(info.name),
                .segname = name16(seg_names[seg]),
                .addr = base + starts[s],
                .size = sizes[s],
                .offset = if (zeroFill(s)) 0 else @intCast(starts[s]),
                .@"align" = @backingInt(aligns[s]),
                .flags = info.flags,
                // Indirect symbol table index, and the stub size.
                .reserved1 = if (s == got) n_imports else 0,
                .reserved2 = if (s == stubs) stub_size else 0,
            });
        };
    };
    const segs_end = w.at;
    w.put(macho.segment_command_64{
        .cmdsize = @sizeOf(macho.segment_command_64),
        .segname = name16("__LINKEDIT"),
        .vmaddr = base + linkedit_vm,
        .vmsize = std.mem.alignForward(u64, file_len - linkedit_off, page_size),
        .fileoff = linkedit_off,
        .filesize = file_len - linkedit_off,
        .maxprot = .{ .READ = true },
        .initprot = .{ .READ = true },
    });
    w.put(macho.linkedit_data_command{ .cmd = .DYLD_CHAINED_FIXUPS, .dataoff = @intCast(fixups_off), .datasize = @intCast(cf.size) });
    w.put(macho.linkedit_data_command{ .cmd = .DYLD_EXPORTS_TRIE, .dataoff = @intCast(trie_off), .datasize = exports_trie.len });
    w.put(macho.symtab_command{ .symoff = @intCast(symtab_off), .nsyms = n_syms, .stroff = @intCast(strtab_off), .strsize = @intCast(strtab_len) });
    w.put(macho.dysymtab_command{
        .ilocalsym = 0,
        .nlocalsym = n_atom_syms,
        .iextdefsym = n_atom_syms,
        .nextdefsym = 1,
        .iundefsym = n_atom_syms + 1,
        .nundefsym = n_bind_imports,
        .indirectsymoff = if (n_indirect > 0) @intCast(indirect_off) else 0,
        .nindirectsyms = n_indirect,
    });
    w.putWithString(macho.dylinker_command{ .cmd = .LOAD_DYLINKER, .cmdsize = dylinker_cmd_size, .name = @sizeOf(macho.dylinker_command) }, dylinker_path, dylinker_cmd_size);
    const uuid_at = w.at + @offsetOf(macho.uuid_command, "uuid");
    w.put(macho.uuid_command{ .uuid = @splat(0) });
    const version = (@as(u32, @intCast(options.min_os.major)) << 16) | (@as(u32, @intCast(options.min_os.minor)) << 8) | @as(u32, @intCast(options.min_os.patch));
    w.put(macho.build_version_command{ .cmdsize = @sizeOf(macho.build_version_command), .platform = .MACOS, .minos = version, .sdk = version, .ntools = 0 });
    w.put(macho.entry_point_command{ .entryoff = l.atomAddr(entry_index) - base });
    w.putWithString(macho.dylib_command{ .cmd = .LOAD_DYLIB, .cmdsize = dylib_cmd_size, .dylib = .{
        .name = @sizeOf(macho.dylib_command),
        .timestamp = 2,
        .current_version = 0x10000,
        .compatibility_version = 0x10000,
    } }, libsystem_path, dylib_cmd_size);
    w.put(macho.linkedit_data_command{ .cmd = .FUNCTION_STARTS, .dataoff = @intCast(func_starts_off), .datasize = @intCast(func_starts_size) });
    w.put(macho.linkedit_data_command{ .cmd = .CODE_SIGNATURE, .dataoff = @intCast(sig_off), .datasize = @intCast(sig_size) });
    std.debug.assert(w.at == cmds_end);

    try sign(io, n_threads, buf, @intCast(sig_off), uuid_at, identifier, seg_file_end[0]);

    if (has_dsym) {
        // The dSYM's parts outside the debug chunks': its header and
        // .debug_abbrev, the units' heads (with their line program
        // headers), and .debug_str.
        const dl = dsym_layout;
        const head = try gpa.alloc(u8, dl.info_off);
        defer gpa.free(head);
        writeDsymHeader(head, dl, buf[uuid_at..][0..16].*, buf[@sizeOf(macho.mach_header_64)..segs_end], base + linkedit_vm + std.mem.alignForward(u64, file_len - linkedit_off, page_size));
        if (dl.info_size > 0) {
            @memcpy(head[dl.abbrev_off..][0..Dwarf.abbrev.len], &Dwarf.abbrev);
            try dwarf.heads(&l, Link.putDsymDebug);
            try l.putDsym(dl.str_off, Dwarf.str);
        }
        try l.putDsym(0, head);
    }
}

/// Where the parts of the dSYM's DWARF file go. It holds the executable's
/// UUID and segment and section commands (with no file contents), as
/// dsymutil's and upstream Zig's dSYMs do, so debuggers match its
/// addresses to the executable's sections; a __DWARF segment with the
/// debug sections, after the executable's address space; and an empty
/// symbol table.
const DsymLayout = struct {
    n_exe_segs: u32,
    exe_segs_size: u32,
    sizeofcmds: u32,
    /// File offsets and sizes of the debug sections, all 0 without debug
    /// info (every entry's atom lost to a duplicate).
    abbrev_off: u64,
    info_off: u64,
    info_size: u64,
    ranges_off: u64,
    ranges_size: u64,
    line_off: u64,
    line_size: u64,
    str_off: u64,
    aranges_off: u64,
    aranges_size: u64,
    dwarf_off: u64,
    len: u64,

    const n_dwarf_sects = 6;

    fn init(n_exe_segs: u32, exe_segs_size: u32, dwarf: *const Dwarf) DsymLayout {
        const has_debug = dwarf.present();
        const sizeofcmds = @sizeOf(macho.uuid_command) + exe_segs_size + @sizeOf(macho.segment_command_64) +
            @as(u32, if (has_debug) n_dwarf_sects * @sizeOf(macho.section_64) else 0) + @sizeOf(macho.symtab_command);
        const dwarf_off = std.mem.alignForward(u64, @sizeOf(macho.mach_header_64) + sizeofcmds, 0x1000);
        const abbrev_size: u64 = if (has_debug) Dwarf.abbrev.len else 0;
        const info_size = dwarf.info_size;
        const ranges_size = if (has_debug) dwarf.ranges_size else 0;
        const line_size = dwarf.line_size;
        const str_size: u64 = if (has_debug) Dwarf.str.len else 0;
        const aranges_size: u64 = dwarf.aranges_size;
        const info_off = dwarf_off + abbrev_size;
        const ranges_off = info_off + info_size;
        const line_off = ranges_off + ranges_size;
        const str_off = line_off + line_size;
        const aranges_off = str_off + str_size;
        return .{
            .n_exe_segs = n_exe_segs,
            .exe_segs_size = exe_segs_size,
            .sizeofcmds = sizeofcmds,
            .abbrev_off = dwarf_off,
            .info_off = info_off,
            .info_size = info_size,
            .ranges_off = ranges_off,
            .ranges_size = ranges_size,
            .line_off = line_off,
            .line_size = line_size,
            .str_off = str_off,
            .aranges_off = aranges_off,
            .aranges_size = aranges_size,
            .dwarf_off = dwarf_off,
            .len = aranges_off + aranges_size,
        };
    }
};

/// Writes the dSYM's header and load commands, and zeros the padding
/// before its __DWARF segment. `exe_segs` are the executable's segment and
/// section commands before __LINKEDIT; `dwarf_vmaddr` is where the
/// executable's address space ends.
fn writeDsymHeader(dsym: []u8, dl: DsymLayout, uuid: [16]u8, exe_segs: []const u8, dwarf_vmaddr: u64) void {
    const has_debug = dl.info_size > 0;
    writeStruct(dsym, macho.mach_header_64{
        .cputype = macho.CPU_TYPE_ARM64,
        .cpusubtype = macho.CPU_SUBTYPE_ARM_ALL,
        .filetype = macho.MH_DSYM,
        .ncmds = dl.n_exe_segs + 3,
        .sizeofcmds = dl.sizeofcmds,
        .flags = 0,
    });
    var w: CmdWriter = .{ .buf = dsym, .at = @sizeOf(macho.mach_header_64) };
    w.put(macho.uuid_command{ .uuid = uuid });
    // The executable's segments, without file contents.
    std.debug.assert(exe_segs.len == dl.exe_segs_size);
    @memcpy(dsym[w.at..][0..exe_segs.len], exe_segs);
    var at = w.at;
    w.at += exe_segs.len;
    while (at < w.at) {
        var seg = std.mem.bytesToValue(macho.segment_command_64, dsym[at..][0..@sizeOf(macho.segment_command_64)]);
        seg.fileoff = 0;
        seg.filesize = 0;
        writeStruct(dsym[at..], seg);
        at += @sizeOf(macho.segment_command_64);
        for (0..seg.nsects) |_| {
            var sect = std.mem.bytesToValue(macho.section_64, dsym[at..][0..@sizeOf(macho.section_64)]);
            sect.offset = 0;
            writeStruct(dsym[at..], sect);
            at += @sizeOf(macho.section_64);
        }
    }
    const dwarf_size = dl.len - dl.dwarf_off;
    w.put(macho.segment_command_64{
        .cmdsize = @sizeOf(macho.segment_command_64) + @as(u32, if (has_debug) DsymLayout.n_dwarf_sects * @sizeOf(macho.section_64) else 0),
        .segname = name16("__DWARF"),
        .vmaddr = dwarf_vmaddr,
        .vmsize = std.mem.alignForward(u64, dwarf_size, page_size),
        .fileoff = dl.dwarf_off,
        .filesize = dwarf_size,
        .maxprot = .{ .READ = true, .WRITE = true, .EXEC = true },
        .initprot = .{ .READ = true, .WRITE = true },
        .nsects = @as(u32, if (has_debug) DsymLayout.n_dwarf_sects else 0),
    });
    if (has_debug) {
        const sects = [DsymLayout.n_dwarf_sects]struct { []const u8, u64, u64 }{
            .{ "__debug_abbrev", dl.abbrev_off, Dwarf.abbrev.len },
            .{ "__debug_info", dl.info_off, dl.info_size },
            .{ "__debug_rnglists", dl.ranges_off, dl.ranges_size },
            .{ "__debug_line", dl.line_off, dl.line_size },
            .{ "__debug_str", dl.str_off, Dwarf.str.len },
            .{ "__debug_aranges", dl.aranges_off, dl.aranges_size },
        };
        for (sects) |sect| w.put(macho.section_64{
            .sectname = name16(sect[0]),
            .segname = name16("__DWARF"),
            .addr = dwarf_vmaddr + sect[1] - dl.dwarf_off,
            .size = sect[2],
            .offset = @intCast(sect[1]),
            .@"align" = 0,
            .flags = macho.S_ATTR_DEBUG,
        });
    }
    w.put(macho.symtab_command{ .symoff = 0, .nsyms = 0, .stroff = 0, .strsize = 0 });
    std.debug.assert(w.at == @sizeOf(macho.mach_header_64) + dl.sizeofcmds);
    @memset(dsym[w.at..dl.dwarf_off], 0);
}

// __unwind_info, from the `frame` of each debug entry: the header; a
// first-level index with room for a leading page, a page per debug chunk,
// and the end; an empty LSDA array; the leading page, which marks code
// before the first function as having no unwind info; then each debug
// chunk's regular second-level page, with room for 2 entries per debug
// entry and 1 more. A chunk writes its page in place: an entry where each
// function starts unless it continues the previous entry's encoding, and
// an entry with no encoding where each run of functions ends, so that code
// without debug info between functions is not taken for theirs.
// `writeUnwindIndex` then lists the pages that have entries. Debuggers and
// unwinders find the page from the index and the entry by binary search.

const unwind_header_size = @sizeOf(macho.unwind_info_section_header);
const unwind_index_entry_size = @sizeOf(macho.unwind_info_section_header_index_entry);
const unwind_page_header_size = @sizeOf(macho.unwind_info_regular_second_level_page_header);
const unwind_entry_size = @sizeOf(macho.unwind_info_regular_second_level_entry);
const unwind_lead_page_size = unwind_page_header_size + unwind_entry_size;

/// Offset of the LSDA array and the pages, for `n_chunks` debug chunks.
fn unwindPagesOff(n_chunks: usize) u64 {
    return unwind_header_size + (n_chunks + 2) * unwind_index_entry_size;
}

/// A debug chunk's page: its number of entries (from `Link.layOutDebug`),
/// its offset in the section, and its first function offset (from
/// `Link.copyDebug`).
const UnwindPage = struct { count: u32, off: u64, first: u32 };

/// The compact unwind encoding of a frame. `frame_pointer` is the
/// prologue `stp x29, x30, [sp, #-16]!; mov x29, sp`, which leaves x29
/// pointing at the saved x29 and x30: UNWIND_ARM64_MODE_FRAME, with the
/// saved register pairs' bits, which `Atom.Unwind.saved` holds as compact
/// unwind defines them. The others have none (0), so unwinders fall back
/// to the frame chain; dyld calls `main`, so no frame of the executable's
/// is the outermost one.
fn unwindEncoding(u: Atom.Unwind) u32 {
    return switch (u.kind) {
        .frame_pointer => 0x0400_0000 | @as(u32, u.saved & Atom.Unwind.savedBits(.aarch64)),
        .none, .outermost => 0,
    };
}

/// Writes the header, the first-level index, and the leading page of
/// `out`, the __unwind_info section, after the debug chunks wrote their
/// pages. Offsets are from the start of __TEXT; __text spans `text_start`
/// to `text_end`.
fn writeUnwindIndex(out: []u8, pages: []const UnwindPage, text_start: u32, text_end: u32) void {
    const pages_off: u32 = @intCast(unwindPagesOff(pages.len));
    var n: u32 = 0;
    var index_at: usize = unwind_header_size;
    const putIndex = struct {
        fn f(o: []u8, at: *usize, count: *u32, function: u32, page: u32, lsda: u32) void {
            writeStruct(o[at.*..], macho.unwind_info_section_header_index_entry{ .functionOffset = function, .secondLevelPagesSectionOffset = page, .lsdaIndexArraySectionOffset = lsda });
            at.* += unwind_index_entry_size;
            count.* += 1;
        }
    }.f;
    const first: ?u32 = for (pages) |p| {
        if (p.count > 0) break p.first;
    } else null;
    const lead = out[pages_off..][0..unwind_lead_page_size];
    if (first != null and first.? > text_start) {
        putIndex(out, &index_at, &n, text_start, pages_off, pages_off);
        writeStruct(lead, macho.unwind_info_regular_second_level_page_header{ .entryPageOffset = unwind_page_header_size, .entryCount = 1 });
        writeStruct(lead[unwind_page_header_size..], macho.unwind_info_regular_second_level_entry{ .functionOffset = text_start, .encoding = 0 });
    } else @memset(lead, 0);
    for (pages) |p| if (p.count > 0) {
        putIndex(out, &index_at, &n, p.first, @intCast(p.off), pages_off);
    };
    // The end: past it, no unwind info.
    putIndex(out, &index_at, &n, text_end, 0, pages_off);
    @memset(out[index_at..pages_off], 0);
    writeStruct(out, macho.unwind_info_section_header{
        .version = macho.UNWIND_SECTION_VERSION,
        .commonEncodingsArraySectionOffset = unwind_header_size,
        .commonEncodingsArrayCount = 0,
        .personalityArraySectionOffset = unwind_header_size,
        .personalityArrayCount = 0,
        .indexSectionOffset = unwind_header_size,
        .indexCount = n,
    });
}

/// One `chunk_len` run of consecutive atoms.
const Chunk = struct {
    // Filled in by `Link.layOut`.
    sizes: [n_sects]u64,
    aligns: [n_sects]std.mem.Alignment,
    /// Absolute addresses needing fixups, per section.
    n_fixups: [n_sects]u64,
    n_syms: u32,
    str_len: u32,
    max_targets: u32,
    /// Function starts: offsets within the chunk's __text of its first and
    /// last function (atoms with code), or `no_func`, and the bytes of the
    /// deltas between its functions.
    first_func: u64,
    last_func: u64,
    starts_len: u32,
    // Filled in serially after `Link.layOut`.
    /// Where the chunk's atoms of each section start, within the section.
    bases: [n_sects]u64,
    /// Padding before `bases`, which the chunk fills.
    lead_gaps: [n_sects]u64,
    /// Index of the chunk's first fixup of each section in `Link.fixups`.
    fixups: [n_sects]u64,
    /// The chunk's first symbol and first byte in the string table.
    sym: u32,
    str: u32,
    /// Where the chunk's function starts go in __LINKEDIT, and the file
    /// offset of the function before its first.
    starts_off: u64,
    prev_func: u64,

    const no_func = std.math.maxInt(u64);
};

const Failure = struct { atom: usize, err: Error, diag: Diagnostic };

/// A relocation target: an address, an import's index, or a link-time
/// value.
const Resolved = struct { v: u64, kind: enum(u8) { addr, import, value } };

/// State shared by the threads of `build`, reading atoms from an `Input`
/// (see `Elf.AtomSlice`; the debug declarations are not used).
fn LinkOf(comptime Input: type) type {
    return struct {
        const Link = @This();

        gpa: Allocator,
        input: Input,
        n_atoms: usize,
        n_debug: usize,
        debug_chunks: []Dwarf.Chunk,
        /// Index into its chunk's `files` of each debug entry, or
        /// `Dwarf.skip`.
        file_of: []u32,
        unwind_pages: []UnwindPage,
        places: []Place,
        keys: []SymbolKey,
        chunks: []Chunk,
        /// Maps a key to the index of the atom kept for it, and from
        /// `resolveAddrs` on to its address.
        symbols: *SymbolTable,
        failures: []?Failure,
        section_addrs: [n_sects]u64 = undefined,
        // Set before `copy`.
        values: *const SymbolTable = undefined,
        /// Import key to its index in `Options.imports`.
        imports: *const SymbolTable = undefined,
        buf: []u8 = undefined,
        symtab_off: u64 = undefined,
        strtab_off: u64 = undefined,
        resolved: []Resolved = undefined,
        max_targets: usize = undefined,
        /// File offset of every chained fixup, in address order.
        fixups: []u64 = undefined,
        /// 1-based section number of each section, for symbols.
        sect_index: [n_sects]u8 = undefined,
        stubs_addr: u64 = undefined,
        got_addr: u64 = undefined,
        /// The address of the thread-local template (`__thread_data`, then
        /// `__thread_bss`), and the import number of `__tlv_bootstrap`.
        tlv_template: u64 = undefined,
        tlv_bootstrap: u24 = undefined,
        numbered: ?Symbols,
        /// With numbered symbols, the address table (see `unset`).
        addrs: []u32,
        /// With numbered symbols, the atom numbered `Symbols.entry`, found by
        /// `resolveAddrsNumbered`.
        entry_atom: ?usize = null,
        /// The dSYM's DWARF file, if one is written, and the file offsets
        /// of its debug sections.
        has_dsym: bool = false,
        dsym: Elf.Target = .{ .memory = &.{} },
        dsym_info_off: u64 = 0,
        dsym_ranges_off: u64 = 0,
        dsym_aranges_off: u64 = 0,
        dsym_line_off: u64 = 0,
        /// With a `.file` dSYM, room per thread for a debug chunk's parts.
        dsym_scratch: []u8 = &.{},
        dsym_scratch_len: usize = 0,
        /// File offset of __unwind_info.
        unwind_off: u64 = 0,

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

        pub fn fail(l: *Link, task: usize, atom: usize, err: Error, diag: Diagnostic) void {
            if (l.failures[task] == null) l.failures[task] = .{ .atom = atom, .err = err, .diag = diag };
        }

        fn atomAddr(l: *const Link, index: u64) u64 {
            const p = l.places[index];
            return l.section_addrs[p.section] + l.chunks[index / chunk_len].bases[p.section] + p.offset;
        }

        fn resolveAddrsKeyed(l: *Link, partition: usize, _: usize) void {
            for (l.symbols.partitionEntries(partition)) |*e| {
                if (e.used) e.value = l.atomAddr(e.value);
            }
        }

        /// Sets the addresses of one chunk's atoms' numbers.
        fn resolveAddrsNumbered(l: *Link, chunk: usize, _: usize) void {
            const s = l.numbered.?;
            const begin = chunk * chunk_len;
            const end = @min(l.n_atoms, begin + chunk_len);
            for (s.atoms[begin..end], begin..) |n, i| {
                if (n.symbol >= l.addrs.len) return l.fail(chunk, i, error.InvalidSymbols, .{ .atom = l.input.atom(i).name });
                l.addrs[n.symbol] = @intCast(l.atomAddr(i) - base_address);
                // Numbers are distinct, so one chunk at most writes this.
                if (n.symbol == s.entry) l.entry_atom = i;
            }
        }

        /// Sets `res` to what the targets of `a`, atom `i`, resolve to, from
        /// `addrs`.
        /// As `Elf`'s: each alias takes its target's entry, an address
        /// moved by its addend; imports and values only with an addend of
        /// 0. Targets are all looked up first.
        fn resolveAliases(l: *Link, aliases: []const Elf.Alias, values: *const SymbolTable, imports: *const SymbolTable, diag: *Diagnostic) Error!void {
            if (aliases.len == 0) return;
            const Entry = struct { table: enum { symbols, imports, values, addrs }, v: u64 };
            const resolved = try l.gpa.alloc(Entry, aliases.len);
            defer l.gpa.free(resolved);
            for (aliases, resolved, 0..) |al, *out, i| {
                const fail_diag: Diagnostic = .{ .atom = "alias", .target = al.target };
                if (l.numbered) |s| {
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
                    if (e >= value_tag and al.addend != 0) {
                        diag.* = fail_diag;
                        return error.InvalidRelocation;
                    }
                    const v = @as(i64, e) + if (e < value_tag) al.addend else 0;
                    if (v < 0 or (e < value_tag and v >= value_tag)) return error.RelocationOverflow;
                    out.* = .{ .table = .addrs, .v = @intCast(v) };
                    continue;
                }
                if (l.symbols.get(al.key) != null or imports.get(al.key) != null or values.get(al.key) != null) {
                    diag.* = .{ .atom = "alias", .target = al.key };
                    return error.DuplicateSymbol;
                }
                if (l.symbols.get(al.target)) |v| {
                    out.* = .{ .table = .symbols, .v = @bitCast(@as(i64, @bitCast(v)) +% al.addend) };
                } else if (imports.get(al.target) orelse values.get(al.target)) |v| {
                    if (al.addend != 0) {
                        diag.* = fail_diag;
                        return error.InvalidRelocation;
                    }
                    out.* = .{ .table = if (imports.get(al.target) != null) .imports else .values, .v = v };
                } else {
                    diag.* = fail_diag;
                    return error.UndefinedSymbol;
                }
            }
            for (aliases, resolved, 0..) |al, e, i| {
                const table = switch (e.table) {
                    .addrs => {
                        l.addrs[l.numbered.?.aliases[i].symbol] = @intCast(e.v);
                        continue;
                    },
                    .symbols => l.symbols,
                    .imports => imports,
                    .values => values,
                };
                table.getOrPut(al.key).* = .{ .key = al.key, .value = e.v, .used = true };
            }
        }

        fn resolveNumbered(l: *Link, a: *const Atom, i: usize, chunk: usize, res: []Resolved) bool {
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
                if (e < value_tag) {
                    r.* = .{ .v = base_address + @as(u64, e), .kind = .addr };
                } else if (e == unset) {
                    l.fail(chunk, i, error.UndefinedSymbol, .{ .atom = a.name, .target = t });
                    return false;
                } else if (e - value_tag < s.values.len) {
                    r.* = .{ .v = s.values[e - value_tag].value, .kind = .value };
                } else {
                    r.* = .{ .v = e - value_tag - s.values.len, .kind = .import };
                }
            }
            return true;
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
        /// part of every section started at 0, and counts the fixups its
        /// absolute addresses need.
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
                .n_fixups = @splat(0),
                .n_syms = 0,
                .str_len = 0,
                .max_targets = 0,
                .first_func = undefined,
                .last_func = undefined,
                .starts_len = undefined,
                .bases = undefined,
                .lead_gaps = undefined,
                .fixups = undefined,
                .sym = undefined,
                .str = undefined,
                .starts_off = undefined,
                .prev_func = undefined,
            };
            var first_func: u64 = Chunk.no_func;
            var last_func: u64 = 0;
            var starts_len: u32 = 0;
            for (l.places[begin..end], begin..) |*p, i| {
                // The numbered path's first read of each atom; the key
                // path checked them in `gatherKeys`.
                if (numbered and !l.input.check(i)) {
                    l.fail(chunk, i, error.InvalidInput, .{});
                    continue;
                }
                const atom = l.input.atom(i);
                const a = Elf.ref(&atom);
                if (!numbered) {
                    if (i + 16 < l.keys.len) l.symbols.prefetch(l.keys[i + 16]);
                    const kept = l.symbols.get(l.keys[i]).?;
                    if (kept != i) {
                        const kept_atom = l.input.atom(kept);
                        if (!Elf.identical(Elf.ref(&kept_atom), a)) l.fail(chunk, i, error.DuplicateSymbol, .{ .atom = a.name, .target = a.key });
                        p.* = .duplicate;
                        continue;
                    }
                }
                if ((a.section == .bss or a.section == .tbss) and (a.bytes.len != 0 or a.relocs.len != 0)) {
                    l.fail(chunk, i, error.InvalidRelocation, .{ .atom = a.name });
                    continue;
                }
                var n_abs: u32 = 0;
                if (a.section == .rodata or a.section == .data or a.section == .tdata) {
                    for (a.relocs) |r| n_abs += @intFromBool(r.info.kind == .aarch64_abs64);
                }
                var s: u4 = switch (a.section) {
                    .text => text,
                    .rodata => if (n_abs > 0) data_const else text_const,
                    .data => data,
                    .bss => bss,
                    .tdata => thread_data,
                    .tbss => thread_bss,
                    // Coverage atoms come only from `-ffuzz`, which is
                    // x86_64-linux only for now.
                    .sancov_cntrs, .sancov_pcs => unreachable,
                    // Init and fini arrays come only from ELF objects.
                    .preinit_array, .init_array, .fini_array => unreachable,
                };
                c.n_fixups[s] += n_abs;
                var off = a.alignment.forward(c.sizes[s]);
                if (s == thread_data or s == thread_bss) {
                    // The bytes go in the template (`copy` places them
                    // again); the atom's place is its descriptor's.
                    c.sizes[s] = off + a.size();
                    c.aligns[s] = c.aligns[s].max(a.alignment);
                    s = thread_vars;
                    off = c.sizes[s];
                    c.sizes[s] += tlv_descriptor_size;
                    c.aligns[s] = .@"8";
                    c.n_fixups[s] += 1;
                    p.* = .{ .offset = std.math.cast(u39, off) orelse {
                        l.fail(chunk, i, error.OutOfMemory, .{ .atom = a.name });
                        continue;
                    }, .gap = 0, .section = s };
                    if (a.name.len > 0) {
                        c.n_syms += 1;
                        c.str_len += @intCast(1 + a.name.len + 1);
                    }
                    c.max_targets = @max(c.max_targets, @as(u32, @intCast(a.targets.len)));
                    continue;
                }
                p.* = .{
                    .offset = std.math.cast(u39, off) orelse {
                        l.fail(chunk, i, error.OutOfMemory, .{ .atom = a.name });
                        continue;
                    },
                    .gap = std.math.cast(u21, off - c.sizes[s]) orelse {
                        l.fail(chunk, i, error.AlignmentTooLarge, .{ .atom = a.name });
                        continue;
                    },
                    .section = s,
                };
                c.sizes[s] = off + a.size();
                c.aligns[s] = c.aligns[s].max(a.alignment);
                // Atoms with code have distinct, ascending offsets.
                if (s == text and a.bytes.len > 0) {
                    if (first_func == Chunk.no_func) first_func = off else starts_len += ulebLen(off - last_func);
                    last_func = off;
                }
                if (a.name.len > 0) {
                    c.n_syms += 1;
                    c.str_len += @intCast(1 + a.name.len + 1);
                }
                c.max_targets = @max(c.max_targets, @as(u32, @intCast(a.targets.len)));
            }
            c.first_func = first_func;
            c.last_func = last_func;
            c.starts_len = starts_len;
            l.chunks[chunk] = c;
        }

        /// Copies one chunk's atoms, applies their relocations, records their
        /// fixups, and writes their symbols.
        fn copyKeyed(l: *Link, chunk: usize, thread: usize) void {
            l.copy(chunk, thread, false);
        }

        /// Out of line, so that the key-based `copy` compiles as if alone.
        noinline fn copyNumbered(l: *Link, chunk: usize, thread: usize) void {
            l.copy(chunk, thread, true);
        }

        fn copy(l: *Link, chunk: usize, thread: usize, comptime numbered: bool) void {
            const c = &l.chunks[chunk];
            const resolved = l.resolved[thread * l.max_targets ..][0..l.max_targets];
            for (c.lead_gaps, c.bases, l.section_addrs, 0..) |gap, chunk_base, sa, s| {
                if (zeroFill(s) or gap == 0) continue;
                const start = sa - base_address + chunk_base;
                @memset(l.buf[start - gap .. start], 0);
            }
            var fixup = c.fixups;
            const begin = chunk * chunk_len;
            const end = @min(l.n_atoms, begin + chunk_len);
            var sym_off = l.symtab_off + @as(u64, c.sym) * @sizeOf(macho.nlist_64);
            var str_off = c.str;
            var starts_off = c.starts_off;
            var prev_func = c.prev_func;
            // The chunk's parts of `__thread_data` and `__thread_bss` so far.
            var tlv_sizes: [2]u64 = @splat(0);
            for (l.places[begin..end], begin..) |place, i| {
                if (i + 4 < l.n_atoms) l.input.prefetch(i + 4, !numbered);
                if (!numbered and i + 2 < l.n_atoms) for (l.input.atom(i + 2).targets) |t| l.symbols.prefetch(t);
                if (place.isDuplicate()) continue;
                const atom = l.input.atom(i);
                const a = Elf.ref(&atom);
                const place_addr = l.section_addrs[place.section] + c.bases[place.section] + place.offset;
                var addr = place_addr;
                var sect = place.section;
                var gap: u64 = place.gap;
                if (sect == thread_vars) {
                    // Place the bytes in the template as `layOut` did, and
                    // write the descriptor.
                    sect = if (a.section == .tdata) thread_data else thread_bss;
                    const size = &tlv_sizes[sect - thread_data];
                    const off = a.alignment.forward(size.*);
                    gap = off - size.*;
                    size.* = off + a.size();
                    addr = l.section_addrs[sect] + c.bases[sect] + off;
                    const desc = l.buf[place_addr - base_address ..][0..tlv_descriptor_size];
                    std.mem.writeInt(u64, desc[0..8], bindPointer(l.tlv_bootstrap, 0), .little);
                    std.mem.writeInt(u64, desc[8..16], 0, .little);
                    std.mem.writeInt(u64, desc[16..24], addr - l.tlv_template, .little);
                    l.fixups[fixup[thread_vars]] = place_addr - base_address;
                    fixup[thread_vars] += 1;
                }
                if (!zeroFill(sect)) {
                    const start = addr - base_address;
                    @memset(l.buf[start - gap .. start], 0);
                    const dst = l.buf[start..][0..a.bytes.len];
                    @memcpy(dst, a.bytes);
                    if (sect == text and a.bytes.len > 0) {
                        starts_off += writeUleb(l.buf[starts_off..], start - prev_func);
                        prev_func = start;
                    }
                    const res = resolved[0..a.targets.len];
                    if (numbered) {
                        if (!l.resolveNumbered(a, i, chunk, res)) return;
                    } else for (a.targets, res) |t, *r| {
                        r.* = if (l.symbols.get(t)) |v|
                            .{ .v = v, .kind = .addr }
                        else if (l.imports.get(t)) |v|
                            .{ .v = v, .kind = .import }
                        else if (l.values.get(t)) |v|
                            .{ .v = v, .kind = .value }
                        else {
                            l.fail(chunk, i, error.UndefinedSymbol, .{ .atom = a.name, .target = t });
                            return;
                        };
                    }
                    var diag: Diagnostic = .{};
                    l.applyRelocs(a, dst, addr, sect, res, &fixup[sect], &diag) catch |err| return l.fail(chunk, i, err, diag);
                }
                if (a.name.len > 0) {
                    // Darwin's names have a leading underscore, which
                    // DW_AT_linkage_name and the atom's name leave out.
                    l.buf[l.strtab_off + str_off] = '_';
                    @memcpy(l.buf[l.strtab_off + str_off + 1 ..][0..a.name.len], a.name);
                    l.buf[l.strtab_off + str_off + 1 + a.name.len] = 0;
                    writeStruct(l.buf[sym_off..], nlist(str_off, macho.N_SECT, l.sect_index[place.section], 0, place_addr));
                    sym_off += @sizeOf(macho.nlist_64);
                    str_off += @intCast(1 + a.name.len + 1);
                }
            }
        }

        /// Sizes one debug chunk's entries, collects their files, and
        /// counts its __unwind_info entries.
        fn layOutDebug(l: *Link, chunk: usize, _: usize) void {
            const task = l.chunks.len + chunk;
            Dwarf.layOutChunk(l, chunk, task, text);
            if (l.failures[task] != null) return;
            l.unwind_pages[chunk].count = l.walkDebug(chunk, undefined, false);
        }

        fn copyAll(l: *Link, task: usize, thread: usize) void {
            if (task >= l.chunks.len) return l.copyDebug(task - l.chunks.len, thread);
            if (l.numbered == null) l.copyKeyed(task, thread) else l.copyNumbered(task, thread);
        }

        /// Writes one debug chunk's subprogram entries and line sequences
        /// into the dSYM, if there is one, and its __unwind_info page.
        noinline fn copyDebug(l: *Link, chunk: usize, thread: usize) void {
            _ = l.walkDebug(chunk, thread, true);
        }

        /// Writes `bytes` at `offset` of the dSYM.
        fn putDsym(l: *Link, offset: u64, bytes: []const u8) Error!void {
            switch (l.dsym) {
                .memory => |m| @memcpy(m[offset..][0..bytes.len], bytes),
                .file => |fd| try Elf.pwriteAll(fd, bytes, offset),
            }
        }

        /// Writes `bytes` at `offset` of a debug section of the dSYM.
        fn putDsymDebug(l: *Link, section: Dwarf.Section, offset: u64, bytes: []const u8) Error!void {
            try l.putDsym(offset + switch (section) {
                .info => l.dsym_info_off,
                .ranges => l.dsym_ranges_off,
                .line => l.dsym_line_off,
                .aranges => l.dsym_aranges_off,
            }, bytes);
        }

        /// Counts (`write` false) or writes one debug chunk's __unwind_info
        /// entries, and when writing, its parts of the dSYM. Both passes walk
        /// the entries the same way, so the count is exact: an entry where
        /// each function starts unless it continues the previous entry's
        /// encoding, and an entry with no encoding where each run of
        /// functions ends. A run continues while the next function is the
        /// next code in __text, so padding between functions takes the
        /// encoding before it, as with ld64; code without debug info ends
        /// it.
        fn walkDebug(l: *Link, chunk: usize, thread: usize, comptime write: bool) u32 {
            const begin = chunk * Dwarf.chunk_len;
            const end = @min(l.n_debug, begin + Dwarf.chunk_len);
            const c = &l.debug_chunks[chunk];
            // A local copy: writes to the outputs could alias `l`.
            const input = l.input;
            // Each unit's part of the subprogram entries, range lists, line
            // sequences, and aranges tuples: in the dSYM, or in the thread's
            // scratch, written out at the end.
            const units = c.units.values();
            const dsym = write and l.has_dsym;
            const pieces: [][]u8 = if (dsym) l.gpa.alloc([]u8, 8 * units.len) catch {
                l.fail(l.chunks.len + chunk, begin, error.OutOfMemory, .{});
                return 0;
            } else &.{};
            defer if (dsym) l.gpa.free(pieces);
            var w: Dwarf.ChunkWriter = undefined;
            if (dsym) {
                const n_u = units.len;
                var at: usize = thread * l.dsym_scratch_len;
                for (units, pieces[0..n_u], pieces[n_u..][0..n_u], pieces[2 * n_u ..][0..n_u], pieces[3 * n_u ..][0..n_u]) |u, *i, *r, *ln, *a| {
                    const lens = [4]u64{ u.info_len, u.n_runs * Dwarf.range_len, u.line_len, u.n_runs * Dwarf.aranges_tuple_len };
                    switch (l.dsym) {
                        .memory => |m| {
                            i.* = m[l.dsym_info_off + u.info_off ..][0..lens[0]];
                            r.* = m[l.dsym_ranges_off + u.ranges_off ..][0..lens[1]];
                            ln.* = m[l.dsym_line_off + u.line_off ..][0..lens[2]];
                            a.* = m[l.dsym_aranges_off + u.aranges_off ..][0..lens[3]];
                        },
                        .file => {
                            i.* = l.dsym_scratch[at..][0..lens[0]];
                            r.* = l.dsym_scratch[at + lens[0] ..][0..lens[1]];
                            ln.* = l.dsym_scratch[at + lens[0] + lens[1] ..][0..lens[2]];
                            a.* = l.dsym_scratch[at + lens[0] + lens[1] + lens[2] ..][0..lens[3]];
                            at += lens[0] + lens[1] + lens[2] + lens[3];
                        },
                    }
                }
                @memcpy(pieces[4 * n_u ..], pieces[0 .. 4 * n_u]);
                w = .{ .c = c, .info = pieces[4 * n_u ..][0..n_u], .ranges = pieces[5 * n_u ..][0..n_u], .line = pieces[6 * n_u ..][0..n_u], .aranges = pieces[7 * n_u ..][0..n_u], .text_addr = l.section_addrs[text] };
            }
            const page = if (write) l.buf[l.unwind_off + l.unwind_pages[chunk].off ..][0 .. unwind_page_header_size + l.unwind_pages[chunk].count * unwind_entry_size] else &.{};
            var n: u32 = 0;
            var first: u32 = 0;
            var encoding: u32 = 0;
            var run_end: u32 = 0;
            var prev_atom: u32 = 0;
            for (l.file_of[begin..end], begin..) |file_of, j| {
                // The entries stream; their fragments, names, and atoms do not.
                if (write and j + 12 < end) {
                    input.prefetchDebug(j + 12);
                    @prefetch(&l.places[input.debugAtom(j + 12)], .{});
                }
                if (file_of == Dwarf.skip) continue;
                const debug = input.debug(j);
                const d = Elf.ref(&debug);
                const atom = input.debugAtom(j);
                const a = input.atom(atom);
                const e = unwindEncoding(Elf.ref(&a).unwind);
                const continues = n > 0 and !l.textBetween(prev_atom, atom);
                prev_atom = atom;
                var start: u32 = 0;
                if (write) {
                    const addr = l.atomAddr(atom);
                    const size = a.bytes.len;
                    if (l.has_dsym) w.entry(d, a.name, addr, size, file_of);
                    start = @intCast(addr - base_address);
                }
                if (n > 0 and !continues and encoding != 0) {
                    if (write) putUnwindEntry(page, n, run_end, 0);
                    n += 1;
                    encoding = 0;
                }
                if (n == 0 or e != encoding) {
                    if (write) {
                        if (n == 0) first = start;
                        putUnwindEntry(page, n, start, e);
                    }
                    n += 1;
                    encoding = e;
                }
                if (write) run_end = start + @as(u32, @intCast(input.atom(atom).bytes.len));
            }
            if (n > 0 and encoding != 0) {
                if (write) putUnwindEntry(page, n, run_end, 0);
                n += 1;
            }
            if (write) {
                if (l.has_dsym) w.finish();
                if (l.has_dsym and l.dsym == .file) {
                    const fd = l.dsym.file;
                    const n_u = units.len;
                    for (units, pieces[0..n_u], pieces[n_u..][0..n_u], pieces[2 * n_u ..][0..n_u], pieces[3 * n_u ..][0..n_u]) |u, i, r, ln, a| {
                        Elf.pwriteAll(fd, i, l.dsym_info_off + u.info_off) catch l.fail(l.chunks.len + chunk, begin, error.WriteFailed, .{});
                        Elf.pwriteAll(fd, r, l.dsym_ranges_off + u.ranges_off) catch l.fail(l.chunks.len + chunk, begin, error.WriteFailed, .{});
                        Elf.pwriteAll(fd, ln, l.dsym_line_off + u.line_off) catch l.fail(l.chunks.len + chunk, begin, error.WriteFailed, .{});
                        Elf.pwriteAll(fd, a, l.dsym_aranges_off + u.aranges_off) catch l.fail(l.chunks.len + chunk, begin, error.WriteFailed, .{});
                    }
                }
                std.debug.assert(n == l.unwind_pages[chunk].count);
                if (n > 0) writeStruct(page, macho.unwind_info_regular_second_level_page_header{ .entryPageOffset = unwind_page_header_size, .entryCount = @intCast(n) });
                l.unwind_pages[chunk].first = first;
            }
            return n;
        }

        /// Whether code that is kept lies between atoms `a` and `b`.
        fn textBetween(l: *const Link, a: u32, b: u32) bool {
            for (l.places[a + 1 .. b]) |p| {
                if (p.section == text and !p.isDuplicate()) return true;
            }
            return false;
        }

        fn putUnwindEntry(page: []u8, i: u32, function: u32, encoding: u32) void {
            writeStruct(page[unwind_page_header_size + i * unwind_entry_size ..], macho.unwind_info_regular_second_level_entry{ .functionOffset = function, .encoding = encoding });
        }

        /// Applies `a`'s relocations to its copy `dst` at address `p_base` in
        /// section `sect`, recording fixups from `fixups.*` on.
        fn applyRelocs(l: *const Link, a: *const Atom, dst: []u8, p_base: u64, sect: u4, resolved: []const Resolved, fixups: *u64, diag: *Diagnostic) Error!void {
            for (a.relocs) |r| {
                const width: u4 = switch (r.info.kind) {
                    .aarch64_abs64, .value64 => 8,
                    .value16 => 2,
                    .value8 => 1,
                    else => 4,
                };
                if (r.offset + @as(u64, width) > dst.len or r.info.target >= resolved.len) {
                    diag.* = .{ .atom = a.name };
                    return error.InvalidRelocation;
                }
                const field = dst[r.offset..];
                const t = resolved[r.info.target];
                const p = p_base + r.offset;
                const addend: i64 = r.addend;
                const insn = std.mem.readInt(u32, field[0..4], .little);
                const invalid = error.InvalidRelocation;
                errdefer diag.* = .{ .atom = a.name, .target = a.targets[r.info.target] };
                switch (r.info.kind) {
                    .aarch64_branch26 => {
                        const s = switch (t.kind) {
                            .addr => t.v,
                            .import => l.stubs_addr + stub_size * t.v,
                            .value => return invalid,
                        };
                        const delta: i64 = @bitCast((s +% @as(u64, @bitCast(addend))) -% p);
                        if (delta & 3 != 0 or delta < -(1 << 27) or delta >= 1 << 27) return error.RelocationOverflow;
                        const imm: u32 = @truncate(@as(u64, @bitCast(delta >> 2)) & 0x3ffffff);
                        std.mem.writeInt(u32, field[0..4], (insn & 0xfc000000) | imm, .little);
                    },
                    .aarch64_page21, .aarch64_got_load_page21 => {
                        const s = switch (t.kind) {
                            .addr => t.v,
                            .import => if (r.info.kind == .aarch64_got_load_page21) l.got_addr + 8 * t.v else return invalid,
                            .value => return invalid,
                        };
                        if (r.info.kind == .aarch64_got_load_page21 and addend != 0) return invalid;
                        const pages = pageDelta(s +% @as(u64, @bitCast(addend)), p);
                        if (pages < -(1 << 20) or pages >= 1 << 20) return error.RelocationOverflow;
                        std.mem.writeInt(u32, field[0..4], patchAdrp(insn, pages), .little);
                    },
                    .aarch64_pageoff12 => {
                        if (t.kind != .addr) return invalid;
                        const off: u32 = @truncate((t.v +% @as(u64, @bitCast(addend))) & 0xfff);
                        const scale = pageOffScale(insn) orelse return invalid;
                        if (off & ((@as(u32, 1) << scale) - 1) != 0) return error.RelocationOverflow;
                        std.mem.writeInt(u32, field[0..4], (insn & ~@as(u32, 0xfff << 10)) | ((off >> scale) << 10), .little);
                    },
                    .aarch64_got_load_pageoff12 => {
                        // ldr xt, [xn, #imm12 * 8]
                        if (insn & 0xffc00000 != 0xf9400000 or addend != 0) return invalid;
                        const v: u32 = switch (t.kind) {
                            .import => ((insn & 0xffc003ff) | @as(u32, @intCast(((l.got_addr + 8 * t.v) & 0xfff) >> 3)) << 10),
                            // Defined here: add xt, xn, #lo12(S).
                            .addr => 0x91000000 | (insn & 0x3ff) | @as(u32, @intCast(t.v & 0xfff)) << 10,
                            .value => return invalid,
                        };
                        std.mem.writeInt(u32, field[0..4], v, .little);
                    },
                    .aarch64_abs64 => {
                        if ((sect != data_const and sect != data and sect != thread_data) or p & 3 != 0) return invalid;
                        const v = switch (t.kind) {
                            .addr => rebase: {
                                const target = @as(i128, t.v) + addend - base_address;
                                if (target < 0 or target >= 1 << 36) return error.RelocationOverflow;
                                break :rebase @as(u64, @intCast(target));
                            },
                            .import => bind: {
                                if (addend < 0 or addend > 255) return error.RelocationOverflow;
                                break :bind bindPointer(@intCast(t.v), @intCast(addend));
                            },
                            .value => return invalid,
                        };
                        std.mem.writeInt(u64, field[0..8], v, .little);
                        l.fixups[fixups.*] = p - base_address;
                        fixups.* += 1;
                    },
                    .value8, .value16, .value32, .value64 => {
                        // Addresses are not known before the loader slides
                        // the image; only link-time values qualify.
                        if (t.kind != .value) return invalid;
                        const v = @as(i128, t.v) + addend;
                        switch (r.info.kind) {
                            .value8 => field[0] = std.math.cast(u8, v) orelse return error.RelocationOverflow,
                            .value16 => std.mem.writeInt(u16, field[0..2], std.math.cast(u16, v) orelse return error.RelocationOverflow, .little),
                            .value32 => std.mem.writeInt(u32, field[0..4], std.math.cast(u32, v) orelse return error.RelocationOverflow, .little),
                            .value64 => std.mem.writeInt(u64, field[0..8], std.math.cast(u64, v) orelse return error.RelocationOverflow, .little),
                            else => unreachable,
                        }
                    },
                    .aarch64_movw_value16 => {
                        // movz or movk, w or x.
                        if (t.kind != .value or insn & 0x5f800000 != 0x52800000) return invalid;
                        const v = std.math.cast(u16, @as(i128, t.v) + addend) orelse return error.RelocationOverflow;
                        std.mem.writeInt(u32, field[0..4], (insn & ~@as(u32, 0xffff << 5)) | (@as(u32, v) << 5), .little);
                    },
                    .aarch64_tlvp_page21, .aarch64_tlvp_pageoff12 => {
                        // A thread-local's address is its descriptor's.
                        if (t.kind != .addr or t.v < l.section_addrs[thread_vars] or t.v >= l.tlv_template or addend != 0) return invalid;
                        if (r.info.kind == .aarch64_tlvp_page21) {
                            std.mem.writeInt(u32, field[0..4], patchAdrp(insn, pageDelta(t.v, p)), .little);
                        } else {
                            // add xd, xn, #lo12
                            if (insn & 0xffc00000 != 0x91000000) return invalid;
                            std.mem.writeInt(u32, field[0..4], insn | @as(u32, @intCast(t.v & 0xfff)) << 10, .little);
                        }
                    },
                    .x86_64_abs64, .x86_64_pc32, .x86_64_tpoff32, .x86_64_tlsld, .x86_64_dtpoff32, .x86_64_gottpoff, .x86_64_tlsgd, .x86_64_abs32, .x86_64_abs32s, .x86_64_tpoff64, .x86_64_dtpmod64, .x86_64_tlsdesc => return invalid,
                }
            }
        }
    };
}

/// Page(target) - Page(p), in 4 KiB pages, as adrp computes it.
fn pageDelta(target: u64, p: u64) i64 {
    return @as(i64, @bitCast(target >> 12)) - @as(i64, @bitCast(p >> 12));
}

/// Sets adrp's immhi:immlo to `pages`.
fn patchAdrp(insn: u32, pages: i64) u32 {
    const imm: u32 = @truncate(@as(u64, @bitCast(pages)) & 0x1fffff);
    return (insn & 0x9f00001f) | ((imm & 3) << 29) | ((imm >> 2) << 5);
}

/// log2 of the unit of an instruction's unsigned 12-bit offset: 0 for
/// `add (immediate)`, the access size for loads and stores, or null for an
/// instruction a pageoff12 relocation cannot patch.
fn pageOffScale(insn: u32) ?u5 {
    // add wd|xd, wn|sp, #imm (no shift)
    if (insn & 0x7fc00000 == 0x11000000) return 0;
    // Loads and stores, unsigned offset: size 111 V 01 opc imm12 Rn Rt.
    if (insn & 0x3b000000 == 0x39000000) {
        const size: u5 = @intCast(insn >> 30);
        // V=1 with opc<1>=1 and size 00 is a q register.
        if (insn & 0x04800000 == 0x04800000 and size == 0) return 4;
        return size;
    }
    return null;
}

/// A chained bind (`dyld_chained_ptr_64_bind`) with `next` 0.
fn bindPointer(ordinal: u24, addend: u8) u64 {
    return (1 << 63) | (@as(u64, addend) << 24) | ordinal;
}

fn nlist(strx: u32, n_type: u8, sect: u8, desc: u16, value: u64) macho.nlist_64 {
    return .{ .n_strx = strx, .n_type = @bitCast(n_type), .n_sect = sect, .n_desc = @bitCast(desc), .n_value = value };
}

fn name16(name: []const u8) [16]u8 {
    var n: [16]u8 = @splat(0);
    @memcpy(n[0..name.len], name);
    return n;
}

const CmdWriter = struct {
    buf: []u8,
    at: usize,

    fn put(w: *CmdWriter, cmd: anytype) void {
        writeStruct(w.buf[w.at..], cmd);
        w.at += @sizeOf(@TypeOf(cmd));
    }

    /// A command followed by a NUL-terminated string, zero-padded to `size`.
    fn putWithString(w: *CmdWriter, cmd: anytype, s: []const u8, size: u32) void {
        const end = w.at + size;
        w.put(cmd);
        @memcpy(w.buf[w.at..][0..s.len], s);
        @memset(w.buf[w.at + s.len .. end], 0);
        w.at = end;
    }
};

/// An exports trie with the one symbol every executable exports,
/// `__mh_execute_header` at offset 0: the root node, with no terminal and
/// one edge to the child at offset 0x17, then the child, with a terminal of
/// flags 0 and address 0 and no edges; zero-padded to 8 bytes.
/// Bytes left free after the load commands.
const header_pad = 32;

fn ulebLen(v: u64) u32 {
    return (64 - @clz(v | 1) + 6) / 7;
}

inline fn writeUleb(out: []u8, value: u64) u32 {
    var v = value;
    var i: u32 = 0;
    while (v >= 0x80) : (v >>= 7) {
        out[i] = @as(u8, @truncate(v)) | 0x80;
        i += 1;
    }
    out[i] = @intCast(v);
    return i + 1;
}

const exports_trie = "\x00\x01" ++ mh_execute_header ++ "\x00\x17" ++ "\x02\x00\x00\x00" ++ "\x00\x00\x00\x00\x00";
comptime {
    std.debug.assert(2 + mh_execute_header.len + 2 == 0x17 and exports_trie.len % 8 == 0);
}

/// The chained fixups blob (`LC_DYLD_CHAINED_FIXUPS`): a
/// `dyld_chained_fixups_header`, a `dyld_chained_starts_in_image` with one
/// entry per segment, a `dyld_chained_starts_in_segment` for each segment
/// with fixups, the imports (`DYLD_CHAINED_IMPORT`), and their names.
const ChainedFixupsLayout = struct {
    n_segs: u32,
    /// Offset of each segment's starts from the starts in image, or 0.
    seg_info: [3]u32,
    seg_start: [3]u64,
    page_count: [3]u16,
    imports_off: u32,
    symbols_off: u32,
    size: u32,
    /// Index of __TEXT in `seg_info_offset`; segments that follow it are
    /// numbered in order.
    seg_ordinal: [3]u32,

    const header_size = 28;
    const starts_off = 32;
    const DYLD_CHAINED_PTR_64_OFFSET = 6;
    const DYLD_CHAINED_PTR_START_NONE = 0xffff;
    const DYLD_CHAINED_IMPORT = 1;

    fn init(n_segs: u32, present: [3]bool, has_fixups: [3]bool, seg_start: [3]u64, seg_mem_end: [3]u64, imports: []const Import) ChainedFixupsLayout {
        var cf: ChainedFixupsLayout = .{
            .n_segs = n_segs,
            .seg_info = @splat(0),
            .seg_start = seg_start,
            .page_count = @splat(0),
            .imports_off = undefined,
            .symbols_off = undefined,
            .size = undefined,
            .seg_ordinal = undefined,
        };
        var ordinal: u32 = 1; // __PAGEZERO is 0
        for (present, &cf.seg_ordinal) |p, *o| {
            o.* = ordinal;
            ordinal += @intFromBool(p);
        }
        var at: u32 = 4 + 4 * n_segs;
        for (has_fixups, 0..) |f, seg| if (f) {
            at = std.mem.alignForward(u32, at, 8);
            cf.seg_info[seg] = at;
            cf.page_count[seg] = @intCast((seg_mem_end[seg] - seg_start[seg]) / page_size);
            at += 22 + 2 * @as(u32, cf.page_count[seg]);
        };
        cf.imports_off = std.mem.alignForward(u32, starts_off + at, 4);
        cf.symbols_off = cf.imports_off + 4 * @as(u32, @intCast(imports.len));
        var symbols_len: u32 = 1;
        for (imports) |imp| symbols_len += @intCast(1 + imp.name.len + 1);
        cf.size = std.mem.alignForward(u32, cf.symbols_off + symbols_len, 8);
        return cf;
    }

    /// Writes the blob at `blob_off` in `buf`, the whole output, and links
    /// `fixups` (file offsets of the fixups, equal to their offsets from the
    /// image base, in address order) into one chain per page.
    fn write(cf: ChainedFixupsLayout, buf: []u8, blob_off: u64, fixups: []const u64, imports: []const Import) void {
        const out = buf[blob_off..][0..cf.size];
        @memset(out, 0);
        // dyld_chained_fixups_header
        put32(out, 0, 0); // fixups_version
        put32(out, 4, starts_off);
        put32(out, 8, cf.imports_off);
        put32(out, 12, cf.symbols_off);
        put32(out, 16, @intCast(imports.len));
        put32(out, 20, DYLD_CHAINED_IMPORT);
        put32(out, 24, 0); // uncompressed symbol names
        // dyld_chained_starts_in_image
        const image = out[starts_off..];
        put32(image, 0, cf.n_segs);
        for (cf.seg_info, cf.seg_ordinal) |info, ordinal| if (info != 0) put32(image, 4 + 4 * ordinal, info);
        var next_fixup: usize = 0;
        for (cf.seg_info, cf.seg_start, cf.page_count) |info, seg_start, page_count| {
            if (info == 0) continue;
            // dyld_chained_starts_in_segment
            const s = image[info..];
            put32(s, 0, 22 + 2 * @as(u32, page_count));
            std.mem.writeInt(u16, s[4..6], page_size, .little);
            std.mem.writeInt(u16, s[6..8], DYLD_CHAINED_PTR_64_OFFSET, .little);
            std.mem.writeInt(u64, s[8..16], seg_start, .little);
            put32(s, 16, 0); // max_valid_pointer
            std.mem.writeInt(u16, s[20..22], page_count, .little);
            const page_starts = s[22..][0 .. 2 * @as(usize, page_count)];
            @memset(page_starts, 0xff); // DYLD_CHAINED_PTR_START_NONE
            const seg_end = seg_start + @as(u64, page_count) * page_size;
            var prev: ?u64 = null;
            while (next_fixup < fixups.len and fixups[next_fixup] < seg_end) : (next_fixup += 1) {
                const off = fixups[next_fixup];
                const page = (off - seg_start) / page_size;
                if (prev != null and (prev.? - seg_start) / page_size == page) {
                    // `next`, in 4-byte strides, is bits 51..62; within a
                    // 16 KiB page it always fits.
                    const p = buf[prev.?..][0..8];
                    std.mem.writeInt(u64, p, std.mem.readInt(u64, p, .little) | (((off - prev.?) / 4) << 51), .little);
                } else {
                    std.mem.writeInt(u16, page_starts[2 * page ..][0..2], @intCast((off - seg_start) % page_size), .little);
                }
                prev = off;
            }
        }
        // Imports: library ordinal 1 (libSystem), not weak, name offset.
        var name_off: u32 = 1;
        for (imports, 0..) |imp, i| {
            put32(out, cf.imports_off + 4 * i, 1 | (name_off << 9));
            out[cf.symbols_off + name_off] = '_';
            @memcpy(out[cf.symbols_off + name_off + 1 ..][0..imp.name.len], imp.name);
            name_off += @intCast(1 + imp.name.len + 1);
        }
    }

    fn put32(o: []u8, at: usize, v: u32) void {
        std.mem.writeInt(u32, o[at..][0..4], v, .little);
    }
};

/// Hashes every 4 KiB page before `sig_off` and writes the signature
/// there, after setting the UUID (at `uuid_at`) from the hashes of the
/// other pages, so the file is hashed once. `text_end` is the end of
/// __TEXT in the file, the executable segment.
/// Checks that the entry point, atom `index`, is code.
fn checkEntry(l: anytype, index: usize, key: SymbolKey, diag: *Diagnostic) Error!void {
    if (l.places[index].section == text) return;
    diag.* = .{ .atom = l.input.atom(index).name, .target = key };
    return error.InvalidRelocation;
}

fn sign(io: std.Io, n_threads: usize, buf: []u8, sig_off: u32, uuid_at: usize, identifier: []const u8, text_end: u64) !void {
    const n_slots = std.math.divCeil(u32, sig_off, sig_page_size) catch unreachable;
    const cd_off = sig_off + @sizeOf(macho.SuperBlob) + @sizeOf(macho.BlobIndex);
    const ident_off = @sizeOf(macho.CodeDirectory);
    const hash_off = ident_off + identifier.len + 1;
    const cd_len = hash_off + n_slots * Sha256.digest_length;
    const hashes = buf[cd_off + hash_off ..][0 .. n_slots * Sha256.digest_length];

    const Hasher = struct {
        buf: []const u8,
        hashes: []u8,
        limit: u32,
        const pages_per_task = 64;
        fn task(h: *const @This(), index: usize, _: usize) void {
            // Page 0 holds the UUID and is hashed last.
            const first = @max(1, index * pages_per_task);
            const end = @min(h.hashes.len / Sha256.digest_length, (index + 1) * pages_per_task);
            for (first..end) |page| h.hashPage(page);
        }
        fn hashPage(h: *const @This(), page: usize) void {
            const start = page * sig_page_size;
            const bytes = h.buf[start..@min(h.limit, start + sig_page_size)];
            Sha256.hash(bytes, h.hashes[page * Sha256.digest_length ..][0..Sha256.digest_length], .{});
        }
    };
    const h: Hasher = .{ .buf = buf, .hashes = hashes, .limit = sig_off };
    try parallel(io, n_threads, std.math.divCeil(usize, n_slots, Hasher.pages_per_task) catch unreachable, &h, Hasher.task);
    // UUID: from all page hashes, with page 0 hashed while the UUID is
    // zero; then page 0 again with the UUID in it.
    h.hashPage(0);
    var uuid: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(hashes, &uuid, .{});
    uuid[6] = (uuid[6] & 0x0f) | 0x50; // version 5, name-based (SHA)
    uuid[8] = (uuid[8] & 0x3f) | 0x80; // RFC 4122 variant
    @memcpy(buf[uuid_at..][0..16], uuid[0..16]);
    h.hashPage(0);

    const be = std.builtin.Endian.big;
    const sb = buf[sig_off..];
    std.mem.writeInt(u32, sb[0..4], macho.CSMAGIC_EMBEDDED_SIGNATURE, be);
    std.mem.writeInt(u32, sb[4..8], @intCast(@sizeOf(macho.SuperBlob) + @sizeOf(macho.BlobIndex) + cd_len), be);
    std.mem.writeInt(u32, sb[8..12], 1, be);
    std.mem.writeInt(u32, sb[12..16], macho.CSSLOT_CODEDIRECTORY, be);
    std.mem.writeInt(u32, sb[16..20], @sizeOf(macho.SuperBlob) + @sizeOf(macho.BlobIndex), be);
    var cd: macho.CodeDirectory = .{
        .magic = macho.CSMAGIC_CODEDIRECTORY,
        .length = @intCast(cd_len),
        .version = macho.CS_SUPPORTSEXECSEG,
        .flags = macho.CS_ADHOC | macho.CS_LINKER_SIGNED,
        .hashOffset = @intCast(hash_off),
        .identOffset = ident_off,
        .nSpecialSlots = 0,
        .nCodeSlots = n_slots,
        .codeLimit = sig_off,
        .hashSize = Sha256.digest_length,
        .hashType = macho.CS_HASHTYPE_SHA256,
        .platform = 0,
        .pageSize = std.math.log2_int(u32, sig_page_size),
        .spare2 = 0,
        .scatterOffset = 0,
        .teamOffset = 0,
        .spare3 = 0,
        .codeLimit64 = 0,
        .execSegBase = 0,
        .execSegLimit = text_end,
        .execSegFlags = macho.CS_EXECSEG_MAIN_BINARY,
    };
    std.mem.byteSwapAllFields(macho.CodeDirectory, &cd);
    writeStruct(buf[cd_off..], cd);
    @memcpy(buf[cd_off + ident_off ..][0..identifier.len], identifier);
    buf[cd_off + ident_off + identifier.len] = 0;
}

test "links and runs a program that writes from __TEXT,__const and exits with 42" {
    if (builtin.cpu.arch != .aarch64 or builtin.os.tag != .macos) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const Encoder = @import("../codegen/aarch64/Encoder.zig");

    const msg_text = "Hello from zap!\n";
    const msg: SymbolKey = .fromContents(.rodata, .@"1", msg_text, &.{}, &.{});
    const msg_ptr: SymbolKey = .fromName("msg_ptr");
    const write_ptr: SymbolKey = .fromName("write_ptr");
    const code_const: SymbolKey = .fromName("code_const");
    const status: SymbolKey = .fromName("status");
    const write_msg: SymbolKey = .fromName("write_msg");
    const main: SymbolKey = .fromName("_main");
    const exit_code: SymbolKey = .fromName("exit_code");
    const write: SymbolKey = .fromName("_write");
    const exit: SymbolKey = .fromName("_exit");

    // write(1, msg_ptr.*, len), branching to `write` through its stub; the
    // string is reached through a rebased pointer in __data.
    var w: Encoder = .init(gpa);
    defer w.deinit();
    try w.stp(.dword, .fp, .lr, .{ .base = .sp, .offset = .{ .pre = -16 } });
    try w.mov(.x, .fp, .sp);
    try w.movz(.x, .x0, 1, 0);
    try w.adrp(.x1, msg_ptr, 0);
    try w.ldr(.dword, .x1, .{ .base = .x1, .offset = .{ .page_off = .{ .sym = msg_ptr } } });
    try w.movz(.x, .x2, msg_text.len, 0);
    try w.bl(.{ .sym = write });
    try w.ldp(.dword, .fp, .lr, .{ .base = .sp, .offset = .{ .post = 16 } });
    try w.ret();
    try w.finish();

    // status = exit_code, a link-time value read from __TEXT,__const,
    // stored through a GOT load of a local symbol (relaxed to adrp, add).
    // The bound pointer to `write` in __DATA_CONST must equal its GOT slot.
    // Then exit(status) through the GOT, or trap.
    var s: Encoder = .init(gpa);
    defer s.deinit();
    const trap = try s.newLabel();
    try s.stp(.dword, .fp, .lr, .{ .base = .sp, .offset = .{ .pre = -16 } });
    try s.mov(.x, .fp, .sp);
    try s.bl(.{ .sym = write_msg });
    try s.adrp(.x8, code_const, 0);
    try s.ldr(.word, .x9, .{ .base = .x8, .offset = .{ .page_off = .{ .sym = code_const, .addend = 4 } } });
    try s.loadGotAddr(.x10, status);
    try s.str(.word, .x9, .at(.x10, 0));
    try s.loadAddr(.x11, write_ptr, 0);
    try s.ldr(.dword, .x11, .at(.x11, 0));
    try s.loadGotAddr(.x12, write);
    try s.cmp(.x, .x11, .r(.x12));
    try s.bcond(.ne, trap);
    try s.ldr(.word, .x0, .at(.x10, 0));
    try s.movWideValue(.movz, .w, .x16, exit_code, 0);
    try s.cmp(.w, .x0, .r(.x16));
    try s.bcond(.ne, trap);
    try s.loadGotAddr(.x16, exit);
    try s.blr(.x16);
    s.bind(trap);
    try s.brk(1);
    try s.finish();

    const msg_atom: Atom = .{ .key = msg, .name = "__anon_msg", .section = .rodata, .bytes = msg_text };
    const atoms = [_]Atom{
        .{ .key = main, .name = "main", .section = .text, .alignment = .@"4", .bytes = s.code.items, .targets = s.refs.targets.keys(), .relocs = s.refs.relocs.items },
        msg_atom,
        .{ .key = write_msg, .name = "write_msg", .section = .text, .alignment = .@"4", .bytes = w.code.items, .targets = w.refs.targets.keys(), .relocs = w.refs.relocs.items },
        .{ .key = status, .name = "status", .section = .bss, .alignment = .@"4", .zero_fill = 4 },
        .{ .key = msg_ptr, .name = "msg_ptr", .section = .data, .alignment = .@"8", .bytes = &@as([8]u8, @splat(0)), .targets = &.{msg}, .relocs = &.{
            .init(0, .aarch64_abs64, 0, 0),
        } },
        .{ .key = write_ptr, .name = "write_ptr", .section = .rodata, .alignment = .@"8", .bytes = &@as([8]u8, @splat(0)), .targets = &.{write}, .relocs = &.{
            .init(0, .aarch64_abs64, 0, 0),
        } },
        .{ .key = code_const, .name = "code_const", .section = .rodata, .alignment = .@"4", .bytes = &@as([8]u8, @splat(0)), .targets = &.{exit_code}, .relocs = &.{
            .init(4, .value32, 0, 0),
        } },
        // A second function's copy of the same constant.
        msg_atom,
    };
    const options: Options = .{
        .entry = main,
        .imports = &.{ .{ .key = write, .name = "write" }, .{ .key = exit, .name = "exit" } },
        .values = &.{.{ .key = exit_code, .value = 42 }},
        .identifier = "hello",
    };

    const bytes = try emit(gpa, io, &atoms, options);
    defer gpa.free(bytes);
    try std.testing.expectEqual(1, std.mem.count(u8, bytes, msg_text));
    const four = try emit(gpa, io, &atoms, o: {
        var o = options;
        o.threads = 4;
        break :o o;
    });
    defer gpa.free(four);
    try std.testing.expectEqualSlices(u8, bytes, four);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try link(gpa, io, tmp.dir, "hello", &atoms, options);
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/hello", .{tmp.sub_path});
    defer gpa.free(path);
    // `link` names the signature after the file, as `emit` was told to.
    const file = try tmp.dir.readFileAlloc(io, "hello", gpa, .unlimited);
    defer gpa.free(file);
    try std.testing.expectEqualSlices(u8, bytes, file);
    const result = try std.process.run(gpa, io, .{ .argv = &.{path} });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqualStrings(msg_text, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 42 }, result.term);

    const verify = try std.process.run(gpa, io, .{ .argv = &.{ "codesign", "--verify", "--strict", path } });
    defer gpa.free(verify.stdout);
    defer gpa.free(verify.stderr);
    try std.testing.expectEqualStrings("", verify.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, verify.term);

    // The same key with different contents is a conflict, not a duplicate;
    // absolute addresses in code have no fixup to carry them.
    var diag: Diagnostic = .{};
    const conflicting = [_]Atom{ atoms[0], .{ .key = main, .name = "other", .section = .text, .bytes = "\xc0\x03\x5f\xd6" } };
    try std.testing.expectError(error.DuplicateSymbol, emit(gpa, io, &conflicting, .{ .entry = main, .diag = &diag }));
    try std.testing.expectEqualStrings("other", diag.atom);
    const abs_in_text = [_]Atom{.{ .key = main, .name = "main", .section = .text, .bytes = &@as([8]u8, @splat(0)), .targets = &.{main}, .relocs = &.{.init(0, .aarch64_abs64, 0, 0)} }};
    try std.testing.expectError(error.InvalidRelocation, emit(gpa, io, &abs_in_text, .{ .entry = main }));
    // A movz takes only a link-time value, and only one that fits 16 bits.
    try std.testing.expectError(error.RelocationOverflow, emit(gpa, io, &atoms, o: {
        var o = options;
        o.values = &.{.{ .key = exit_code, .value = 0x10000 }};
        break :o o;
    }));
    const movz_of_addr = [_]Atom{.{ .key = main, .name = "main", .section = .text, .bytes = "\x00\x00\x80\x52", .targets = &.{main}, .relocs = &.{.init(0, .aarch64_movw_value16, 0, 0)} }};
    try std.testing.expectError(error.InvalidRelocation, emit(gpa, io, &movz_of_addr, .{ .entry = main }));
}

test "an alias links as a reference to its target, with numbered symbols too" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const main: SymbolKey = .fromName("main");
    const msg: SymbolKey = .fromName("msg");
    const write: SymbolKey = .fromName("import.write");
    const v: SymbolKey = .fromName("value");
    const msg_alias: SymbolKey = .fromName("extaddr.msg");
    const write_alias: SymbolKey = .fromName("extaddr.write");
    const v_alias: SymbolKey = .fromName("extaddr.value");
    const zeros: [24]u8 = @splat(0);
    // A constant holding an address inside `msg` (a rebase), an import's
    // address (a bind), and a value: through aliases, then directly.
    const relocs = [2][3]Atom.Reloc{
        .{ .init(0, .aarch64_abs64, 0, 1), .init(8, .aarch64_abs64, 1, 0), .init(16, .value64, 2, 0) },
        .{ .init(0, .aarch64_abs64, 0, 4), .init(8, .aarch64_abs64, 1, 0), .init(16, .value64, 2, 0) },
    };
    var atoms: [2][3]Atom = undefined;
    for (&atoms, [_][]const SymbolKey{ &.{ msg_alias, write_alias, v_alias }, &.{ msg, write, v } }, &relocs) |*set, targets, *set_relocs| set.* = .{
        .{ .key = main, .name = "main", .section = .text, .alignment = .@"4", .bytes = "\xc0\x03\x5f\xd6" },
        .{ .key = msg, .name = "msg", .section = .rodata, .bytes = "hi from dyld\x00" },
        .{ .key = .fromName("table"), .name = "table", .section = .data, .alignment = .@"8", .bytes = &zeros, .targets = targets, .relocs = set_relocs },
    };
    const imports = [_]Import{.{ .key = write, .name = "write" }};
    const values = [_]Value{.{ .key = v, .value = 5 }};
    const aliases = [_]Elf.Alias{
        .{ .key = msg_alias, .target = msg, .addend = 3 },
        .{ .key = write_alias, .target = write, .addend = 0 },
        .{ .key = v_alias, .target = v, .addend = 0 },
    };
    const want = try emit(gpa, io, &atoms[1], .{ .entry = main, .imports = &imports, .values = &values });
    defer gpa.free(want);
    const linked = try emit(gpa, io, &atoms[0], .{ .entry = main, .imports = &imports, .values = &values, .aliases = &aliases });
    defer gpa.free(linked);
    try std.testing.expectEqualSlices(u8, want, linked);

    // Numbers: the atoms, the import, the value, then the aliases.
    const numbering = [_]SymbolKey{ main, msg, .fromName("table"), write, v, msg_alias, write_alias, v_alias };
    var numbered_atoms: [3]Elf.NumberedAtom = undefined;
    var targets: std.ArrayList(u32) = .empty;
    defer targets.deinit(gpa);
    for (atoms[0], &numbered_atoms, 0..) |a, *n, i| {
        n.* = .{ .symbol = @intCast(i), .targets = @intCast(targets.items.len) };
        for (a.targets) |t| try targets.append(gpa, @intCast(std.mem.indexOfScalar(SymbolKey, &numbering, t).?));
    }
    const numbered = try emit(gpa, io, &atoms[0], .{ .entry = main, .imports = &imports, .aliases = &aliases, .symbols = .{
        .atoms = &numbered_atoms,
        .targets = targets.items,
        .values = &.{.{ .symbol = 4, .value = 5 }},
        .imports = &.{3},
        .aliases = &.{ .{ .symbol = 5, .target = 1 }, .{ .symbol = 6, .target = 3 }, .{ .symbol = 7, .target = 4 } },
        .entry = 0,
        .len = numbering.len,
    } });
    defer gpa.free(numbered);
    try std.testing.expectEqualSlices(u8, want, numbered);

    var moved = aliases;
    moved[1].addend = 8;
    try std.testing.expectError(error.InvalidRelocation, emit(gpa, io, &atoms[0], .{ .entry = main, .imports = &imports, .values = &values, .aliases = &moved }));
}

test "gives each thread its own thread-locals from __thread_data and __thread_bss" {
    if (builtin.cpu.arch != .aarch64 or builtin.os.tag != .macos) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const Encoder = @import("../codegen/aarch64/Encoder.zig");

    const main: SymbolKey = .fromName("main");
    const run: SymbolKey = .fromName("run");
    const counter: SymbolKey = .fromName("counter");
    const ptr: SymbolKey = .fromName("ptr");
    const zero: SymbolKey = .fromName("zero");
    const big: SymbolKey = .fromName("big");
    const target: SymbolKey = .fromName("target");
    const pthread_create: SymbolKey = .fromName("pthread_create");
    const pthread_join: SymbolKey = .fromName("pthread_join");
    const exit: SymbolKey = .fromName("exit");

    // run(arg): counter += arg; zero += 1; big[3] = 1; return counter.
    var r: Encoder = .init(gpa);
    defer r.deinit();
    try r.stp(.dword, .fp, .lr, .{ .base = .sp, .offset = .{ .pre = -32 } });
    try r.mov(.x, .fp, .sp);
    try r.str(.dword, .x0, .at(.sp, 16));
    try r.threadLocalAddr(counter);
    try r.ldr(.dword, .x9, .at(.x0, 0));
    try r.ldr(.dword, .x10, .at(.sp, 16));
    try r.addSub(.add, .x, .x9, .x9, .r(.x10));
    try r.str(.dword, .x9, .at(.x0, 0));
    try r.str(.dword, .x9, .at(.sp, 24));
    try r.threadLocalAddr(zero);
    try r.ldr(.word, .x9, .at(.x0, 0));
    try r.addSub(.add, .w, .x9, .x9, .{ .imm = 1 });
    try r.str(.word, .x9, .at(.x0, 0));
    try r.threadLocalAddr(big);
    try r.movz(.w, .x9, 1, 0);
    try r.str(.byte, .x9, .at(.x0, 3));
    try r.ldr(.dword, .x0, .at(.sp, 24));
    try r.ldp(.dword, .fp, .lr, .{ .base = .sp, .offset = .{ .post = 32 } });
    try r.ret();
    try r.finish();

    // Run `run(10)` on a thread, which must return 15, then check that
    // this thread's copies are the initial ones: counter 5, zero and big
    // zero, big 16-byte aligned, and ptr the rebased address of `target`.
    var m: Encoder = .init(gpa);
    defer m.deinit();
    const trap = try m.newLabel();
    try m.stp(.dword, .fp, .lr, .{ .base = .sp, .offset = .{ .pre = -48 } });
    try m.mov(.x, .fp, .sp);
    try m.addSub(.add, .x, .x0, .sp, .{ .imm = 32 });
    try m.movz(.x, .x1, 0, 0);
    try m.loadAddr(.x2, run, 0);
    try m.movz(.x, .x3, 10, 0);
    try m.bl(.{ .sym = pthread_create });
    try m.cbz(true, .w, .x0, trap);
    try m.ldr(.dword, .x0, .at(.sp, 32));
    try m.addSub(.add, .x, .x1, .sp, .{ .imm = 40 });
    try m.bl(.{ .sym = pthread_join });
    try m.cbz(true, .w, .x0, trap);
    try m.ldr(.dword, .x9, .at(.sp, 40));
    try m.cmp(.x, .x9, .{ .imm = 15 });
    try m.bcond(.ne, trap);
    try m.threadLocalAddr(counter);
    try m.ldr(.dword, .x9, .at(.x0, 0));
    try m.cmp(.x, .x9, .{ .imm = 5 });
    try m.bcond(.ne, trap);
    try m.threadLocalAddr(zero);
    try m.ldr(.word, .x9, .at(.x0, 0));
    try m.cbz(true, .w, .x9, trap);
    try m.threadLocalAddr(big);
    try m.ldr(.byte, .x9, .at(.x0, 3));
    try m.cbz(true, .w, .x9, trap);
    try m.tst(.x, .x0, .{ .imm = 15 });
    try m.bcond(.ne, trap);
    try m.threadLocalAddr(ptr);
    try m.ldr(.dword, .x9, .at(.x0, 0));
    try m.loadAddr(.x10, target, 0);
    try m.cmp(.x, .x9, .r(.x10));
    try m.bcond(.ne, trap);
    try m.movz(.w, .x0, 42, 0);
    try m.bl(.{ .sym = exit });
    m.bind(trap);
    try m.brk(1);
    try m.finish();

    const atoms = [_]Atom{
        .{ .key = main, .name = "main", .section = .text, .alignment = .@"4", .bytes = m.code.items, .targets = m.refs.targets.keys(), .relocs = m.refs.relocs.items },
        .{ .key = zero, .name = "zero", .section = .tbss, .alignment = .@"4", .zero_fill = 4 },
        .{ .key = counter, .name = "counter", .section = .tdata, .alignment = .@"8", .bytes = &.{ 5, 0, 0, 0, 0, 0, 0, 0 } },
        .{ .key = run, .name = "run", .section = .text, .alignment = .@"4", .bytes = r.code.items, .targets = r.refs.targets.keys(), .relocs = r.refs.relocs.items },
        .{ .key = big, .name = "big", .section = .tbss, .alignment = .@"16", .zero_fill = 100 },
        .{ .key = ptr, .name = "ptr", .section = .tdata, .alignment = .@"8", .bytes = &@as([8]u8, @splat(0)), .targets = &.{target}, .relocs = &.{.init(0, .aarch64_abs64, 0, 0)} },
        .{ .key = target, .name = "target", .section = .data, .alignment = .@"8", .bytes = &@as([8]u8, @splat(0)) },
    };
    const options: Options = .{
        .entry = main,
        .imports = &.{ .{ .key = pthread_create, .name = "pthread_create" }, .{ .key = pthread_join, .name = "pthread_join" }, .{ .key = exit, .name = "exit" } },
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try link(gpa, io, tmp.dir, "tlv", &atoms, options);
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/tlv", .{tmp.sub_path});
    defer gpa.free(path);
    const result = try std.process.run(gpa, io, .{ .argv = &.{path} });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 42 }, result.term);

    // A tlvp relocation takes only a thread-local.
    var diag: Diagnostic = .{};
    var bad = atoms;
    bad[0].targets = &.{target};
    bad[0].relocs = &.{.init(0, .aarch64_tlvp_page21, 0, 0)};
    try std.testing.expectError(error.InvalidRelocation, emit(gpa, io, &bad, .{ .entry = main, .imports = options.imports, .diag = &diag }));
}

test "links many chunks of atoms and pages of fixups the same way on any number of threads" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const Encoder = @import("../codegen/aarch64/Encoder.zig");
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // f_i adds the 4-byte constant c_(i % 50) = i % 50 + 1 to w19 and
    // branches to f_(i+1); the last one branches to `finish`. Most
    // constants are duplicates, many in other chunks; alignments vary.
    // `finish` walks a list of nodes { next, value pointer } that alternate
    // between __data and __DATA_CONST, so both segments have several pages
    // of chained rebases, adds each value to w19, writes a message, and
    // exits with w19. Some f_i also add a thread-local from .tdata (whose
    // value is i % 50 + 1) or .tbss (0), spread over the chunks.
    const n = 2 * chunk_len + 300;
    const n_nodes = 3000;
    const msg_text = "chunks ok\n";
    const msg: SymbolKey = .fromContents(.rodata, .@"1", msg_text, &.{}, &.{});
    const finish: SymbolKey = .fromName("finish");
    const main: SymbolKey = .fromName("_main");
    const write: SymbolKey = .fromName("_write");
    const exit: SymbolKey = .fromName("_exit");
    var constants: [50]Atom = undefined;
    for (&constants, 0..) |*c, j| {
        const bytes = try arena.dupe(u8, std.mem.asBytes(&@as(u32, @intCast(j + 1))));
        c.* = .{ .key = .fromContents(.rodata, .@"4", bytes, &.{}, &.{}), .name = "", .section = .rodata, .alignment = .@"4", .bytes = bytes };
    }
    const key = struct {
        fn f(prefix: []const u8, i: usize) SymbolKey {
            var buf: [32]u8 = undefined;
            return .fromName(std.fmt.bufPrint(&buf, "{s}{d}", .{ prefix, i }) catch unreachable);
        }
    }.f;

    var atoms: std.ArrayList(Atom) = .empty;
    var expected: u32 = 0;
    for (0..n) |i| {
        var e: Encoder = .init(arena);
        const c = constants[i % 50].key;
        try e.adrp(.x9, c, 0);
        try e.ldr(.word, .x9, .{ .base = .x9, .offset = .{ .page_off = .{ .sym = c } } });
        try e.addSub(.add, .w, .x19, .x19, .r(.x9));
        if (i % 97 == 0 or i % 89 == 0) {
            const tdata = i % 97 == 0;
            const tl = key(if (tdata) "td" else "tb", i);
            try e.threadLocalAddr(tl);
            try e.ldr(.word, .x9, .at(.x0, 0));
            try e.addSub(.add, .w, .x19, .x19, .r(.x9));
            const alignment: std.mem.Alignment = if (i % 2 == 0) .@"4" else .@"16";
            if (tdata) {
                expected +%= @intCast(i % 50 + 1);
                const bytes = try arena.dupe(u8, std.mem.asBytes(&@as(u32, @intCast(i % 50 + 1))));
                try atoms.append(arena, .{ .key = tl, .name = "td", .section = .tdata, .alignment = alignment, .bytes = bytes });
            } else {
                try atoms.append(arena, .{ .key = tl, .name = "tb", .section = .tbss, .alignment = alignment, .zero_fill = 4 + i % 5 });
            }
        }
        try e.b(.{ .sym = if (i + 1 < n) key("f", i + 1) else finish });
        try e.finish();
        expected +%= @intCast(i % 50 + 1);
        const alignments = [_]std.mem.Alignment{ .@"4", .@"16", .@"64" };
        try atoms.append(arena, .{ .key = key("f", i), .name = try std.fmt.allocPrint(arena, "f{d}", .{i}), .section = .text, .alignment = alignments[i % 3], .bytes = e.code.items, .targets = e.refs.targets.keys(), .relocs = e.refs.relocs.items });
        try atoms.append(arena, constants[i % 50]);
        if (i % 7 == 0) try atoms.append(arena, .{ .key = key("pad", i), .name = "pad", .section = .bss, .alignment = .@"8", .zero_fill = i % 13 });
    }
    for (0..n_nodes) |k| {
        const last = k + 1 == n_nodes;
        const targets = try arena.dupe(SymbolKey, if (last) &.{constants[k % 50].key} else &.{ constants[k % 50].key, key("node", k + 1) });
        const relocs: []const Atom.Reloc = if (last) &.{.init(8, .aarch64_abs64, 0, 0)} else &.{ .init(0, .aarch64_abs64, 1, 0), .init(8, .aarch64_abs64, 0, 0) };
        expected +%= @intCast(k % 50 + 1);
        try atoms.append(arena, .{ .key = key("node", k), .name = "node", .section = if (k % 2 == 0) .data else .rodata, .alignment = .@"8", .bytes = &@as([16]u8, @splat(0)), .targets = targets, .relocs = relocs });
    }

    var f: Encoder = .init(arena);
    const loop = try f.newLabel();
    try f.loadAddr(.x20, key("node", 0), 0);
    f.bind(loop);
    try f.ldr(.dword, .x1, .at(.x20, 8));
    try f.ldr(.word, .x1, .at(.x1, 0));
    try f.addSub(.add, .w, .x19, .x19, .r(.x1));
    try f.ldr(.dword, .x20, .at(.x20, 0));
    try f.cbz(true, .x, .x20, loop);
    try f.movz(.x, .x0, 1, 0);
    try f.loadAddr(.x1, msg, 0);
    try f.movz(.x, .x2, msg_text.len, 0);
    try f.bl(.{ .sym = write });
    try f.uxt(.byte, .x0, .x19);
    try f.bl(.{ .sym = exit });
    try f.finish();
    try atoms.append(arena, .{ .key = finish, .name = "finish", .section = .text, .alignment = .@"4", .bytes = f.code.items, .targets = f.refs.targets.keys(), .relocs = f.refs.relocs.items });
    try atoms.append(arena, .{ .key = msg, .name = "msg", .section = .rodata, .bytes = msg_text });
    var s: Encoder = .init(arena);
    try s.movz(.x, .x19, 0, 0);
    try s.b(.{ .sym = key("f", 0) });
    try s.finish();
    try atoms.append(arena, .{ .key = main, .name = "main", .section = .text, .alignment = .@"4", .bytes = s.code.items, .targets = s.refs.targets.keys(), .relocs = s.refs.relocs.items });

    const imports: []const Import = &.{ .{ .key = write, .name = "write" }, .{ .key = exit, .name = "exit" } };
    const one = try emit(gpa, io, atoms.items, .{ .entry = main, .imports = imports, .threads = 1, .identifier = "chunks" });
    defer gpa.free(one);
    const four = try emit(gpa, io, atoms.items, .{ .entry = main, .imports = imports, .threads = 4, .identifier = "chunks" });
    defer gpa.free(four);
    try std.testing.expectEqualSlices(u8, one, four);

    // The function starts list every function, the symbols in __text, in
    // address order, across chunks.
    {
        var from_symtab: std.ArrayList(u64) = .empty;
        const st = testMachOCommand(macho.symtab_command, one, .SYMTAB).?;
        for (0..st.nsyms) |i| {
            const sym = std.mem.bytesToValue(macho.nlist_64, one[st.symoff + i * @sizeOf(macho.nlist_64) ..][0..@sizeOf(macho.nlist_64)]);
            // Not __mh_execute_header, the one external symbol.
            if (sym.n_sect == 1 and !sym.n_type.bits.ext) try from_symtab.append(arena, sym.n_value - base_address);
        }
        std.mem.sortUnstable(u64, from_symtab.items, {}, std.sort.asc(u64));
        const fs = testMachOCommand(macho.linkedit_data_command, one, .FUNCTION_STARTS).?;
        try std.testing.expect(fs.datasize % 8 == 0 and fs.dataoff < st.symoff);
        var r: std.Io.Reader = .fixed(one[fs.dataoff..][0..fs.datasize]);
        var from_starts: std.ArrayList(u64) = .empty;
        var addr: u64 = 0;
        while (true) {
            const delta = try r.takeLeb128(u64);
            if (delta == 0) break;
            addr += delta;
            try from_starts.append(arena, addr);
        }
        try std.testing.expectEqual(n + 2, from_starts.items.len);
        try std.testing.expectEqualSlices(u64, from_symtab.items, from_starts.items);
        // Room after the load commands.
        const hdr = std.mem.bytesToValue(macho.mach_header_64, one[0..@sizeOf(macho.mach_header_64)]);
        try std.testing.expect(testMachOSection(one, "__text").?.offset >= @sizeOf(macho.mach_header_64) + hdr.sizeofcmds + 32);
    }

    // Numbered symbols, as the cache's manifest supplies them: the atoms
    // the key-based link keeps, in its order, then the imports, numbered
    // densely, give the same bytes as the key-based link of those atoms.
    // (Not of all atoms: chunks of other atoms align differently.)
    var numbers: std.AutoHashMapUnmanaged(SymbolKey, u32) = .empty;
    var kept: std.ArrayList(Atom) = .empty;
    for (atoms.items) |a| {
        const gop = try numbers.getOrPut(arena, a.key);
        if (gop.found_existing) continue;
        gop.value_ptr.* = @intCast(kept.items.len);
        try kept.append(arena, a);
    }
    const import_numbers = try arena.alloc(u32, imports.len);
    for (imports, import_numbers, 0..) |imp, *num, i| {
        num.* = @intCast(kept.items.len + i);
        try numbers.put(arena, imp.key, num.*);
    }
    const numbered_atoms = try arena.alloc(Elf.NumberedAtom, kept.items.len);
    var targets: std.ArrayList(u32) = .empty;
    for (numbered_atoms, kept.items, 0..) |*num, a, i| {
        num.* = .{ .symbol = @intCast(i), .targets = @intCast(targets.items.len) };
        for (a.targets) |t| try targets.append(arena, numbers.get(t).?);
    }
    var symbols: Symbols = .{ .atoms = numbered_atoms, .targets = targets.items, .imports = import_numbers, .entry = numbers.get(main).?, .len = @intCast(numbers.count()) };
    const keyed = try emit(gpa, io, kept.items, .{ .entry = main, .imports = imports, .identifier = "chunks" });
    defer gpa.free(keyed);
    for ([_]usize{ 1, 4 }) |threads| {
        const numbered = try emit(gpa, io, kept.items, .{ .entry = main, .imports = imports, .threads = threads, .identifier = "chunks", .symbols = symbols });
        defer gpa.free(numbered);
        try std.testing.expectEqualSlices(u8, keyed, numbered);
    }
    // So does an input returning records by value, which the linker checks
    // before reading, with the runs split between `targets` and
    // `targets_tail`. Of several invalid records, the lowest is reported.
    const checked = try arena.alloc(std.atomic.Value(bool), kept.items.len);
    @memset(checked, .init(false));
    const input: Elf.TestInput = .{ .slice = .{ .atoms = kept.items, .debug_entries = &.{} }, .checked = checked };
    var split = symbols;
    const half = numbered_atoms[kept.items.len / 2].targets;
    split.targets = targets.items[0..half];
    split.targets_tail = targets.items[half..];
    for ([_]?Symbols{ null, split }) |input_symbols| {
        const from_input = try emitInput(gpa, io, input, .{ .entry = main, .imports = imports, .threads = 4, .identifier = "chunks", .symbols = input_symbols });
        defer gpa.free(from_input);
        try std.testing.expectEqualSlices(u8, keyed, from_input);
        var bad = input;
        bad.bad = &.{ kept.items.len - 1, 2500 };
        var input_diag: Diagnostic = .{};
        try std.testing.expectError(error.InvalidInput, emitInput(gpa, io, bad, .{ .entry = main, .imports = imports, .threads = 4, .symbols = input_symbols, .diag = &input_diag }));
        try std.testing.expectEqual(2500, input_diag.index.?);
    }
    // A run may not straddle the two.
    const two = for (kept.items, 0..) |a, i| {
        if (a.targets.len >= 2) break i;
    } else unreachable;
    split.targets = targets.items[0 .. numbered_atoms[two].targets + 1];
    split.targets_tail = targets.items[numbered_atoms[two].targets + 1 ..];
    try std.testing.expectError(error.InvalidSymbols, emitInput(gpa, io, input, .{ .entry = main, .imports = imports, .symbols = split }));
    // An import's number left undefined, and an entry that is not code.
    var diag: Diagnostic = .{};
    symbols.imports = &.{ import_numbers[0], symbols.len };
    try std.testing.expectError(error.InvalidSymbols, emit(gpa, io, kept.items, .{ .entry = main, .imports = imports, .symbols = symbols }));
    symbols.imports = &.{ import_numbers[0], import_numbers[0] };
    try std.testing.expectError(error.UndefinedSymbol, emit(gpa, io, kept.items, .{ .entry = main, .imports = imports, .symbols = symbols, .diag = &diag }));
    try std.testing.expectEqual(exit, diag.target.?);
    symbols.imports = import_numbers;
    symbols.entry = numbers.get(msg).?;
    try std.testing.expectError(error.InvalidRelocation, emit(gpa, io, kept.items, .{ .entry = main, .imports = imports, .symbols = symbols, .diag = &diag }));
    try std.testing.expectEqualStrings("msg", diag.atom);

    // Running the output needs a Mac.
    if (builtin.cpu.arch != .aarch64 or builtin.os.tag != .macos) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try link(gpa, io, tmp.dir, "chunks", atoms.items, .{ .entry = main, .imports = imports, .threads = 3 });
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/chunks", .{tmp.sub_path});
    defer gpa.free(path);
    const file = try tmp.dir.readFileAlloc(io, "chunks", gpa, .unlimited);
    defer gpa.free(file);
    try std.testing.expectEqualSlices(u8, one, file);
    const result = try std.process.run(gpa, io, .{ .argv = &.{path} });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqualStrings(msg_text, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = @truncate(expected) }, result.term);
}

test "writes a dSYM that std.debug symbolizes and __unwind_info for each function" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const Encoder = @import("../codegen/aarch64/Encoder.zig");
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // _main, which has no debug info, calls f_0. f_i adds 1 to w19 on line
    // i + 2, column 5, of its file, and calls f_(i+1) inside a frame-pointer
    // frame; every tenth is naked and tail-calls instead. Every seventh is
    // followed by a function without debug info, and one function appears
    // twice, the copy's entry losing with it. _main exits with w19.
    const n = 2 * Dwarf.chunk_len + 300;
    const main: SymbolKey = .fromName("_main");
    const fkey = struct {
        fn f(prefix: []const u8, i: usize) SymbolKey {
            var buf: [32]u8 = undefined;
            return .fromName(std.fmt.bufPrint(&buf, "{s}{d}", .{ prefix, i }) catch unreachable);
        }
    }.f;
    const files = [_][]const u8{ "a.zig", "dir/b.zig", "/abs/c.zig" };
    const units = [_][]const u8{ "src/root.zig", "/zig/lib/std/std.zig" };
    var atoms: std.ArrayList(Atom) = .empty;
    var debug: std.ArrayList(Atom.Debug) = .empty;
    var m: Encoder = .init(arena);
    try m.stp(.dword, .fp, .lr, .{ .base = .sp, .offset = .{ .pre = -16 } });
    try m.mov(.x, .fp, .sp);
    try m.movz(.x, .x19, 0, 0);
    try m.bl(.{ .sym = fkey("f", 0) });
    try m.uxt(.byte, .x0, .x19);
    try m.ldp(.dword, .fp, .lr, .{ .base = .sp, .offset = .{ .post = 16 } });
    try m.ret();
    try m.finish();
    try atoms.append(arena, .{ .key = main, .name = "main", .section = .text, .alignment = .@"4", .bytes = m.code.items, .targets = m.refs.targets.keys(), .relocs = m.refs.relocs.items });
    const naked = struct {
        fn f(i: usize) bool {
            return i % 10 == 9;
        }
    }.f;
    const dup = n - 5;
    for (0..n) |i| {
        var e: Encoder = .init(arena);
        var lines: Atom.LineProgram = .{};
        if (!naked(i)) {
            try e.stp(.dword, .fp, .lr, .{ .base = .sp, .offset = .{ .pre = -16 } });
            try e.mov(.x, .fp, .sp);
        }
        try lines.addRow(arena, @intCast(e.code.items.len), 1, 4);
        try e.addSub(.add, .w, .x19, .x19, .{ .imm = 1 });
        if (naked(i)) {
            if (i + 1 < n) try e.b(.{ .sym = fkey("f", i + 1) }) else try e.ret();
        } else {
            if (i + 1 < n) try e.bl(.{ .sym = fkey("f", i + 1) });
            try e.ldp(.dword, .fp, .lr, .{ .base = .sp, .offset = .{ .post = 16 } });
            try e.ret();
        }
        try e.finish();
        const name = try std.fmt.allocPrint(arena, "f{d}", .{i});
        const atom: Atom = .{ .key = fkey("f", i), .name = name, .section = .text, .alignment = if (i % 3 == 0) .@"16" else .@"4", .bytes = e.code.items, .targets = e.refs.targets.keys(), .relocs = e.refs.relocs.items, .unwind = if (naked(i)) .none else .frame_pointer };
        const entry: Atom.Debug = .{ .file = files[i / 1000 % files.len], .name = name, .base_line = @intCast(i), .lines = lines.bytes.items, .unit = units[i / 300 % units.len] };
        try debug.append(arena, d: {
            var d = entry;
            d.atom = @intCast(atoms.items.len);
            break :d d;
        });
        try atoms.append(arena, atom);
        if (i == dup) {
            var d = entry;
            d.atom = @intCast(atoms.items.len);
            try debug.append(arena, d);
            try atoms.append(arena, atom);
        }
        if (i % 7 == 0) try atoms.append(arena, .{ .key = fkey("helper", i), .name = "helper", .section = .text, .alignment = .@"4", .bytes = &.{ 0xc0, 0x03, 0x5f, 0xd6 } });
    }

    const options: Options = .{ .entry = main, .identifier = "prog", .debug = debug.items, .comp_dir = "/w" };
    const one = try emitWithDsym(gpa, io, atoms.items, o: {
        var o = options;
        o.threads = 1;
        break :o o;
    });
    defer gpa.free(one.exe);
    defer gpa.free(one.dsym);
    const four = try emitWithDsym(gpa, io, atoms.items, o: {
        var o = options;
        o.threads = 4;
        break :o o;
    });
    defer gpa.free(four.exe);
    defer gpa.free(four.dsym);
    try std.testing.expectEqualSlices(u8, one.exe, four.exe);
    try std.testing.expectEqualSlices(u8, one.dsym, four.dsym);
    const plain = try emit(gpa, io, atoms.items, options);
    defer gpa.free(plain);
    try std.testing.expectEqualSlices(u8, one.exe, plain);
    const stripped = try emit(gpa, io, atoms.items, o: {
        var o = options;
        o.debug = &.{};
        break :o o;
    });
    defer gpa.free(stripped);
    try std.testing.expect(testMachOSection(stripped, "__unwind_info") == null);

    // `link` writes the same files, the DWARF one where std.debug and lldb
    // look for it.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try link(gpa, io, tmp.dir, "prog", atoms.items, options);
    const written = try tmp.dir.readFileAlloc(io, "prog", gpa, .unlimited);
    defer gpa.free(written);
    try std.testing.expectEqualSlices(u8, one.exe, written);
    const written_dsym = try tmp.dir.readFileAlloc(io, "prog.dSYM/Contents/Resources/DWARF/prog", gpa, .unlimited);
    defer gpa.free(written_dsym);
    try std.testing.expectEqualSlices(u8, one.dsym, written_dsym);
    const path = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/prog", .{tmp.sub_path});
    if (builtin.cpu.arch == .aarch64 and builtin.os.tag == .macos) {
        const result = try std.process.run(gpa, io, .{ .argv = &.{path} });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = @truncate(n) }, result.term);
    }

    // std.debug finds the dSYM by the executable's UUID and resolves
    // functions in every debug chunk to their names and rows; the second
    // instruction of each is on line i + 2, column 5.
    const di_gpa = std.debug.getDebugInfoAllocator();
    var mf = try std.debug.MachOFile.load(di_gpa, io, path, .aarch64);
    defer mf.deinit(di_gpa);
    for ([_]usize{ 0, 9, 997, 2047, 2048, 3001, dup, n - 1 }) |index| {
        const name = try std.fmt.allocPrint(arena, "f{d}", .{index});
        const addr = testMachOSymbol(one.exe, name).?;
        const body = addr + if (naked(index)) 0 else @as(u64, 8);
        const dwarf, const vaddr = try mf.getDwarfForAddress(di_gpa, io, body);
        try std.testing.expectEqual(body, vaddr);
        var symbols: std.ArrayList(std.debug.Symbol) = .empty;
        try dwarf.getSymbols(arena, arena, .little, vaddr, false, &symbols);
        const loc = symbols.items[0].source_location.?;
        try std.testing.expectEqualStrings(name, symbols.items[0].name.?);
        try std.testing.expectEqualStrings(std.fs.path.basenamePosix(units[index / 300 % units.len]), symbols.items[0].compile_unit_name.?);
        try std.testing.expectEqual(index + 2, loc.line);
        try std.testing.expectEqual(5, loc.column);
        const file = files[index / 1000 % files.len];
        try std.testing.expectEqualStrings(if (file[0] == '/') file else try std.fmt.allocPrint(arena, "/w/{s}", .{file}), loc.file_name);
    }

    // lldb finds a dSYM's units only through .debug_aranges: a set per
    // unit, whose ranges are in __text and cover every function of the
    // unit.
    const text_sect = testMachOSection(one.exe, "__text").?;
    const info = testMachOSection(one.dsym, "__debug_info").?;
    const aranges_sect = testMachOSection(one.dsym, "__debug_aranges").?;
    const aranges = one.dsym[aranges_sect.offset..][0..aranges_sect.size];
    for ([_]usize{ 0, 9, 997, 2047, 2048, 3001, dup, n - 1 }) |index| {
        const name = try std.fmt.allocPrint(arena, "f{d}", .{index});
        const addr = testMachOSymbol(one.exe, name).?;
        var at: usize = 0;
        const unit_name = while (at < aranges.len) {
            const set = aranges[at..][0 .. std.mem.readInt(u32, aranges[at..][0..4], .little) + 4];
            at += set.len;
            const tuples = std.mem.bytesAsSlice(u64, set[16 .. set.len - 16]);
            var i: usize = 0;
            const found = while (i < tuples.len) : (i += 2) {
                try std.testing.expect(tuples[i] >= text_sect.addr and tuples[i] + tuples[i + 1] <= text_sect.addr + text_sect.size);
                if (addr >= tuples[i] and addr < tuples[i] + tuples[i + 1]) break true;
            } else false;
            // The unit's name, after its header, abbrev code, producer, and
            // language.
            if (found) break std.mem.sliceTo(one.dsym[info.offset + std.mem.readInt(u32, set[6..10], .little) + 12 + 1 + 4 + 2 ..], 0);
        } else return error.TestExpectedEqual;
        try std.testing.expectEqualStrings(std.fs.path.basenamePosix(units[index / 300 % units.len]), unit_name);
    }

    // Each function's code has its frame's encoding, and code without
    // debug info none, looked up as std.debug's unwinder does.
    const frame: u32 = 0x0400_0000;
    const main_addr = testMachOSymbol(one.exe, "main").?;
    try std.testing.expectEqual(0, testUnwindEncoding(one.exe, main_addr + 4).?);
    for (0..n) |index| {
        const name = try std.fmt.allocPrint(arena, "f{d}", .{index});
        const addr = testMachOSymbol(one.exe, name).?;
        const expected: u32 = if (naked(index)) 0 else frame;
        try std.testing.expectEqual(expected, testUnwindEncoding(one.exe, addr).?);
        try std.testing.expectEqual(expected, testUnwindEncoding(one.exe, addr + if (naked(index)) 4 else @as(u64, 8)).?);
        if (index % 7 == 0) {
            // The helper after it, which starts at the next 4-byte boundary.
            const helper = addr + atoms.items[debug.items[index + @intFromBool(index > dup)].atom].bytes.len;
            try std.testing.expectEqual(0, testUnwindEncoding(one.exe, helper).?);
        }
    }
    try std.testing.expectEqual(null, testUnwindEncoding(one.exe, text_sect.addr + text_sect.size));
}

fn testMachOCommand(comptime T: type, bytes: []const u8, cmd: macho.LC) ?T {
    const hdr = std.mem.bytesToValue(macho.mach_header_64, bytes[0..@sizeOf(macho.mach_header_64)]);
    var at: usize = @sizeOf(macho.mach_header_64);
    for (0..hdr.ncmds) |_| {
        const lc = std.mem.bytesToValue(macho.load_command, bytes[at..][0..@sizeOf(macho.load_command)]);
        if (lc.cmd == cmd) return std.mem.bytesToValue(T, bytes[at..][0..@sizeOf(T)]);
        at += lc.cmdsize;
    }
    return null;
}

fn testMachOSection(bytes: []const u8, name: []const u8) ?macho.section_64 {
    const hdr = std.mem.bytesToValue(macho.mach_header_64, bytes[0..@sizeOf(macho.mach_header_64)]);
    var at: usize = @sizeOf(macho.mach_header_64);
    for (0..hdr.ncmds) |_| {
        const lc = std.mem.bytesToValue(macho.load_command, bytes[at..][0..@sizeOf(macho.load_command)]);
        if (lc.cmd == .SEGMENT_64) {
            const seg = std.mem.bytesToValue(macho.segment_command_64, bytes[at..][0..@sizeOf(macho.segment_command_64)]);
            for (0..seg.nsects) |i| {
                const sect = std.mem.bytesToValue(macho.section_64, bytes[at + @sizeOf(macho.segment_command_64) + i * @sizeOf(macho.section_64) ..][0..@sizeOf(macho.section_64)]);
                if (std.mem.eql(u8, sect.sectName(), name)) return sect;
            }
        }
        at += lc.cmdsize;
    }
    return null;
}

fn testMachOSymbol(bytes: []const u8, name: []const u8) ?u64 {
    const hdr = std.mem.bytesToValue(macho.mach_header_64, bytes[0..@sizeOf(macho.mach_header_64)]);
    var at: usize = @sizeOf(macho.mach_header_64);
    for (0..hdr.ncmds) |_| {
        const lc = std.mem.bytesToValue(macho.load_command, bytes[at..][0..@sizeOf(macho.load_command)]);
        if (lc.cmd == .SYMTAB) {
            const st = std.mem.bytesToValue(macho.symtab_command, bytes[at..][0..@sizeOf(macho.symtab_command)]);
            for (0..st.nsyms) |i| {
                const sym = std.mem.bytesToValue(macho.nlist_64, bytes[st.symoff + i * @sizeOf(macho.nlist_64) ..][0..@sizeOf(macho.nlist_64)]);
                const sym_name = std.mem.sliceTo(bytes[st.stroff + sym.n_strx ..], 0);
                if (sym_name.len == name.len + 1 and sym_name[0] == '_' and std.mem.eql(u8, sym_name[1..], name)) return sym.n_value;
            }
        }
        at += lc.cmdsize;
    }
    return null;
}

/// The compact unwind encoding of the code at `addr`, found the way
/// std.debug.SelfInfo's Mach-O unwinder finds it (0: no unwind info), or
/// null if the index says there is none.
fn testUnwindEncoding(bytes: []const u8, addr: u64) ?u32 {
    const sect = testMachOSection(bytes, "__unwind_info").?;
    const info = bytes[sect.offset..][0..sect.size];
    const header = std.mem.bytesToValue(macho.unwind_info_section_header, info[0..@sizeOf(macho.unwind_info_section_header)]);
    const indices = std.mem.bytesAsSlice(macho.unwind_info_section_header_index_entry, info[header.indexSectionOffset..][0 .. header.indexCount * @sizeOf(macho.unwind_info_section_header_index_entry)]);
    const pc = addr - base_address;
    var left: usize = 0;
    var len: usize = indices.len;
    while (len > 1) {
        const mid = left + len / 2;
        if (pc < indices[mid].functionOffset) {
            len /= 2;
        } else {
            left = mid;
            len -= len / 2;
        }
    }
    const start = indices[left].secondLevelPagesSectionOffset;
    if (start == 0) return null;
    const page = std.mem.bytesToValue(macho.unwind_info_regular_second_level_page_header, info[start..][0..@sizeOf(macho.unwind_info_regular_second_level_page_header)]);
    std.debug.assert(page.kind == .REGULAR and page.entryCount > 0);
    const entries = std.mem.bytesAsSlice(macho.unwind_info_regular_second_level_entry, info[start + page.entryPageOffset ..][0 .. page.entryCount * @sizeOf(macho.unwind_info_regular_second_level_entry)]);
    left = 0;
    len = entries.len;
    while (len > 1) {
        const mid = left + len / 2;
        if (pc < entries[mid].functionOffset) {
            len /= 2;
        } else {
            left = mid;
            len -= len / 2;
        }
    }
    return entries[left].encoding;
}
