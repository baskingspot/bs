//! The unit the backends hand to the linkers: one function's machine code, or
//! one piece of data, with symbolic relocations. See "CodeGen" and "Linkers"
//! in docs/architecture.md.
//!
//! An Atom holds no InternPool indices and no addresses, so it can be cached
//! on disk and relinked unchanged. It does not own its slices; whoever
//! produced it (CodeGen's arena, the cache) keeps them alive until the link.

const std = @import("std");

const Atom = @This();

/// Identifies the atom's symbol; relocations name their target by key.
key: SymbolKey,
/// Symbol name written to the output's symbol table. For declarations this is
/// the rendered unit key; content-addressed atoms may use any name.
name: []const u8,
section: Section,
alignment: std.mem.Alignment = .@"1",
/// Machine code or initialized data. Must be empty for `.bss`.
bytes: []const u8 = &.{},
/// Size of a `.bss` atom. Must be 0 for other sections.
zero_fill: u64 = 0,
/// Sorted by offset. Must be empty for `.bss`.
relocs: []const Reloc = &.{},
/// Source line of the declaration's first line. `lines` are relative to it,
/// so moving a declaration changes only this field.
base_line: u32 = 0,
/// Line-table fragment for the atom's code. The ELF linker does not read it
/// yet; DWARF emission will.
lines: []const Line = &.{},

/// 128-bit stable identity of a symbol. Derived from the unit key for
/// declarations (`fromName`) and from the contents for anonymous constants
/// (`fromContents`), never from in-memory indices. Two atoms with the same key
/// are the same symbol: the linker keeps one and requires the others to be
/// identical, which is how content-addressed atoms are deduplicated.
pub const SymbolKey = enum(u128) {
    _,

    pub fn fromName(name: []const u8) SymbolKey {
        var h = Hasher.init(&hash_key);
        h.update(name);
        return @fromBackingInt(@intCast(h.finalInt()));
    }

    /// Key of an anonymous constant: a hash of everything the linker emits for
    /// it, so equal constants from different functions collapse to one.
    pub fn fromContents(
        section: Section,
        alignment: std.mem.Alignment,
        bytes: []const u8,
        relocs: []const Reloc,
    ) SymbolKey {
        var h = Hasher.init(&hash_key);
        h.update(&.{ @backingInt(section), @backingInt(alignment) });
        h.update(std.mem.asBytes(&@as(u64, bytes.len)));
        h.update(bytes);
        for (relocs) |r| {
            h.update(std.mem.asBytes(&r.offset));
            h.update(&.{@backingInt(r.kind)});
            h.update(std.mem.asBytes(&@backingInt(r.target)));
            h.update(std.mem.asBytes(&r.addend));
        }
        return @fromBackingInt(@intCast(h.finalInt()));
    }

    const Hasher = std.crypto.auth.siphash.SipHash128(1, 3);
    const hash_key: [Hasher.key_length]u8 = "zap symbol key!!".*;
};

/// Where an atom is placed. Thread-local `.tdata`/`.tbss` will be added
/// here; see the TLS note in `Elf.zig`.
pub const Section = enum(u8) {
    text,
    rodata,
    data,
    bss,
};

pub const Reloc = struct {
    /// Byte offset of the patched field within the atom.
    offset: u32,
    kind: Kind,
    target: SymbolKey,
    addend: i64,

    /// Address kinds are target-specific; kinds for other architectures are
    /// added alongside.
    pub const Kind = enum(u8) {
        /// 64-bit absolute address: S + A (ELF R_X86_64_64).
        x86_64_abs64,
        /// 32-bit PC-relative: S + A - P, where P is the address of the field
        /// (ELF R_X86_64_PC32 / PLT32). Calls and RIP-relative operands use
        /// it with A = -4 - (bytes after the field in the instruction).
        x86_64_pc32,
        /// V + A as a little-endian unsigned integer of 1, 2, 4, or 8 bytes,
        /// where V is the integer the whole compilation assigns to `target`
        /// (for example an error's code in the global error set). V comes
        /// from the linker's `values` option, not from an atom, so atoms do
        /// not change when the assignment does.
        value8,
        value16,
        value32,
        value64,
    };
};

pub const Line = struct {
    /// Offset of the first instruction of the row within `bytes`.
    offset: u32,
    /// Line relative to `base_line`.
    line: u32,
    column: u32,
};

pub fn size(a: *const Atom) u64 {
    return if (a.section == .bss) a.zero_fill else a.bytes.len;
}

test "content keys distinguish relocation targets" {
    const a: SymbolKey = .fromName("a");
    const b: SymbolKey = .fromName("b");
    const bytes: [8]u8 = @splat(0);
    const ka = SymbolKey.fromContents(.rodata, .@"8", &bytes, &.{.{ .offset = 0, .kind = .x86_64_abs64, .target = a, .addend = 0 }});
    const kb = SymbolKey.fromContents(.rodata, .@"8", &bytes, &.{.{ .offset = 0, .kind = .x86_64_abs64, .target = b, .addend = 0 }});
    try std.testing.expect(ka != kb);
    try std.testing.expectEqual(ka, SymbolKey.fromContents(.rodata, .@"8", &bytes, &.{.{ .offset = 0, .kind = .x86_64_abs64, .target = a, .addend = 0 }}));
}
