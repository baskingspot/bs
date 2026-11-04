//! The unit the backends hand to the linkers: one function's machine code, or
//! one piece of data, with symbolic relocations. See "CodeGen" and "Linkers"
//! in docs/architecture.md.
//!
//! An Atom holds no InternPool indices and no addresses, so it can be cached
//! on disk and relinked unchanged. It does not own its slices; whoever
//! produced it (CodeGen's arena, the cache) keeps them alive until the link.

const std = @import("std");

const Atom = @This();

/// Identifies the atom's symbol; other atoms reference it by key.
key: SymbolKey,
/// Symbol name written to the output's symbol table. For declarations this is
/// upstream's name, the declaration's qualified name ("widgets.TextInput.update",
/// "array_list.Aligned(u8,null).append", with `__func_` and a hash for a
/// generic function's instance); names may repeat, as upstream's do. The
/// key, not the name, is the atom's identity. Content-addressed atoms may
/// use any name.
name: []const u8,
section: Section,
alignment: std.mem.Alignment = .@"1",
/// Machine code or initialized data. Must be empty for `.bss` and `.tbss`.
bytes: []const u8 = &.{},
/// Size of a `.bss` or `.tbss` atom. Must be 0 for other sections.
zero_fill: u64 = 0,
/// The distinct symbols (or link-time values) this atom references, each
/// once. Relocations refer to them by index, which keeps relocation records
/// small and lets the linker resolve each key once per atom.
targets: []const SymbolKey = &.{},
/// Sorted by offset. Must be empty for `.bss` and `.tbss`.
relocs: []const Reloc = &.{},
/// How the function's frame unwinds, from which the linkers write call
/// frame information. It describes the code, not its debug info, so it is
/// the atom's. Data atoms and naked functions keep `.none`.
unwind: Unwind = .none,
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
        targets: []const SymbolKey,
        relocs: []const Reloc,
    ) SymbolKey {
        var h = Hasher.init(&hash_key);
        h.update(&.{ @backingInt(section), @backingInt(alignment) });
        h.update(std.mem.asBytes(&@as(u64, bytes.len)));
        h.update(bytes);
        for (relocs) |r| {
            h.update(std.mem.asBytes(&r.offset));
            h.update(&.{@backingInt(r.info.kind)});
            h.update(std.mem.asBytes(&@backingInt(targets[r.info.target])));
            h.update(std.mem.asBytes(&r.addend));
        }
        return @fromBackingInt(@intCast(h.finalInt()));
    }

    /// The linker-defined start or end of an output section, which
    /// `@extern` names `__start_<name>`/`__stop_<name>`, or
    /// `__init_array_start`/`__init_array_end` and the like. Only the
    /// coverage sections and the init and fini arrays have them.
    pub fn sectionBound(section: Section, bound: enum { start, stop }) SymbolKey {
        var buf: [64]u8 = undefined;
        return .fromName(std.fmt.bufPrint(&buf, "section.{t}.{t}", .{ section, bound }) catch unreachable);
    }

    const Hasher = std.crypto.auth.siphash.SipHash128(1, 3);
    const hash_key: [Hasher.key_length]u8 = "zap symbol key!!".*;
};

/// Where an atom is placed.
pub const Section = enum(u8) {
    text,
    rodata,
    data,
    bss,
    /// Thread-local variables, initialized from `bytes` (`.tdata`) or
    /// zeroed (`.tbss`). Every thread gets its own copy; code reaches it
    /// relative to the thread pointer (`x86_64_tpoff32`).
    tdata,
    tbss,
    /// Coverage instrumentation (`-ffuzz`; docs/architecture.md,
    /// "Fuzzing"): one zero-filled byte per coverage point
    /// (`__sancov_cntrs`), and one address per point, in the same order
    /// (`__sancov_pcs1`). The linker keeps each section's atoms in input
    /// order and defines its start and end (`SymbolKey.sectionBound`).
    sancov_cntrs,
    sancov_pcs,
    /// Arrays of function addresses the start code runs before `main`
    /// (`.preinit_array`, then `.init_array`) and at exit (`.fini_array`),
    /// from C objects (docs/architecture.md, "Object, archive and
    /// shared-library inputs"). The linker keeps each section's atoms in
    /// input order, so its producer orders them by priority, and defines
    /// its start and end (`__init_array_start` and the others).
    preinit_array,
    init_array,
    fini_array,

    /// Whether atoms in the section are zero-filled, with no `bytes`.
    pub fn isZeroFill(s: Section) bool {
        // A shift and a test: cheaper in the linkers' per-atom loops than
        // two compares.
        const mask: u64 = 1 << @backingInt(Section.bss) | 1 << @backingInt(Section.tbss) | 1 << @backingInt(Section.sancov_cntrs);
        return mask >> @intCast(@backingInt(s) & 63) & 1 != 0;
    }
};

