//! Static, non-PIE x86_64 ELF linker. Takes the whole set of Atoms, lays out
//! sections, resolves relocations, and writes the executable in one pass
//! into one buffer. Nothing is patched afterwards.
//!
//! File layout, with each segment starting on a page boundary and mapped at
//! `base_address + file offset`:
//!
//!   R   ELF header, program headers, .rodata
//!   RX  .text
//!   RW  .data, then .bss (memory only)
//!       .symtab, .strtab, .shstrtab, section headers (not loaded)
//!
//! TLS is not implemented. `.tdata` and `.tbss` will go at the start of the
//! RW segment, before `.data`, covered by a PT_TLS program header, with
//! TP-relative relocation kinds resolved against the end of that segment.

const std = @import("std");
const builtin = @import("builtin");
const elf = std.elf;
const Allocator = std.mem.Allocator;
const Atom = @import("Atom.zig");
const SymbolKey = Atom.SymbolKey;

comptime {
    // Structs are copied into the output as host bytes.
    std.debug.assert(builtin.cpu.arch.endian() == .little);
}

pub const Options = struct {
    entry: SymbolKey,
    /// Integers assigned by the whole compilation, read by `value*`
    /// relocations.
    values: []const Value = &.{},
    base_address: u64 = 0x200000,
    /// Filled in when linking fails with a symbol-related error.
    diag: ?*Diagnostic = null,
};

pub const Value = struct { key: SymbolKey, value: u64 };

pub const Diagnostic = struct {
    /// Atom whose definition or relocation failed.
    atom: []const u8 = "",
    /// The undefined or overflowing target, if any.
    target: ?SymbolKey = null,
};

pub const Error = Allocator.Error || error{
    /// Two atoms share a key but differ in contents.
    DuplicateSymbol,
    UndefinedSymbol,
    RelocationOverflow,
    /// A relocation lies outside its atom, or is in a `.bss` atom.
    InvalidRelocation,
};

/// Links `atoms` and writes the executable to `sub_path` in `dir`.
pub fn link(gpa: Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, atoms: []const Atom, options: Options) !void {
    const bytes = try emit(gpa, atoms, options);
    defer gpa.free(bytes);
    try dir.writeFile(io, .{ .sub_path = sub_path, .data = bytes, .flags = .{ .permissions = .executable_file } });
}

const page_size = 0x1000;

/// Section header indices; the order is the layout order.
const Shndx = enum(u16) { null, rodata, text, data, bss, symtab, strtab, shstrtab };
const shnum = std.enums.values(Shndx).len;
/// Section header of each `Atom.Section`.
const shndx_of = [4]Shndx{ .text, .rodata, .data, .bss };
/// `addrs` entry of an atom dropped as a duplicate.
const duplicate = std.math.maxInt(u64);
const shstrtab = "\x00.rodata\x00.text\x00.data\x00.bss\x00.symtab\x00.strtab\x00.shstrtab\x00";

