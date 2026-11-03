//! Static libraries (`zap build-lib`, the default static linkage): a GNU ar
//! archive holding the library's one relocatable object, as upstream
//! writes it: a `/SYM64/` symbol index of the object's defined global and
//! weak symbols (empty when it has none), then the member, named after the
//! root source file (`protobuf.o` for `-Mroot=src/protobuf.zig`), with a
//! `//` name table when the name does not fit the header.

const std = @import("std");
const Io = std.Io;
const elf = std.elf;
const Allocator = std.mem.Allocator;

/// Writes the archive of object `obj` (an ELF64 ET_REL) to `ar_path`.
pub fn write(gpa: Allocator, io: Io, dir: Io.Dir, ar_path: []const u8, member_name: []const u8, obj: []const u8) !void {
    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(gpa);
    var count: u64 = 0;
    try definedSymbols(gpa, obj, &names, &count);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.appendSlice(gpa, "!<arch>\n");
    const index_size = 8 + 8 * count + names.items.len;
    try header(gpa, &out, "/SYM64/", index_size);
    const index_start = out.items.len;
    try out.appendNTimes(gpa, 0, 8 + 8 * count);
    try out.appendSlice(gpa, names.items);
    if (out.items.len % 2 != 0) try out.append(gpa, '\n');

    // The member's name: `name/` in the header, or `/<offset>` into a
    // `//` table of `name/\n` entries.
    const short = member_name.len + 1 <= 16;
    if (!short) {
        try header(gpa, &out, "//", member_name.len + 2);
        try out.appendSlice(gpa, member_name);
        try out.appendSlice(gpa, "/\n");
        if (out.items.len % 2 != 0) try out.append(gpa, '\n');
    }
    const member_offset = out.items.len;
    var name_buf: [17]u8 = undefined;
    try header(gpa, &out, if (short) try std.fmt.bufPrint(&name_buf, "{s}/", .{member_name}) else "/0", obj.len);
    try out.appendSlice(gpa, obj);
    if (out.items.len % 2 != 0) try out.append(gpa, '\n');

    std.mem.writeInt(u64, out.items[index_start..][0..8], count, .big);
    for (0..count) |i| std.mem.writeInt(u64, out.items[index_start + 8 + 8 * i ..][0..8], member_offset, .big);

    var atomic = try dir.createFileAtomic(io, ar_path, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, out.items);
    try atomic.replace(io);
}

/// A member header: name, mtime, uid, gid, mode, size, all space-padded.
fn header(gpa: Allocator, out: *std.ArrayList(u8), name: []const u8, size: u64) !void {
    try out.print(gpa, "{s: <16}{s: <12}{s: <6}{s: <6}{s: <8}{d: <10}`\n", .{ name, "0", "0", "0", "644", size });
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