/// 12 bytes: relocation records are about as numerous as instructions that
/// reference other symbols, so their size is a large part of link time.
pub const Reloc = extern struct {
    /// Byte offset of the patched field within the atom.
    offset: u32,
    addend: i32,
    info: Info,

    pub const Info = packed struct(u32) {
        /// Index into the atom's `targets`.
        target: u24,
        kind: Kind,
    };

    pub fn init(offset: u32, kind: Kind, target: u24, addend: i32) Reloc {
        return .{ .offset = offset, .addend = addend, .info = .{ .target = target, .kind = kind } };
    }

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
        /// checked for overflow. V is the integer the whole compilation
        /// assigns to the target (for example an error's code in the global
        /// error set), from the linker's `values` option rather than from an
        /// atom, so atoms do not change when the assignment does. A target
        /// that names a symbol gives its address instead.
        value8,
        value16,
        value32,
        value64,
        /// aarch64 kinds. P is the address of the instruction or field; the
        /// instruction's other bits are kept. In Mach-O, a target that is
        /// imported from a dylib is reached through its GOT slot or a stub.
        ///
        /// 64-bit absolute address: S + A. Mach-O emits a rebase (or, for an
        /// import, a bind) fixup, so it is only valid in data and constants,
        /// at 4-byte aligned addresses.
        aarch64_abs64,
        /// b, bl: (S + A - P) >> 2 into imm26 (±128 MiB). Branches to an
        /// import go to its stub.
        aarch64_branch26,
        /// adrp: Page(S + A) - Page(P), 4 KiB pages, into immhi:immlo.
        aarch64_page21,
        /// add or load/store with an unsigned offset: (S + A) & 0xfff into
        /// imm12, divided by the access size the instruction encodes (1 for
        /// add, up to 16 for q registers), which the address must be
        /// aligned to.
        aarch64_pageoff12,
        /// adrp: Page(GOT(S)) - Page(P), where GOT(S) is the address of S's
        /// GOT slot. A must be 0.
        aarch64_got_load_page21,
        /// 64-bit ldr: GOT(S) & 0xfff, divided by 8, into imm12. A must be
        /// 0. If S is defined in the image, the linker points the pair at S
        /// itself and turns the ldr into an add.
        aarch64_got_load_pageoff12,
        /// x86_64 again, after the kinds above so their numbers, which
        /// the cache stores, stay put.
        ///
        /// 32-bit signed offset of a thread-local symbol from the thread
        /// pointer (fs), local-exec model: S + A - TLS end, where the TLS
        /// end is the start of the TLS segment plus its memory size rounded
        /// up to its alignment (ELF R_X86_64_TPOFF32, x86_64 TLS variant
        /// 2). S must be in `.tdata` or `.tbss`.
        x86_64_tpoff32,
        /// movz or movk: V + A into imm16, checked to fit 16 bits; the
        /// instruction's hw field shifts it. Only for link-time values, so
        /// an error compare is `movz w16, #code; cmp wN, w16` instead of a
        /// load from a constant.
        aarch64_movw_value16,
        /// adrp: Page(TLV(S)) - Page(P), where TLV(S) is the address of
        /// thread-local S's descriptor (Mach-O `__thread_vars`), whose
        /// thunk returns S's address for the calling thread. S must be in
        /// `.tdata` or `.tbss`; A must be 0.
        aarch64_tlvp_page21,
        /// 64-bit add: TLV(S) & 0xfff into imm12, completing the address of
        /// S's descriptor after `aarch64_tlvp_page21`. A must be 0.
        aarch64_tlvp_pageoff12,
        /// x86_64 local-dynamic TLS, in position-independent code only
        /// (see "Position-independent code" in docs/architecture.md).
        ///
        /// 32-bit PC-relative address of the module's TLS GOT pair (module
        /// ID, 0), which `__tls_get_addr` takes: GOT + A - P (ELF
        /// R_X86_64_TLSLD), in `lea rdi, [rip + S@tlsld]`, which must be
        /// followed by `call __tls_get_addr`. S is a thread-local of the
        /// module; A = -4.
        x86_64_tlsld,
        /// 32-bit offset of thread-local S in its module's TLS block: S + A
        /// minus the start of the TLS segment (ELF R_X86_64_DTPOFF32).
        x86_64_dtpoff32,
        /// x86_64 TLS for a thread-local another module may define
        /// (`extern threadlocal`), in objects only: only `ElfObject` takes
        /// them, as R_X86_64_GOTTPOFF and R_X86_64_TLSGD against an import,
        /// and the final link resolves them; an image's link rejects them.
        ///
        /// 32-bit PC-relative address of the GOT entry holding S's offset
        /// from the thread pointer, initial-exec model: in `add dst, [rip +
        /// S@gottpoff]` after `mov dst, fs:0`. A = -4.
        x86_64_gottpoff,
        /// 32-bit PC-relative address of S's TLS GOT pair (module ID,
        /// offset), general-dynamic model: in `data16 lea rdi, [rip +
        /// S@tlsgd]`, which must be followed by the padded `call
        /// __tls_get_addr`. A = -4.
        x86_64_tlsgd,
        /// 32-bit absolute addresses, in non-PIE code from C objects
        /// (docs/architecture.md, "Object, archive and shared-library
        /// inputs"), which only non-PIE executables take: S + A,
        /// zero-extended and checked to fit u32 (ELF R_X86_64_32), and
        /// sign-extended and checked to fit i32 (R_X86_64_32S).
        x86_64_abs32,
        x86_64_abs32s,
        /// 64-bit offset of thread-local S from the thread pointer, in an
        /// executable's slot for initial-exec code: S + A - TLS end for
        /// the image's own S; for an import (a shared library's
        /// thread-local, A = 0) the loader writes it (ELF
        /// R_X86_64_TPOFF64).
        x86_64_tpoff64,
    };
};

