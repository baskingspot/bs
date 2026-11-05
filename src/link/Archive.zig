//! Static libraries (`bs build-lib`, the default static linkage): a GNU ar
//! archive of the library's relocatable objects, as upstream's own
//! linker writes it (`-fno-lld`; LLD names members after the objects'
//! cache paths instead): a
//! `/SYM64/` symbol index of the objects' defined global and weak symbols
//! (empty when they have none), then the members: the Zig object, named
//! after the root source file (`protobuf.o` for
//! `-Mroot=src/protobuf.zig`), then the object inputs, named after their
//! files, then one per C source (`add.o`), with a
//! `//` name table for the names that do not fit the header; odd sizes
//! are padded with a zero byte, as upstream pads them.
//!
//! `Reader` reads archives given as link inputs: GNU and BSD-style
//! `ar` files with a `/` or `/SYM64/` symbol index and `//` long names,
//! and Darwin's, with BSD `#1/<n>` long names and a `__.SYMDEF` index.

const std = @import("std");
const Io = std.Io;
const elf = std.elf;
const Allocator = std.mem.Allocator;

/// A member to write: its name, without the trailing `/`, and an ELF64
/// ET_REL.
pub const Input = struct { name: []const u8, bytes: []const u8 };

/// Writes the archive of `members`, in order, to `ar_path`.
pub fn write(gpa: Allocator, io: Io, dir: Io.Dir, ar_path: []const u8, members: []const Input) !void {
    // Each member's symbols, and how many.
    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(gpa);
    const counts = try gpa.alloc(u64, members.len);
    defer gpa.free(counts);
    var count: u64 = 0;
    for (members, counts) |m, *c| {
        const before = count;
        try definedSymbols(gpa, m.bytes, &names, &count);
        c.* = count - before;
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.appendSlice(gpa, "!<arch>\n");
    const index_size = 8 + 8 * count + names.items.len;
    try header(gpa, &out, "/SYM64/", index_size);
    const index_start = out.items.len;
    try out.appendNTimes(gpa, 0, 8 + 8 * count);
    try out.appendSlice(gpa, names.items);
    if (out.items.len % 2 != 0) try out.append(gpa, 0);

    // The names that do not fit a header: `name/\n` entries of a `//`
    // table, which the headers name as `/<offset>`.
    var long: std.ArrayList(u8) = .empty;
    defer long.deinit(gpa);
    const long_at = try gpa.alloc(?usize, members.len);
    defer gpa.free(long_at);
    for (members, long_at) |m, *at| {
        at.* = null;
        if (m.name.len + 1 <= 16) continue;
        at.* = long.items.len;
        try long.appendSlice(gpa, m.name);
        try long.appendSlice(gpa, "/\n");
    }
    if (long.items.len != 0) {
        try header(gpa, &out, "//", long.items.len);
        try out.appendSlice(gpa, long.items);
        if (out.items.len % 2 != 0) try out.append(gpa, 0);
    }
    var sym: u64 = 0;
    for (members, long_at, counts) |m, at, c| {
        const member_offset = out.items.len;
        var name_buf: [17]u8 = undefined;
        const name = if (at) |o| try std.mem.print(&name_buf, "/{d}", .{o}) else try std.mem.print(&name_buf, "{s}/", .{m.name});
        try header(gpa, &out, name, m.bytes.len);
        try out.appendSlice(gpa, m.bytes);
        if (out.items.len % 2 != 0) try out.append(gpa, 0);
        for (0..c) |_| {
            std.mem.writeInt(u64, out.items[index_start + 8 + 8 * sym ..][0..8], member_offset, .big);
            sym += 1;
        }
    }
    std.mem.writeInt(u64, out.items[index_start..][0..8], count, .big);

    var atomic = try dir.createFileAtomic(io, ar_path, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, out.items);
    try atomic.replace(io);
}

/// Writes a Darwin archive of arm64 Mach-O `members`, in order, to
/// `ar_path`, as upstream's `zig build-lib` writes one for aarch64-macos
/// (`src/link/MachO/relocatable.zig`): a `__.SYMDEF` index of 32-bit
/// (name offset, member offset) pairs over the members' defined external
/// symbols, sorted by name offset, then the members, each named with BSD
/// `#1/<n>` and its name padded so that its contents start 8-aligned.
pub fn writeDarwin(gpa: Allocator, io: Io, dir: Io.Dir, ar_path: []const u8, members: []const Input) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The index's strings and, per symbol, its member.
    var strings: std.ArrayList(u8) = .empty;
    const Entry = struct { off: u32, member: u32 };
    var entries: std.ArrayList(Entry) = .empty;
    for (members, 0..) |m, i| {
        var it = try machoDefined(m.bytes);
        while (try it.next()) |name| {
            try entries.append(arena, .{ .off = @intCast(strings.items.len), .member = @intCast(i) });
            try strings.appendSlice(arena, name);
            try strings.append(arena, 0);
        }
    }
    while (strings.items.len % 4 != 0) try strings.append(arena, 0);
    const symdef_size = 4 + 8 * entries.items.len + 4 + strings.items.len;
    // Member offsets, after the index.
    var pos: u64 = 8 + darwinMemberSize("__.SYMDEF", 8, symdef_size);
    const member_off = try arena.alloc(u32, members.len);
    for (members, member_off) |m, *o| {
        pos = std.mem.alignForward(u64, pos, 2);
        o.* = @intCast(pos);
        pos += darwinMemberSize(m.name, pos, m.bytes.len);
    }
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "!<arch>\n");
    try darwinHeader(arena, &out, "__.SYMDEF", symdef_size);
    try appendU32(arena, &out, @intCast(8 * entries.items.len));
    for (entries.items) |e| {
        try appendU32(arena, &out, e.off);
        try appendU32(arena, &out, member_off[e.member]);
    }
    try appendU32(arena, &out, @intCast(strings.items.len));
    try out.appendSlice(arena, strings.items);
    for (members, member_off) |m, o| {
        while (out.items.len < o) try out.append(arena, 0);
        try darwinHeader(arena, &out, m.name, m.bytes.len);
        try out.appendSlice(arena, m.bytes);
    }
    var atomic = try dir.createFileAtomic(io, ar_path, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, out.items);
    try atomic.replace(io);
}

