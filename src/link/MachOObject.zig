//! Relocatable arm64 Mach-O objects (MH_OBJECT, `bs build-obj` and the
//! objects of static libraries on aarch64-macos) from the same Atoms as an
//! executable, for ld64, upstream's linker and bs's own (`MachOInput`).
//!
//! - One unnamed LC_SEGMENT_64 holding the sections that have atoms, in
//!   this order, zero-fill last: __TEXT,__text; __TEXT,__const (`.rodata`
//!   without absolute addresses); __DATA,__const (`.rodata` with them,
//!   which the final link makes read-only after fixups); __DATA,__data;
//!   __DATA,__mod_init_func (`.init_array`); __DATA,__thread_data;
//!   __DATA,__thread_vars; __LD,__compact_unwind; __DATA,__bss;
//!   __DATA,__thread_bss. Section addresses are laid out from 0.
//! - Symbols: one per atom, valued at its address: the atom's exports
//!   (external, private external for hidden visibility, N_WEAK_DEF for
//!   weak ones), else a local symbol of its name (`l<n>` for an unnamed
//!   one); then an undefined external per import (N_WEAK_REF for weak
//!   ones). Locals come first, then the defined externals and the
//!   undefined ones, each sorted by name, as LC_DYSYMTAB groups them.
//! - A thread-local atom's bytes go to __thread_data or __thread_bss as
//!   `<name>$tlv$init`, and its symbol names its descriptor in
//!   __thread_vars (`__tlv_bootstrap`, 0, the init's address), as Clang's.
//!   Its `aarch64_tlvp_pageoff12` add becomes the ldr that the TLVP
//!   relocation expects, which the final link relaxes back.
//! - Relocations, extern against the target's symbol: BRANCH26, PAGE21,
//!   PAGEOFF12, GOT_LOAD_*, TLVP_LOAD_* (an ARM64_RELOC_ADDEND before
//!   any with an addend), and UNSIGNED for 64-bit addresses, whose addend
//!   stays in the field. Targets with a link-time value (`values`, error
//!   codes) are written in place.
//! - A __compact_unwind entry per function with a frame record, as the
//!   executable's __unwind_info gives it.
//! - No debug info yet: Zig frames in a library linked from such an
//!   object have symbols but no lines.

const std = @import("std");
const macho = std.macho;
const Allocator = std.mem.Allocator;
const Atom = @import("Atom.zig");
const Elf = @import("Elf.zig");
const ElfDynamic = @import("ElfDynamic.zig");
const MachO = @import("MachO.zig");
const SymbolKey = Atom.SymbolKey;

pub const Export = ElfDynamic.Export;
pub const Import = ElfDynamic.Import;

pub const Options = struct {
    values: []const Elf.Value = &.{},
    exports: []const Export = &.{},
    imports: []const Import = &.{},
    aliases: []const Elf.Alias = &.{},
    min_os: std.SemanticVersion = .{ .major = 15, .minor = 0, .patch = 0 },
    diag: ?*Elf.Diagnostic = null,
};

pub const Error = error{ OutOfMemory, UndefinedSymbol, UnsupportedRelocation, RelocationOverflow };

/// Writes the object of `atoms` to `sub_path` in `dir`.
pub fn link(gpa: Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, atoms: []const Atom, options: Options) !void {
    const bytes = try emit(gpa, atoms, options);
    defer gpa.free(bytes);
    try dir.writeFile(io, .{ .sub_path = sub_path, .data = bytes });
}

