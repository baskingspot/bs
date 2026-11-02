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
//!   __TEXT        r-x  header and load commands, __text, __stubs, __const
//!   __DATA_CONST  rw-, read-only after fixups  __got, __const
//!   __DATA        rw-  __data, __bss (memory only)
//!   __LINKEDIT    r--  chained fixups, exports trie, symbol table, indirect
//!                      symbol table, string table, code signature
//!
//! `.rodata` atoms without absolute addresses go to __TEXT,__const; those
//! with `aarch64_abs64` relocations go to __DATA_CONST,__const, because the
//! loader must slide the addresses. Every import gets a GOT slot, bound by
//! dyld, and a 12-byte stub (adrp, ldr, br through x16) for branches.
//! Absolute addresses become chained fixups (`DYLD_CHAINED_PTR_64_OFFSET`
//! rebases and binds, the format ld64 emits for arm64 since macOS 12), so
//! there are no rebase or bind opcodes and dyld walks each page's chain.
//!
//! The code signature is the one ld64 emits by default ("linker-signed"):
//! one CodeDirectory with a SHA-256 hash per 4 KiB page of everything
//! before it, flagged ad hoc, which is all Apple Silicon needs to run the
//! file. The UUID is derived from the same page hashes.
//!
//! Not implemented yet: TLS (`__thread_vars`, `__thread_data`,
//! `__thread_bss`), and debug info: it takes no `Atom.Debug` entries, and
//! there is no DWARF (in macOS's scheme, a debug map of N_OSO stabs or a
//! dSYM).

const std = @import("std");
const builtin = @import("builtin");
const macho = std.macho;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Atom = @import("Atom.zig");
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
    /// Zig 0.17.0's default minimum for aarch64-macos is 15.0.
    min_os: std.SemanticVersion = .{ .major = 15, .minor = 0, .patch = 0 },
    /// Threads to link with, the calling thread included; null means one
    /// per CPU. The output is the same for any number.
    threads: ?usize = null,
    /// Filled in when linking fails with a symbol-related error.
    diag: ?*Diagnostic = null,
};

pub const Import = struct {
    key: SymbolKey,
    /// The Mach-O symbol name, with its leading underscore: `_write`.
    name: []const u8,
};

pub const Value = Elf.Value;
pub const Diagnostic = Elf.Diagnostic;
/// As for ELF; `InvalidRelocation` also covers relocation kinds of another
/// architecture, absolute addresses in code, misaligned fixups, and
/// addresses taken of imports other than through the GOT.
pub const Error = Elf.Error;