/// Links `atoms` into the bytes of an executable, owned by the caller.
///
/// Every pass walks `atoms` in input order, so the Atom structs are read
/// sequentially. Within a section, atoms keep their input order.
pub fn emit(gpa: Allocator, atoms: []const Atom, options: Options) Error![]u8 {
    var unused_diag: Diagnostic = .{};
    const diag = options.diag orelse &unused_diag;
    const text = @backingInt(Atom.Section.text);
    const rodata = @backingInt(Atom.Section.rodata);
    const data = @backingInt(Atom.Section.data);
    const bss = @backingInt(Atom.Section.bss);

    // Deduplicate by key and place each new atom at the end of its section.
    // `symbols` maps a key to its atom's index, and after layout to its
    // address. `addrs` holds offsets within the section until then.
    var symbols: SymbolTable = try .init(gpa, atoms.len);
    defer symbols.deinit(gpa);
    const addrs = try gpa.alloc(u64, atoms.len);
    defer gpa.free(addrs);
    var sizes: [4]u64 = @splat(0);
    var aligns: [4]std.mem.Alignment = @splat(.@"1");
    var n_syms: u64 = 1;
    var strtab_len: u64 = 1;
    for (atoms, addrs, 0..) |*a, *addr, i| {
        if (i + 8 < atoms.len) symbols.prefetch(atoms[i + 8].key);
        const e = symbols.getOrPut(a.key);
        if (e.used) {
            if (!identical(&atoms[e.value], a)) {
                diag.* = .{ .atom = a.name, .target = a.key };
                return error.DuplicateSymbol;
            }
            addr.* = duplicate;
            continue;
        }
        if (a.section == .bss and (a.bytes.len != 0 or a.relocs.len != 0)) {
            diag.* = .{ .atom = a.name };
            return error.InvalidRelocation;
        }
        e.* = .{ .key = a.key, .value = i, .used = true };
        const s = @backingInt(a.section);
        addr.* = a.alignment.forward(sizes[s]);
        sizes[s] = addr.* + a.size();
        aligns[s] = aligns[s].max(a.alignment);
        n_syms += 1;
        if (a.name.len > 0) strtab_len += a.name.len + 1;
    }
    if (symbols.get(options.entry) == null) {
        diag.* = .{ .target = options.entry };
        return error.UndefinedSymbol;
    }

    var values: SymbolTable = try .init(gpa, options.values.len);
    defer values.deinit(gpa);
    for (options.values) |v| values.getOrPut(v.key).* = .{ .key = v.key, .value = v.value, .used = true };

    // Section placement, as file offsets (for .bss, address - base).
    const has_rx = sizes[text] > 0;
    const has_rw = sizes[data] > 0 or sizes[bss] > 0;
    const phnum: u16 = 2 + @as(u16, @intFromBool(has_rx)) + @intFromBool(has_rw);
    const headers_end: u64 = @sizeOf(elf.Elf64.Ehdr) + phnum * @sizeOf(elf.Elf64.Phdr);
    var starts: [4]u64 = undefined;
    starts[rodata] = aligns[rodata].forward(headers_end);
    const r_end = starts[rodata] + sizes[rodata];
    const rx_start = if (has_rx) std.mem.alignForward(u64, r_end, page_size) else r_end;
    starts[text] = aligns[text].forward(rx_start);
    const text_end = starts[text] + sizes[text];
    const rw_start = if (has_rw) std.mem.alignForward(u64, text_end, page_size) else text_end;
    starts[data] = aligns[data].forward(rw_start);
    const file_end = starts[data] + sizes[data];
    starts[bss] = aligns[bss].forward(file_end);
    const mem_end = starts[bss] + sizes[bss];

    const base = options.base_address;
    for (atoms, addrs) |*a, *addr| {
        if (addr.* != duplicate) addr.* += base + starts[@backingInt(a.section)];
    }
    for (symbols.entries) |*e| if (e.used) {
        e.value = addrs[e.value];
    };

    const symtab_off = std.mem.alignForward(u64, file_end, 8);
    const strtab_off = symtab_off + n_syms * @sizeOf(elf.Elf64.Sym);
    const shstrtab_off = strtab_off + strtab_len;
    const shoff = std.mem.alignForward(u64, shstrtab_off + shstrtab.len, 8);
    const buf = try gpa.alloc(u8, shoff + shnum * @sizeOf(elf.Elf64.Shdr));
    errdefer gpa.free(buf);

    // Section contents, with relocations applied in place. `ends` tracks how
    // far each section is written; gaps are filled as they are passed.
    const fills: [3]u8 = .{ 0xcc, 0, 0 };
    var ends: [3]u64 = undefined;
    ends[rodata] = headers_end;
    ends[text] = r_end;
    ends[data] = text_end;
    const ctx: RelocCtx = .{ .symbols = &symbols, .values = &values, .diag = diag };
    for (atoms, addrs, 0..) |*a, addr, i| {
        // An atom's bytes, its relocations, and their `symbols` entries are
        // scattered in memory; start those misses a few atoms ahead.
        if (i + 4 < atoms.len) {
            @prefetch(atoms[i + 4].relocs.ptr, .{});
            @prefetch(atoms[i + 4].bytes.ptr, .{});
        }
        if (i + 2 < atoms.len) for (atoms[i + 2].relocs) |r| symbols.prefetch(r.target);
        if (addr == duplicate or a.section == .bss) continue;
        const s = @backingInt(a.section);
        const start = addr - base;
        @memset(buf[ends[s]..start], fills[s]);
        const dst = buf[start..][0..a.bytes.len];
        @memcpy(dst, a.bytes);
        try ctx.apply(a, dst, addr);
        ends[s] = start + a.bytes.len;
    }
    // Sections without atoms, and the tail after .data.
    for (ends, 0..) |end, s| @memset(buf[end .. starts[s] + sizes[s]], fills[s]);
    @memset(buf[file_end..symtab_off], 0);

    // Symbol and string tables.
    const syms = buf[symtab_off..strtab_off];
    @memset(syms[0..@sizeOf(elf.Elf64.Sym)], 0);
    buf[strtab_off] = 0;
    var sym_off: usize = @sizeOf(elf.Elf64.Sym);
    var str_off: u32 = 1;
    for (atoms, addrs) |*a, addr| {
        if (addr == duplicate) continue;
        var name: u32 = 0;
        if (a.name.len > 0) {
            name = str_off;
            @memcpy(buf[strtab_off + str_off ..][0..a.name.len], a.name);
            buf[strtab_off + str_off + a.name.len] = 0;
            str_off += @intCast(a.name.len + 1);
        }
        writeStruct(syms[sym_off..], elf.Elf64.Sym{
            .name = name,
            .info = .{ .type = if (a.section == .text) .FUNC else .OBJECT, .bind = .GLOBAL },
            .other = .{ .visibility = .DEFAULT },
            .shndx = @backingInt(shndx_of[@backingInt(a.section)]),
            .value = addr,
            .size = a.size(),
        });
        sym_off += @sizeOf(elf.Elf64.Sym);
    }
    @memcpy(buf[shstrtab_off..][0..shstrtab.len], shstrtab);
    @memset(buf[shstrtab_off + shstrtab.len .. shoff], 0);

    // Headers.
    writeStruct(buf, elf.Elf64.Ehdr{
        .ident = .{ .class = .@"64", .data = .@"2LSB", .version = 1, .osabi = .NONE, .abiversion = 0 },
        .type = .EXEC,
        .machine = .X86_64,
        .version = 1,
        .entry = symbols.get(options.entry).?,
        .phoff = @sizeOf(elf.Elf64.Ehdr),
        .shoff = shoff,
        .flags = .{ .int = 0 },
        .ehsize = @sizeOf(elf.Elf64.Ehdr),
        .phentsize = @sizeOf(elf.Elf64.Phdr),
        .phnum = phnum,
        .shentsize = @sizeOf(elf.Elf64.Shdr),
        .shnum = shnum,
        .shstrndx = @backingInt(Shndx.shstrtab),
    });
    var ph_off: usize = @sizeOf(elf.Elf64.Ehdr);
    const phdrs = [_]struct { bool, elf.PF, u64, u64, u64 }{
        .{ true, .{ .R = true }, 0, r_end, r_end },
        .{ has_rx, .{ .R = true, .X = true }, rx_start, text_end - rx_start, text_end - rx_start },
        .{ has_rw, .{ .R = true, .W = true }, rw_start, file_end - rw_start, mem_end - rw_start },
    };
    for (phdrs) |p| if (p[0]) {
        writeStruct(buf[ph_off..], elf.Elf64.Phdr{
            .type = .LOAD,
            .flags = p[1],
            .offset = p[2],
            .vaddr = base + p[2],
            .paddr = base + p[2],
            .filesz = p[3],
            .memsz = p[4],
            .@"align" = page_size,
        });
        ph_off += @sizeOf(elf.Elf64.Phdr);
    };
    writeStruct(buf[ph_off..], elf.Elf64.Phdr{
        .type = .GNU_STACK,
        .flags = .{ .R = true, .W = true },
        .offset = 0,
        .vaddr = 0,
        .paddr = 0,
        .filesz = 0,
        .memsz = 0,
        .@"align" = 16,
    });

    const shdrs = [_]elf.Elf64.Shdr{
        std.mem.zeroes(elf.Elf64.Shdr),
        shdr(1, .PROGBITS, .{ .ALLOC = true }, base, starts[rodata], sizes[rodata], aligns[rodata]),
        shdr(9, .PROGBITS, .{ .ALLOC = true, .EXECINSTR = true }, base, starts[text], sizes[text], aligns[text]),
        shdr(15, .PROGBITS, .{ .ALLOC = true, .WRITE = true }, base, starts[data], sizes[data], aligns[data]),
        shdr(21, .NOBITS, .{ .ALLOC = true, .WRITE = true }, base, starts[bss], sizes[bss], aligns[bss]),
        .{ .name = 26, .type = .SYMTAB, .flags = .{ .shf = .{} }, .addr = 0, .offset = symtab_off, .size = n_syms * @sizeOf(elf.Elf64.Sym), .link = @backingInt(Shndx.strtab), .info = 1, .addralign = 8, .entsize = @sizeOf(elf.Elf64.Sym) },
        .{ .name = 34, .type = .STRTAB, .flags = .{ .shf = .{} }, .addr = 0, .offset = strtab_off, .size = strtab_len, .link = 0, .info = 0, .addralign = 1, .entsize = 0 },
        .{ .name = 42, .type = .STRTAB, .flags = .{ .shf = .{} }, .addr = 0, .offset = shstrtab_off, .size = shstrtab.len, .link = 0, .info = 0, .addralign = 1, .entsize = 0 },
    };
    for (shdrs, 0..) |s, i| writeStruct(buf[shoff + i * @sizeOf(elf.Elf64.Shdr) ..], s);
    return buf;
}