/// The bytes of a Darwin member at offset `at`: its header, its name,
/// NUL-padded so that the contents start 8-aligned, and the contents.
fn darwinMemberSize(name: []const u8, at: u64, size: u64) u64 {
    const name_start = at + 60;
    const contents = std.mem.alignForward(u64, name_start + name.len + 1, 8);
    return contents - at + size;
}

fn darwinHeader(gpa: Allocator, out: *std.ArrayList(u8), name: []const u8, size: u64) !void {
    const name_start = out.items.len + 60;
    const name_len = std.mem.alignForward(u64, name_start + name.len + 1, 8) - name_start;
    var buf: [16]u8 = undefined;
    const field = try std.mem.print(&buf, "#1/{d}", .{name_len});
    try out.print(gpa, "{s: <16}{s: <12}{s: <6}{s: <6}{s: <8}{d: <10}`\n", .{ field, "0", "0", "0", "0", size + name_len });
    try out.appendSlice(gpa, name);
    try out.appendNTimes(gpa, 0, name_len - name.len);
}

fn appendU32(gpa: Allocator, out: *std.ArrayList(u8), v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try out.appendSlice(gpa, &b);
}

/// The names of a Mach-O object's defined external symbols that other
/// objects can bind to (not private externals), as the index lists them.
const MachODefined = struct {
    obj: []const u8,
    syms: u64 = 0,
    n: u32 = 0,
    strs: u64 = 0,
    strsize: u32 = 0,
    i: u32 = 0,

    fn next(it: *MachODefined) !?[]const u8 {
        while (it.i < it.n) {
            const at = it.syms + @as(u64, it.i) * 16;
            it.i += 1;
            if (at + 16 > it.obj.len) return error.InvalidObject;
            const strx = std.mem.readInt(u32, it.obj[at..][0..4], .little);
            const n_type = it.obj[at + 4];
            // N_EXT, not N_PEXT or a stab, and N_SECT.
            if (n_type & 0xe0 != 0 or n_type & 0x01 == 0 or n_type & 0x10 != 0 or n_type & 0x0e != 0x0e) continue;
            if (strx >= it.strsize or it.strs + it.strsize > it.obj.len) return error.InvalidObject;
            return std.mem.sliceTo(it.obj[it.strs + strx .. it.strs + it.strsize], 0);
        }
        return null;
    }
};