/// Links `atoms` and writes the executable to `sub_path` in `dir`, built
/// directly in a shared mapping of a new file. The old file is replaced,
/// not truncated: the kernel caches the code signature of a file it has
/// run, and rewriting that file in place gets the next run killed.
pub fn link(gpa: Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, atoms: []const Atom, options: Options) !void {
    var o = options;
    if (o.identifier == null) o.identifier = std.fs.path.basename(sub_path);
    dir.deleteFile(io, sub_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
    var out: Elf.FileOutput = .{ .file = try dir.createFile(io, sub_path, .{ .read = true, .permissions = .executable_file }) };
    defer out.file.close(io);
    errdefer dir.deleteFile(io, sub_path) catch {};
    defer if (out.map.len > 0) {
        // The kernel caches code signing state when the file is mapped,
        // before it has a signature, and without this every exec of the
        // file is killed although `codesign -v` accepts it. Invalidating
        // the mapping purges that state, as Go's linker does
        // (golang/go#42684).
        std.posix.msync(out.map, std.posix.MSF.INVALIDATE) catch {};
        std.posix.munmap(out.map);
    };
    try build(gpa, io, atoms, o, &out);
}

/// Links `atoms` into the bytes of an executable, owned by the caller.
pub fn emit(gpa: Allocator, io: std.Io, atoms: []const Atom, options: Options) Error![]u8 {
    var out: Elf.MemoryOutput = .{ .gpa = gpa };
    errdefer gpa.free(out.buf);
    try build(gpa, io, atoms, options, &out);
    return out.buf;
}

pub const base_address = 0x1_0000_0000;
/// Segment alignment: arm64 macOS uses 16 KiB pages.
const page_size = 0x4000;
/// Code signature hash pages.
const sig_page_size = 0x1000;
const stub_size = 12;

/// Output sections, in layout order.
const Sect = enum(u3) { text, stubs, text_const, got, data_const, data, bss };
const n_sects = 7;
const Seg = enum(u2) { text, data_const, data };
const sect_info = [n_sects]struct { seg: Seg, name: []const u8, flags: u32 }{
    .{ .seg = .text, .name = "__text", .flags = macho.S_REGULAR | macho.S_ATTR_PURE_INSTRUCTIONS | macho.S_ATTR_SOME_INSTRUCTIONS },
    .{ .seg = .text, .name = "__stubs", .flags = macho.S_SYMBOL_STUBS | macho.S_ATTR_PURE_INSTRUCTIONS | macho.S_ATTR_SOME_INSTRUCTIONS },
    .{ .seg = .text, .name = "__const", .flags = macho.S_REGULAR },
    .{ .seg = .data_const, .name = "__got", .flags = macho.S_NON_LAZY_SYMBOL_POINTERS },
    .{ .seg = .data_const, .name = "__const", .flags = macho.S_REGULAR },
    .{ .seg = .data, .name = "__data", .flags = macho.S_REGULAR },
    .{ .seg = .data, .name = "__bss", .flags = macho.S_ZEROFILL },
};
const seg_names = [3][]const u8{ "__TEXT", "__DATA_CONST", "__DATA" };

const text = @backingInt(Sect.text);
const stubs = @backingInt(Sect.stubs);
const text_const = @backingInt(Sect.text_const);
const got = @backingInt(Sect.got);
const data_const = @backingInt(Sect.data_const);
const data = @backingInt(Sect.data);
const bss = @backingInt(Sect.bss);

/// Where pass 1 placed an atom.
const Place = packed struct(u64) {
    /// Offset within the chunk's part of the section.
    offset: u40,
    /// Alignment padding between the previous atom of the section and this
    /// one, which the copy pass fills.
    gap: u21,
    section: u3,

    const duplicate: Place = @bitCast(@as(u64, std.math.maxInt(u64)));

    fn isDuplicate(p: Place) bool {
        return @as(u64, @bitCast(p)) == std.math.maxInt(u64);
    }
};
/// Atoms per unit of work in placement and copying.
const chunk_len = 2048;
const dylinker_path = "/usr/lib/dyld";
const libsystem_path = "/usr/lib/libSystem.B.dylib";
const mh_execute_header = "__mh_execute_header";

/// Links `atoms` into the buffer `out.buffer(io, len)` returns. The phases
/// are those of `Elf.build`: deduplicate, place per chunk, place chunks,
/// resolve addresses, then copy and relocate per chunk, each spread over
/// threads. Mach-O adds a serial pass that writes the GOT and stubs and
/// links fixups into per-page chains, and a parallel pass that hashes
/// pages for the code signature.
fn build(gpa: Allocator, io: std.Io, atoms: []const Atom, options: Options, out: anytype) !void {
    var unused_diag: Diagnostic = .{};
    const diag = options.diag orelse &unused_diag;

    const n_chunks = std.math.divCeil(usize, atoms.len, chunk_len) catch unreachable;
    const n_threads = @max(1, @min(n_chunks, options.threads orelse std.Thread.getCpuCount() catch 1));
    const n_partitions = std.math.ceilPowerOfTwoAssert(usize, @min(n_threads, 8));

    var symbols: SymbolTable = try .init(atoms.len, n_partitions);
    defer symbols.deinit();
    const places = try gpa.alloc(Place, atoms.len);
    defer gpa.free(places);
    const keys = try gpa.alloc(SymbolKey, atoms.len);
    defer gpa.free(keys);
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

    // Place chunks within sections, and their symbols, names, and fixups.
    var sizes: [n_sects]u64 = @splat(0);
    var aligns: [n_sects]std.mem.Alignment = @splat(.@"1");
    var n_atom_syms: u32 = 0;
    var strtab_len: u64 = 1;
    var max_targets: usize = 0;
    const n_imports: u32 = std.math.cast(u32, options.imports.len) orelse return error.OutOfMemory;
    // Fixups in address order: GOT slots, then __DATA_CONST,__const, then
    // __data, each section's in chunk order.
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
    for (chunks) |*c| {
        c.fixups[data_const] += n_fixups[got];
        c.fixups[data] += n_fixups[got] + n_fixups[data_const];
    }
    const total_fixups = n_fixups[got] + n_fixups[data_const] + n_fixups[data];

    const entry_index = symbols.get(options.entry) orelse {
        diag.* = .{ .target = options.entry };
        return error.UndefinedSymbol;
    };
    if (places[entry_index].section != text) {
        diag.* = .{ .atom = atoms[entry_index].name, .target = options.entry };
        return error.InvalidRelocation;
    }

    var values: SymbolTable = try .init(options.values.len, 1);
    defer values.deinit();
    for (options.values) |v| values.getOrPut(v.key).* = .{ .key = v.key, .value = v.value, .used = true };
    var imports: SymbolTable = try .init(options.imports.len, 1);
    defer imports.deinit();
    for (options.imports, 0..) |imp, i| {
        const e = imports.getOrPut(imp.key);
        if (!e.used) e.* = .{ .key = imp.key, .value = i, .used = true };
        strtab_len += imp.name.len + 1;
    }
    strtab_len += mh_execute_header.len + 1;
    sizes[stubs] = @as(u64, n_imports) * stub_size;
    aligns[stubs] = .@"4";
    sizes[got] = @as(u64, n_imports) * 8;
    aligns[got] = .@"8";

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
        dylib_cmd_size + @sizeOf(macho.linkedit_data_command); // code signature
    var ncmds: u32 = 12;
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
        var at: u64 = cmds_end;
        for (sect_info, 0..) |info, s| {
            const seg = @backingInt(info.seg);
            if (s == 0 or sect_info[s - 1].seg != info.seg) {
                // A new segment starts on a page, except __TEXT at 0.
                if (s != 0) at = std.mem.alignForward(u64, at, page_size);
                seg_start[seg] = if (s == 0) 0 else at;
            }
            starts[s] = aligns[s].forward(at);
            at = starts[s] + sizes[s];
            if (s != bss) seg_file_end[seg] = at;
            seg_mem_end[seg] = at;
        }
    }
    for (&seg_file_end, seg_start, seg_present) |*end, start, p| {
        end.* = if (p) std.mem.alignForward(u64, end.*, page_size) else start;
    }
    // __DATA's file part ends where its data ends, rounded to a page; __bss
    // and any other memory-only tail follow in memory.
    seg_file_end[@backingInt(Seg.data)] = if (sizes[data] > 0) std.mem.alignForward(u64, starts[data] + sizes[data], page_size) else seg_start[@backingInt(Seg.data)];
    for (&seg_mem_end, seg_start, seg_present) |*end, start, p| {
        end.* = if (p) std.mem.alignForward(u64, end.*, page_size) else start;
    }
    const last_seg: usize = if (seg_present[2]) 2 else if (seg_present[1]) 1 else 0;
    const linkedit_off = seg_file_end[last_seg];
    const linkedit_vm = seg_mem_end[last_seg];

    // __LINKEDIT contents.
    const fixups_seg = [3]bool{ false, n_fixups[got] + n_fixups[data_const] > 0, n_fixups[data] > 0 };
    const cf = ChainedFixupsLayout.init(n_segs, seg_present, fixups_seg, seg_start, seg_mem_end, options.imports);
    const fixups_off = linkedit_off;
    const trie_off = fixups_off + cf.size;
    const symtab_off = trie_off + exports_trie.len;
    const n_syms: u32 = n_atom_syms + 1 + n_imports;
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
    for (&l.section_addrs, starts) |*sa, st| sa.* = base + st;
    try parallel(io, n_threads, n_partitions, &l, Link.resolveAddrs);

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
            .{ starts[got], starts[got] + sizes[got] },
            .{ starts[data_const], starts[data_const] + sizes[data_const] },
            .{ starts[data], starts[data] + sizes[data] },
            .{ fixups_off, strtab_end },
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
    try parallel(io, n_threads, n_chunks, &l, Link.copy);
    try l.check(diag);

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
    cf.write(buf, fixups_off, fixups, options.imports);
    @memcpy(buf[trie_off..][0..exports_trie.len], exports_trie);

    // Symbols after the atoms': __mh_execute_header (exported), then the
    // imports (undefined), and their names.
    {
        var sym_off = symtab_off + @as(u64, n_atom_syms) * @sizeOf(macho.nlist_64);
        var str_off = strtab_len - (mh_execute_header.len + 1);
        for (options.imports) |imp| str_off -= imp.name.len + 1;
        buf[strtab_off] = 0;
        writeStruct(buf[sym_off..], nlist(@intCast(str_off), macho.N_SECT | macho.N_EXT, 1, macho.REFERENCED_DYNAMICALLY, base));
        sym_off += @sizeOf(macho.nlist_64);
        @memcpy(buf[strtab_off + str_off ..][0..mh_execute_header.len], mh_execute_header);
        buf[strtab_off + str_off + mh_execute_header.len] = 0;
        str_off += mh_execute_header.len + 1;
        for (options.imports, 0..) |imp, i| {
            // Two-level namespace: library ordinal 1, libSystem.
            writeStruct(buf[sym_off..], nlist(@intCast(str_off), macho.N_UNDF | macho.N_EXT, 0, 1 << 8, 0));
            sym_off += @sizeOf(macho.nlist_64);
            @memcpy(buf[strtab_off + str_off ..][0..imp.name.len], imp.name);
            buf[strtab_off + str_off + imp.name.len] = 0;
            str_off += imp.name.len + 1;
            // Indirect symbols: the stubs' entries, then the GOT's.
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
        .flags = macho.MH_NOUNDEFS | macho.MH_DYLDLINK | macho.MH_TWOLEVEL | macho.MH_PIE,
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
                .offset = if (s == bss) 0 else @intCast(starts[s]),
                .@"align" = @backingInt(aligns[s]),
                .flags = info.flags,
                // Indirect symbol table index, and the stub size.
                .reserved1 = if (s == got) n_imports else 0,
                .reserved2 = if (s == stubs) stub_size else 0,
            });
        };
    };
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
        .nundefsym = n_imports,
        .indirectsymoff = if (n_indirect > 0) @intCast(indirect_off) else 0,
        .nindirectsyms = n_indirect,
    });
    w.putWithString(macho.dylinker_command{ .cmd = .LOAD_DYLINKER, .cmdsize = dylinker_cmd_size, .name = @sizeOf(macho.dylinker_command) }, dylinker_path, dylinker_cmd_size);
    const uuid_at = w.at + @offsetOf(macho.uuid_command, "uuid");
    w.put(macho.uuid_command{ .uuid = @splat(0) });
    const version = (@as(u32, @intCast(options.min_os.major)) << 16) | (@as(u32, @intCast(options.min_os.minor)) << 8) | @as(u32, @intCast(options.min_os.patch));
    w.put(macho.build_version_command{ .cmdsize = @sizeOf(macho.build_version_command), .platform = .MACOS, .minos = version, .sdk = version, .ntools = 0 });
    w.put(macho.entry_point_command{ .entryoff = symbols.get(options.entry).? - base });
    w.putWithString(macho.dylib_command{ .cmd = .LOAD_DYLIB, .cmdsize = dylib_cmd_size, .dylib = .{
        .name = @sizeOf(macho.dylib_command),
        .timestamp = 2,
        .current_version = 0x10000,
        .compatibility_version = 0x10000,
    } }, libsystem_path, dylib_cmd_size);
    w.put(macho.linkedit_data_command{ .cmd = .CODE_SIGNATURE, .dataoff = @intCast(sig_off), .datasize = @intCast(sig_size) });
    std.debug.assert(w.at == cmds_end);

    try sign(io, n_threads, buf, @intCast(sig_off), uuid_at, identifier, seg_file_end[0]);
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
};