/// Open-addressing hash table from symbol key to a u64, with key and value
/// in one entry so that resolving a relocation costs one cache miss. Keys
/// are already uniformly distributed, so their low bits are the hash.
const SymbolTable = struct {
    entries: []Entry,

    const Entry = struct { key: SymbolKey, value: u64, used: bool };

    fn init(gpa: Allocator, max_count: usize) Allocator.Error!SymbolTable {
        const entries = try gpa.alloc(Entry, std.math.ceilPowerOfTwoAssert(usize, @max(16, max_count * 2)));
        for (entries) |*e| e.used = false;
        return .{ .entries = entries };
    }

    fn deinit(t: *SymbolTable, gpa: Allocator) void {
        gpa.free(t.entries);
    }

    /// The entry for `key`: used if `key` is present, else the free slot to
    /// fill in. The table must not be full.
    fn getOrPut(t: *const SymbolTable, key: SymbolKey) *Entry {
        const mask = t.entries.len - 1;
        var i: usize = @as(usize, @truncate(@backingInt(key))) & mask;
        while (true) : (i = (i + 1) & mask) {
            const e = &t.entries[i];
            if (!e.used or e.key == key) return e;
        }
    }

    fn prefetch(t: *const SymbolTable, key: SymbolKey) void {
        @prefetch(&t.entries[@as(usize, @truncate(@backingInt(key))) & (t.entries.len - 1)], .{});
    }

    fn get(t: *const SymbolTable, key: SymbolKey) ?u64 {
        const e = t.getOrPut(key);
        return if (e.used) e.value else null;
    }
};