/// Builds an atom's `targets` and `relocs`, adding each target once. Used by
/// the encoder and by data lowering.
pub const RelocList = struct {
    /// `targets.keys()` is the atom's `targets`, in first-use order.
    targets: std.ArrayHashMapUnmanaged(SymbolKey, void, KeyContext, false) = .empty,
    relocs: std.ArrayList(Reloc) = .empty,

    pub fn deinit(l: *RelocList, gpa: std.mem.Allocator) void {
        l.targets.deinit(gpa);
        l.relocs.deinit(gpa);
    }

    pub fn append(l: *RelocList, gpa: std.mem.Allocator, offset: u32, kind: Reloc.Kind, target: SymbolKey, addend: i64) !void {
        const gop = try l.targets.getOrPut(gpa, target);
        try l.relocs.append(gpa, .init(offset, kind, @intCast(gop.index), @intCast(addend)));
    }

    /// Orders `relocs` by offset, as `Atom.relocs` requires.
    pub fn sort(l: *RelocList) void {
        std.mem.sort(Reloc, l.relocs.items, {}, struct {
            fn lt(_: void, a: Reloc, b: Reloc) bool {
                return a.offset < b.offset;
            }
        }.lt);
    }

    const KeyContext = struct {
        // Keys are already uniformly distributed hashes.
        pub fn hash(_: KeyContext, k: SymbolKey) u32 {
            return @truncate(@backingInt(k));
        }
        pub fn eql(_: KeyContext, a: SymbolKey, b: SymbolKey, _: usize) bool {
            return a == b;
        }
    };
};