const Sect = enum(u8) {
    text,
    text_const,
    data_const,
    data,
    mod_init_func,
    thread_data,
    thread_vars,
    compact_unwind,
    bss,
    thread_bss,

    const info = [_]struct { seg: []const u8, name: []const u8, flags: u32 }{
        .{ .seg = "__TEXT", .name = "__text", .flags = macho.S_REGULAR | macho.S_ATTR_PURE_INSTRUCTIONS | macho.S_ATTR_SOME_INSTRUCTIONS },
        .{ .seg = "__TEXT", .name = "__const", .flags = macho.S_REGULAR },
        .{ .seg = "__DATA", .name = "__const", .flags = macho.S_REGULAR },
        .{ .seg = "__DATA", .name = "__data", .flags = macho.S_REGULAR },
        .{ .seg = "__DATA", .name = "__mod_init_func", .flags = macho.S_MOD_INIT_FUNC_POINTERS },
        .{ .seg = "__DATA", .name = "__thread_data", .flags = macho.S_THREAD_LOCAL_REGULAR },
        .{ .seg = "__DATA", .name = "__thread_vars", .flags = macho.S_THREAD_LOCAL_VARIABLES },
        .{ .seg = "__LD", .name = "__compact_unwind", .flags = macho.S_REGULAR | macho.S_ATTR_DEBUG },
        .{ .seg = "__DATA", .name = "__bss", .flags = macho.S_ZEROFILL },
        .{ .seg = "__DATA", .name = "__thread_bss", .flags = macho.S_THREAD_LOCAL_ZEROFILL },
    };

    fn zeroFill(s: Sect) bool {
        return s == .bss or s == .thread_bss;
    }
};

const n_sects = Sect.info.len;

/// A piece of a section: an atom's bytes (or zero fill), a thread-local
/// descriptor, or a compact unwind entry.
const Piece = struct {
    sect: Sect,
    off: u64 = 0,
    size: u64,
    alignment: u64,
    /// The atom it comes from.
    atom: u32,
    what: enum { bytes, descriptor, unwind },
    /// For `unwind`: which of `MachO.unwindParts`.
    part: u8 = 0,
};

const Reloc = struct { address: u32, symbol: u32, pcrel: bool, length: u2, kind: macho.reloc_type_arm64 };

const Sym = struct {
    name: []const u8,
    /// N_SECT's section (1-based), or 0 for an undefined symbol.
    sect: u8,
    value: u64,
    external: bool,
    private: bool = false,
    weak: bool = false,
};