fn machoDefined(obj: []const u8) !MachODefined {
    if (obj.len < 32 or std.mem.readInt(u32, obj[0..4], .little) != 0xfeedfacf) return error.InvalidObject;
    const ncmds = std.mem.readInt(u32, obj[16..20], .little);
    var at: u64 = 32;
    for (0..ncmds) |_| {
        if (at + 8 > obj.len) return error.InvalidObject;
        const cmd = std.mem.readInt(u32, obj[at..][0..4], .little);
        const size = std.mem.readInt(u32, obj[at + 4 ..][0..4], .little);
        if (cmd == 0x2) {
            if (at + 24 > obj.len) return error.InvalidObject;
            return .{
                .obj = obj,
                .syms = std.mem.readInt(u32, obj[at + 8 ..][0..4], .little),
                .n = std.mem.readInt(u32, obj[at + 12 ..][0..4], .little),
                .strs = std.mem.readInt(u32, obj[at + 16 ..][0..4], .little),
                .strsize = std.mem.readInt(u32, obj[at + 20 ..][0..4], .little),
            };
        }
        if (size == 0) return error.InvalidObject;
        at += size;
    }
    return .{ .obj = obj };
}

/// A member header: name, mtime, uid, gid, mode, size, all space-padded.
fn header(gpa: Allocator, out: *std.ArrayList(u8), name: []const u8, size: u64) !void {
    try out.print(gpa, "{s: <16}{s: <12}{s: <6}{s: <6}{s: <8}{d: <10}`\n", .{ name, "0", "0", "0", "0", size });
}

/// Appends the NUL-terminated names of `obj`'s defined global and weak
/// symbols to `names`, counting them in `count`.
fn definedSymbols(gpa: Allocator, obj: []const u8, names: *std.ArrayList(u8), count: *u64) !void {
    if (obj.len < @sizeOf(elf.Elf64_Ehdr)) return error.InvalidObject;
    const eh = std.mem.bytesToValue(elf.Elf64_Ehdr, obj[0..@sizeOf(elf.Elf64_Ehdr)]);
    for (0..eh.e_shnum) |i| {
        const sh = try readAt(elf.Elf64_Shdr, obj, eh.e_shoff + i * @sizeOf(elf.Elf64_Shdr));
        if (sh.sh_type != elf.SHT_SYMTAB) continue;
        const strtab = try readAt(elf.Elf64_Shdr, obj, eh.e_shoff + @as(u64, sh.sh_link) * @sizeOf(elf.Elf64_Shdr));
        if (strtab.sh_offset + strtab.sh_size > obj.len) return error.InvalidObject;
        const strings = obj[strtab.sh_offset..][0..strtab.sh_size];
        for (sh.sh_info..sh.sh_size / @sizeOf(elf.Elf64_Sym)) |s| {
            const sym = try readAt(elf.Elf64_Sym, obj, sh.sh_offset + s * @sizeOf(elf.Elf64_Sym));
            const bind = sym.st_bind();
            if (sym.st_shndx == elf.SHN_UNDEF or (bind != elf.STB_GLOBAL and bind != elf.STB_WEAK)) continue;
            if (sym.st_name >= strings.len) return error.InvalidObject;
            try names.appendSlice(gpa, std.mem.sliceTo(strings[sym.st_name..], 0));
            try names.append(gpa, 0);
            count.* += 1;
        }
    }
}

