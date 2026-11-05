//! Relocatable links of arm64 Mach-O objects (`ld -r`): one MH_OBJECT from
//! several, for `bs build-obj` with object inputs or C sources on
//! aarch64-macos, as upstream's `flushObject` (`MachO/relocatable.zig`)
//! merges them (docs/slop/architecture.md, "Relocatable links"). ElfMerge
//! is its ELF counterpart.
//!
//! The inputs stay as they are, not converted to Atoms: sections with the
//! same segment and section name are concatenated in input order, each
//! input's section whole at its alignment, zero-fill sections last;
//! symbols and relocations are renumbered and moved with their sections.
//!
//! - Debug sections (S_ATTR_DEBUG, `__DWARF`, but not `__compact_unwind`,
//!   which has the attribute too) are dropped, as upstream
//!   drops them: their offsets into each other have no relocations, so
//!   they cannot be concatenated. (Upstream copies a single input as it
//!   is, debug info included; `main.writeMerged` does too.)
//! - Symbols: every input's local symbols, then the globals (private
//!   externals too), one per name: a strong definition over a weak one
//!   over COMMON (the largest, the strictest alignment) over references;
//!   two strong definitions are an error; a reference is weak only if
//!   every reference is. Defined globals, then the undefined and COMMON
//!   ones, each sorted by name, as LC_DYSYMTAB groups them. Stabs are
//!   dropped.
//! - Relocations keep their order (so ADDEND and SUBTRACTOR pairs stay
//!   together), with their addresses moved by their section's place and
//!   extern ones renumbered. A section-relative (non-extern) UNSIGNED,
//!   such as `__compact_unwind`'s function field, names its target by
//!   address, so the field moves with the target section; Clang emits no
//!   other section-relative arm64 relocation, and they are an error.
//! - The inputs' `__objc_imageinfo` merge into one, as ld64 merges them
//!   (`MachOInput.mergeImageInfo`).
//! - `__eh_frame` pieces must need no padding between them, which would
//!   read as a terminator.
//! - Kept load commands: LC_BUILD_VERSION (or LC_VERSION_MIN_*) of the
//!   first input with one, and each distinct LC_LINKER_OPTION. Linker
//!   optimization hints and data-in-code entries, which are hints, are
//!   dropped. MH_SUBSECTIONS_VIA_SYMBOLS only if every input has it.

const std = @import("std");
const macho = std.macho;
const Allocator = std.mem.Allocator;
const MachOInput = @import("MachOInput.zig");

pub const Input = @import("ElfMerge.zig").Input;

pub const Error = error{ OutOfMemory, InvalidObject, DuplicateSymbol, UnsupportedObject };

const Object = MachOInput.Object;
const Sym = MachOInput.Sym;
const Reloc = MachOInput.Reloc;

const OutSection = struct {
    hdr: macho.section_64,
    pieces: std.ArrayList(Piece) = .empty,
    relocs: std.ArrayList([8]u8) = .empty,
};

const Piece = struct { object: u32, sect: u32, offset: u64 };

const unmapped = std.math.maxInt(u32);
/// A symbol reference to a global (by its index in `globals`) rather than
/// a local.
const global_bit: u32 = 1 << 31;

const Global = struct {
    name: []const u8,
    sym: Sym,
    state: enum { undef, common, weak_def, def },
    strong_ref: bool = false,
    path: []const u8,
    index: u32 = 0,
};

/// The section-relative UNSIGNED fields to move, in output section order.
const Patch = struct { sect: u32, offset: u64, wide: bool, delta: u64 };

/// Whether section `s` is debug info, which the merge drops:
/// S_ATTR_DEBUG, except `__LD,__compact_unwind`, which has it too.
fn dropped(s: macho.section_64) bool {
    return s.flags & macho.S_ATTR_DEBUG != 0 and !std.mem.eql(u8, std.mem.sliceTo(&s.sectname, 0), "__compact_unwind");
}

const reloc_unsigned = 0;
const reloc_subtractor = 1;
const reloc_addend = 10;