pub fn emit(gpa: Allocator, atoms: []const Atom, options: Options) Error![]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const diag = options.diag;

    // Where each atom's bytes go, and its descriptor and unwind entry.
    var pieces: std.ArrayList(Piece) = .empty;
    const body = try arena.alloc(u32, atoms.len);
    const desc = try arena.alloc(?u32, atoms.len);
    @memset(desc, null);
    for (atoms, 0..) |a, i| {
        const sect: Sect = switch (a.section) {
            .text => .text,
            .rodata => if (hasAbs(a)) .data_const else .text_const,
            .data => .data,
            .bss => .bss,
            .tdata => .thread_data,
            .tbss => .thread_bss,
            .init_array => .mod_init_func,
            .preinit_array, .fini_array, .sancov_cntrs, .sancov_pcs, .objc => {
                if (diag) |d| d.* = .{ .atom = a.name };
                return error.UnsupportedRelocation;
            },
        };
        body[i] = @intCast(pieces.items.len);
        try pieces.append(arena, .{ .sect = sect, .size = if (a.section.isZeroFill()) a.zero_fill else a.bytes.len, .alignment = a.alignment.toByteUnits(), .atom = @intCast(i), .what = .bytes });
        if (a.section == .tdata or a.section == .tbss) {
            desc[i] = @intCast(pieces.items.len);
            try pieces.append(arena, .{ .sect = .thread_vars, .size = 24, .alignment = 8, .atom = @intCast(i), .what = .descriptor });
        }
        if (a.section == .text and MachO.unwindEncoding(a.unwind) != 0) {
            var parts: [3]MachO.UnwindPart = undefined;
            for (0..MachO.unwindParts(a.unwind, @intCast(a.bytes.len), &parts).len) |k|
                try pieces.append(arena, .{ .sect = .compact_unwind, .size = 32, .alignment = 8, .atom = @intCast(i), .what = .unwind, .part = @intCast(k) });
        }
    }

    // Sections: their pieces in atom order, and addresses from 0.
    var sect_size: [n_sects]u64 = @splat(0);
    var sect_align: [n_sects]u64 = @splat(1);
    for (pieces.items) |*p| {
        const s = @backingInt(p.sect);
        p.off = std.mem.alignForward(u64, sect_size[s], p.alignment);
        sect_size[s] = p.off + p.size;
        sect_align[s] = @max(sect_align[s], p.alignment);
    }
    var sect_index: [n_sects]u8 = @splat(0);
    var sect_addr: [n_sects]u64 = @splat(0);
    var n_used: u8 = 0;
    var addr: u64 = 0;
    for (0..n_sects) |s| {
        if (sect_size[s] == 0) continue;
        n_used += 1;
        sect_index[s] = n_used;
        addr = std.mem.alignForward(u64, addr, sect_align[s]);
        sect_addr[s] = addr;
        addr += sect_size[s];
    }
    const pieceAddr = struct {
        fn f(p: Piece, sa: *const [n_sects]u64) u64 {
            return sa[@backingInt(p.sect)] + p.off;
        }
    }.f;

    // Symbols. Each atom's: its exports, else a local of its name.
    var syms: std.ArrayList(Sym) = .empty;
    var exports_of: std.AutoHashMapUnmanaged(SymbolKey, std.ArrayList(Export)) = .empty;
    for (options.exports) |x| {
        const gop = try exports_of.getOrPut(arena, x.key);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(arena, x);
    }
    // The symbol relocations to each atom's key use, by key.
    var key_sym: std.AutoHashMapUnmanaged(SymbolKey, u32) = .empty;
    var tlv_bootstrap: ?u32 = null;
    const init_sym = try arena.alloc(u32, atoms.len);
    for (atoms, 0..) |a, i| {
        const p = pieces.items[body[i]];
        // A thread-local's name is its descriptor's.
        const named = if (desc[i]) |d| pieces.items[d] else p;
        const value = pieceAddr(named, &sect_addr);
        const sect = sect_index[@backingInt(named.sect)];
        if (exports_of.get(a.key)) |list| {
            for (list.items, 0..) |x, k| {
                if (k == 0) try key_sym.put(arena, a.key, @intCast(syms.items.len));
                try syms.append(arena, .{ .name = try std.fmt.allocPrint(arena, "_{s}", .{x.name}), .sect = sect, .value = value + x.offset, .external = true, .private = x.visibility == .hidden, .weak = x.weak });
            }
        } else {
            try key_sym.put(arena, a.key, @intCast(syms.items.len));
            const name = if (a.name.len == 0) try std.fmt.allocPrint(arena, "l{d}", .{i}) else try std.fmt.allocPrint(arena, "_{s}", .{a.name});
            try syms.append(arena, .{ .name = name, .sect = sect, .value = value, .external = false });
        }
        if (desc[i] != null) {
            init_sym[i] = @intCast(syms.items.len);
            try syms.append(arena, .{ .name = try std.fmt.allocPrint(arena, "{s}$tlv$init", .{syms.items[key_sym.get(a.key).?].name}), .sect = sect_index[@backingInt(p.sect)], .value = pieceAddr(p, &sect_addr), .external = false });
            if (tlv_bootstrap == null) {
                tlv_bootstrap = @intCast(syms.items.len);
                try syms.append(arena, .{ .name = "__tlv_bootstrap", .sect = 0, .value = 0, .external = true });
            }
        }
    }
    for (options.imports) |imp| {
        if (key_sym.contains(imp.key)) continue;
        try key_sym.put(arena, imp.key, @intCast(syms.items.len));
        try syms.append(arena, .{ .name = try std.fmt.allocPrint(arena, "_{s}", .{imp.name}), .sect = 0, .value = 0, .external = true, .weak = imp.weak });
    }
    var values: std.AutoHashMapUnmanaged(SymbolKey, u64) = .empty;
    for (options.values) |v| try values.put(arena, v.key, v.value);
    var aliases: std.AutoHashMapUnmanaged(SymbolKey, Elf.Alias) = .empty;
    for (options.aliases) |al| try aliases.put(arena, al.key, al);

    // Section contents and relocations.
    var contents: [n_sects][]u8 = undefined;
    for (0..n_sects) |s| {
        contents[s] = if (isZeroSect(s)) &.{} else try arena.alloc(u8, sect_size[s]);
        @memset(contents[s], 0);
    }
    var relocs: [n_sects]std.ArrayList(Reloc) = @splat(.empty);
    for (pieces.items) |p| {
        const a = atoms[p.atom];
        const s = @backingInt(p.sect);
        switch (p.what) {
            .descriptor => {
                const at: u32 = @intCast(p.off);
                try relocs[s].append(arena, .{ .address = at, .symbol = tlv_bootstrap.?, .pcrel = false, .length = 3, .kind = .ARM64_RELOC_UNSIGNED });
                try relocs[s].append(arena, .{ .address = at + 16, .symbol = init_sym[p.atom], .pcrel = false, .length = 3, .kind = .ARM64_RELOC_UNSIGNED });
            },
            .unwind => {
                // A part's address is the function's plus its offset (the
                // relocation's addend).
                const out = contents[s][p.off..][0..32];
                var buf: [3]MachO.UnwindPart = undefined;
                const parts = MachO.unwindParts(a.unwind, @intCast(a.bytes.len), &buf);
                const part = parts[p.part];
                const end = if (p.part + 1 < parts.len) parts[p.part + 1].off else a.bytes.len;
                std.mem.writeInt(u64, out[0..8], part.off, .little);
                std.mem.writeInt(u32, out[8..12], @intCast(end - part.off), .little);
                std.mem.writeInt(u32, out[12..16], part.encoding, .little);
                try relocs[s].append(arena, .{ .address = @intCast(p.off), .symbol = key_sym.get(a.key).?, .pcrel = false, .length = 3, .kind = .ARM64_RELOC_UNSIGNED });
            },
            .bytes => {
                if (p.sect.zeroFill()) continue;
                const out = contents[s][p.off..][0..a.bytes.len];
                @memcpy(out, a.bytes);
                for (a.relocs) |r| {
                    var key = a.targets[r.info.target];
                    var addend: i64 = r.addend;
                    if (aliases.get(key)) |al| {
                        key = al.target;
                        addend += al.addend;
                    }
                    const field = out[r.offset..];
                    if (values.get(key)) |v| {
                        try writeValue(field, r.info.kind, @bitCast(@as(i64, @bitCast(v)) +% addend));
                        continue;
                    }
                    const sym = key_sym.get(key) orelse {
                        if (diag) |d| d.* = .{ .atom = a.name, .target = key };
                        return error.UndefinedSymbol;
                    };
                    const at: u32 = @intCast(p.off + r.offset);
                    const kind: macho.reloc_type_arm64, const pcrel: bool, const length: u2 = switch (r.info.kind) {
                        .aarch64_abs64, .value64 => {
                            std.mem.writeInt(i64, field[0..8], addend, .little);
                            try relocs[s].append(arena, .{ .address = at, .symbol = sym, .pcrel = false, .length = 3, .kind = .ARM64_RELOC_UNSIGNED });
                            continue;
                        },
                        .aarch64_branch26 => .{ .ARM64_RELOC_BRANCH26, true, 2 },
                        .aarch64_page21 => .{ .ARM64_RELOC_PAGE21, true, 2 },
                        .aarch64_pageoff12 => .{ .ARM64_RELOC_PAGEOFF12, false, 2 },
                        .aarch64_got_load_page21 => .{ .ARM64_RELOC_GOT_LOAD_PAGE21, true, 2 },
                        .aarch64_got_load_pageoff12 => .{ .ARM64_RELOC_GOT_LOAD_PAGEOFF12, false, 2 },
                        .aarch64_tlvp_page21 => .{ .ARM64_RELOC_TLVP_LOAD_PAGE21, true, 2 },
                        .aarch64_tlvp_pageoff12 => tlvp: {
                            // `add xd, xn, #0` to `ldr xd, [xn]`, same registers.
                            const insn = std.mem.readInt(u32, field[0..4], .little);
                            std.mem.writeInt(u32, field[0..4], 0xf9400000 | (insn & 0x3ff), .little);
                            break :tlvp .{ .ARM64_RELOC_TLVP_LOAD_PAGEOFF12, false, 2 };
                        },
                        else => {
                            if (diag) |d| d.* = .{ .atom = a.name, .target = key };
                            return error.UnsupportedRelocation;
                        },
                    };
                    if (addend != 0) {
                        const add24 = std.math.cast(i24, addend) orelse {
                            if (diag) |d| d.* = .{ .atom = a.name, .target = key };
                            return error.RelocationOverflow;
                        };
                        try relocs[s].append(arena, .{ .address = at, .symbol = @as(u24, @bitCast(add24)), .pcrel = false, .length = 2, .kind = .ARM64_RELOC_ADDEND });
                    }
                    try relocs[s].append(arena, .{ .address = at, .symbol = sym, .pcrel = pcrel, .length = length, .kind = kind });
                }
            },
        }
    }

    // Symbol order: locals, defined externals, undefined externals, the
    // last two sorted by name; relocations follow the renumbering.
    const order = try arena.alloc(u32, syms.items.len);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    std.mem.sort(u32, order, syms.items, struct {
        fn group(s: Sym) u2 {
            return if (!s.external) 0 else if (s.sect != 0) 1 else 2;
        }
        fn lessThan(ss: []const Sym, a: u32, b: u32) bool {
            const ga = group(ss[a]);
            const gb = group(ss[b]);
            if (ga != gb) return ga < gb;
            if (ga == 0) return a < b;
            return std.mem.lessThan(u8, ss[a].name, ss[b].name);
        }
    }.lessThan);
    const new_index = try arena.alloc(u32, syms.items.len);
    for (order, 0..) |old, new| new_index[old] = @intCast(new);
    var n_local: u32 = 0;
    var n_extdef: u32 = 0;
    for (syms.items) |s| {
        if (!s.external) n_local += 1 else if (s.sect != 0) n_extdef += 1;
    }
    const n_undef: u32 = @intCast(syms.items.len - n_local - n_extdef);

    // String table: a leading space and NUL, as ld64 expects index 0 empty.
    var strtab: std.ArrayList(u8) = .empty;
    try strtab.appendSlice(arena, " \x00");
    const strx = try arena.alloc(u32, syms.items.len);
    for (order) |old| {
        strx[old] = @intCast(strtab.items.len);
        try strtab.appendSlice(arena, syms.items[old].name);
        try strtab.append(arena, 0);
    }
    while (strtab.items.len % 8 != 0) try strtab.append(arena, 0);

    // Layout: header, load commands, section contents, relocations,
    // symbols, strings.
    const seg_cmd_size = @sizeOf(macho.segment_command_64) + @as(u32, n_used) * @sizeOf(macho.section_64);
    const build_cmd_size = @sizeOf(macho.build_version_command);
    const cmds_size: u32 = seg_cmd_size + build_cmd_size + @sizeOf(macho.symtab_command) + @sizeOf(macho.dysymtab_command);
    var off: u64 = @sizeOf(macho.mach_header_64) + cmds_size;
    var sect_off: [n_sects]u64 = @splat(0);
    const file_start = off;
    for (0..n_sects) |s| {
        if (sect_size[s] == 0 or isZeroSect(s)) continue;
        // File offsets keep the addresses' alignment.
        off = file_start + sect_addr[s];
        sect_off[s] = off;
        off += sect_size[s];
    }
    var reloc_off: [n_sects]u64 = @splat(0);
    off = std.mem.alignForward(u64, off, 8);
    for (0..n_sects) |s| {
        reloc_off[s] = off;
        off += relocs[s].items.len * 8;
    }
    const sym_off = off;
    off += syms.items.len * @sizeOf(macho.nlist_64);
    const str_off = off;
    off += strtab.items.len;

    const buf = try gpa.alloc(u8, off);
    errdefer gpa.free(buf);
    @memset(buf, 0);
    var w: Writer = .{ .buf = buf };
    // mach_header_64
    w.int(u32, macho.MH_MAGIC_64);
    w.int(u32, @bitCast(macho.CPU_TYPE_ARM64));
    w.int(u32, macho.CPU_SUBTYPE_ARM_ALL);
    w.int(u32, macho.MH_OBJECT);
    w.int(u32, 4);
    w.int(u32, cmds_size);
    w.int(u32, 0);
    w.int(u32, 0);
    // LC_SEGMENT_64, unnamed, covering every section.
    const seg_file_size = if (n_used == 0) 0 else blk: {
        var end: u64 = 0;
        for (0..n_sects) |s| if (sect_size[s] != 0 and !isZeroSect(s)) {
            end = @max(end, sect_addr[s] + sect_size[s]);
        };
        break :blk end;
    };
    w.int(u32, @backingInt(macho.LC.SEGMENT_64));
    w.int(u32, seg_cmd_size);
    w.bytes(&(@as([16]u8, @splat(0))));
    w.int(u64, 0);
    w.int(u64, addr);
    w.int(u64, if (n_used == 0) 0 else file_start);
    w.int(u64, seg_file_size);
    w.int(u32, 7);
    w.int(u32, 7);
    w.int(u32, n_used);
    w.int(u32, 0);
    for (0..n_sects) |s| {
        if (sect_size[s] == 0) continue;
        const inf = Sect.info[s];
        w.bytes(&name16(inf.name));
        w.bytes(&name16(inf.seg));
        w.int(u64, sect_addr[s]);
        w.int(u64, sect_size[s]);
        w.int(u32, @intCast(sect_off[s]));
        w.int(u32, std.math.log2_int(u64, sect_align[s]));
        w.int(u32, if (relocs[s].items.len == 0) 0 else @intCast(reloc_off[s]));
        w.int(u32, @intCast(relocs[s].items.len));
        w.int(u32, inf.flags);
        w.int(u32, 0);
        w.int(u32, 0);
        w.int(u32, 0);
    }
    // LC_BUILD_VERSION: macOS and its minimum, and no SDK version, as
    // upstream's objects.
    w.int(u32, @backingInt(macho.LC.BUILD_VERSION));
    w.int(u32, build_cmd_size);
    w.int(u32, @backingInt(macho.PLATFORM.MACOS));
    w.int(u32, MachO.packVersion(options.min_os));
    w.int(u32, 0);
    w.int(u32, 0);
    // LC_SYMTAB
    w.int(u32, @backingInt(macho.LC.SYMTAB));
    w.int(u32, @sizeOf(macho.symtab_command));
    w.int(u32, @intCast(sym_off));
    w.int(u32, @intCast(syms.items.len));
    w.int(u32, @intCast(str_off));
    w.int(u32, @intCast(strtab.items.len));
    // LC_DYSYMTAB: the three groups, nothing else.
    w.int(u32, @backingInt(macho.LC.DYSYMTAB));
    w.int(u32, @sizeOf(macho.dysymtab_command));
    w.int(u32, 0);
    w.int(u32, n_local);
    w.int(u32, n_local);
    w.int(u32, n_extdef);
    w.int(u32, n_local + n_extdef);
    w.int(u32, n_undef);
    w.at += @sizeOf(macho.dysymtab_command) - 8 - 6 * 4;

    for (0..n_sects) |s| {
        if (sect_size[s] == 0 or isZeroSect(s)) continue;
        @memcpy(buf[sect_off[s]..][0..sect_size[s]], contents[s]);
        // An ADDEND comes right before the relocation it modifies.
        var rw: Writer = .{ .buf = buf, .at = reloc_off[s] };
        for (relocs[s].items) |r| {
            const symnum: u32 = if (r.kind == .ARM64_RELOC_ADDEND) r.symbol else new_index[r.symbol];
            rw.int(u32, r.address);
            rw.int(u32, symnum | @as(u32, @intFromBool(r.pcrel)) << 24 | @as(u32, r.length) << 25 | @as(u32, @intFromBool(r.kind != .ARM64_RELOC_ADDEND)) << 27 | @as(u32, @backingInt(r.kind)) << 28);
        }
    }
    var sw: Writer = .{ .buf = buf, .at = sym_off };
    for (order) |old| {
        const s = syms.items[old];
        var n_type: u8 = if (s.sect != 0) macho.N_SECT else macho.N_UNDF;
        if (s.external) n_type |= macho.N_EXT;
        if (s.private) n_type |= macho.N_PEXT;
        const desc_bits: u16 = if (!s.weak) 0 else if (s.sect != 0) macho.N_WEAK_DEF else macho.N_WEAK_REF;
        sw.int(u32, strx[old]);
        sw.int(u8, n_type);
        sw.int(u8, s.sect);
        sw.int(u16, desc_bits);
        sw.int(u64, s.value);
    }
    @memcpy(buf[str_off..][0..strtab.items.len], strtab.items);
    return buf;
}

