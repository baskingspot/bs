//! Turns analyzed functions into Atoms and links them: the sink that
//! `Zcu.analyzeAll` hands each function's IR to. Owns every Atom's memory
//! until the link, lowers the data the code refers to (declarations,
//! anonymous constants, panic messages), and assigns error codes, which
//! reach machine code only through `value*` relocations.

const std = @import("std");
const Allocator = std.mem.Allocator;
const InternPool = @import("InternPool.zig");
const Index = InternPool.Index;
const Ir = @import("Ir.zig");
const Type = @import("Type.zig");
const Zcu = @import("Zcu.zig");
const Atom = @import("link/Atom.zig");
const SymbolKey = Atom.SymbolKey;
const Elf = @import("link/Elf.zig");
const CodeGen = @import("codegen/x86_64/CodeGen.zig");

const Emit = @This();

gpa: Allocator,
/// Owns atom bytes, relocations, and names.
arena: std.heap.ArenaAllocator,
zcu: *Zcu,
atoms: std.ArrayList(Atom) = .empty,
/// Debug info of the function atoms, in atom order.
debug: std.ArrayList(Atom.Debug) = .empty,
/// Content-addressed atoms already emitted.
content_keys: std.AutoHashMapUnmanaged(SymbolKey, void) = .empty,
/// Declarations whose data the code refers to; lowered by `finish`.
navs: std.AutoArrayHashMapUnmanaged(InternPool.NavIndex, void) = .empty,
/// Error names referenced by `value*` relocations.
errors: std.AutoArrayHashMapUnmanaged(InternPool.String, void) = .empty,
/// Whether any function calls the panic helpers.
uses_panic: bool = false,
/// Compile errors that codegen reports (unsupported constructs), rendered
/// like Sema's.
failed: bool = false,
/// The entry symbol, once `finish` found it.
entry: ?SymbolKey = null,
/// What produced each atom, for the on-disk cache (`Incremental`).
atom_owners: std.ArrayList(Owner) = .empty,
/// Content-addressed atoms each unit referred to.
content_uses: std.ArrayList(ContentUse) = .empty,
/// The owner of atoms added now.
owner: Owner = .link,

pub const Owner = union(enum) {
    unit: Zcu.AnalUnit,
    /// A content-addressed constant, shared by the units that use it.
    content,
    /// Code the link needs regardless of units (panic helpers).
    link,
};

pub const ContentUse = struct { unit: Zcu.AnalUnit, key: SymbolKey };

pub fn init(gpa: Allocator, zcu: *Zcu) Emit {
    return .{ .gpa = gpa, .arena = .init(gpa), .zcu = zcu };
}

pub fn deinit(emit: *Emit) void {
    const gpa = emit.gpa;
    emit.atoms.deinit(gpa);
    emit.debug.deinit(gpa);
    emit.content_keys.deinit(gpa);
    emit.navs.deinit(gpa);
    emit.errors.deinit(gpa);
    emit.atom_owners.deinit(gpa);
    emit.content_uses.deinit(gpa);
    emit.arena.deinit();
}

/// Sink callback from `Zcu.analyzeAll`.
pub fn function(emit: *Emit, zcu: *Zcu, ir: *const Ir) !void {
    _ = zcu;
    emit.owner = .{ .unit = .{ .func = ir.func } };
    defer emit.owner = .link;
    CodeGen.generate(emit, ir) catch |err| switch (err) {
        error.CodegenFail => emit.failed = true,
        else => |e| return e,
    };
}

/// Lowers the remaining data, then links everything into `sub_path`.
/// Returns false (after reporting errors to the Zcu) if it could not.
pub fn finish(emit: *Emit, io: std.Io, dir: std.Io.Dir, sub_path: []const u8) !bool {
    const zcu = emit.zcu;
    const ip = &zcu.ip;
    // Lowering a declaration can request more declarations.
    var i: usize = 0;
    while (i < emit.navs.count()) : (i += 1) {
        try emit.lowerNav(emit.navs.keys()[i]);
    }
    if (emit.uses_panic) try CodeGen.emitPanicHelpers(emit);

    var entry: ?SymbolKey = null;
    for (zcu.exports.items) |e| {
        const nav = ip.getNav(e.nav);
        if (nav.status != .resolved) continue;
        if (std.mem.eql(u8, ip.stringSlice(e.name), "_start") and ip.indexToKey(nav.val) == .func) {
            entry = try emit.funcKey(nav.val);
        }
    }
    if (emit.failed) return false;
    emit.entry = entry;
    const entry_key = entry orelse {
        try zcu.addError(0, .{ .start = 0, .end = 0, .main = 0 }, "zap requires the root file to export '_start' (std.start is not supported yet)", .{});
        return false;
    };

    // Error codes: the order names were first interned, starting at 1.
    var values: std.ArrayList(Elf.Value) = .empty;
    defer values.deinit(emit.gpa);
    for (emit.errors.keys()) |name| {
        try values.append(emit.gpa, .{ .key = errorKey(ip, name), .value = try ip.errorValue(name) });
    }
    var diag: Elf.Diagnostic = .{};
    // Source paths are as the compiler opened them, relative to the cwd.
    const cwd = try std.process.currentPathAlloc(io, emit.gpa);
    defer emit.gpa.free(cwd);
    Elf.link(emit.gpa, io, dir, sub_path, emit.atoms.items, .{ .entry = entry_key, .values = values.items, .diag = &diag, .debug = emit.debug.items, .comp_dir = cwd }) catch |err| {
        std.debug.print("error: link failed: {t} (atom '{s}')\n", .{ err, diag.atom });
        return false;
    };
    return true;
}

