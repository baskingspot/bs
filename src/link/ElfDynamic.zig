//! The dynamic sections of an x86_64 ELF shared object (`zap build-lib
//! -dynamic`), which `Elf` lays out and writes when `Options.dynamic` is
//! set: .dynsym, .dynstr, .hash, .gnu.hash, the .plt stubs, and .dynamic.
//! See "Position-independent code and shared libraries" in
//! docs/architecture.md.
//!
//! Everything here depends only on the exports' and imports' names, so it
//! is built before layout; only the defined symbols' values, which need
//! addresses, are filled in afterwards (`writeSymbols`).
//!
//! .dynsym holds the null symbol, the imports (undefined) in input order,
//! then the exports with default or protected visibility, ordered by GNU
//! hash bucket as .gnu.hash requires. Binding is eager: each import has a
//! GOT slot, which an R_X86_64_GLOB_DAT fills at load time, and a PLT stub
//! that jumps through it, so the output needs no lazy-binding machinery.

const std = @import("std");
const elf = std.elf;
const Allocator = std.mem.Allocator;
const Atom = @import("Atom.zig");
const SymbolKey = Atom.SymbolKey;

/// A symbol the output defines for other modules: the atom `key` (or a
/// part of it), as `name`.
pub const Export = struct {
    key: SymbolKey,
    name: []const u8,
    /// Where in the atom the symbol is, and its size, if not the whole
    /// atom: an input object's symbol in its section's atom.
    offset: u64 = 0,
    size: ?u64 = null,
    weak: bool = false,
    visibility: std.lang.SymbolVisibility = .default,
    /// In an executable: the atom is a copy of a library's data object,
    /// which the loader fills from the library's (R_X86_64_COPY), and
    /// which every module then uses, the library too. Versioned as the
    /// import it replaces (`Import.version` and `Import.library`).
    copy: ?Copy = null,

    pub const Copy = struct {
        version: ?[]const u8,
        library: u32,
        /// Another name of an earlier export's copy, which the library
        /// defines at the same address (`environ` and `__environ`): it
        /// gets a symbol but no relocation of its own.
        alias: bool = false,
    };
};

/// A symbol the output references and another module defines. Relocations
/// name it by `key`, which no atom may have.
pub const Import = struct {
    key: SymbolKey,
    name: []const u8,
    weak: bool = false,
    /// Reached PC-relative, so the final link must define it in its module
    /// (STV_HIDDEN, and R_X86_64_PC32 rather than PLT32). Only objects
    /// have hidden imports.
    hidden: bool = false,
    /// A thread-local (STT_TLS): in an executable, reached through slots
    /// the loader writes with TPOFF64 relocations.
    tls: bool = false,
    /// With glibc: the symbol version the import binds to
    /// (`GLIBC_2.2.5`), or null for none, and the index in
    /// `Options.needed` of the library that defines it.
    version: ?[]const u8 = null,
    library: u32 = 0,
};

/// What makes an image a shared object.
pub const Options = struct {
    exports: []const Export = &.{},
    imports: []const Import = &.{},
    /// DT_SONAME, or null for none.
    soname: ?[]const u8 = null,
    /// DT_RUNPATH, directories separated by ':', or null for none.
    runpath: ?[]const u8 = null,
    /// A dynamically linked executable (ET_EXEC) rather than a shared
    /// object: PT_INTERP names `interp`, and the image is not
    /// position-independent. Its extern slots are its GOT, so imports get
    /// neither PLT stubs nor GOT slots: only an absolute relocation to an
    /// import needs the loader.
    interp: ?[]const u8 = null,
    /// The libraries the image links (DT_NEEDED), which imports with a
    /// version name (.gnu.version, .gnu.version_r): an executable's or a
    /// shared object's that links glibc.
    needed: []const []const u8 = &.{},

    pub fn executable(o: *const Options) bool {
        return o.interp != null;
    }
};

/// The key of `_DYNAMIC`, the address of .dynamic, which the linker
/// defines (std.dynamic_library reads it through a weak hidden extern).
pub const dynamic_key: SymbolKey = .fromName("link._DYNAMIC");