/// What the linkers need to emit DWARF for a function: a compile unit
/// entry and a line-number program. Linkers take these apart from the
/// atoms, as a slice sorted by `atom`, so that a link without debug info
/// never reads them and one with it streams through them.
pub const Debug = struct {
    /// Index of the function's atom in the link's atoms. Set by whoever
    /// assembles the link's input (`Emit.addFunction`), not by CodeGen.
    atom: u32 = undefined,
    /// Path of the source file as the compiler opened it: absolute, or
    /// relative to the linker's `comp_dir`.
    file: []const u8,
    /// Simple name of the declaration, as debuggers and stack traces show
    /// it (DW_AT_name). The symbol table keeps the atom's `name`.
    name: []const u8,
    /// Zero-based line of the declaration's first line. `lines` is relative
    /// to it, so moving a declaration changes only this field.
    base_line: u32,
    /// DWARF line-number program fragment for the atom's code, built with
    /// `LineProgram`. It starts from address = the atom's start, line =
    /// `base_line` + 1, column 0, and uses the standard opcodes and the
    /// special-opcode parameters of `LineProgram`; the linker wraps it in a
    /// sequence and copies it, rewriting only the operands at `patches`.
    lines: []const u8,
    /// The compile unit: the path of the module's root source file, with
    /// `file`'s path rules. Each distinct unit is one unit of the output,
    /// named after the file's basename in the file's directory, as
    /// upstream names its units ("std.zig" in .../lib/std), with a line
    /// program of its own. "" is the unit of the first file, named after
    /// its path in `comp_dir`.
    unit: []const u8 = "",
    /// Other source files `lines` switches to, with `file`'s path rules,
    /// each followed by a 0 byte. A local file index is 0 for `file` and
    /// k + 1 for the k-th path (see `localFile`). Like every field here,
    /// it holds no pointers, so cached records decode in place.
    files: []const u8 = "",
    /// Calls inlined into the function, in preorder (a call's parent
    /// precedes it, and its first child, if any, follows it at once).
    inlines: []const Inline = &.{},
    /// The inline calls' names, which `Inline.name_off` and
    /// `Inline.name_len` slice (see `inlineName`).
    inline_names: []const u8 = "",
    /// For the cache, not the linker: per inline call, the callee
    /// declaration's stable key (`SymbolKey.fromName` of its `Nav.key`),
    /// by which a relink can refresh `Inline.base_line` when the callee
    /// moves but the caller is reused.
    inline_callees: []const SymbolKey = &.{},
    /// Offsets in `lines` of the opcodes whose operands the linker
    /// rewrites, in order (see `LineProgram.switchTo`):
    /// - `DW_LNS_set_file`, then a ULEB128 padded to 3 bytes holding a
    ///   local file index, which becomes the unit's file index;
    /// - `DW_LNS_advance_line`, then an SLEB128 padded to 5 bytes holding a
    ///   base, 0 for the function's and k + 1 for `inlines[k]`'s, which
    ///   becomes the difference between that base line and the previous
    ///   such patch's (at first, the function's).
    /// A fragment without patches is copied unchanged.
    patches: []const u32 = &.{},

    pub const Inline = extern struct {
        /// The callee's simple name, in `inline_names`.
        name_off: u32,
        name_len: u32,
        /// The callee's source file, as a local file index.
        file: u32,
        /// Zero-based line of the callee declaration's first line.
        base_line: u32,
        /// Zero-based line of the call, relative to the parent's
        /// `base_line`, and zero-based column. The call is in the parent's
        /// file.
        call_line: u32,
        call_column: u32,
        /// The inlined code: offsets `low..high` in the atom.
        low: u32,
        high: u32,
        /// Index in `inlines` of the inline call containing this one, or
        /// `none` for a call directly in the function.
        parent: u32,

        pub const none = std.math.maxInt(u32);
    };

    /// The path of local file index `local`, which must be in range.
    pub fn localFile(d: *const Debug, local: u32) []const u8 {
        if (local == 0) return d.file;
        var start: usize = 0;
        for (1..local) |_| start = std.mem.indexOfScalarPos(u8, d.files, start, 0).? + 1;
        return d.files[start..std.mem.indexOfScalarPos(u8, d.files, start, 0).?];
    }

    pub fn inlineName(d: *const Debug, inl: Inline) []const u8 {
        return d.inline_names[inl.name_off..][0..inl.name_len];
    }
};