fn shdr(name: u32, ty: elf.SHT, flags: elf.SHF, base: u64, offset: u64, size: u64, alignment: std.mem.Alignment) elf.Elf64.Shdr {
    return .{
        .name = name,
        .type = ty,
        .flags = .{ .shf = flags },
        .addr = base + offset,
        .offset = offset,
        .size = size,
        .link = 0,
        .info = 0,
        .addralign = alignment.toByteUnits(),
        .entsize = 0,
    };
}

fn writeStruct(dst: []u8, s: anytype) void {
    @memcpy(dst[0..@sizeOf(@TypeOf(s))], std.mem.asBytes(&s));
}

fn identical(a: *const Atom, b: *const Atom) bool {
    if (a.section != b.section or a.alignment != b.alignment or a.size() != b.size() or a.relocs.len != b.relocs.len) return false;
    if (!std.mem.eql(u8, a.bytes, b.bytes)) return false;
    for (a.relocs, b.relocs) |x, y| {
        if (x.offset != y.offset or x.kind != y.kind or x.target != y.target or x.addend != y.addend) return false;
    }
    return true;
}

const RelocCtx = struct {
    symbols: *const SymbolTable,
    values: *const SymbolTable,
    diag: *Diagnostic,

    /// Applies `a`'s relocations to its copy `dst` at address `p_base`.
    fn apply(c: RelocCtx, a: *const Atom, dst: []u8, p_base: u64) Error!void {
        for (a.relocs) |r| {
            const width: u4 = switch (r.kind) {
                .x86_64_abs64, .value64 => 8,
                .x86_64_pc32, .value32 => 4,
                .value16 => 2,
                .value8 => 1,
            };
            if (r.offset + @as(u64, width) > dst.len) {
                c.diag.* = .{ .atom = a.name, .target = r.target };
                return error.InvalidRelocation;
            }
            const field = dst[r.offset..];
            switch (r.kind) {
                .x86_64_abs64 => std.mem.writeInt(u64, field[0..8], (try c.addr(a, r.target)) +% @as(u64, @bitCast(r.addend)), .little),
                .x86_64_pc32 => {
                    const s = try c.addr(a, r.target);
                    const v = @as(i128, s) + r.addend - (p_base + r.offset);
                    std.mem.writeInt(i32, field[0..4], std.math.cast(i32, v) orelse return c.overflow(a, r), .little);
                },
                .value8, .value16, .value32, .value64 => {
                    const v = @as(i128, c.values.get(r.target) orelse return c.undefinedSymbol(a, r.target)) + r.addend;
                    switch (r.kind) {
                        .value8 => field[0] = std.math.cast(u8, v) orelse return c.overflow(a, r),
                        .value16 => std.mem.writeInt(u16, field[0..2], std.math.cast(u16, v) orelse return c.overflow(a, r), .little),
                        .value32 => std.mem.writeInt(u32, field[0..4], std.math.cast(u32, v) orelse return c.overflow(a, r), .little),
                        .value64 => std.mem.writeInt(u64, field[0..8], std.math.cast(u64, v) orelse return c.overflow(a, r), .little),
                        else => unreachable,
                    }
                },
            }
        }
    }

    fn addr(c: RelocCtx, a: *const Atom, target: SymbolKey) Error!u64 {
        return c.symbols.get(target) orelse c.undefinedSymbol(a, target);
    }

    fn undefinedSymbol(c: RelocCtx, a: *const Atom, target: SymbolKey) Error {
        c.diag.* = .{ .atom = a.name, .target = target };
        return error.UndefinedSymbol;
    }

    fn overflow(c: RelocCtx, a: *const Atom, r: Atom.Reloc) Error {
        c.diag.* = .{ .atom = a.name, .target = r.target };
        return error.RelocationOverflow;
    }
};