/// One PLT stub per import: `jmp [rip + slot]` and a 2-byte nop.
pub const plt_entry_size = 8;

pub const Tables = struct {
    /// Indices in `Options.exports` of the exports in .dynsym, in .dynsym
    /// order, after the imports.
    exports: []const u32,
    n_imports: u32,
    dynstr: []const u8,
    /// Offset in `dynstr` of each symbol after the null one.
    names: []const u32,
    soname: ?u32,
    runpath: ?u32 = null,
    hash: []const u8,
    gnu_hash: []const u8,
    /// An executable's: the offset in `dynstr` of each needed library, and
    /// .gnu.version and .gnu.version_r (empty without versioned imports).
    needed: []const u32 = &.{},
    versym: []const u8 = &.{},
    verneed: []const u8 = &.{},
    verneed_count: u32 = 0,

    pub fn symbolCount(t: *const Tables) u32 {
        return 1 + t.n_imports + @as(u32, @intCast(t.exports.len));
    }

    pub fn dynsymSize(t: *const Tables) u64 {
        return @as(u64, t.symbolCount()) * @sizeOf(elf.Elf64.Sym);
    }
};

/// Builds the tables that depend only on names, in `arena`.
pub fn tables(arena: Allocator, o: Options) Allocator.Error!Tables {
    var exports: std.ArrayList(u32) = .empty;
    for (o.exports, 0..) |x, i| {
        if (x.visibility == .hidden) continue;
        try exports.append(arena, @intCast(i));
    }
    const n_imports: u32 = @intCast(o.imports.len);
    const n_syms: u32 = 1 + n_imports + @as(u32, @intCast(exports.items.len));

    // .gnu.hash: the exports sorted by bucket (stably, so the order is the
    // input's within a bucket).
    const n_buckets: u32 = @max(1, @as(u32, @intCast(exports.items.len / 4)));
    const hashes = try arena.alloc(u32, o.exports.len);
    for (exports.items) |i| hashes[i] = gnuHash(o.exports[i].name);
    const Ctx = struct {
        hashes: []const u32,
        n_buckets: u32,
        fn lessThan(c: @This(), a: u32, b: u32) bool {
            const ba = c.hashes[a] % c.n_buckets;
            const bb = c.hashes[b] % c.n_buckets;
            return ba < bb or (ba == bb and a < b);
        }
    };
    std.mem.sort(u32, exports.items, Ctx{ .hashes = hashes, .n_buckets = n_buckets }, Ctx.lessThan);

    // .dynstr: the null string, the soname and the runpath, then the
    // names.
    var dynstr: std.ArrayList(u8) = .empty;
    try dynstr.append(arena, 0);
    var soname: ?u32 = null;
    var runpath: ?u32 = null;
    for ([_]?[]const u8{ o.soname, o.runpath }, [_]*?u32{ &soname, &runpath }) |str, off| if (str) |s| {
        off.* = @intCast(dynstr.items.len);
        try dynstr.appendSlice(arena, s);
        try dynstr.append(arena, 0);
    };
    const needed = try arena.alloc(u32, o.needed.len);
    for (needed, o.needed) |*off, lib| {
        off.* = @intCast(dynstr.items.len);
        try dynstr.appendSlice(arena, lib);
        try dynstr.append(arena, 0);
    }
    const names = try arena.alloc(u32, n_syms - 1);
    for (o.imports, 0..) |imp, k| {
        names[k] = @intCast(dynstr.items.len);
        try dynstr.appendSlice(arena, imp.name);
        try dynstr.append(arena, 0);
    }
    for (exports.items, n_imports..) |i, k| {
        names[k] = @intCast(dynstr.items.len);
        try dynstr.appendSlice(arena, o.exports[i].name);
        try dynstr.append(arena, 0);
    }

    // .hash (SysV): every symbol, chained per bucket.
    const sysv_buckets: u32 = @max(1, n_syms / 2);
    const hash = try arena.alloc(u32, 2 + sysv_buckets + n_syms);
    @memset(hash, 0);
    hash[0] = sysv_buckets;
    hash[1] = n_syms;
    const buckets = hash[2..][0..sysv_buckets];
    const chains = hash[2 + sysv_buckets ..];
    for (1..n_syms) |k| {
        const name = std.mem.sliceTo(dynstr.items[names[k - 1]..], 0);
        const b = sysvHash(name) % sysv_buckets;
        chains[k] = buckets[b];
        buckets[b] = @intCast(k);
    }

    // .gnu.hash: header, bloom filter, buckets, then a chain value per
    // hashed symbol, whose low bit marks the last of its bucket.
    const sym_offset = 1 + n_imports;
    const n_hashed: u32 = @intCast(exports.items.len);
    const bloom_size: u32 = std.math.ceilPowerOfTwoAssert(u32, @max(1, n_hashed / 2));
    const bloom_shift = 26;
    const gnu = try arena.alignedAlloc(u8, .@"8", 16 + bloom_size * 8 + n_buckets * 4 + n_hashed * 4);
    @memset(gnu, 0);
    const header: *[4]u32 = @ptrCast(gnu[0..16]);
    header.* = .{ n_buckets, sym_offset, bloom_size, bloom_shift };
    const bloom: []align(1) u64 = std.mem.bytesAsSlice(u64, gnu[16..][0 .. bloom_size * 8]);
    const gnu_buckets: []align(1) u32 = std.mem.bytesAsSlice(u32, gnu[16 + bloom_size * 8 ..][0 .. n_buckets * 4]);
    const gnu_chain: []align(1) u32 = std.mem.bytesAsSlice(u32, gnu[16 + bloom_size * 8 + n_buckets * 4 ..]);
    for (exports.items, 0..) |i, k| {
        const h = hashes[i];
        bloom[(h / 64) % bloom_size] |= @as(u64, 1) << @intCast(h % 64) | @as(u64, 1) << @intCast((h >> bloom_shift) % 64);
        const b = h % n_buckets;
        if (gnu_buckets[b] == 0) gnu_buckets[b] = sym_offset + @as(u32, @intCast(k));
        const last = k + 1 == exports.items.len or hashes[exports.items[k + 1]] % n_buckets != b;
        gnu_chain[k] = (h & ~@as(u32, 1)) | @intFromBool(last);
    }

    // .gnu.version: one index per .dynsym entry (0 local, 1 global, 2.. a
    // version needed); .gnu.version_r: per library with versioned imports,
    // a Verneed and a Vernaux per version, indices in that order.
    var versym: []u16 = &.{};
    var verneed: std.ArrayList(u8) = .empty;
    var verneed_count: u32 = 0;
    const versioned = for (o.imports) |imp| {
        if (imp.version != null) break true;
    } else for (o.exports) |x| {
        if (x.copy != null and x.copy.?.version != null) break true;
    } else false;
    if (versioned) {
        versym = try arena.alloc(u16, n_syms);
        @memset(versym, 1);
        versym[0] = 0;
        var next_index: u16 = 2;
        var prev_need_at: usize = 0;
        for (o.needed, needed, 0..) |_, file, lib| {
            var versions: std.ArrayList([]const u8) = .empty;
            for (0..n_syms - 1) |k| {
                const v, const in_lib = if (k < n_imports)
                    .{ o.imports[k].version orelse continue, o.imports[k].library }
                else c: {
                    const cp = o.exports[exports.items[k - n_imports]].copy orelse continue;
                    break :c .{ cp.version orelse continue, cp.library };
                };
                if (in_lib != lib) continue;
                const vi = for (versions.items, 0..) |seen, j| {
                    if (std.mem.eql(u8, seen, v)) break j;
                } else blk: {
                    try versions.append(arena, v);
                    break :blk versions.items.len - 1;
                };
                versym[k + 1] = next_index + @as(u16, @intCast(vi));
            }
            if (versions.items.len == 0) continue;
            const need_at = verneed.items.len;
            const need: elf.Verneed = .{
                .version = 1,
                .cnt = @intCast(versions.items.len),
                .file = file,
                .aux = @sizeOf(elf.Verneed),
                .next = 0,
            };
            try verneed.appendSlice(arena, std.mem.asBytes(&need));
            for (versions.items, 0..) |v, j| {
                const name: u32 = @intCast(dynstr.items.len);
                try dynstr.appendSlice(arena, v);
                try dynstr.append(arena, 0);
                const aux: elf.Vernaux = .{
                    .hash = sysvHash(v),
                    .flags = 0,
                    .other = next_index + @as(u16, @intCast(j)),
                    .name = name,
                    .next = if (j + 1 < versions.items.len) @sizeOf(elf.Vernaux) else 0,
                };
                try verneed.appendSlice(arena, std.mem.asBytes(&aux));
            }
            next_index += @intCast(versions.items.len);
            // Link the previous Verneed to this one.
            if (verneed_count > 0) {
                const prev_next: *align(1) u32 = @ptrCast(verneed.items[prev_need_at + @offsetOf(elf.Verneed, "next") ..][0..4]);
                prev_next.* = @intCast(need_at - prev_need_at);
            }
            prev_need_at = need_at;
            verneed_count += 1;
        }
    }

    return .{
        .needed = needed,
        .versym = std.mem.sliceAsBytes(versym),
        .verneed = verneed.items,
        .verneed_count = verneed_count,
        .exports = exports.items,
        .n_imports = n_imports,
        .dynstr = dynstr.items,
        .names = names,
        .soname = soname,
        .runpath = runpath,
        .hash = std.mem.sliceAsBytes(hash),
        .gnu_hash = gnu,
    };
}