fn readAt(comptime T: type, bytes: []const u8, offset: u64) !T {
    if (offset + @sizeOf(T) > bytes.len) return error.InvalidObject;
    return std.mem.bytesToValue(T, bytes[@intCast(offset)..][0..@sizeOf(T)]);
}

/// An archive given as a link input, read in place: its symbol index, and
/// members on demand (see "Object, archive and shared-library inputs" in
/// docs/slop/architecture.md).
pub const Reader = struct {
    bytes: []const u8,
    /// Each indexed symbol's name and its member's header offset.
    symbols: []const Symbol,
    /// The `//` table, or empty.
    long_names: []const u8,

    pub const Symbol = struct { name: []const u8, member: u64 };

    pub const Member = struct {
        /// The name without the trailing `/`.
        name: []const u8,
        bytes: []const u8,
    };

    pub const Error = error{ InvalidArchive, ThinArchive, OutOfMemory };

    pub fn init(arena: Allocator, bytes: []const u8) Error!Reader {
        if (std.mem.startsWith(u8, bytes, "!<thin>\n")) return error.ThinArchive;
        if (!std.mem.startsWith(u8, bytes, "!<arch>\n")) return error.InvalidArchive;
        var r: Reader = .{ .bytes = bytes, .symbols = &.{}, .long_names = "" };
        var symbols: std.ArrayList(Symbol) = .empty;
        var off: u64 = 8;
        // The index and the name table come first.
        while (off < bytes.len) {
            const h = try r.headerAt(off);
            if (std.mem.eql(u8, h.raw_name, "/") or std.mem.eql(u8, h.raw_name, "/SYM64/")) {
                const wide = h.raw_name.len > 1;
                const w: usize = if (wide) 8 else 4;
                const data = h.data;
                if (data.len < w) return error.InvalidArchive;
                const n = if (wide) std.mem.readInt(u64, data[0..8], .big) else std.mem.readInt(u32, data[0..4], .big);
                if (n > (data.len - w) / w) return error.InvalidArchive;
                var names_at: usize = w + @as(usize, @intCast(n)) * w;
                try symbols.ensureUnusedCapacity(arena, @intCast(n));
                for (0..@intCast(n)) |i| {
                    const at = if (wide) std.mem.readInt(u64, data[w + 8 * i ..][0..8], .big) else std.mem.readInt(u32, data[w + 4 * i ..][0..4], .big);
                    const end = std.mem.findScalarPos(u8, data, names_at, 0) orelse return error.InvalidArchive;
                    symbols.appendAssumeCapacity(.{ .name = data[names_at..end], .member = at });
                    names_at = end + 1;
                }
            } else if (std.mem.eql(u8, h.raw_name, "//")) {
                r.long_names = h.data;
            } else if (std.mem.startsWith(u8, h.raw_name, "__.SYMDEF")) {
                // Darwin's ranlib table: its size in bytes, then (string
                // offset, member header offset) pairs, then the strings'
                // size and the strings, all little-endian; 64-bit fields
                // in `__.SYMDEF_64`.
                const wide = std.mem.startsWith(u8, h.raw_name, "__.SYMDEF_64");
                const w: usize = if (wide) 8 else 4;
                const data = h.data;
                const field = struct {
                    fn f(d: []const u8, at: usize, width: usize) Error!u64 {
                        if (at > d.len or d.len - at < width) return error.InvalidArchive;
                        return if (width == 8) std.mem.readInt(u64, d[at..][0..8], .little) else std.mem.readInt(u32, d[at..][0..4], .little);
                    }
                }.f;
                const table_len = try field(data, 0, w);
                if (table_len % (2 * w) != 0 or table_len > data.len - w) return error.InvalidArchive;
                const strs_at = w + @as(usize, @intCast(table_len));
                const strs_len = try field(data, strs_at, w);
                if (strs_len > data.len - strs_at - w) return error.InvalidArchive;
                const strs = data[strs_at + w ..][0..@intCast(strs_len)];
                const n: usize = @intCast(table_len / (2 * w));
                try symbols.ensureUnusedCapacity(arena, n);
                for (0..n) |i| {
                    const strx = try field(data, w + 2 * w * i, w);
                    const at = try field(data, w + 2 * w * i + w, w);
                    if (strx >= strs.len) return error.InvalidArchive;
                    symbols.appendAssumeCapacity(.{ .name = std.mem.sliceTo(strs[@intCast(strx)..], 0), .member = at });
                }
            } else break;
            off = h.next;
        }
        r.symbols = symbols.items;
        return r;
    }

    /// The member whose header is at `offset`.
    pub fn member(r: *const Reader, offset: u64) Error!Member {
        const h = try r.headerAt(offset);
        var name = h.raw_name;
        if (name.len > 1 and name[0] == '/' and std.ascii.isDigit(name[1])) {
            const at = std.fmt.parseInt(usize, name[1..], 10) catch return error.InvalidArchive;
            if (at >= r.long_names.len) return error.InvalidArchive;
            const end = std.mem.findScalarPos(u8, r.long_names, at, '\n') orelse r.long_names.len;
            name = r.long_names[at..end];
        }
        if (name.len > 0 and name[name.len - 1] == '/') name = name[0 .. name.len - 1];
        return .{ .name = name, .bytes = h.data };
    }

    const Header = struct { raw_name: []const u8, data: []const u8, next: u64 };

    fn headerAt(r: *const Reader, offset: u64) Error!Header {
        if (offset > r.bytes.len or r.bytes.len - offset < 60) return error.InvalidArchive;
        const h = r.bytes[@intCast(offset)..][0..60];
        if (!std.mem.eql(u8, h[58..60], "`\n")) return error.InvalidArchive;
        const size = std.fmt.parseInt(u64, std.mem.trimEnd(u8, h[48..58], " "), 10) catch return error.InvalidArchive;
        const start = offset + 60;
        if (size > r.bytes.len - start) return error.InvalidArchive;
        var raw_name = std.mem.trimEnd(u8, h[0..16], " ");
        var data = r.bytes[@intCast(start)..][0..@intCast(size)];
        // BSD: the name is the first n bytes of the data, padded with
        // zeros.
        if (std.mem.startsWith(u8, raw_name, "#1/")) {
            const n = std.fmt.parseInt(usize, raw_name[3..], 10) catch return error.InvalidArchive;
            if (n > data.len) return error.InvalidArchive;
            raw_name = std.mem.sliceTo(data[0..n], 0);
            data = data[n..];
        }
        return .{
            .raw_name = raw_name,
            .data = data,
            .next = start + size + (size & 1),
        };
    }
};