fn isZeroSect(s: usize) bool {
    return s == @backingInt(Sect.bss) or s == @backingInt(Sect.thread_bss);
}

fn hasAbs(a: Atom) bool {
    for (a.relocs) |r| if (r.info.kind == .aarch64_abs64) return true;
    return false;
}

/// A `value*` or `aarch64_movw_value16` field with its link-time value.
fn writeValue(field: []u8, kind: Atom.Reloc.Kind, v: u64) Error!void {
    switch (kind) {
        .value8 => field[0] = std.math.cast(u8, v) orelse return error.RelocationOverflow,
        .value16 => std.mem.writeInt(u16, field[0..2], std.math.cast(u16, v) orelse return error.RelocationOverflow, .little),
        .value32 => std.mem.writeInt(u32, field[0..4], std.math.cast(u32, v) orelse return error.RelocationOverflow, .little),
        .value64, .aarch64_abs64 => std.mem.writeInt(u64, field[0..8], v, .little),
        .aarch64_movw_value16 => {
            const imm = std.math.cast(u16, v) orelse return error.RelocationOverflow;
            const insn = std.mem.readInt(u32, field[0..4], .little);
            std.mem.writeInt(u32, field[0..4], (insn & ~@as(u32, 0xffff << 5)) | @as(u32, imm) << 5, .little);
        },
        else => return error.UnsupportedRelocation,
    }
}