/// A defined symbol's place, as `Elf` resolved it.
pub const Defined = struct {
    value: u64,
    size: u64,
    shndx: u16,
    type: elf.STT,
};

/// Writes .dynsym into `out`: the imports, then the exports, whose
/// places `defined` gives in `t.exports`' order.
pub fn writeSymbols(out: []u8, t: *const Tables, o: Options, defined: []const Defined) void {
    var syms: []align(1) elf.Elf64.Sym = std.mem.bytesAsSlice(elf.Elf64.Sym, out[0..t.dynsymSize()]);
    syms[0] = std.mem.zeroes(elf.Elf64.Sym);
    for (o.imports, 1.., t.names[0..t.n_imports]) |imp, k, name| syms[k] = .{
        .name = name,
        .info = .{ .type = if (imp.tls) .TLS else .NOTYPE, .bind = if (imp.weak) .WEAK else .GLOBAL },
        .other = .{ .visibility = .DEFAULT },
        .shndx = elf.SHN_UNDEF,
        .value = 0,
        .size = 0,
    };
    for (t.exports, defined, t.names[t.n_imports..], 1 + t.n_imports..) |i, d, name, k| {
        const x = o.exports[i];
        syms[k] = .{
            .name = name,
            .info = .{ .type = d.type, .bind = if (x.weak) .WEAK else .GLOBAL },
            .other = .{ .visibility = if (x.visibility == .protected) .PROTECTED else .DEFAULT },
            .shndx = d.shndx,
            .value = d.value,
            .size = d.size,
        };
    }
}

