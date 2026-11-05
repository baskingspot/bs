//! An arm64 Mach-O dynamic library an aarch64-macos executable or dylib
//! links against: its install name and versions (LC_ID_DYLIB), which go in
//! the output's LC_LOAD_DYLIB, and the names it exports, from its exports
//! trie (LC_DYLD_EXPORTS_TRIE, or LC_DYLD_INFO's), which the link binds to
//! it by two-level ordinal. Re-exports count: dyld follows them. A
//! universal file contributes its arm64 slice.

const std = @import("std");
const macho = std.macho;
const Allocator = std.mem.Allocator;

const Dylib = @This();

path: []const u8,
install_name: []const u8,
current_version: u32,
compatibility_version: u32,
/// Exported names without Darwin's leading underscore.
exports: std.StringHashMapUnmanaged(Export) = .empty,

/// `reexport` marks a name a stub takes from a library it re-exports
/// (`Tbd`): a link prefers a library that defines the name itself, as
/// upstream binds to the defining library when that one is linked too.
pub const Export = packed struct(u8) { weak: bool, tls: bool, reexport: bool = false, _: u5 = 0 };

pub const Error = error{ OutOfMemory, InvalidDylib };

pub fn parse(arena: Allocator, path: []const u8, file: []const u8) Error!Dylib {
    const bytes = try thinSlice(file);
    if (bytes.len < @sizeOf(macho.mach_header_64)) return error.InvalidDylib;
    const mh = std.mem.bytesToValue(macho.mach_header_64, bytes[0..@sizeOf(macho.mach_header_64)]);
    if (mh.magic != macho.MH_MAGIC_64 or mh.cputype != macho.CPU_TYPE_ARM64 or mh.filetype != macho.MH_DYLIB) return error.InvalidDylib;
    var d: Dylib = .{ .path = path, .install_name = "", .current_version = 0, .compatibility_version = 0 };
    var trie: []const u8 = &.{};
    var at: usize = @sizeOf(macho.mach_header_64);
    for (0..mh.ncmds) |_| {
        if (at + 8 > bytes.len) return error.InvalidDylib;
        const cmd = std.mem.readInt(u32, bytes[at..][0..4], .little);
        const size = std.mem.readInt(u32, bytes[at + 4 ..][0..4], .little);
        if (size < 8 or at + size > bytes.len) return error.InvalidDylib;
        const lc = bytes[at..][0..size];
        switch (cmd) {
            @backingInt(macho.LC.ID_DYLIB) => {
                if (size < @sizeOf(macho.dylib_command)) return error.InvalidDylib;
                const c = std.mem.bytesToValue(macho.dylib_command, lc[0..@sizeOf(macho.dylib_command)]);
                if (c.dylib.name >= size) return error.InvalidDylib;
                d.install_name = std.mem.sliceTo(lc[c.dylib.name..], 0);
                d.current_version = c.dylib.current_version;
                d.compatibility_version = c.dylib.compatibility_version;
            },
            @backingInt(macho.LC.DYLD_EXPORTS_TRIE) => {
                if (size < 16) return error.InvalidDylib;
                trie = try range(bytes, std.mem.readInt(u32, lc[8..12], .little), std.mem.readInt(u32, lc[12..16], .little));
            },
            @backingInt(macho.LC.DYLD_INFO), @backingInt(macho.LC.DYLD_INFO_ONLY) => {
                if (size < 48) return error.InvalidDylib;
                trie = try range(bytes, std.mem.readInt(u32, lc[40..44], .little), std.mem.readInt(u32, lc[44..48], .little));
            },
            else => {},
        }
        at += size;
    }
    if (d.install_name.len == 0) return error.InvalidDylib;
    if (trie.len > 0) {
        var name: std.ArrayList(u8) = .empty;
        try d.walk(arena, trie, 0, &name, 0);
    }
    return d;
}

fn range(bytes: []const u8, off: u32, len: u32) Error![]const u8 {
    if (@as(u64, off) + len > bytes.len) return error.InvalidDylib;
    return bytes[off..][0..len];
}

/// Collects the names below the node at `node`, whose path spells `name`.
fn walk(d: *Dylib, arena: Allocator, trie: []const u8, node: usize, name: *std.ArrayList(u8), depth: u32) Error!void {
    // Edges only lengthen names, and a trie deeper than any name is bad.
    if (depth > 4096) return error.InvalidDylib;
    var at = node;
    const term = try uleb(trie, &at);
    if (term != 0) {
        var t = at;
        const flags = try uleb(trie, &t);
        if (name.items.len > 1 and name.items[0] == '_') {
            const kind = flags & macho.EXPORT_SYMBOL_FLAGS_KIND_MASK;
            try d.exports.put(arena, try arena.dupe(u8, name.items[1..]), .{
                .weak = flags & macho.EXPORT_SYMBOL_FLAGS_WEAK_DEFINITION != 0,
                .tls = kind == macho.EXPORT_SYMBOL_FLAGS_KIND_THREAD_LOCAL,
            });
        }
    }
    at = std.math.add(usize, at, std.math.cast(usize, term) orelse return error.InvalidDylib) catch return error.InvalidDylib;
    if (at >= trie.len) return error.InvalidDylib;
    const n = trie[at];
    at += 1;
    for (0..n) |_| {
        const rest = trie[@min(at, trie.len)..];
        const label = std.mem.sliceTo(rest, 0);
        if (label.len == rest.len) return error.InvalidDylib;
        at += label.len + 1;
        const child = try uleb(trie, &at);
        if (child >= trie.len or child == 0) return error.InvalidDylib;
        const len = name.items.len;
        try name.appendSlice(arena, label);
        try d.walk(arena, trie, @intCast(child), name, depth + 1);
        name.shrinkRetainingCapacity(len);
    }
}

fn uleb(bytes: []const u8, at: *usize) Error!u64 {
    var v: u64 = 0;
    var shift: u32 = 0;
    while (true) {
        if (at.* >= bytes.len or shift > 63) return error.InvalidDylib;
        const b = bytes[at.*];
        at.* += 1;
        v |= @as(u64, b & 0x7f) << @intCast(shift);
        if (b & 0x80 == 0) return v;
        shift += 7;
    }
}

/// The arm64 slice of a universal file, or the file itself.
fn thinSlice(bytes: []const u8) Error![]const u8 {
    if (bytes.len < 8 or std.mem.readInt(u32, bytes[0..4], .big) != macho.FAT_MAGIC) return bytes;
    const n = std.mem.readInt(u32, bytes[4..8], .big);
    for (0..n) |i| {
        const at = 8 + i * @sizeOf(macho.fat_arch);
        if (at + @sizeOf(macho.fat_arch) > bytes.len) return error.InvalidDylib;
        const cpu = std.mem.readInt(i32, bytes[at..][0..4], .big);
        const off = std.mem.readInt(u32, bytes[at + 8 ..][0..4], .big);
        const size = std.mem.readInt(u32, bytes[at + 12 ..][0..4], .big);
        if (cpu != macho.CPU_TYPE_ARM64) continue;
        if (@as(u64, off) + size > bytes.len) return error.InvalidDylib;
        return bytes[off..][0..size];
    }
    return error.InvalidDylib;
}