fn name16(name: []const u8) [16]u8 {
    var n: [16]u8 = @splat(0);
    @memcpy(n[0..name.len], name);
    return n;
}

const Writer = struct {
    buf: []u8,
    at: u64 = 0,

    fn int(w: *Writer, comptime T: type, v: T) void {
        std.mem.writeInt(T, w.buf[w.at..][0..@sizeOf(T)], v, .little);
        w.at += @sizeOf(T);
    }

    fn bytes(w: *Writer, b: []const u8) void {
        @memcpy(w.buf[w.at..][0..b.len], b);
        w.at += b.len;
    }
};

test "an object and a Darwin archive of it read back with MachOInput" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const MachOInput = @import("MachOInput.zig");
    const Archive = @import("Archive.zig");
    const entry: SymbolKey = .fromName("entry");
    const helper: SymbolKey = .fromName("helper");
    const code: SymbolKey = .fromName("error.Code");
    const ext: SymbolKey = .fromName("import.ext");
    const ptr: SymbolKey = .fromName("ptr");
    const tl: SymbolKey = .fromName("tl");
    // entry: bl helper; movz w0, #<code>; adrp x1, ext@GOTPAGE;
    // ldr x1, [x1, ext@GOTPAGEOFF]; adrp x0, tl@TLVPPAGE;
    // add x0, x0, tl@TLVPPAGEOFF. helper: ret. ptr: .quad entry + 8.
    const insns = [_]u32{ 0x94000000, 0x52800000, 0x90000001, 0xf9400021, 0x90000000, 0x91000000 };
    const atoms = [_]Atom{
        .{ .key = entry, .name = "entry", .section = .text, .alignment = .@"4", .bytes = std.mem.sliceAsBytes(&insns), .targets = &.{ helper, code, ext, tl }, .relocs = &.{
            .init(0, .aarch64_branch26, 0, 0),        .init(4, .aarch64_movw_value16, 1, 0),
            .init(8, .aarch64_got_load_page21, 2, 0), .init(12, .aarch64_got_load_pageoff12, 2, 0),
            .init(16, .aarch64_tlvp_page21, 3, 0),    .init(20, .aarch64_tlvp_pageoff12, 3, 0),
        } },
        .{ .key = helper, .name = "helper", .section = .text, .alignment = .@"4", .bytes = &.{ 0xc0, 0x03, 0x5f, 0xd6 } },
        .{ .key = ptr, .name = "ptr", .section = .data, .alignment = .@"8", .bytes = &@as([8]u8, @splat(0)), .targets = &.{entry}, .relocs = &.{.init(0, .aarch64_abs64, 0, 8)} },
        .{ .key = tl, .name = "tl", .section = .tbss, .alignment = .@"4", .zero_fill = 4 },
    };
    const obj = try emit(gpa, &atoms, .{
        .values = &.{.{ .key = code, .value = 7 }},
        .exports = &.{ .{ .key = entry, .name = "entry" }, .{ .key = ptr, .name = "ptr" }, .{ .key = tl, .name = "tl" } },
        .imports = &.{.{ .key = ext, .name = "ext" }},
    });
    defer gpa.free(obj);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try Archive.writeDarwin(gpa, io, tmp.dir, "lib.a", &.{.{ .name = "an_object_with_a_long_name.o", .bytes = obj }});
    const lib = try tmp.dir.readFileAlloc(io, "lib.a", gpa, .unlimited);
    defer gpa.free(lib);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var in: MachOInput = .{ .arena = arena_state.allocator() };
    try in.addArchive("lib.a", lib);
    const Ctx = struct {
        pub fn zigExport(_: @This(), _: []const u8) !?SymbolKey {
            return null;
        }
        pub fn rtExport(_: @This(), _: []const u8) !?SymbolKey {
            return null;
        }
        pub fn importSym(_: @This(), name: []const u8, _: bool) !?SymbolKey {
            return if (std.mem.eql(u8, name, "ext")) .fromName("import.ext") else null;
        }
    };
    // The index names the member's three definitions, not the import.
    try std.testing.expectEqual(0, try in.pull(&.{"entry"}, Ctx{}));
    try std.testing.expectEqualStrings("lib.a(an_object_with_a_long_name.o)", in.objects.items[0].path);
    const c = try in.convert(Ctx{});
    try std.testing.expectEqual(0, in.errors.items.len);
    const text = (try in.lookup("entry")).?;
    try std.testing.expectEqual(0, text.offset);
    const data = (try in.lookup("ptr")).?;
    const thread_local = (try in.lookup("tl")).?;
    var seen: usize = 0;
    for (c.atoms) |a| {
        if (a.key == text.key) {
            seen += 1;
            // The value is written in place; helper is a local 24 bytes
            // into the same section.
            try std.testing.expectEqual(0x52800000 | 7 << 5, std.mem.readInt(u32, a.bytes[4..8], .little));
            const Got = struct { offset: u32, kind: Atom.Reloc.Kind, target: SymbolKey, addend: i32 };
            var got: [5]Got = undefined;
            try std.testing.expectEqual(5, a.relocs.len);
            for (a.relocs, &got) |r, *g| g.* = .{ .offset = r.offset, .kind = r.info.kind, .target = a.targets[r.info.target], .addend = r.addend };
            try std.testing.expectEqualSlices(Got, &.{
                .{ .offset = 0, .kind = .aarch64_branch26, .target = text.key, .addend = 24 },
                .{ .offset = 8, .kind = .aarch64_got_load_page21, .target = ext, .addend = 0 },
                .{ .offset = 12, .kind = .aarch64_got_load_pageoff12, .target = ext, .addend = 0 },
                .{ .offset = 16, .kind = .aarch64_tlvp_page21, .target = thread_local.key, .addend = 0 },
                .{ .offset = 20, .kind = .aarch64_tlvp_pageoff12, .target = thread_local.key, .addend = 0 },
            }, &got);
        } else if (a.key == data.key) {
            seen += 1;
            try std.testing.expectEqual(1, a.relocs.len);
            try std.testing.expectEqual(.aarch64_abs64, a.relocs[0].info.kind);
            try std.testing.expectEqual(text.key, a.targets[a.relocs[0].info.target]);
            try std.testing.expectEqual(8, a.relocs[0].addend);
        }
    }
    try std.testing.expectEqual(2, seen);
}