/// A function's unwind information (see `Atom.unwind`).
pub const Unwind = extern struct {
    kind: Kind,
    /// With `frame_pointer` and an epilogue: the length of the out-of-line
    /// stack probes that end the code, which run in the body's frame;
    /// 0 for none.
    probes: u8 = 0,
    /// The callee-saved registers the prologue saves, with `frame_pointer`
    /// only; the bits and the prologue are each architecture's (see
    /// `savedBits`):
    /// - x86_64: rbx 0x1, r12 0x2, r13 0x4, r14 0x8, r15 0x10, pushed in
    ///   that order right after `push rbp; mov rbp, rsp`, the k-th pushed
    ///   at CFA - 24 - 8k (rbx's push is 1 byte, the others' 2);
    /// - aarch64: compact unwind's register pairs, x19/x20 0x1 through
    ///   x27/x28 0x10 and d8/d9 0x100 through d14/d15 0x800.
    saved: u16 = 0,
    /// With `frame_pointer`: the distance from the function's one
    /// epilogue's `ret` to the end of the code, so the `ret` is at offset
    /// `size - epilogue`; 0 when the function never returns. The epilogue
    /// is the frame pointer's restore and `ret` (x86_64: `pop rbp; ret`,
    /// after which the CFA is rsp + 8); CodeGen returns from elsewhere by
    /// jumping to it. After the `ret` come frameless stubs, if any (the
    /// CFA is rsp + 8 and the frame pointer and saved registers hold the
    /// physical frame's values, as at the `ret`), then the `probes`. 1 is
    /// a function that ends with its `ret`. Counted from the end so that
    /// the record stays 6 bytes and `Atom` 96.
    epilogue: u16 = 0,

    pub const none: Unwind = .{ .kind = .none };
    pub const frame_pointer: Unwind = .{ .kind = .frame_pointer };
    pub const outermost: Unwind = .{ .kind = .outermost };

    pub const Kind = enum(u8) {
        /// No unwind info, as for naked functions and data.
        none,
        /// The target's frame-pointer prologue at the start of the code
        /// (x86_64: `push rbp; mov rbp, rsp`), then the `saved` registers'
        /// saves, after which the frame is addressed from the frame
        /// pointer until the epilogue.
        frame_pointer,
        /// The outermost frame, such as std.start's `_start`: unwinding
        /// stops here (x86_64: return address undefined, as for
        /// `.cfi_undefined rip`).
        outermost,
    };

    pub const Arch = enum { x86_64, aarch64 };

    /// The `saved` bits `arch` defines.
    pub fn savedBits(arch: Arch) u16 {
        return switch (arch) {
            .x86_64 => 0x1f,
            .aarch64 => 0x0f1f,
        };
    }

    /// Whether `u` is one `arch` can describe: saved registers, an
    /// epilogue and probes only with a frame pointer, probes only after
    /// the epilogue's `ret`, and only `arch`'s saved registers.
    pub fn valid(u: Unwind, arch: Arch) bool {
        if (u.saved & ~savedBits(arch) != 0) return false;
        if (u.probes != 0 and u.epilogue <= u.probes) return false;
        return (u.saved == 0 and u.epilogue == 0) or u.kind == .frame_pointer;
    }
};