test Reader {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A GNU archive with a 32-bit index, a long name and an odd-sized
    // member, as `ar rcs` writes it.
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(arena, "!<arch>\n");
    const index = "\x00\x00\x00\x02" ++ "\x00\x00\x00\x00" ++ "\x00\x00\x00\x00" ++ "foo\x00bar\x00";
    try header(arena, &b, "/", index.len);
    try b.appendSlice(arena, index);
    const names = "a_rather_long_member.o/\n";
    try header(arena, &b, "//", names.len);
    try b.appendSlice(arena, names);
    const m0: u32 = @intCast(b.items.len);
    try header(arena, &b, "/0", 3);
    try b.appendSlice(arena, "abc\n");
    const m1: u32 = @intCast(b.items.len);
    try header(arena, &b, "s.o/", 2);
    try b.appendSlice(arena, "xy");
    std.mem.writeInt(u32, b.items[8 + 60 + 4 ..][0..4], m0, .big);
    std.mem.writeInt(u32, b.items[8 + 60 + 8 ..][0..4], m1, .big);

    const r: Reader = try .init(arena, b.items);
    try std.testing.expectEqual(2, r.symbols.len);
    try std.testing.expectEqualStrings("bar", r.symbols[1].name);
    const a = try r.member(r.symbols[0].member);
    try std.testing.expectEqualStrings("a_rather_long_member.o", a.name);
    try std.testing.expectEqualStrings("abc", a.bytes);
    const s = try r.member(r.symbols[1].member);
    try std.testing.expectEqualStrings("s.o", s.name);
    try std.testing.expectEqualStrings("xy", s.bytes);
    try std.testing.expectError(error.ThinArchive, Reader.init(arena, "!<thin>\n"));

    // Darwin's, as `zig ar` writes it for macOS: BSD names and a
    // little-endian ranlib table.
    var d: std.ArrayList(u8) = .empty;
    try d.appendSlice(arena, "!<arch>\n");
    const symdef_name = "__.SYMDEF\x00\x00\x00";
    const table = "\x10\x00\x00\x00" ++ "\x00\x00\x00\x00" ++ "MMMM" ++ "\x04\x00\x00\x00" ++ "NNNN" ++ "\x08\x00\x00\x00" ++ "_f\x00\x00_g\x00\x00";
    try header(arena, &d, "#1/12", symdef_name.len + table.len);
    try d.appendSlice(arena, symdef_name ++ table);
    const table_at = 8 + 60 + symdef_name.len;
    const d0: u32 = @intCast(d.items.len);
    try header(arena, &d, "#1/20", 20 + 3);
    try d.appendSlice(arena, "a_long_member_name.o" ++ "ab\n" ++ "\n");
    const d1: u32 = @intCast(d.items.len);
    try header(arena, &d, "#1/4", 4 + 2);
    try d.appendSlice(arena, "b.o\x00xy");
    std.mem.writeInt(u32, d.items[table_at + 8 ..][0..4], d0, .little);
    std.mem.writeInt(u32, d.items[table_at + 16 ..][0..4], d1, .little);
    const dr: Reader = try .init(arena, d.items);
    try std.testing.expectEqual(2, dr.symbols.len);
    try std.testing.expectEqualStrings("_g", dr.symbols[1].name);
    const da = try dr.member(dr.symbols[0].member);
    try std.testing.expectEqualStrings("a_long_member_name.o", da.name);
    try std.testing.expectEqualStrings("ab\n", da.bytes);
    const db = try dr.member(dr.symbols[1].member);
    try std.testing.expectEqualStrings("b.o", db.name);
    try std.testing.expectEqualStrings("xy", db.bytes);
}

test "Darwin archive from upstream's llvm-ar" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // test/link_input/macho_member.c and macho_other.c for aarch64-macos,
    // as `zig ar --format=darwin rcs` archives them (build.zig's
    // `addMachOInputs`): a `#1/12` `__.SYMDEF` table and a `#1/36` name.
    const lib = @embedFile("macho_input_lib.a");
    const ar: Reader = try .init(arena, lib);
    try std.testing.expectEqual(3, ar.symbols.len);
    for (ar.symbols, [_][]const u8{ "_first", "_second", "_unpulled" }, [_][]const u8{ "macho_input_long_member_name.o", "macho_input_long_member_name.o", "other.o" }) |sym, name, member| {
        try std.testing.expectEqualStrings(name, sym.name);
        const m = try ar.member(sym.member);
        try std.testing.expectEqualStrings(member, m.name);
        try std.testing.expectEqual(std.macho.MH_MAGIC_64, std.mem.readInt(u32, m.bytes[0..4], .little));
    }
}