pub fn allocator(emit: *Emit) Allocator {
    return emit.arena.allocator();
}

pub fn addAtom(emit: *Emit, atom: Atom) !void {
    try emit.atom_owners.ensureUnusedCapacity(emit.gpa, 1);
    try emit.atoms.append(emit.gpa, atom);
    emit.atom_owners.appendAssumeCapacity(emit.owner);
}

/// Adds a function's atom and its debug info.
pub fn addFunction(emit: *Emit, atom: Atom, debug: Atom.Debug) !void {
    try emit.debug.ensureUnusedCapacity(emit.gpa, 1);
    var d = debug;
    d.atom = @intCast(emit.atoms.items.len);
    try emit.addAtom(atom);
    emit.debug.appendAssumeCapacity(d);
}

/// Adds a content-addressed rodata atom for `bytes` and its sorted `relocs`
/// unless an identical one exists, and returns its key.
pub fn contentAtom(emit: *Emit, alignment: u64, bytes: []const u8, targets: []const SymbolKey, relocs: []const Atom.Reloc) !SymbolKey {
    const a: std.mem.Alignment = .fromByteUnits(@max(alignment, 1));
    const key: SymbolKey = .fromContents(.rodata, a, bytes, targets, relocs);
    if (emit.owner == .unit) try emit.content_uses.append(emit.gpa, .{ .unit = emit.owner.unit, .key = key });
    const gop = try emit.content_keys.getOrPut(emit.gpa, key);
    if (gop.found_existing) return key;
    const owner = emit.owner;
    emit.owner = .content;
    defer emit.owner = owner;
    const arena = emit.allocator();
    try emit.addAtom(.{
        .key = key,
        .name = try std.fmt.allocPrint(arena, "__anon_{x}", .{@backingInt(key)}),
        .section = .rodata,
        .alignment = a,
        .bytes = try arena.dupe(u8, bytes),
        .targets = try arena.dupe(SymbolKey, targets),
        .relocs = try arena.dupe(Atom.Reloc, relocs),
    });
    return key;
}

pub fn unitName(emit: *Emit, unit: Zcu.AnalUnit) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(emit.allocator());
    emit.zcu.unitKey(unit, &aw.writer) catch return error.OutOfMemory;
    return aw.written();
}

pub fn funcKey(emit: *Emit, func: Index) !SymbolKey {
    return .fromName(try emit.unitName(.{ .func = func }));
}

/// The key of a declaration's data atom, requesting that it be emitted.
pub fn navKey(emit: *Emit, nav: InternPool.NavIndex) !SymbolKey {
    try emit.navs.put(emit.gpa, nav, {});
    return .fromName(try emit.unitName(.{ .nav_val = nav }));
}

pub fn errorKey(ip: *const InternPool, name: InternPool.String) SymbolKey {
    return errorKeyFromName(ip.stringSlice(name));
}

pub fn errorKeyFromName(name: []const u8) SymbolKey {
    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "error.{s}", .{name}) catch unreachable;
    return .fromName(s);
}

pub fn useError(emit: *Emit, name: InternPool.String) !SymbolKey {
    try emit.errors.put(emit.gpa, name, {});
    return errorKey(&emit.zcu.ip, name);
}

/// Lowers an anonymous constant into its own content-addressed atom.
pub fn uavKey(emit: *Emit, val: Index) !SymbolKey {
    const ip = &emit.zcu.ip;
    const ty = ip.typeOf(val);
    const size = Type.abiSize(ip, ty);
    const bytes = try emit.gpa.alloc(u8, size);
    defer emit.gpa.free(bytes);
    var refs: Atom.RelocList = .{};
    defer refs.deinit(emit.gpa);
    try CodeGen.lowerValue(emit, val, bytes, &refs, 0);
    refs.sort();
    return emit.contentAtom(Type.abiAlignment(ip, ty), bytes, refs.targets.keys(), refs.relocs.items);
}

fn lowerNav(emit: *Emit, nav_index: InternPool.NavIndex) !void {
    const ip = &emit.zcu.ip;
    const nav = ip.getNav(nav_index);
    const ty = ip.typeOf(nav.val);
    if (!Type.hasRuntimeBits(ip, ty)) return;
    emit.owner = .{ .unit = .{ .nav_val = nav_index } };
    defer emit.owner = .link;
    const arena = emit.allocator();
    const bytes = try arena.alloc(u8, Type.abiSize(ip, ty));
    var refs: Atom.RelocList = .{};
    defer refs.deinit(emit.gpa);
    try CodeGen.lowerValue(emit, nav.val, bytes, &refs, 0);
    refs.sort();
    try emit.addAtom(.{
        .key = .fromName(try emit.unitName(.{ .nav_val = nav_index })),
        .name = ip.stringSlice(nav.fqn),
        .section = if (nav.is_const) .rodata else .data,
        .alignment = .fromByteUnits(Type.abiAlignment(ip, ty)),
        .bytes = bytes,
        .targets = try arena.dupe(SymbolKey, refs.targets.keys()),
        .relocs = try arena.dupe(Atom.Reloc, refs.relocs.items),
    });
}