/// PLT stub `i`, at `stub`, jumping through the GOT slot at `slot`.
pub fn pltEntry(stub: u64, slot: u64) [plt_entry_size]u8 {
    var e: [plt_entry_size]u8 = .{ 0xff, 0x25, 0, 0, 0, 0, 0x66, 0x90 };
    std.mem.writeInt(i32, e[2..6], @intCast(@as(i64, @bitCast(slot -% (stub + 6)))), .little);
    return e;
}

/// The addresses .dynamic points at.
pub const Addresses = struct {
    dynsym: u64,
    dynstr: u64,
    hash: u64,
    gnu_hash: u64,
    rela: u64,
    rela_size: u64,
    versym: u64 = 0,
    verneed: u64 = 0,
    /// The address and size of .preinit_array, .init_array and
    /// .fini_array, which the loader runs. Empty ones get no entries.
    arrays: [3]Array = @splat(.{}),

    pub const Array = struct { addr: u64 = 0, size: u64 = 0 };
};

/// The number of .dynamic entries `writeDynamic` writes, with `n_arrays`
/// of `Addresses.arrays` not empty.
pub fn dynamicCount(t: *const Tables, o: Options, n_arrays: u64) u64 {
    const exe: u64 = @intFromBool(o.executable());
    const versions: u64 = 3 * @as(u64, @intFromBool(t.verneed_count > 0));
    return 12 + @as(u64, @intFromBool(t.soname != null)) + @intFromBool(t.runpath != null) + t.needed.len + exe + versions + 2 * n_arrays;
}