test "links and runs a program that writes from rodata and exits with 42" {
    if (builtin.cpu.arch != .x86_64 or builtin.os.tag != .linux) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const Encoder = @import("../codegen/x86_64/Encoder.zig");

    const msg_text = "Hello from zap!\n";
    const msg: SymbolKey = .fromContents(.rodata, .@"1", msg_text, &.{});
    const msg_ptr: SymbolKey = .fromName("msg_ptr");
    const status: SymbolKey = .fromName("status");
    const write_msg: SymbolKey = .fromName("write_msg");
    const start: SymbolKey = .fromName("_start");
    const exit_code: SymbolKey = .fromName("exit_code");

    // write(1, msg_ptr.*, len); the string is reached through an absolute
    // pointer in .data.
    var w: Encoder = .init(gpa);
    defer w.deinit();
    try w.mov(.dword, .{ .reg = .rax }, .{ .imm = 1 });
    try w.mov(.dword, .{ .reg = .rdi }, .{ .imm = 1 });
    try w.mov(.qword, .{ .reg = .rsi }, .{ .mem = .sym(msg_ptr, 0) });
    try w.mov(.dword, .{ .reg = .rdx }, .{ .imm = msg_text.len });
    try w.syscall();
    try w.ret();
    w.finish();

    // status = exit_code (a link-time value); exit(status) if it is 42.
    var s: Encoder = .init(gpa);
    defer s.deinit();
    try s.call(.{ .sym = write_msg });
    try s.mov(.dword, .{ .mem = .sym(status, 0) }, .{ .imm = 0 });
    try s.relocs.append(gpa, .{ .offset = @intCast(s.code.items.len - 4), .kind = .value32, .target = exit_code, .addend = 0 });
    try s.mov(.dword, .{ .reg = .rdi }, .{ .mem = .sym(status, 0) });
    try s.alu(.cmp, .dword, .{ .reg = .rdi }, .{ .imm = 42 });
    const ok = try s.newLabel();
    try s.jcc(.e, .{ .label = ok });
    try s.ud2();
    s.bind(ok);
    try s.mov(.dword, .{ .reg = .rax }, .{ .imm = 60 });
    try s.syscall();
    s.finish();

    const msg_atom: Atom = .{ .key = msg, .name = "__anon_msg", .section = .rodata, .bytes = msg_text };
    const atoms = [_]Atom{
        .{ .key = start, .name = "_start", .section = .text, .alignment = .@"16", .bytes = s.code.items, .relocs = s.relocs.items },
        msg_atom,
        .{ .key = write_msg, .name = "write_msg", .section = .text, .alignment = .@"16", .bytes = w.code.items, .relocs = w.relocs.items },
        .{ .key = status, .name = "status", .section = .bss, .alignment = .@"4", .zero_fill = 4 },
        .{ .key = msg_ptr, .name = "msg_ptr", .section = .data, .alignment = .@"8", .bytes = &@as([8]u8, @splat(0)), .relocs = &.{
            .{ .offset = 0, .kind = .x86_64_abs64, .target = msg, .addend = 0 },
        } },
        // A second function's copy of the same constant.
        msg_atom,
    };
    const options: Options = .{ .entry = start, .values = &.{.{ .key = exit_code, .value = 42 }} };

    const bytes = try emit(gpa, &atoms, options);
    defer gpa.free(bytes);
    try std.testing.expectEqual(1, std.mem.count(u8, bytes, msg_text));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try link(gpa, io, tmp.dir, "hello", &atoms, options);
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/hello", .{tmp.sub_path});
    defer gpa.free(path);
    const result = try std.process.run(gpa, io, .{ .argv = &.{path} });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqualStrings(msg_text, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 42 }, result.term);

    // The same key with different contents is a conflict, not a duplicate.
    var diag: Diagnostic = .{};
    const conflicting = [_]Atom{ atoms[0], .{ .key = start, .name = "other", .section = .text, .bytes = "\xc3" } };
    try std.testing.expectError(error.DuplicateSymbol, emit(gpa, &conflicting, .{ .entry = start, .diag = &diag }));
    try std.testing.expectEqualStrings("other", diag.atom);
}
