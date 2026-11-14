//! Container-level assembly (`comptime { asm (...); }`), which upstream's
//! self-hosted backends drop and its LLVM backend hands to LLVM's
//! assembler. bs assembles each block with the target's inline assembler
//! into one `.text` atom owned by the unit that ran it; the block's named
//! labels are offsets in that atom, and its `.global` ones are symbols the
//! link binds external names to (`Emit.asm_symbols`). What the assembler
//! cannot handle is a compile error at the `asm`, never dropped code.
//!
//! Beyond the inline assembler's instructions and numeric local labels,
//! a block may define named labels (`name:`) and use `.global`/`.globl`,
//! `.set`/`.equ` with a symbol (an alias), `.type`, `.text`,
//! `.section .text` and, at its start, `.p2align` and `.balign`. Labels,
//! globals and aliases are the module's, across its blocks. On aarch64 a
//! named label is a branch target in its own block; elsewhere it is not
//! an operand yet.

const std = @import("std");
const Zcu = @import("../Zcu.zig");
const InternPool = @import("../InternPool.zig");
const Emit = @import("../Emit.zig");
const Atom = @import("../link/Atom.zig");
const CodeGen = @import("x86_64/CodeGen.zig");
const CodeGenA64 = @import("aarch64/CodeGen.zig");

/// Assembles every block of `emit.zcu.global_asm` into atoms and their
/// global symbols into `emit.asm_symbols`. Returns false after reporting
/// errors. Symbols are the module's, as LLVM assembles all of a module's
/// blocks as one: a `.globl` in one block may name a label or a `.set`
/// alias of another.
pub fn assembleAll(emit: *Emit) !bool {
    var ok = true;
    var m: Module = .{};
    for (emit.zcu.global_asm.items, 0..) |*block, i| {
        var nth: u32 = 0;
        for (emit.zcu.global_asm.items[0..i]) |b| nth += @intFromBool(std.meta.eql(b.unit, block.unit));
        const saved = emit.owner;
        emit.owner = .{ .unit = block.unit };
        defer emit.owner = saved;
        const result = switch (emit.zcu.ip.target) {
            .x86_64_linux => assemble(CodeGen.GlobalAsm, emit, block, nth, &m),
            .aarch64_macos, .aarch64_linux => assemble(CodeGenA64.GlobalAsm, emit, block, nth, &m),
        };
        result catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => ok = false,
        };
    }
    if (!ok) return false;
    return resolve(emit, &m);
}

/// The module's symbols, by the name Zig code and C know them by
/// (`symbolName`).
const Module = struct {
    labels: std.array_hash_map.String(Emit.ExternTarget) = .empty,
    globals: std.ArrayList(Named) = .empty,
    /// `.set name, target`.
    aliases: std.ArrayList(Named) = .empty,

    const Named = struct { name: []const u8, target: []const u8 = "", block: *const Zcu.GlobalAsm };
};

/// Binds each `.globl` name to its label or alias. A name nothing in the
/// module defines is an undefined reference, which no instruction can
/// make yet.
fn resolve(emit: *Emit, m: *Module) !bool {
    for (m.globals.items) |global| {
        const name = global.name;
        const t = m.labels.get(name) orelse for (m.aliases.items) |a| {
            if (!std.mem.eql(u8, a.name, name)) continue;
            break m.labels.get(a.target) orelse if (try emit.userExport(a.target)) |key| Emit.ExternTarget{ .key = key } else return fail(emit, a.block, "'.set {s}, {s}': bs supports only a symbol that the module defines as the target of '.set' yet", .{ a.name, a.target });
        } else continue;
        if (try emit.userExport(name) != null) return fail(emit, global.block, "symbol '{s}' is defined by container-level assembly and exported by Zig code", .{name});
        // An object's and a shared object's exports name atoms.
        if ((emit.obj or emit.shared) and t.addend != 0)
            return fail(emit, global.block, "bs does not support a global symbol after the start of container-level assembly in objects and shared objects yet ('{s}')", .{name});
        try emit.asm_symbols.put(emit.gpa, name, t);
    }
    return true;
}

