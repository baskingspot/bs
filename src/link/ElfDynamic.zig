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

/// A symbol the output defines for other modules: the atom `key`, as `name`.
pub const Export = struct {
    key: SymbolKey,
    name: []const u8,
    weak: bool = false,
    visibility: std.lang.SymbolVisibility = .default,
};

/// A symbol the output references and another module defines. Relocations
/// name it by `key`, which no atom may have.
pub const Import = struct { key: SymbolKey, name: []const u8, weak: bool = false };

/// What makes an image a shared object.
pub const Options = struct {
    exports: []const Export = &.{},
    imports: []const Import = &.{},
    /// DT_SONAME, or null for none.
    soname: ?[]const u8 = null,
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
    hash: []const u8,
    gnu_hash: []const u8,

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

    // .dynstr: the null string, the soname, then the names.
    var dynstr: std.ArrayList(u8) = .empty;
    try dynstr.append(arena, 0);
    var soname: ?u32 = null;
    if (o.soname) |s| {
        soname = @intCast(dynstr.items.len);
        try dynstr.appendSlice(arena, s);
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

    return .{
        .exports = exports.items,
        .n_imports = n_imports,
        .dynstr = dynstr.items,
        .names = names,
        .soname = soname,
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
        .info = .{ .type = .NOTYPE, .bind = if (imp.weak) .WEAK else .GLOBAL },
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
};

/// The number of .dynamic entries `writeDynamic` writes.
pub fn dynamicCount(t: *const Tables) u64 {
    return 12 + @as(u64, @intFromBool(t.soname != null));
}

pub fn writeDynamic(out: []u8, t: *const Tables, a: Addresses) void {
    var entries: [13]elf.Elf64_Dyn = undefined;
    var n: usize = 0;
    if (t.soname) |s| {
        entries[n] = .{ .d_tag = elf.DT_SONAME, .d_val = s };
        n += 1;
    }
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
        .{ elf.DT_FLAGS, elf.DF_BIND_NOW },
        .{ elf.DT_FLAGS_1, elf.DF_1_NOW },
        .{ elf.DT_NULL, 0 },
    }) |e| {
        entries[n] = .{ .d_tag = e[0], .d_val = e[1] };
        n += 1;
    }
    std.debug.assert(n == dynamicCount(t));
    @memcpy(out[0 .. n * @sizeOf(elf.Elf64_Dyn)], std.mem.sliceAsBytes(entries[0..n]));
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