const Failure = struct { atom: usize, err: Error, diag: Diagnostic };

/// A relocation target: an address, an import's index, or a link-time
/// value.
const Resolved = struct { v: u64, kind: enum(u8) { addr, import, value } };

/// State shared by the threads of `build`.
const Link = struct {
    atoms: []const Atom,
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

    fn resolveAddrs(l: *Link, partition: usize, _: usize) void {
        for (l.symbols.partitionEntries(partition)) |*e| {
            if (e.used) e.value = l.atomAddr(e.value);
        }
    }

    fn gatherKeys(l: *Link, chunk: usize, _: usize) void {
        const begin = chunk * chunk_len;
        const atoms = l.atoms[begin..@min(l.atoms.len, begin + chunk_len)];
        for (atoms, l.keys[begin..][0..atoms.len]) |*a, *k| k.* = a.key;
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
    fn layOut(l: *Link, chunk: usize, _: usize) void {
        const begin = chunk * chunk_len;
        const atoms = l.atoms[begin..@min(l.atoms.len, begin + chunk_len)];
        var c: Chunk = .{
            .sizes = @splat(0),
            .aligns = @splat(.@"1"),
            .n_fixups = @splat(0),
            .n_syms = 0,
            .str_len = 0,
            .max_targets = 0,
            .bases = undefined,
            .lead_gaps = undefined,
            .fixups = undefined,
            .sym = undefined,
            .str = undefined,
        };
        for (atoms, l.places[begin..][0..atoms.len], begin..) |*a, *p, i| {
            if (i + 16 < l.keys.len) l.symbols.prefetch(l.keys[i + 16]);
            const kept = l.symbols.get(l.keys[i]).?;
            if (kept != i) {
                if (!Elf.identical(&l.atoms[kept], a)) l.fail(chunk, i, error.DuplicateSymbol, .{ .atom = a.name, .target = a.key });
                p.* = .duplicate;
                continue;
            }
            if (a.section == .bss and (a.bytes.len != 0 or a.relocs.len != 0)) {
                l.fail(chunk, i, error.InvalidRelocation, .{ .atom = a.name });
                continue;
            }
            var n_abs: u32 = 0;
            if (a.section == .rodata or a.section == .data) {
                for (a.relocs) |r| n_abs += @intFromBool(r.info.kind == .aarch64_abs64);
            }
            const s: u3 = switch (a.section) {
                .text => text,
                .rodata => if (n_abs > 0) data_const else text_const,
                .data => data,
                .bss => bss,
            };
            c.n_fixups[s] += n_abs;
            const off = a.alignment.forward(c.sizes[s]);
            p.* = .{
                .offset = std.math.cast(u40, off) orelse {
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
            if (a.name.len > 0) {
                c.n_syms += 1;
                c.str_len += @intCast(a.name.len + 1);
            }
            c.max_targets = @max(c.max_targets, @as(u32, @intCast(a.targets.len)));
        }
        l.chunks[chunk] = c;
    }

    /// Copies one chunk's atoms, applies their relocations, records their
    /// fixups, and writes their symbols.
    fn copy(l: *Link, chunk: usize, thread: usize) void {
        const c = &l.chunks[chunk];
        const resolved = l.resolved[thread * l.max_targets ..][0..l.max_targets];
        for (c.lead_gaps, c.bases, l.section_addrs, 0..) |gap, chunk_base, sa, s| {
            if (s == bss or gap == 0) continue;
            const start = sa - base_address + chunk_base;
            @memset(l.buf[start - gap .. start], 0);
        }
        var fixup = c.fixups;
        const begin = chunk * chunk_len;
        const atoms = l.atoms[begin..@min(l.atoms.len, begin + chunk_len)];
        var sym_off = l.symtab_off + @as(u64, c.sym) * @sizeOf(macho.nlist_64);
        var str_off = c.str;
        for (atoms, l.places[begin..][0..atoms.len], begin..) |*a, place, i| {
            if (i + 4 < l.atoms.len) {
                const n = &l.atoms[i + 4];
                Elf.prefetchSlice(u8, n.bytes[0..@min(n.bytes.len, 64)]);
                Elf.prefetchSlice(SymbolKey, n.targets);
                Elf.prefetchSlice(Atom.Reloc, n.relocs);
                Elf.prefetchSlice(u8, n.name);
            }
            if (i + 2 < l.atoms.len) for (l.atoms[i + 2].targets) |t| l.symbols.prefetch(t);
            if (place.isDuplicate()) continue;
            const addr = l.section_addrs[place.section] + c.bases[place.section] + place.offset;
            if (place.section != bss) {
                const start = addr - base_address;
                @memset(l.buf[start - place.gap .. start], 0);
                const dst = l.buf[start..][0..a.bytes.len];
                @memcpy(dst, a.bytes);
                const res = resolved[0..a.targets.len];
                for (a.targets, res) |t, *r| {
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
                l.applyRelocs(a, dst, addr, place.section, res, &fixup[place.section], &diag) catch |err| return l.fail(chunk, i, err, diag);
            }
            if (a.name.len > 0) {
                @memcpy(l.buf[l.strtab_off + str_off ..][0..a.name.len], a.name);
                l.buf[l.strtab_off + str_off + a.name.len] = 0;
                writeStruct(l.buf[sym_off..], nlist(str_off, macho.N_SECT, l.sect_index[place.section], 0, addr));
                sym_off += @sizeOf(macho.nlist_64);
                str_off += @intCast(a.name.len + 1);
            }
        }
    }

    /// Applies `a`'s relocations to its copy `dst` at address `p_base` in
    /// section `sect`, recording fixups from `fixups.*` on.
    fn applyRelocs(l: *const Link, a: *const Atom, dst: []u8, p_base: u64, sect: u3, resolved: []const Resolved, fixups: *u64, diag: *Diagnostic) Error!void {
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
                    if ((sect != data_const and sect != data) or p & 3 != 0) return invalid;
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
                .x86_64_abs64, .x86_64_pc32 => return invalid,
            }
        }
    }
};

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
        for (imports) |imp| symbols_len += @intCast(imp.name.len + 1);
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
            @memcpy(out[cf.symbols_off + name_off ..][0..imp.name.len], imp.name);
            name_off += @intCast(imp.name.len + 1);
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
    try s.cmp(.w, .x0, .{ .imm = 42 });
    try s.bcond(.ne, trap);
    try s.loadGotAddr(.x16, exit);
    try s.blr(.x16);
    s.bind(trap);
    try s.brk(1);
    try s.finish();

    const msg_atom: Atom = .{ .key = msg, .name = "__anon_msg", .section = .rodata, .bytes = msg_text };
    const atoms = [_]Atom{
        .{ .key = main, .name = "_main", .section = .text, .alignment = .@"4", .bytes = s.code.items, .targets = s.refs.targets.keys(), .relocs = s.refs.relocs.items },
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
        .imports = &.{ .{ .key = write, .name = "_write" }, .{ .key = exit, .name = "_exit" } },
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
    const abs_in_text = [_]Atom{.{ .key = main, .name = "_main", .section = .text, .bytes = &@as([8]u8, @splat(0)), .targets = &.{main}, .relocs = &.{.init(0, .aarch64_abs64, 0, 0)} }};
    try std.testing.expectError(error.InvalidRelocation, emit(gpa, io, &abs_in_text, .{ .entry = main }));
}

test "links many chunks of atoms and pages of fixups the same way on any number of threads" {
    if (builtin.cpu.arch != .aarch64 or builtin.os.tag != .macos) return error.SkipZigTest;
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
    // exits with w19.
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
    try atoms.append(arena, .{ .key = main, .name = "_main", .section = .text, .alignment = .@"4", .bytes = s.code.items, .targets = s.refs.targets.keys(), .relocs = s.refs.relocs.items });

    const imports: []const Import = &.{ .{ .key = write, .name = "_write" }, .{ .key = exit, .name = "_exit" } };
    const one = try emit(gpa, io, atoms.items, .{ .entry = main, .imports = imports, .threads = 1, .identifier = "chunks" });
    defer gpa.free(one);
    const four = try emit(gpa, io, atoms.items, .{ .entry = main, .imports = imports, .threads = 4, .identifier = "chunks" });
    defer gpa.free(four);
    try std.testing.expectEqualSlices(u8, one, four);

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