/// The size of the largest .dynamic `writeDynamic` writes without
/// libraries.
const max_fixed_entries = 23;

pub fn writeDynamic(out: []u8, t: *const Tables, o: Options, a: Addresses) void {
    var at: usize = 0;
    const put = struct {
        fn f(buf: []u8, pos: *usize, tag: i64, val: u64) void {
            const e: elf.Elf64_Dyn = .{ .d_tag = tag, .d_val = val };
            @memcpy(buf[pos.*..][0..@sizeOf(elf.Elf64_Dyn)], std.mem.asBytes(&e));
            pos.* += @sizeOf(elf.Elf64_Dyn);
        }
    }.f;
    for (t.needed) |lib| put(out, &at, elf.DT_NEEDED, lib);
    if (t.soname) |s| put(out, &at, elf.DT_SONAME, s);
    if (t.runpath) |r| put(out, &at, elf.DT_RUNPATH, r);
    var fixed: [max_fixed_entries]struct { i64, u64 } = undefined;
    var n: usize = 0;
    for ([_]struct { i64, u64 }{
        .{ elf.DT_HASH, a.hash },
        .{ elf.DT_GNU_HASH, a.gnu_hash },
        .{ elf.DT_SYMTAB, a.dynsym },
        .{ elf.DT_SYMENT, @sizeOf(elf.Elf64.Sym) },
        .{ elf.DT_STRTAB, a.dynstr },
        .{ elf.DT_STRSZ, t.dynstr.len },
        .{ elf.DT_RELA, a.rela },
        .{ elf.DT_RELASZ, a.rela_size },
        .{ elf.DT_RELAENT, @sizeOf(elf.Elf64.Rela) },
    }) |e| {
        fixed[n] = e;
        n += 1;
    }
    if (t.verneed_count > 0) {
        fixed[n..][0..3].* = .{ .{ elf.DT_VERSYM, a.versym }, .{ elf.DT_VERNEED, a.verneed }, .{ elf.DT_VERNEEDNUM, t.verneed_count } };
        n += 3;
    }
    if (o.executable()) {
        // Where the loader publishes `r_debug` for debuggers.
        fixed[n] = .{ elf.DT_DEBUG, 0 };
        n += 1;
    }
    var n_arrays: u64 = 0;
    for (a.arrays, [_][2]i64{ .{ elf.DT_PREINIT_ARRAY, elf.DT_PREINIT_ARRAYSZ }, .{ elf.DT_INIT_ARRAY, elf.DT_INIT_ARRAYSZ }, .{ elf.DT_FINI_ARRAY, elf.DT_FINI_ARRAYSZ } }) |arr, tags| {
        if (arr.size == 0) continue;
        fixed[n..][0..2].* = .{ .{ tags[0], arr.addr }, .{ tags[1], arr.size } };
        n += 2;
        n_arrays += 1;
    }
    fixed[n..][0..3].* = .{ .{ elf.DT_FLAGS, elf.DF_BIND_NOW }, .{ elf.DT_FLAGS_1, elf.DF_1_NOW }, .{ elf.DT_NULL, 0 } };
    n += 3;
    for (fixed[0..n]) |e| put(out, &at, e[0], e[1]);
    std.debug.assert(at == dynamicCount(t, o, n_arrays) * @sizeOf(elf.Elf64_Dyn));
}

/// The GNU hash of `name` (DJB).
pub fn gnuHash(name: []const u8) u32 {
    var h: u32 = 5381;
    for (name) |c| h = h *% 33 +% c;
    return h;
}

/// The SysV ELF hash of `name`.
pub fn sysvHash(name: []const u8) u32 {
    var h: u32 = 0;
    for (name) |c| {
        h = (h << 4) +% c;
        const g = h & 0xf0000000;
        if (g != 0) h ^= g >> 24;
        h &= ~g;
    }
    return h;
}