/// The merged object, allocated with `gpa`. `diag` gets a message for
/// `DuplicateSymbol`, `InvalidObject` and `UnsupportedObject`, allocated
/// with `arena`.
pub fn merge(gpa: Allocator, arena: Allocator, inputs: []const Input, diag: *[]const u8) Error![]u8 {
    const objects = try arena.alloc(Object, inputs.len);
    for (objects, inputs) |*o, in| o.* = MachOInput.parseObject(arena, in.path, in.bytes) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => {
            diag.* = try std.fmt.allocPrint(arena, "{s}: not an arm64 Mach-O relocatable object", .{in.path});
            return error.InvalidObject;
        },
    };

    // The load commands kept, and whether every input has subsections.
    var version_cmd: []const u8 = &.{};
    var linker_options: std.ArrayList([]const u8) = .empty;
    var subsections = true;
    for (objects) |*o| {
        const mh = std.mem.bytesToValue(macho.mach_header_64, o.bytes[0..@sizeOf(macho.mach_header_64)]);
        if (mh.flags & macho.MH_SUBSECTIONS_VIA_SYMBOLS == 0) subsections = false;
        var off: usize = @sizeOf(macho.mach_header_64);
        for (0..mh.ncmds) |_| {
            const cmd = std.mem.readInt(u32, o.bytes[off..][0..4], .little);
            const size = std.mem.readInt(u32, o.bytes[off + 4 ..][0..4], .little);
            const raw = o.bytes[off..][0..size];
            switch (cmd) {
                @backingInt(macho.LC.BUILD_VERSION), @backingInt(macho.LC.VERSION_MIN_MACOSX) => if (version_cmd.len == 0) {
                    version_cmd = raw;
                },
                @backingInt(macho.LC.LINKER_OPTION) => for (linker_options.items) |seen| {
                    if (std.mem.eql(u8, seen, raw)) break;
                } else try linker_options.append(arena, raw),
                @backingInt(macho.LC.DYSYMTAB) => {
                    const d = std.mem.bytesToValue(macho.dysymtab_command, raw[0..@sizeOf(macho.dysymtab_command)]);
                    if (d.nindirectsyms != 0) {
                        diag.* = try std.fmt.allocPrint(arena, "{s}: an object with indirect symbols, which bs does not merge", .{o.path});
                        return error.UnsupportedObject;
                    }
                },
                else => {},
            }
            off += size;
        }
    }

    // Sections, in first-seen order, and each input section's place.
    var sects: std.ArrayList(OutSection) = .empty;
    // The inputs' `__objc_imageinfo`, merged into the first one's place.
    var image_info: ?[2]u32 = null;
    var image_info_sect: u32 = unmapped;
    const sect_map = try arena.alloc([]u32, objects.len);
    const piece_off = try arena.alloc([]u64, objects.len);
    for (objects, sect_map, piece_off, 0..) |*o, *map, *offs, oi| {
        map.* = try arena.alloc(u32, o.sects.len);
        offs.* = try arena.alloc(u64, o.sects.len);
        @memset(map.*, unmapped);
        for (o.sects[1..], 1..) |s, si| {
            if (dropped(s)) continue;
            const out: u32 = for (sects.items, 0..) |*os, k| {
                if (std.mem.eql(u8, &os.hdr.segname, &s.segname) and std.mem.eql(u8, &os.hdr.sectname, &s.sectname)) break @intCast(k);
            } else new: {
                var hdr = s;
                hdr.size = 0;
                hdr.@"align" = 0;
                try sects.append(arena, .{ .hdr = hdr });
                break :new @intCast(sects.items.len - 1);
            };
            const os = &sects.items[out];
            if (os.hdr.flags & macho.SECTION_TYPE != s.flags & macho.SECTION_TYPE) {
                diag.* = try std.fmt.allocPrint(arena, "{s}: section {s},{s} has another type than in an earlier input", .{ o.path, std.mem.sliceTo(&s.segname, 0), std.mem.sliceTo(&s.sectname, 0) });
                return error.UnsupportedObject;
            }
            os.hdr.@"align" = @max(os.hdr.@"align", s.@"align");
            if (std.mem.eql(u8, std.mem.sliceTo(&s.sectname, 0), "__objc_imageinfo")) {
                if (s.size != 8 or s.nreloc != 0) {
                    diag.* = try std.fmt.allocPrint(arena, "{s}: section '__objc_imageinfo' is not 8 bytes of image info", .{o.path});
                    return error.UnsupportedObject;
                }
                MachOInput.mergeImageInfo(&image_info, o.sectionBytes(si)[0..8]);
                image_info_sect = out;
                if (os.pieces.items.len != 0) {
                    map.*[si] = out;
                    offs.*[si] = 0;
                    continue;
                }
            }
            const at = std.mem.alignForward(u64, os.hdr.size, @as(u64, 1) << @intCast(@min(s.@"align", 15)));
            if (at != os.hdr.size and std.mem.eql(u8, std.mem.sliceTo(&s.sectname, 0), "__eh_frame")) {
                diag.* = try std.fmt.allocPrint(arena, "{s}: its __eh_frame needs padding after the earlier inputs', which would end the section for unwinders", .{o.path});
                return error.UnsupportedObject;
            }
            try os.pieces.append(arena, .{ .object = @intCast(oi), .sect = @intCast(si), .offset = at });
            os.hdr.size = at + s.size;
            map.*[si] = out;
            offs.*[si] = at;
        }
    }
    // Zero-fill sections last; then the output ordinals and addresses.
    const order = try arena.alloc(u32, sects.items.len);
    {
        var n: usize = 0;
        for ([2]bool{ false, true }) |zero| for (sects.items, 0..) |os, k| if (MachOInput.isZeroFill(os.hdr) == zero) {
            order[n] = @intCast(k);
            n += 1;
        };
    }
    const ordinal = try arena.alloc(u8, sects.items.len);
    if (sects.items.len > 255) {
        diag.* = "more than 255 sections";
        return error.UnsupportedObject;
    }
    var addr: u64 = 0;
    for (order, 0..) |k, n| {
        const os = &sects.items[k];
        ordinal[k] = @intCast(n + 1);
        addr = std.mem.alignForward(u64, addr, @as(u64, 1) << @intCast(@min(os.hdr.@"align", 15)));
        os.hdr.addr = addr;
        addr += os.hdr.size;
    }
    const vm_size = addr;
    // How far an input section's contents moved.
    const delta = struct {
        fn f(ss: []const OutSection, maps: []const []u32, offsets: []const []u64, objs: []const Object, oi: usize, si: usize) u64 {
            return ss[maps[oi][si]].hdr.addr +% offsets[oi][si] -% objs[oi].sects[si].addr;
        }
    }.f;

    // Symbols: locals as they come, globals by name.
    var locals: std.ArrayList(Sym) = .empty;
    var local_names: std.ArrayList([]const u8) = .empty;
    var globals: std.ArrayList(Global) = .empty;
    var by_name: std.StringHashMapUnmanaged(u32) = .empty;
    const sym_map = try arena.alloc([]u32, objects.len);
    for (objects, sym_map, 0..) |*o, *map, oi| {
        map.* = try arena.alloc(u32, o.syms.len);
        @memset(map.*, unmapped);
        for (o.syms, 0..) |sym_in, i| {
            if (sym_in.isStab()) continue;
            var sym = sym_in;
            const name = o.symName(sym);
            if (sym.kind() == macho.N_SECT) {
                if (sect_map[oi][sym.n_sect] == unmapped) continue;
                sym.n_value +%= delta(sects.items, sect_map, piece_off, objects, oi, sym.n_sect);
                sym.n_sect = ordinal[sect_map[oi][sym.n_sect]];
            }
            if (!sym.isExternal()) {
                if (sym.kind() != macho.N_SECT and sym.kind() != macho.N_ABS) continue;
                map.*[i] = @intCast(locals.items.len);
                try locals.append(arena, sym);
                try local_names.append(arena, name);
                continue;
            }
            const gop = try by_name.getOrPut(arena, name);
            if (!gop.found_existing) {
                gop.value_ptr.* = @intCast(globals.items.len);
                try globals.append(arena, .{ .name = name, .sym = sym, .state = .undef, .path = o.path });
            }
            map.*[i] = gop.value_ptr.* | global_bit;
            const g = &globals.items[gop.value_ptr.*];
            switch (sym.kind()) {
                macho.N_UNDF => if (sym.n_value == 0) {
                    if (sym.n_desc & macho.N_WEAK_REF == 0) g.strong_ref = true;
                } else switch (g.state) {
                    .def, .weak_def => {},
                    .undef => g.* = .{ .name = name, .sym = sym, .state = .common, .strong_ref = g.strong_ref, .path = o.path },
                    .common => {
                        g.sym.n_value = @max(g.sym.n_value, sym.n_value);
                        const al = @max((g.sym.n_desc >> 8) & 0xf, (sym.n_desc >> 8) & 0xf);
                        g.sym.n_desc = (g.sym.n_desc & ~@as(u16, 0xf00)) | al << 8;
                    },
                },
                macho.N_SECT, macho.N_ABS => {
                    const weak = sym.n_desc & macho.N_WEAK_DEF != 0;
                    switch (g.state) {
                        .def => if (!weak) {
                            diag.* = try std.fmt.allocPrint(arena, "duplicate symbol: {s}, defined in {s} and {s}", .{ name, g.path, o.path });
                            return error.DuplicateSymbol;
                        },
                        .weak_def => if (!weak) {
                            g.* = .{ .name = name, .sym = sym, .state = .def, .strong_ref = g.strong_ref, .path = o.path };
                        },
                        .undef, .common => g.* = .{ .name = name, .sym = sym, .state = if (weak) .weak_def else .def, .strong_ref = g.strong_ref, .path = o.path },
                    }
                },
                else => {
                    diag.* = try std.fmt.allocPrint(arena, "{s}: symbol '{s}' has a type bs does not merge ({x})", .{ o.path, name, sym.n_type });
                    return error.UnsupportedObject;
                },
            }
        }
    }
    // Defined globals, then the undefined and COMMON ones, by name.
    const sorted = try arena.alloc(u32, globals.items.len);
    for (sorted, 0..) |*s, k| s.* = @intCast(k);
    const Order = struct {
        gs: []const Global,
        fn defined(g: Global) bool {
            return g.state == .def or g.state == .weak_def;
        }
        fn less(c: @This(), a: u32, b: u32) bool {
            const da = defined(c.gs[a]);
            const db = defined(c.gs[b]);
            if (da != db) return da;
            return std.mem.lessThan(u8, c.gs[a].name, c.gs[b].name);
        }
    };
    std.mem.sort(u32, sorted, Order{ .gs = globals.items }, Order.less);
    var n_extdef: u32 = 0;
    for (sorted, 0..) |gi, k| {
        const g = &globals.items[gi];
        g.index = @intCast(locals.items.len + k);
        if (Order.defined(g.*)) n_extdef += 1;
        if (g.state == .undef) {
            g.sym = .{ .n_strx = 0, .n_type = macho.N_UNDF | macho.N_EXT, .n_sect = 0, .n_desc = if (g.strong_ref) 0 else macho.N_WEAK_REF, .n_value = 0 };
        }
    }
    const n_syms: u32 = @intCast(locals.items.len + globals.items.len);

    // Relocations, and the fields of section-relative ones to move.
    var patches: std.ArrayList(Patch) = .empty;
    for (sects.items, 0..) |*os, k| for (os.pieces.items) |p| {
        const o = &objects[p.object];
        const s = o.sects[p.sect];
        const raw = o.bytes[s.reloff..][0 .. @as(usize, s.nreloc) * 8];
        var prev_type: u4 = reloc_addend;
        for (0..s.nreloc) |ri| {
            const r = Reloc.read(raw[ri * 8 ..][0..8]);
            if (r.address & 0x8000_0000 != 0 or @as(u64, r.address) >= s.size) {
                diag.* = try std.fmt.allocPrint(arena, "{s}: a relocation outside its section", .{o.path});
                return error.InvalidObject;
            }
            var symbolnum: u32 = r.symbolnum;
            if (r.type == reloc_addend) {
                // The addend, not a symbol.
            } else if (r.external) {
                const m = if (r.symbolnum < o.syms.len) sym_map[p.object][r.symbolnum] else unmapped;
                if (m == unmapped) {
                    diag.* = try std.fmt.allocPrint(arena, "{s}: a relocation against a symbol of a dropped section, or a missing one", .{o.path});
                    return error.UnsupportedObject;
                }
                symbolnum = if (m & global_bit != 0) globals.items[m & ~global_bit].index else m;
            } else {
                if (r.type != reloc_unsigned or prev_type == reloc_subtractor or r.symbolnum == 0 or r.symbolnum >= o.sects.len) {
                    diag.* = try std.fmt.allocPrint(arena, "{s}: a section-relative relocation of type {d}, which bs does not merge", .{ o.path, r.type });
                    return error.UnsupportedObject;
                }
                const target = sect_map[p.object][r.symbolnum];
                if (target == unmapped) {
                    diag.* = try std.fmt.allocPrint(arena, "{s}: a relocation against a dropped section", .{o.path});
                    return error.UnsupportedObject;
                }
                try patches.append(arena, .{ .sect = @intCast(k), .offset = p.offset + r.address, .wide = r.length == 3, .delta = delta(sects.items, sect_map, piece_off, objects, p.object, r.symbolnum) });
                symbolnum = ordinal[target];
            }
            prev_type = r.type;
            var out: [8]u8 = undefined;
            std.mem.writeInt(u32, out[0..4], @intCast(p.offset + r.address), .little);
            std.mem.writeInt(u32, out[4..8], symbolnum | @as(u32, @intFromBool(r.pcrel)) << 24 | @as(u32, r.length) << 25 | @as(u32, @intFromBool(r.external)) << 27 | @as(u32, r.type) << 28, .little);
            try os.relocs.append(arena, out);
        }
    };

    // The string table: names in symbol order.
    var strtab: std.ArrayList(u8) = .empty;
    try strtab.append(arena, 0);
    const strx = try arena.alloc(u32, n_syms);
    for (local_names.items, 0..) |name, k| {
        strx[k] = if (name.len == 0) 0 else @intCast(strtab.items.len);
        if (name.len != 0) try strtab.print(arena, "{s}\x00", .{name});
    }
    for (globals.items) |g| {
        strx[g.index] = @intCast(strtab.items.len);
        try strtab.print(arena, "{s}\x00", .{g.name});
    }
    while (strtab.items.len % 8 != 0) try strtab.append(arena, 0);

    // Layout: header, load commands, section contents, relocations,
    // symbols, strings.
    const seg_cmd_size = @sizeOf(macho.segment_command_64) + sects.items.len * @sizeOf(macho.section_64);
    const cmds_size = seg_cmd_size + version_cmd.len + blk: {
        var n: usize = 0;
        for (linker_options.items) |lo| n += lo.len;
        break :blk n;
    } + @sizeOf(macho.symtab_command) + @sizeOf(macho.dysymtab_command);
    const n_cmds = 3 + @as(usize, @intFromBool(version_cmd.len != 0)) + linker_options.items.len;
    var off: u64 = @sizeOf(macho.mach_header_64) + cmds_size;
    const data_start = off;
    var file_end: u64 = data_start;
    for (order) |k| {
        const os = &sects.items[k];
        if (MachOInput.isZeroFill(os.hdr)) {
            os.hdr.offset = 0;
            continue;
        }
        // Each section at its address's offset from the first, as Clang
        // lays them out.
        os.hdr.offset = @intCast(data_start + os.hdr.addr);
        file_end = data_start + os.hdr.addr + os.hdr.size;
    }
    off = std.mem.alignForward(u64, file_end, 8);
    for (order) |k| {
        const os = &sects.items[k];
        os.hdr.nreloc = @intCast(os.relocs.items.len);
        os.hdr.reloff = if (os.relocs.items.len == 0) 0 else @intCast(off);
        os.hdr.reserved1 = 0;
        os.hdr.reserved2 = 0;
        off += os.relocs.items.len * 8;
    }
    const symoff = std.mem.alignForward(u64, off, 8);
    const stroff = symoff + @as(u64, n_syms) * @sizeOf(Sym);
    const total = stroff + strtab.items.len;
    if (total > std.math.maxInt(u32)) return error.UnsupportedObject;

    const buf = try gpa.alloc(u8, total);
    errdefer gpa.free(buf);
    @memset(buf, 0);
    var at: usize = 0;
    const put = struct {
        fn f(b: []u8, pos: *usize, v: anytype) void {
            const bytes = std.mem.asBytes(&v);
            @memcpy(b[pos.*..][0..bytes.len], bytes);
            pos.* += bytes.len;
        }
    }.f;
    put(buf, &at, macho.mach_header_64{
        .magic = macho.MH_MAGIC_64,
        .cputype = macho.CPU_TYPE_ARM64,
        .cpusubtype = macho.CPU_SUBTYPE_ARM_ALL,
        .filetype = macho.MH_OBJECT,
        .ncmds = @intCast(n_cmds),
        .sizeofcmds = @intCast(cmds_size),
        .flags = if (subsections) macho.MH_SUBSECTIONS_VIA_SYMBOLS else 0,
    });
    put(buf, &at, macho.segment_command_64{
        .cmdsize = @intCast(seg_cmd_size),
        .segname = @splat(0),
        .vmaddr = 0,
        .vmsize = vm_size,
        .fileoff = data_start,
        .filesize = file_end - data_start,
        .maxprot = .{ .READ = true, .WRITE = true, .EXEC = true },
        .initprot = .{ .READ = true, .WRITE = true, .EXEC = true },
        .nsects = @intCast(sects.items.len),
    });
    for (order) |k| put(buf, &at, sects.items[k].hdr);
    @memcpy(buf[at..][0..version_cmd.len], version_cmd);
    at += version_cmd.len;
    for (linker_options.items) |lo| {
        @memcpy(buf[at..][0..lo.len], lo);
        at += lo.len;
    }
    put(buf, &at, macho.symtab_command{ .symoff = @intCast(symoff), .nsyms = n_syms, .stroff = @intCast(stroff), .strsize = @intCast(strtab.items.len) });
    put(buf, &at, macho.dysymtab_command{
        .ilocalsym = 0,
        .nlocalsym = @intCast(locals.items.len),
        .iextdefsym = @intCast(locals.items.len),
        .nextdefsym = n_extdef,
        .iundefsym = @intCast(locals.items.len + n_extdef),
        .nundefsym = @intCast(globals.items.len - n_extdef),
        .tocoff = 0,
        .ntoc = 0,
        .modtaboff = 0,
        .nmodtab = 0,
        .extrefsymoff = 0,
        .nextrefsyms = 0,
        .indirectsymoff = 0,
        .nindirectsyms = 0,
        .extreloff = 0,
        .nextrel = 0,
        .locreloff = 0,
        .nlocrel = 0,
    });
    std.debug.assert(at == data_start);
    for (sects.items) |os| {
        if (MachOInput.isZeroFill(os.hdr)) continue;
        for (os.pieces.items) |p| @memcpy(buf[os.hdr.offset + p.offset ..][0..@intCast(objects[p.object].sects[p.sect].size)], objects[p.object].sectionBytes(p.sect));
        @memcpy(buf[os.hdr.reloff..][0 .. os.relocs.items.len * 8], std.mem.sliceAsBytes(os.relocs.items));
    }
    if (image_info) |info| {
        const ii = sects.items[image_info_sect].hdr.offset;
        std.mem.writeInt(u32, buf[ii..][0..4], info[0], .little);
        std.mem.writeInt(u32, buf[ii + 4 ..][0..4], info[1], .little);
    }
    for (patches.items) |p| {
        const field = buf[sects.items[p.sect].hdr.offset + p.offset ..];
        if (p.wide)
            std.mem.writeInt(u64, field[0..8], std.mem.readInt(u64, field[0..8], .little) +% p.delta, .little)
        else
            std.mem.writeInt(u32, field[0..4], std.mem.readInt(u32, field[0..4], .little) +% @as(u32, @truncate(p.delta)), .little);
    }
    for (locals.items, 0..) |sym, k| {
        var s = sym;
        s.n_strx = strx[k];
        @memcpy(buf[symoff + k * @sizeOf(Sym) ..][0..@sizeOf(Sym)], std.mem.asBytes(&s));
    }
    for (globals.items) |g| {
        var s = g.sym;
        s.n_strx = strx[g.index];
        @memcpy(buf[symoff + @as(u64, g.index) * @sizeOf(Sym) ..][0..@sizeOf(Sym)], std.mem.asBytes(&s));
    }
    @memcpy(buf[stroff..][0..strtab.items.len], strtab.items);
    return buf;
}