/// Builds `Debug.lines` from rows in increasing code offset.
pub const LineProgram = struct {
    bytes: std.ArrayList(u8) = .empty,
    /// `Debug.patches`.
    patches: std.ArrayList(u32) = .empty,
    /// Registers after the last row, relative to the atom.
    state: State = .{},
    /// Registers before the last row, and where it starts in `bytes`, so a
    /// row at the same offset can replace it.
    prev: State = .{},
    prev_len: usize = 0,

    const State = struct { offset: u32 = 0, line: u32 = 0, column: u32 = 0 };

    // As upstream Zig's DWARF emitter. The linkers write the header.
    pub const line_base = -5;
    pub const line_range = 14;
    pub const opcode_base = 13;

    pub fn deinit(lp: *LineProgram, gpa: std.mem.Allocator) void {
        lp.bytes.deinit(gpa);
        lp.patches.deinit(gpa);
    }

    /// Makes the rows after it come from local file index `file`, with
    /// lines relative to `base` (0 for the function's base line, k + 1 for
    /// `inlines[k]`'s). Line arguments stay relative to whichever base is
    /// in effect, so the line register is that base's line + 1 + the row's
    /// line, and moving any declaration changes only a base line.
    pub fn switchTo(lp: *LineProgram, gpa: std.mem.Allocator, file: u32, base: u32) !void {
        std.debug.assert(file < 1 << 21);
        try lp.bytes.ensureUnusedCapacity(gpa, 4 + 6);
        try lp.patches.ensureUnusedCapacity(gpa, 2);
        lp.patches.appendAssumeCapacity(@intCast(lp.bytes.items.len));
        lp.bytes.appendSliceAssumeCapacity(&.{ std.dwarf.LNS.set_file, @as(u8, @truncate(file)) | 0x80, @as(u8, @truncate(file >> 7)) | 0x80, @intCast(file >> 14) });
        lp.patches.appendAssumeCapacity(@intCast(lp.bytes.items.len));
        lp.bytes.appendAssumeCapacity(std.dwarf.LNS.advance_line);
        lp.bytes.appendSliceAssumeCapacity(&paddedSleb(base));
        // A row at the offset of the last one adds to it from here.
        lp.prev = lp.state;
        lp.prev_len = lp.bytes.items.len;
    }

    /// `v` as an SLEB128 padded to 5 bytes.
    pub fn paddedSleb(v: i64) [5]u8 {
        var out: [5]u8 = undefined;
        for (&out, 0..) |*b, i| b.* = @as(u7, @truncate(@as(u64, @bitCast(v >> @intCast(7 * i))))) | @as(u8, if (i < 4) 0x80 else 0);
        return out;
    }

    /// Adds a row: the code at `offset` comes from zero-based `line`
    /// (relative to the declaration) and zero-based `column`. A row at the
    /// offset of the previous one replaces it.
    pub fn addRow(lp: *LineProgram, gpa: std.mem.Allocator, offset: u32, line: u32, column: u32) !void {
        if (lp.bytes.items.len > 0 and offset == lp.state.offset) {
            lp.bytes.items.len = lp.prev_len;
            lp.state = lp.prev;
        }
        std.debug.assert(offset >= lp.state.offset);
        lp.prev = lp.state;
        lp.prev_len = lp.bytes.items.len;
        // Worst case: set_column, advance_line, advance_pc, special opcode.
        try lp.bytes.ensureUnusedCapacity(gpa, 1 + 5 + 1 + 10 + 1 + 5 + 1);
        const out = &lp.bytes;
        const dwarf_column = column + 1;
        if (dwarf_column != lp.state.column) {
            out.appendAssumeCapacity(std.dwarf.LNS.set_column);
            appendUleb(out, dwarf_column);
        }
        var line_delta = @as(i64, line) - lp.state.line;
        if (line_delta < line_base or line_delta >= line_base + line_range) {
            out.appendAssumeCapacity(std.dwarf.LNS.advance_line);
            appendSleb(out, line_delta);
            line_delta = 0;
        }
        var addr_delta: u64 = offset - lp.state.offset;
        const max_special_addr: u64 = @intCast(@divTrunc(255 - opcode_base - (line_delta - line_base), line_range));
        if (addr_delta > max_special_addr) {
            // const_add_pc adds the address advance of special opcode 255.
            const const_add = (255 - opcode_base) / line_range;
            if (addr_delta - const_add <= max_special_addr) {
                out.appendAssumeCapacity(std.dwarf.LNS.const_add_pc);
                addr_delta -= const_add;
            } else {
                out.appendAssumeCapacity(std.dwarf.LNS.advance_pc);
                appendUleb(out, addr_delta);
                addr_delta = 0;
            }
        }
        out.appendAssumeCapacity(@intCast((line_delta - line_base) + line_range * @as(i64, @intCast(addr_delta)) + opcode_base));
        lp.state = .{ .offset = offset, .line = line, .column = dwarf_column };
    }

    fn appendUleb(out: *std.ArrayList(u8), value: u64) void {
        var v = value;
        while (v >= 0x80) : (v >>= 7) out.appendAssumeCapacity(@as(u8, @truncate(v)) | 0x80);
        out.appendAssumeCapacity(@intCast(v));
    }

    fn appendSleb(out: *std.ArrayList(u8), value: i64) void {
        var v = value;
        while (true) {
            const b: u8 = @as(u7, @truncate(@as(u64, @bitCast(v))));
            v >>= 7;
            if ((v == 0 and b & 0x40 == 0) or (v == -1 and b & 0x40 != 0)) return out.appendAssumeCapacity(b);
            out.appendAssumeCapacity(b | 0x80);
        }
    }
};

comptime {
    std.debug.assert(@sizeOf(Reloc) == 12);
}

pub fn size(a: *const Atom) u64 {
    return if (a.section.isZeroFill()) a.zero_fill else a.bytes.len;
}

test "content keys distinguish relocation targets" {
    const a: SymbolKey = .fromName("a");
    const b: SymbolKey = .fromName("b");
    const bytes: [8]u8 = @splat(0);
    const relocs: []const Reloc = &.{.init(0, .x86_64_abs64, 0, 0)};
    const ka = SymbolKey.fromContents(.rodata, .@"8", &bytes, &.{a}, relocs);
    const kb = SymbolKey.fromContents(.rodata, .@"8", &bytes, &.{b}, relocs);
    try std.testing.expect(ka != kb);
    try std.testing.expectEqual(ka, SymbolKey.fromContents(.rodata, .@"8", &bytes, &.{a}, relocs));
}
