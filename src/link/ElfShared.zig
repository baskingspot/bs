//! An x86_64 ELF shared library (`.so`) as a link input: the symbols it
//! defines for other modules, which an executable imports from it, and the
//! soname its DT_NEEDED names ("Object, archive and shared-library inputs"
//! in docs/slop/architecture.md). Read in place.

const std = @import("std");
const elf = std.elf;
const Allocator = std.mem.Allocator;

const Shared = @This();

path: []const u8,
/// DT_SONAME, or the path for a library without one, as ld names it.
soname: []const u8,
/// Its defined dynamic symbols, by name: the default version of each, as
/// an unversioned reference binds to it.
symbols: std.StringHashMapUnmanaged(Symbol) = .empty,
/// The symbols it references and does not define, whose definitions keep
/// their libraries needed when it is (`Glibc.dynamicOptions`).
undefs: []const Undef = &.{},

pub const Undef = struct { name: []const u8, weak: bool };

pub const Symbol = struct {
    /// The version the symbol is defined in (`ZLIB_1.2.9`), which an
    /// import names in .gnu.version_r; null for the library's base
    /// version or none, which an import references unversioned.
    version: ?[]const u8,
    /// A data object, which non-PIC code may need copied into the
    /// executable, `size` bytes at `value` (where its aliases are too).
    object: bool,
    /// A thread-local (STT_TLS), which an executable reaches through a
    /// slot the loader writes its thread-pointer offset into (TPOFF64).
    tls: bool = false,
    size: u64,
    value: u64,
};

pub const Error = error{ OutOfMemory, InvalidShared };