test "a merged object has its inputs' sections, symbols and relocations" {
    const testing = std.testing;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // test/link_input/macho_*.c and macho_objc_*.m from upstream's Clang
    // (build.zig's `addMachOInputs`): a constructor, GOT loads, an
    // absolute symbol, __compact_unwind and Objective-C sections.
    const reader: @import("Archive.zig").Reader = try .init(arena, @embedFile("macho_input_lib.a"));
    var inputs: std.ArrayList(Input) = .empty;
    try inputs.append(arena, .{ .path = "main.o", .bytes = @embedFile("macho_input_main.o") });
    var members: std.AutoArrayHashMapUnmanaged(u64, void) = .empty;
    for (reader.symbols) |s| try members.put(arena, s.member, {});
    for (members.keys()) |at| {
        const m = try reader.member(at);
        try inputs.append(arena, .{ .path = m.name, .bytes = m.bytes });
    }
    try testing.expectEqual(3, inputs.items.len);
    try inputs.append(arena, .{ .path = "a.o", .bytes = @embedFile("macho_input_objc_a.o") });
    try inputs.append(arena, .{ .path = "b.o", .bytes = @embedFile("macho_input_objc_b.o") });
    var diag: []const u8 = "";
    const merged = try merge(testing.allocator, arena, inputs.items, &diag);
    defer testing.allocator.free(merged);
    const out = try MachOInput.parseObject(arena, "merged.o", merged);

    const Find = struct {
        fn sect(o: *const Object, s: macho.section_64) usize {
            for (o.sects[1..], 1..) |x, i| {
                if (std.mem.eql(u8, &x.segname, &s.segname) and std.mem.eql(u8, &x.sectname, &s.sectname)) return i;
            }
            unreachable;
        }
        /// Where `needle` is in `hay`; in __compact_unwind, ignoring each
        /// 32-byte entry's function field.
        fn place(hay: []const u8, from: u64, needle: []const u8, unwind: bool) ?u64 {
            if (!unwind) return std.mem.findPos(u8, hay, @intCast(from), needle);
            var at: usize = @intCast(std.mem.alignForward(u64, from, 32));
            while (at + needle.len <= hay.len) : (at += 32) {
                for (0..needle.len / 32) |e| {
                    if (!std.mem.eql(u8, hay[at + e * 32 + 8 ..][0..24], needle[e * 32 + 8 ..][0..24])) break;
                } else return at;
            }
            return null;
        }
        fn following(o: *const Object, si: usize, value: u64) []const u8 {
            const b = o.sectionBytes(si);
            const at: usize = @intCast(value - o.sects[si].addr);
            return b[at..@min(b.len, at + 16)];
        }
    };
    var n_relocs: usize = 0;
    // Inputs land in input order: where the next one's search starts, per
    // merged section.
    var cursors: std.AutoHashMapUnmanaged(usize, u64) = .empty;
    for (inputs.items) |in| {
        const o = try MachOInput.parseObject(arena, in.path, in.bytes);
        // Each defined symbol is in the merged object, in the same
        // section, before the same bytes (but in __compact_unwind, whose
        // function fields move with __text: the relocations below check
        // them).
        for (o.syms) |sym| {
            if (sym.isStab() or sym.kind() != macho.N_SECT or MachOInput.isZeroFill(o.sects[sym.n_sect]) or dropped(o.sects[sym.n_sect])) continue;
            if (std.mem.eql(u8, std.mem.sliceTo(&o.sects[sym.n_sect].sectname, 0), "__compact_unwind")) continue;
            const si = Find.sect(&out, o.sects[sym.n_sect]);
            const want = Find.following(&o, sym.n_sect, sym.n_value);
            for (out.syms) |m| {
                if (m.kind() == macho.N_SECT and m.n_sect == si and std.mem.eql(u8, out.symName(m), o.symName(sym)) and
                    std.mem.eql(u8, Find.following(&out, si, m.n_value)[0..want.len], want)) break;
            } else return error.TestExpectedEqual;
        }
        // Each relocation is at its place in the merged section, of the
        // same kind, against the same name or the same place.
        for (o.sects[1..], 1..) |s, si| {
            if (dropped(s) or s.nreloc == 0) continue;
            const osi = Find.sect(&out, s);
            const os = out.sects[osi];
            // Where the input's section went: the first place whose
            // bytes match it.
            const ob = out.sectionBytes(osi);
            const from = (try cursors.getOrPutValue(arena, osi, 0)).value_ptr;
            const base: u64 = if (MachOInput.isZeroFill(s)) 0 else Find.place(ob, from.*, o.sectionBytes(si), std.mem.eql(u8, std.mem.sliceTo(&s.sectname, 0), "__compact_unwind")) orelse return error.TestExpectedEqual;
            from.* = base + s.size;
            const raw = o.bytes[s.reloff..][0 .. @as(usize, s.nreloc) * 8];
            const out_raw = out.bytes[os.reloff..][0 .. @as(usize, os.nreloc) * 8];
            for (0..s.nreloc) |ri| {
                const r = Reloc.read(raw[ri * 8 ..][0..8]);
                n_relocs += 1;
                const m = for (0..os.nreloc) |k| {
                    const x = Reloc.read(out_raw[k * 8 ..][0..8]);
                    if (x.address == base + r.address and x.type == r.type) break x;
                } else return error.TestExpectedEqual;
                try testing.expectEqual(r.pcrel, m.pcrel);
                try testing.expectEqual(r.length, m.length);
                try testing.expectEqual(r.external, m.external);
                if (r.type == reloc_addend) {
                    try testing.expectEqual(r.symbolnum, m.symbolnum);
                } else if (r.external) {
                    try testing.expectEqualStrings(o.symName(o.syms[r.symbolnum]), out.symName(out.syms[m.symbolnum]));
                } else {
                    // The field names the same place in the same section.
                    const t = o.sects[r.symbolnum];
                    const ot = out.sects[m.symbolnum];
                    try testing.expectEqualSlices(u8, &t.sectname, &ot.sectname);
                    const field = std.mem.readInt(u64, o.sectionBytes(si)[r.address..][0..8], .little);
                    const out_field = std.mem.readInt(u64, ob[@intCast(base + r.address)..][0..8], .little);
                    const want = Find.following(&o, r.symbolnum, field);
                    try testing.expectEqualSlices(u8, want, Find.following(&out, m.symbolnum, out_field)[0..want.len]);
                }
            }
        }
    }
    try testing.expect(n_relocs > 20);
    // The two image infos are one, as ld64 merges them.
    for (out.sects[1..], 1..) |s, si| if (std.mem.eql(u8, std.mem.sliceTo(&s.sectname, 0), "__objc_imageinfo")) {
        try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0x40, 0, 0, 0 }, out.sectionBytes(si));
    };

    // bs's own linker takes it as it takes the inputs.
    var in: MachOInput = .{ .arena = arena };
    try in.addObject("merged.o", merged);
    const Ctx = struct {
        pub fn zigExport(_: @This(), _: []const u8) !?@import("Atom.zig").SymbolKey {
            return null;
        }
        pub fn rtExport(_: @This(), _: []const u8) !?@import("Atom.zig").SymbolKey {
            return null;
        }
        pub fn importSym(_: @This(), name: []const u8, _: bool) !?@import("Atom.zig").SymbolKey {
            return .fromName(name);
        }
    };
    const c = try in.convert(Ctx{});
    try testing.expectEqual(0, in.errors.items.len);
    try testing.expect((try in.lookup("second")) != null);
    const abs = (try in.lookup("macho_abs")).?;
    for (c.values) |v| if (v.key == abs.key) try testing.expectEqual(0x1234, v.value);

    // Two strong definitions of a name are an error.
    try testing.expectError(error.DuplicateSymbol, merge(testing.allocator, arena, &.{ inputs.items[0], inputs.items[0] }, &diag));
    try testing.expect(std.mem.startsWith(u8, diag, "duplicate symbol: _") and std.mem.endsWith(u8, diag, ", defined in main.o and main.o"));
}