fn fail(emit: *Emit, block: *const Zcu.GlobalAsm, comptime fmt: []const u8, args: anytype) !bool {
    try emit.addError(block.file, block.span, fmt, args);
    return false;
}

const Label = struct { name: []const u8, offset: u32 };

fn assemble(comptime Asm: type, emit: *Emit, block: *const Zcu.GlobalAsm, nth: u32, m: *Module) !void {
    const ip = &emit.zcu.ip;
    const arena = emit.allocator();
    const target = ip.target;
    var g: Asm = .init(emit, .{ .file = block.file, .span = block.span });
    defer g.deinit();
    var labels: std.ArrayList(Label) = .empty;
    // aarch64 instructions are 4-byte aligned.
    var alignment: std.mem.Alignment = if (target.arch() == .aarch64) .@"4" else .@"1";

    var lines = std.mem.tokenizeScalar(u8, ip.stringSlice(block.source), '\n');
    while (lines.next()) |source_line| {
        // `//` starts a comment; on x86_64, `#` too (in aarch64 syntax it
        // marks an immediate).
        var code = source_line;
        if (std.mem.find(u8, code, "//")) |i| code = code[0..i];
        if (target.arch() == .x86_64) if (std.mem.findScalar(u8, code, '#')) |i| {
            code = code[0..i];
        };
        // LLVM's Mach-O assembler for aarch64 starts a comment at `;` and
        // separates statements with `%%`; the ELF ones separate with `;`.
        const macho = target == .aarch64_macos;
        if (macho) if (std.mem.findScalar(u8, code, ';')) |i| {
            code = code[0..i];
        };
        var statements = std.mem.tokenizeSequence(u8, code, if (macho) "%%" else ";");
        while (statements.next()) |raw| {
            var s = std.mem.trim(u8, raw, " \t\r");
            // Named labels; numeric ones are the inline assembler's.
            while (namedLabel(s)) |name| {
                for (labels.items) |l| if (std.mem.eql(u8, l.name, name)) return g.fail("asm label '{s}' is defined twice", .{name});
                const owned = try arena.dupe(u8, name);
                try labels.append(arena, .{ .name = owned, .offset = @intCast(g.cg.e.code.items.len) });
                if (@hasDecl(Asm, "label")) try g.label(owned);
                s = std.mem.trim(u8, s[name.len + 1 ..], " \t");
            }
            if (s.len == 0) continue;
            if (s[0] != '.') {
                try g.statement(s);
                continue;
            }
            const sp = std.mem.findAny(u8, s, " \t") orelse s.len;
            const directive = s[0..sp];
            const arg = std.mem.trim(u8, s[sp..], " \t");
            const eql = std.mem.eql;
            if (eql(u8, directive, ".global") or eql(u8, directive, ".globl")) {
                if (!isSymbol(arg)) return g.fail("bad symbol name in '{s}'", .{s});
                // One a C name cannot reach on aarch64-macos is the
                // module's own.
                if (symbolName(target, arg)) |name| try m.globals.append(arena, .{ .name = try arena.dupe(u8, name), .block = block });
            } else if (eql(u8, directive, ".set") or eql(u8, directive, ".equ")) {
                // A symbol alias: `.set alias, symbol`.
                const comma = std.mem.findScalar(u8, arg, ',') orelse return g.fail("bad '{s}'", .{s});
                const alias = std.mem.trim(u8, arg[0..comma], " \t");
                const to = std.mem.trim(u8, arg[comma + 1 ..], " \t");
                if (!isSymbol(alias) or !isSymbol(to) or std.ascii.isDigit(to[0]))
                    return g.fail("bs supports only a symbol as the value of '{s}' yet", .{s});
                const alias_name = symbolName(target, alias) orelse continue;
                const to_name = symbolName(target, to) orelse return g.fail("bs supports only a symbol that the module defines as the target of '{s}' yet", .{s});
                try m.aliases.append(arena, .{ .name = try arena.dupe(u8, alias_name), .target = try arena.dupe(u8, to_name), .block = block });
            } else if (eql(u8, directive, ".type") or eql(u8, directive, ".text") or
                (eql(u8, directive, ".section") and (eql(u8, arg, ".text") or std.mem.startsWith(u8, arg, ".text,"))))
            {
                // Symbols and code are functions in `.text` already.
            } else if (eql(u8, directive, ".p2align") or eql(u8, directive, ".balign")) {
                if (g.cg.e.code.items.len != 0) return g.fail("bs does not support '{s}' after the start of container-level assembly yet", .{s});
                const first = std.mem.trim(u8, arg[0 .. std.mem.findScalar(u8, arg, ',') orelse arg.len], " \t");
                const n = std.fmt.parseInt(u8, first, 0) catch return g.fail("bad alignment in '{s}'", .{s});
                const a: std.mem.Alignment = if (eql(u8, directive, ".p2align"))
                    if (n < 16) @fromBackingInt(@intCast(n)) else return g.fail("bad alignment in '{s}'", .{s})
                else if (n != 0 and std.math.isPowerOfTwo(n)) .fromByteUnits(n) else return g.fail("bad alignment in '{s}'", .{s});
                alignment = alignment.max(a);
            } else try g.statement(s);
        }
    }
    try g.finish();

    // A block without code (only directives) has no atom.
    const e = &g.cg.e;
    if (e.code.items.len == 0) {
        if (labels.items.len != 0) return g.fail("bs does not support labels in container-level assembly without code yet", .{});
        return;
    }
    // Keyed by the unit's stable key and the block's place among its
    // blocks, which do not depend on analysis order or file numbers.
    var aw: std.Io.Writer.Allocating = .init(arena);
    aw.writer.writeAll("bs.asm\x00") catch return error.OutOfMemory;
    emit.zcu.unitKey(block.unit, &aw.writer) catch return error.OutOfMemory;
    aw.writer.print("\x00{d}", .{nth}) catch return error.OutOfMemory;
    const key: Atom.SymbolKey = .fromName(aw.written());
    // The atom is named after its first label, as the symbol a profiler
    // shows for its first instruction.
    const name = for (labels.items) |l| {
        if (l.offset == 0) break symbolName(target, l.name) orelse l.name;
    } else "asm";
    try emit.addAtom(.{
        .key = key,
        .name = name,
        .section = .text,
        .alignment = alignment,
        .bytes = try arena.dupe(u8, e.code.items),
        .targets = try arena.dupe(Atom.SymbolKey, e.refs.targets.keys()),
        .relocs = try arena.dupe(Atom.Reloc, e.refs.relocs.items),
    });
    for (labels.items) |l| {
        const c_name = symbolName(target, l.name) orelse continue;
        const gop = try m.labels.getOrPut(arena, c_name);
        if (gop.found_existing) return g.fail("container-level assembly defines symbol '{s}' twice", .{c_name});
        gop.value_ptr.* = .{ .key = key, .addend = l.offset };
    }
}

/// The name of label `l`: `name:` at the start of `s`, unless it is a
/// numeric local label.
fn namedLabel(s: []const u8) ?[]const u8 {
    const colon = std.mem.findScalar(u8, s, ':') orelse return null;
    const name = s[0..colon];
    if (!isSymbol(name) or std.ascii.isDigit(name[0])) return null;
    return name;
}

fn isSymbol(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '.' and c != '$') return false;
    return true;
}

/// The name Zig code and C objects know assembly symbol `name` by, or null
/// for one they cannot name: on aarch64-macos the name without its leading
/// underscore.
fn symbolName(target: InternPool.Target, name: []const u8) ?[]const u8 {
    if (target != .aarch64_macos) return name;
    if (name.len < 2 or name[0] != '_') return null;
    return name[1..];
}