/// Parses `bytes`, an ELF64 x86_64 ET_DYN, kept in place.
pub fn parse(arena: Allocator, path: []const u8, bytes: []const u8) Error!Shared {
    if (bytes.len < @sizeOf(elf.Elf64_Ehdr) or !std.mem.eql(u8, bytes[0..4], elf.MAGIC)) return error.InvalidShared;
    const eh = std.mem.bytesToValue(elf.Elf64_Ehdr, bytes[0..@sizeOf(elf.Elf64_Ehdr)]);
    if (eh.e_ident[elf.EI.CLASS] != elf.ELFCLASS64 or eh.e_ident[elf.EI.DATA] != elf.ELFDATA2LSB) return error.InvalidShared;
    if (eh.e_type != .DYN or eh.e_machine != .X86_64 or eh.e_shentsize != @sizeOf(elf.Elf64_Shdr)) return error.InvalidShared;
    const shdrs_end = std.math.add(u64, eh.e_shoff, @as(u64, eh.e_shnum) * @sizeOf(elf.Elf64_Shdr)) catch return error.InvalidShared;
    if (shdrs_end > bytes.len) return error.InvalidShared;
    const shdrs = std.mem.bytesAsSlice(elf.Elf64_Shdr, bytes[@intCast(eh.e_shoff)..@intCast(shdrs_end)]);
    const section = struct {
        fn f(all: @TypeOf(shdrs), b: []const u8, index: usize) Error![]const u8 {
            if (index >= all.len) return error.InvalidShared;
            const sh = all[index];
            const end = std.math.add(u64, sh.sh_offset, sh.sh_size) catch return error.InvalidShared;
            if (sh.sh_type == elf.SHT_NOBITS or end > b.len) return error.InvalidShared;
            return b[@intCast(sh.sh_offset)..@intCast(end)];
        }
    }.f;

    var syms: []align(1) const elf.Elf64_Sym = &.{};
    var strtab: []const u8 = "";
    var versym: []align(1) const u16 = &.{};
    var verdef: []const u8 = "";
    var verdef_count: u64 = 0;
    var dynamic: []align(1) const elf.Elf64_Dyn = &.{};
    for (shdrs, 0..) |sh, i| switch (sh.sh_type) {
        elf.SHT_DYNSYM => {
            syms = std.mem.bytesAsSlice(elf.Elf64_Sym, try section(shdrs, bytes, i));
            strtab = try section(shdrs, bytes, sh.sh_link);
        },
        elf.SHT_GNU_VERSYM => versym = std.mem.bytesAsSlice(u16, try section(shdrs, bytes, i)),
        elf.SHT_GNU_VERDEF => {
            verdef = try section(shdrs, bytes, i);
            verdef_count = sh.sh_info;
        },
        elf.SHT_DYNAMIC => dynamic = std.mem.bytesAsSlice(elf.Elf64_Dyn, try section(shdrs, bytes, i)),
        else => {},
    };
    const str = struct {
        fn f(t: []const u8, off: u64) []const u8 {
            if (off >= t.len) return "";
            return std.mem.sliceTo(t[@intCast(off)..], 0);
        }
    }.f;

    // Version names by index; the base version (VER_FLG_BASE) stays null.
    var versions: std.AutoHashMapUnmanaged(u16, ?[]const u8) = .empty;
    var at: u64 = 0;
    for (0..verdef_count) |_| {
        if (at + @sizeOf(elf.Verdef) > verdef.len) return error.InvalidShared;
        const vd = std.mem.bytesToValue(elf.Verdef, verdef[@intCast(at)..][0..@sizeOf(elf.Verdef)]);
        const aux_at = at + vd.aux;
        if (aux_at + @sizeOf(elf.Verdaux) > verdef.len) return error.InvalidShared;
        const aux = std.mem.bytesToValue(elf.Verdaux, verdef[@intCast(aux_at)..][0..@sizeOf(elf.Verdaux)]);
        try versions.put(arena, @backingInt(vd.ndx), if (vd.flags & elf.VER_FLG_BASE != 0) null else str(strtab, aux.name));
        if (vd.next == 0) break;
        at += vd.next;
    }

    var lib: Shared = .{ .path = path, .soname = path };
    for (dynamic) |d| if (d.d_tag == elf.DT_SONAME) {
        lib.soname = str(strtab, d.d_val);
    };
    var undefs: std.ArrayList(Undef) = .empty;
    for (syms, 0..) |sym, i| {
        if (sym.st_shndx == elf.SHN_UNDEF) {
            const bind = sym.st_bind();
            const name = str(strtab, sym.st_name);
            if ((bind == elf.STB_GLOBAL or bind == elf.STB_WEAK) and name.len != 0)
                try undefs.append(arena, .{ .name = name, .weak = bind == elf.STB_WEAK });
            continue;
        }
        switch (sym.st_bind()) {
            elf.STB_GLOBAL, elf.STB_WEAK, elf.STB_GNU_UNIQUE => {},
            else => continue,
        }
        // Default or protected visibility.
        if (sym.st_other & 3 != 0 and sym.st_other & 3 != 3) continue;
        var version: ?[]const u8 = null;
        if (i < versym.len) {
            // Hidden (non-default) versions and local symbols do not bind
            // unversioned references.
            if (versym[i] & 0x8000 != 0 or versym[i] == 0) continue;
            version = versions.get(versym[i]) orelse null;
        }
        const name = str(strtab, sym.st_name);
        if (name.len == 0) continue;
        const gop = try lib.symbols.getOrPut(arena, name);
        if (gop.found_existing) continue;
        gop.value_ptr.* = .{ .version = version, .object = sym.st_type() == elf.STT_OBJECT, .tls = sym.st_type() == elf.STT_TLS, .size = sym.st_size, .value = sym.st_value };
    }
    lib.undefs = undefs.items;
    return lib;
}

/// The library's other data objects at `value`: the aliases of a copied
/// object, which its own code may use instead.
pub fn aliases(lib: *const Shared, arena: Allocator, value: u64) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = lib.symbols.iterator();
    while (it.next()) |e| if (e.value_ptr.object and e.value_ptr.value == value) try out.append(arena, e.key_ptr.*);
    std.mem.sortUnstable([]const u8, out.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return out.items;
}
