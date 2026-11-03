//! Turns analyzed functions into Atoms and links them: the sink that
//! `Zcu.analyzeAll` hands each function's IR to. Owns every Atom's memory
//! until the link, lowers the data the code refers to (declarations,
//! anonymous constants), and assigns error codes, which
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
const ElfObject = @import("link/ElfObject.zig");
const CodeGen = @import("codegen/x86_64/CodeGen.zig");
const Ssa = @import("codegen/Ssa.zig");

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
/// External symbols the code reads the address of (`@extern`), by name,
/// and whether every reference is weak. `finish` writes each one's slot.
externs: std.StringArrayHashMapUnmanaged(bool) = .empty,
/// Whether code reads `error_name_table`.
uses_error_names: bool = false,
/// Compile errors that codegen reports (unsupported constructs), rendered
/// like Sema's.
failed: bool = false,
/// The entry symbol, once `finish` found it.
entry: ?SymbolKey = null,
/// Whether the output is a relocatable object (`zap build-obj`): it needs
/// no entry, its exports are symbols for other objects, and symbols it
/// does not define are imported from them.
obj: bool = false,
/// `--stack`: the executable's main thread stack size.
stack_size: u64 = 16 * 1024 * 1024,
/// In an object, the symbols other objects define, by name, and whether
/// every reference is weak.
imports: std.StringArrayHashMapUnmanaged(bool) = .empty,
/// In an object, its exports, once `finish` found them.
exports: std.ArrayList(ElfObject.Export) = .empty,
/// What produced each atom, for the on-disk cache (`Incremental`).
atom_owners: std.ArrayList(Owner) = .empty,
/// Content-addressed atoms each unit referred to.
content_uses: std.ArrayList(ContentUse) = .empty,
/// What each unit's code requested besides its atoms (declarations' data,
/// error codes, external symbols, compiler_rt helpers, the error name
/// table), possibly repeated, for the on-disk cache: a unit loaded from it
/// requests them again.
unit_refs: std.ArrayList(UnitRef) = .empty,
/// The owner of atoms added now.
owner: Owner = .link,
/// `uavKey`'s results, by value and alignment. Each one's lowering
/// requested `uav_refs[refs_start..][0..refs_len]` and used the content
/// atoms `uav_uses[uses_start..][0..uses_len]`, which a later owner of a
/// hit records again, as lowering anew would.
uav_memo: std.AutoHashMapUnmanaged(struct { val: Index, alignment: u64 }, UavMemo) = .empty,
uav_refs: std.ArrayList(@FieldType(UnitRef, "ref")) = .empty,
uav_uses: std.ArrayList(SymbolKey) = .empty,
/// Lowerings in progress that record into `uav_refs` and `uav_uses`.
uav_capturing: u32 = 0,
/// `exportTarget` calls, whose results can change while analysis runs: a
/// lowering that made one is not memoized.
export_lookups: u32 = 0,
/// Whether each owner's atoms are still adjacent in `atoms`; if not,
/// `finish` regroups them (`groupByOwner`).
grouped: bool = true,
/// Units and the link's code that already have atoms, while `grouped`.
units_seen: std.AutoHashMapUnmanaged(Zcu.AnalUnit, void) = .empty,
link_seen: bool = false,
/// The error codes `finish` assigned, for `link`.
error_values: std.ArrayList(Elf.Value) = .empty,
/// Time spent in `CodeGen.generate`, for `ZAP_TIMING`.
codegen_ns: u64 = 0,
/// `ZAP_BENCH_CODEGEN`: a copy of every function's IR, which
/// `benchCodegen` generates again after analysis.
bench_irs: ?std.ArrayList(Ir) = null,
/// The SSA form of the function being generated, reused for the next.
ssa: Ssa = .{},
/// Per-stage backend time and size, for `ZAP_TIMING` and bench-codegen.
codegen_stats: CodeGenStats = .{},

pub const CodeGenStats = struct {
    /// Building the SSA form from the IR.
    build_ns: u64 = 0,
    /// Liveness and register allocation.
    alloc_ns: u64 = 0,
    /// Lowering and encoding the SSA form, and making the Atom.
    emit_ns: u64 = 0,
    functions: u64 = 0,
    ir_insts: u64 = 0,
    /// Machine code of the functions, and their frames' slots and
    /// outgoing argument areas.
    code_bytes: u64 = 0,
    frame_bytes: u64 = 0,

    pub fn print(s: CodeGenStats, label: []const u8) void {
        const per = struct {
            fn f(ns: u64, n: u64) f64 {
                return @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(@max(n, 1)));
            }
        }.f;
        const ms = struct {
            fn f(ns: u64) f64 {
                return @as(f64, @floatFromInt(ns)) / 1e6;
            }
        }.f;
        std.debug.print("{s}: {d} functions, {d} IR instructions; ssa build {d:.1} ms ({d:.1} ns/IR), regalloc {d:.1} ms ({d:.1} ns/IR), emit {d:.1} ms ({d:.1} ns/IR), total {d:.1} ns/IR; {d:.2} code bytes/IR, {d:.0} frame bytes/function\n", .{
            label,
            s.functions,
            s.ir_insts,
            ms(s.build_ns),
            per(s.build_ns, s.ir_insts),
            ms(s.alloc_ns),
            per(s.alloc_ns, s.ir_insts),
            ms(s.emit_ns),
            per(s.emit_ns, s.ir_insts),
            per(s.build_ns + s.alloc_ns + s.emit_ns, s.ir_insts),
            per(s.code_bytes, s.ir_insts),
            per(s.frame_bytes, s.functions),
        });
    }
};

pub const Owner = union(enum) {
    unit: Zcu.AnalUnit,
    /// A content-addressed constant, shared by the units that use it.
    content,
    /// Code the link needs regardless of units (the error name table).
    link,
};

const UavMemo = struct { key: SymbolKey, refs_start: u32, refs_len: u32, uses_start: u32, uses_len: u32 };

pub const ContentUse = struct { unit: Zcu.AnalUnit, key: SymbolKey };

pub const UnitRef = struct {
    unit: Zcu.AnalUnit,
    ref: union(enum) {
        nav: InternPool.NavIndex,
        err: InternPool.String,
        /// `useExtern`; the name is owned by `externs`.
        ext: struct { name: []const u8, weak: bool },
        /// `requestCompilerRt`'s key, owned by `Zcu.rt_helpers`.
        rt: []const u8,
        error_names,
    },
};

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
    emit.externs.deinit(gpa);
    emit.imports.deinit(gpa);
    emit.exports.deinit(gpa);
    emit.atom_owners.deinit(gpa);
    emit.content_uses.deinit(gpa);
    emit.unit_refs.deinit(gpa);
    emit.ssa.deinit(gpa);
    if (emit.bench_irs) |*irs| {
        for (irs.items) |*ir| ir.deinit(gpa);
        irs.deinit(gpa);
    }
    emit.uav_memo.deinit(gpa);
    emit.uav_refs.deinit(gpa);
    emit.uav_uses.deinit(gpa);
    emit.units_seen.deinit(gpa);
    emit.error_values.deinit(gpa);
    emit.arena.deinit();
}

/// Sink callback from `Zcu.analyzeAll`.
pub fn function(emit: *Emit, zcu: *Zcu, ir: *const Ir) !void {
    if (emit.bench_irs) |*irs| {
        var list = ir.instructions.toMultiArrayList();
        try irs.append(emit.gpa, .{
            .instructions = (try list.clone(emit.gpa)).slice(),
            .extra = try emit.gpa.dupe(u32, ir.extra),
            .func = ir.func,
            .main_block = ir.main_block,
            .rbrace_line = ir.rbrace_line,
            .rbrace_column = ir.rbrace_column,
        });
    }
    emit.owner = .{ .unit = .{ .func = ir.func } };
    defer emit.owner = .link;
    const t0 = std.Io.Timestamp.now(zcu.io, .awake);
    defer emit.codegen_ns += @intCast(t0.durationTo(.now(zcu.io, .awake)).nanoseconds);
    CodeGen.generate(emit, ir) catch |err| switch (err) {
        error.CodegenFail => emit.failed = true,
        else => |e| return e,
    };
}

/// `ZAP_BENCH_CODEGEN=n`: generates every function captured during
/// analysis again, `runs` times, each into a fresh Emit, and prints the
/// fastest run's stages. Code generation reads the Zcu without changing
/// what a later build of the same functions produces.
pub fn benchCodegen(emit: *Emit, runs: u32) !void {
    const irs = emit.bench_irs orelse return;
    var best: ?CodeGenStats = null;
    for (0..runs) |_| {
        var e: Emit = .init(emit.gpa, emit.zcu);
        defer e.deinit();
        for (irs.items) |*ir| try e.function(emit.zcu, ir);
        const s = e.codegen_stats;
        if (best == null or s.build_ns + s.alloc_ns + s.emit_ns < best.?.build_ns + best.?.alloc_ns + best.?.emit_ns) best = s;
    }
    if (best) |s| s.print("bench-codegen (fastest run)");
}

/// Lowers the remaining data and orders the atoms for `link`. Returns
/// false (after reporting errors to the Zcu) if it could not. Afterwards
/// the atoms and the Zcu are only read, so the cache can record the build
/// while it links.
pub fn finish(emit: *Emit) !bool {
    const zcu = emit.zcu;
    const ip = &zcu.ip;
    // Before the declarations: a slot can request an exported one.
    if (!try emit.lowerExternSlots()) return false;
    if (emit.obj) try emit.findExports();
    // Lowering a declaration can request more declarations.
    var i: usize = 0;
    while (i < emit.navs.count()) : (i += 1) {
        try emit.lowerNav(emit.navs.keys()[i]);
    }
    if (emit.uses_error_names) try emit.emitErrorNameTable();

    var entry: ?SymbolKey = null;
    for (zcu.exports.items) |e| {
        if (e.target != .nav) continue;
        const nav = ip.getNav(e.target.nav);
        if (nav.status != .resolved) continue;
        if (std.mem.eql(u8, ip.stringSlice(e.name), "_start") and ip.keyTag(nav.val) == .func) {
            entry = try emit.funcKey(nav.val);
        }
    }
    if (emit.failed) return false;
    emit.entry = entry;
    if (entry == null and !emit.obj) {
        try zcu.addError(0, .{ .start = 0, .end = 0, .main = 0 }, "zap requires the root file to export '_start' (std.start is not supported yet)", .{});
        return false;
    }

    if (!emit.grouped) try groupByOwner(emit.gpa, &emit.atoms, &emit.atom_owners, &emit.debug);

    // Error codes: the order names were first interned, starting at 1.
    for (emit.errors.keys()) |name| {
        try emit.error_values.append(emit.gpa, .{ .key = errorKey(ip, name), .value = try ip.errorValue(name) });
    }
    return true;
}

/// Links the atoms `finish` prepared into `sub_path`. Returns false, after
/// printing the error, if the link failed.
pub fn link(emit: *Emit, io: std.Io, dir: std.Io.Dir, sub_path: []const u8) !bool {
    var diag: Elf.Diagnostic = .{};
    // Source paths are as the compiler opened them, relative to the cwd.
    const cwd = try std.process.currentPathAlloc(io, emit.gpa);
    defer emit.gpa.free(cwd);
    const options: Elf.Options = .{ .entry = emit.entry, .values = emit.error_values.items, .diag = &diag, .debug = emit.debug.items, .comp_dir = cwd, .stack_size = emit.stack_size };
    const result = if (emit.obj) obj: {
        const imports = try emit.gpa.alloc(ElfObject.Import, emit.imports.count());
        defer emit.gpa.free(imports);
        for (imports, emit.imports.keys(), emit.imports.values()) |*imp, name, weak| imp.* = .{ .key = importKey(name), .name = name, .weak = weak };
        break :obj ElfObject.link(emit.gpa, io, dir, sub_path, emit.atoms.items, options, .{ .exports = emit.exports.items, .imports = imports });
    } else Elf.link(emit.gpa, io, dir, sub_path, emit.atoms.items, options);
    result catch |err| {
        std.debug.print("error: link failed: {t} (atom '{s}')\n", .{ err, diag.atom });
        return false;
    };
    return true;
}

/// The key of the 8-byte slot holding the address of external symbol
/// `name`, requesting that `finish` write it.
pub fn useExtern(emit: *Emit, name: []const u8, weak: bool) !SymbolKey {
    const gop = try emit.externs.getOrPut(emit.gpa, name);
    if (!gop.found_existing) {
        gop.key_ptr.* = try emit.allocator().dupe(u8, name);
        gop.value_ptr.* = weak;
    } else if (!weak) gop.value_ptr.* = false;
    try emit.addRef(.{ .ext = .{ .name = gop.key_ptr.*, .weak = weak } });
    return externSlotKey(name);
}

/// Records that the current unit's code requested `ref`.
fn addRef(emit: *Emit, ref: @FieldType(UnitRef, "ref")) !void {
    if (emit.owner == .unit) try emit.unit_refs.append(emit.gpa, .{ .unit = emit.owner.unit, .ref = ref });
    if (emit.uav_capturing != 0) try emit.uav_refs.append(emit.gpa, ref);
}

/// Records that the current unit's code used content atom `key`.
fn addContentUse(emit: *Emit, key: SymbolKey) !void {
    if (emit.owner == .unit) try emit.content_uses.append(emit.gpa, .{ .unit = emit.owner.unit, .key = key });
    if (emit.uav_capturing != 0) try emit.uav_uses.append(emit.gpa, key);
}

/// `Zcu.requestCompilerRt` on behalf of the current unit.
pub fn requestCompilerRt(emit: *Emit, file_name: []const u8, name: []const u8) ![]const u8 {
    const key = try emit.zcu.requestCompilerRt(file_name, name);
    try emit.addRef(.{ .rt = key });
    return key;
}

/// `Zcu.requestCompilerRtExport` on behalf of the current unit.
pub fn requestCompilerRtExport(emit: *Emit, name: []const u8) !?[]const u8 {
    const key = try emit.zcu.requestCompilerRtExport(name) orelse return null;
    try emit.addRef(.{ .rt = key });
    return key;
}

/// Requests the error name table, which `@errorName` reads.
pub fn useErrorNames(emit: *Emit) !void {
    emit.uses_error_names = true;
    try emit.addRef(.error_names);
}

fn externSlotKey(name: []const u8) SymbolKey {
    var buf: [256]u8 = undefined;
    return .fromName(std.fmt.bufPrint(&buf, "extern.{s}", .{name}) catch name);
}

/// The key relocations name an imported symbol by (see `useImport`).
fn importKey(name: []const u8) SymbolKey {
    var buf: [256]u8 = undefined;
    return .fromName(std.fmt.bufPrint(&buf, "import.{s}", .{name}) catch name);
}

/// In an object, the key of `name`, which another object defines.
fn useImport(emit: *Emit, name: []const u8, weak: bool) !SymbolKey {
    const gop = try emit.imports.getOrPut(emit.gpa, name);
    if (!gop.found_existing) {
        gop.key_ptr.* = try emit.allocator().dupe(u8, name);
        gop.value_ptr.* = weak;
    } else if (!weak) gop.value_ptr.* = false;
    return importKey(name);
}

/// Collects an object's exports: each name once, as `exportTarget` picks
/// it, and only those with an atom.
fn findExports(emit: *Emit) !void {
    const ip = &emit.zcu.ip;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(emit.gpa);
    for (emit.zcu.exports.items) |x| {
        const name = ip.stringSlice(x.name);
        const key = switch (x.target) {
            .nav => |n| key: {
                const nav = ip.getNav(n);
                if (nav.status != .resolved) continue;
                if (ip.keyTag(nav.val) == .func) break :key try emit.funcKey(nav.val);
                if (!Type.hasRuntimeBits(ip, ip.typeOf(nav.val))) continue;
                break :key try emit.navKey(n);
            },
            .uav => |v| try emit.uavKey(v, 0),
        };
        if ((try seen.getOrPut(emit.gpa, name)).found_existing) continue;
        try emit.exports.append(emit.gpa, .{ .key = key, .name = name });
    }
}

/// Writes the slot of each external symbol: the address of the export of
/// that name, or 0 for an undefined weak symbol; in an object, a symbol
/// that is not exported is imported. Returns false after reporting an
/// undefined strong symbol.
fn lowerExternSlots(emit: *Emit) !bool {
    const zcu = emit.zcu;
    const arena = emit.allocator();
    var ok = true;
    for (emit.externs.keys(), emit.externs.values()) |name, weak| {
        const target = if (emit.obj) try emit.userExport(name) orelse try emit.useImport(name, weak) else try emit.exportTarget(name);
        if (target == null and !weak) {
            try zcu.addError(0, .{ .start = 0, .end = 0, .main = 0 }, "undefined symbol: {s}", .{name});
            ok = false;
            continue;
        }
        const bytes = try arena.alloc(u8, 8);
        @memset(bytes, 0);
        const targets: []const SymbolKey = if (target) |t| try arena.dupe(SymbolKey, &.{t}) else &.{};
        const relocs: []const Atom.Reloc = if (target != null) try arena.dupe(Atom.Reloc, &.{.init(0, .x86_64_abs64, 0, 0)}) else &.{};
        try emit.addAtom(.{
            .key = externSlotKey(name),
            .name = try std.fmt.allocPrint(arena, "extern.{s}", .{name}),
            .section = .rodata,
            .alignment = .@"8",
            .bytes = bytes,
            .targets = targets,
            .relocs = relocs,
        });
    }
    return ok;
}

/// The symbol exported as `name`, or null if there is none. In an object,
/// a symbol that is not exported is imported, as upstream leaves it to the
/// final link; an executable resolves it against compiler_rt, as upstream
/// links it. Complete only once analysis is.
pub fn exportTarget(emit: *Emit, name: []const u8) !?SymbolKey {
    emit.export_lookups += 1;
    if (try emit.userExport(name)) |key| return key;
    if (emit.obj) return try emit.useImport(name, false);
    return if (try emit.zcu.requestCompilerRtExport(name)) |key| .fromName(key) else null;
}

/// The symbol the compilation exports as `name`, or null.
fn userExport(emit: *Emit, name: []const u8) !?SymbolKey {
    const zcu = emit.zcu;
    const ip = &zcu.ip;
    for (zcu.exports.items) |x| {
        if (!std.mem.eql(u8, ip.stringSlice(x.name), name)) continue;
        const x_nav = switch (x.target) {
            .nav => |n| n,
            .uav => |v| return try emit.uavKey(v, 0),
        };
        const nav = ip.getNav(x_nav);
        if (nav.status != .resolved) continue;
        return if (ip.keyTag(nav.val) == .func) try emit.funcKey(nav.val) else try emit.navKey(x_nav);
    }
    return null;
}

pub fn allocator(emit: *Emit) Allocator {
    return emit.arena.allocator();
}

pub fn addAtom(emit: *Emit, atom: Atom) !void {
    try emit.atom_owners.ensureUnusedCapacity(emit.gpa, 1);
    const owners = emit.atom_owners.items;
    if (emit.grouped and (owners.len == 0 or !std.meta.eql(owners[owners.len - 1], emit.owner))) switch (emit.owner) {
        .unit => |u| if ((try emit.units_seen.getOrPut(emit.gpa, u)).found_existing) {
            emit.grouped = false;
        },
        .link => {
            if (emit.link_seen) emit.grouped = false;
            emit.link_seen = true;
        },
        // Each content-addressed atom is its own owner.
        .content => {},
    };
    try emit.atoms.append(emit.gpa, atom);
    emit.atom_owners.appendAssumeCapacity(emit.owner);
}

/// Reorders atoms so that each owner's are adjacent, owners in the order
/// of their first atom, and drops atoms whose key an earlier one has, with
/// their debug entries. That is the list the cache's manifest replays
/// (nodes in the order of their first atom, `Incremental.record`), and the
/// linker lays out atoms in chunks of input positions, so a fresh link of
/// any other order or with duplicates could differ from a relink in
/// padding.
pub fn groupByOwner(gpa: Allocator, atoms: *std.ArrayList(Atom), owners: *std.ArrayList(Owner), debug: *std.ArrayList(Atom.Debug)) !void {
    const Group = union(enum) { unit: Zcu.AnalUnit, content: SymbolKey, link };
    const dropped = std.math.maxInt(u32);
    const n = atoms.items.len;
    const group_of = try gpa.alloc(u32, n);
    defer gpa.free(group_of);
    var groups: std.AutoHashMapUnmanaged(Group, u32) = .empty;
    defer groups.deinit(gpa);
    var keys: std.AutoHashMapUnmanaged(SymbolKey, void) = .empty;
    defer keys.deinit(gpa);
    for (atoms.items, owners.items, group_of) |a, o, *g| {
        if ((try keys.getOrPut(gpa, a.key)).found_existing) {
            g.* = dropped;
            continue;
        }
        const gop = try groups.getOrPut(gpa, switch (o) {
            .unit => |u| .{ .unit = u },
            .content => .{ .content = a.key },
            .link => .link,
        });
        if (!gop.found_existing) gop.value_ptr.* = groups.count() - 1;
        g.* = gop.value_ptr.*;
    }
    // A stable counting sort by group.
    const starts = try gpa.alloc(u32, groups.count() + 1);
    defer gpa.free(starts);
    @memset(starts, 0);
    for (group_of) |g| if (g != dropped) {
        starts[g + 1] += 1;
    };
    for (1..starts.len) |i| starts[i] += starts[i - 1];
    const kept = starts[starts.len - 1];
    const new_index = try gpa.alloc(u32, n);
    defer gpa.free(new_index);
    for (group_of, new_index) |g, *ni| {
        if (g == dropped) {
            ni.* = dropped;
            continue;
        }
        ni.* = starts[g];
        starts[g] += 1;
    }
    const new_atoms = try gpa.alloc(Atom, kept);
    defer gpa.free(new_atoms);
    const new_owners = try gpa.alloc(Owner, kept);
    defer gpa.free(new_owners);
    for (atoms.items, owners.items, new_index) |a, o, ni| if (ni != dropped) {
        new_atoms[ni] = a;
        new_owners[ni] = o;
    };
    @memcpy(atoms.items[0..kept], new_atoms);
    atoms.shrinkRetainingCapacity(kept);
    @memcpy(owners.items[0..kept], new_owners);
    owners.shrinkRetainingCapacity(kept);
    var d_kept: usize = 0;
    for (debug.items) |d| if (new_index[d.atom] != dropped) {
        debug.items[d_kept] = d;
        debug.items[d_kept].atom = new_index[d.atom];
        d_kept += 1;
    };
    debug.shrinkRetainingCapacity(d_kept);
    std.mem.sortUnstable(Atom.Debug, debug.items, {}, struct {
        fn lt(_: void, a: Atom.Debug, b: Atom.Debug) bool {
            return a.atom < b.atom;
        }
    }.lt);
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
    try emit.addContentUse(key);
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
    try emit.addRef(.{ .nav = nav });
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

/// A `[:0]const u8` per error code, for `@errorName` at runtime. It is
/// built after every function is lowered, when the set of errors the
/// program uses is known; codes stay symbolic everywhere else.
pub const error_name_table: SymbolKey = .fromName("__zap_error_names");

fn emitErrorNameTable(emit: *Emit) !void {
    const ip = &emit.zcu.ip;
    const gpa = emit.gpa;
    var max: u32 = 0;
    for (emit.errors.keys()) |name| max = @max(max, try ip.errorValue(name));
    const bytes = try emit.allocator().alloc(u8, (@as(usize, max) + 1) * 16);
    @memset(bytes, 0);
    var refs: Atom.RelocList = .{};
    defer refs.deinit(gpa);
    for (emit.errors.keys()) |name| {
        const s = ip.stringSlice(name);
        const z = try gpa.alloc(u8, s.len + 1);
        defer gpa.free(z);
        @memcpy(z[0..s.len], s);
        z[s.len] = 0;
        const off: u32 = try ip.errorValue(name) * 16;
        try refs.append(gpa, off, .x86_64_abs64, try emit.contentAtom(1, z, &.{}, &.{}), 0);
        std.mem.writeInt(u64, bytes[off + 8 ..][0..8], s.len, .little);
    }
    refs.sort();
    try emit.addAtom(.{
        .key = error_name_table,
        .name = "__zap_error_names",
        .section = .rodata,
        .alignment = .@"8",
        .bytes = bytes,
        .targets = try emit.allocator().dupe(SymbolKey, refs.targets.keys()),
        .relocs = try emit.allocator().dupe(Atom.Reloc, refs.relocs.items),
    });
}

pub fn useError(emit: *Emit, name: InternPool.String) !SymbolKey {
    try emit.errors.put(emit.gpa, name, {});
    try emit.addRef(.{ .err = name });
    return errorKey(&emit.zcu.ip, name);
}

/// Lowers an anonymous constant into its own content-addressed atom,
/// aligned to at least `alignment` (0 for its type's). Memoized: a value's
/// bytes and relocations are the same each time, so a repeated call only
/// records again the uses that lowering it made.
pub fn uavKey(emit: *Emit, val: Index, alignment: u64) !SymbolKey {
    const gpa = emit.gpa;
    if (emit.uav_memo.get(.{ .val = val, .alignment = alignment })) |m| {
        // By index: recording into `uav_refs` and `uav_uses` for an outer
        // lowering can grow them.
        for (m.refs_start..m.refs_start + m.refs_len) |i| {
            const ref = emit.uav_refs.items[i];
            try emit.addRef(ref);
        }
        for (m.uses_start..m.uses_start + m.uses_len) |i| {
            const use = emit.uav_uses.items[i];
            try emit.addContentUse(use);
        }
        try emit.addContentUse(m.key);
        return m.key;
    }
    const ip = &emit.zcu.ip;
    const ty = ip.typeOf(val);
    const size = Type.abiSize(ip, ty);
    const bytes = try gpa.alloc(u8, size);
    defer gpa.free(bytes);
    var refs: Atom.RelocList = .{};
    defer refs.deinit(gpa);
    const refs_start: u32 = @intCast(emit.uav_refs.items.len);
    const uses_start: u32 = @intCast(emit.uav_uses.items.len);
    const lookups = emit.export_lookups;
    {
        emit.uav_capturing += 1;
        defer emit.uav_capturing -= 1;
        try CodeGen.lowerValue(emit, val, bytes, &refs, 0);
    }
    refs.sort();
    const key = try emit.contentAtom(@max(alignment, Type.abiAlignment(ip, ty)), bytes, refs.targets.keys(), refs.relocs.items);
    if (emit.export_lookups == lookups) try emit.uav_memo.put(gpa, .{ .val = val, .alignment = alignment }, .{
        .key = key,
        .refs_start = refs_start,
        .refs_len = @intCast(emit.uav_refs.items.len - refs_start),
        .uses_start = uses_start,
        // Without the use `contentAtom` just recorded for an outer lowering.
        .uses_len = @intCast(emit.uav_uses.items.len - uses_start - @intFromBool(emit.uav_capturing != 0)),
    });
    return key;
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
        .section = if (nav.is_threadlocal) .tdata else if (nav.is_const) .rodata else .data,
        .alignment = .fromByteUnits(if (nav.alignment != 0) nav.alignment else Type.abiAlignment(ip, ty)),
        .bytes = bytes,
        .targets = try arena.dupe(SymbolKey, refs.targets.keys()),
        .relocs = try arena.dupe(Atom.Reloc, refs.relocs.items),
    });
}

test "a relink in the manifest's order reproduces the fresh link, with mixed alignments and duplicates" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cache = @import("cache.zig");
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var atoms: std.ArrayList(Atom) = .empty;
    defer atoms.deinit(gpa);
    var owners: std.ArrayList(Owner) = .empty;
    defer owners.deinit(gpa);
    var debug: std.ArrayList(Atom.Debug) = .empty;
    defer debug.deinit(gpa);
    const alignments = [_]std.mem.Alignment{ .@"1", .@"16", .@"64", .@"8" };

    // Constants, content-addressed: 50, each emitted again later.
    var constants: [50]Atom = undefined;
    for (&constants, 0..) |*c, j| {
        const bytes = try arena.alloc(u8, 1 + j % 13);
        @memset(bytes, @intCast(j));
        const a = alignments[j % 4];
        c.* = .{ .key = .fromContents(.rodata, a, bytes, &.{}, &.{}), .name = "", .section = .rodata, .alignment = a, .bytes = bytes };
    }
    const start: SymbolKey = .fromName("_start");
    try atoms.append(gpa, .{ .key = start, .name = "_start", .section = .text, .bytes = &.{ 0xe8, 0, 0, 0, 0, 0xcc }, .targets = &.{.fromName("f0")}, .relocs = &.{.init(1, .x86_64_pc32, 0, -4)} });
    try owners.append(gpa, .link);
    for (constants) |c| {
        try atoms.append(gpa, c);
        try owners.append(gpa, .content);
    }
    const n = 3000;
    for (0..n) |i| {
        const unit: Zcu.AnalUnit = .{ .func = @fromBackingInt(@intCast(100_000 + i)) };
        const name = try std.fmt.allocPrint(arena, "f{d}", .{i});
        const bytes = try arena.alloc(u8, 5 + i % 37);
        @memset(bytes, 0x90);
        const target = constants[i % constants.len].key;
        try debug.append(gpa, .{ .atom = @intCast(atoms.items.len), .file = "t.zig", .name = name, .base_line = @intCast(i), .lines = &.{}, .frame = .frame_pointer });
        try atoms.append(gpa, .{ .key = .fromName(name), .name = name, .section = .text, .alignment = alignments[i % 3], .bytes = bytes, .targets = try arena.dupe(SymbolKey, &.{target}), .relocs = &.{.init(1, .x86_64_pc32, 0, -4)} });
        try owners.append(gpa, .{ .unit = unit });
        if (i % 7 == 0) {
            try atoms.append(gpa, constants[i % constants.len]);
            try owners.append(gpa, .content);
        }
        // A unit's second atom, after other units' atoms.
        if (i % 11 == 10) {
            const extra = try std.fmt.allocPrint(arena, "data{d}", .{i});
            try atoms.append(gpa, .{ .key = .fromName(extra), .name = extra, .section = .data, .alignment = alignments[i % 4], .bytes = try arena.dupe(u8, "abcdefgh") });
            try owners.append(gpa, .{ .unit = .{ .func = @fromBackingInt(@intCast(100_000 + i - 5)) } });
        }
    }
    try atoms.append(gpa, .{ .key = .fromName("tail"), .name = "tail", .section = .bss, .alignment = .@"64", .zero_fill = 100 });
    try owners.append(gpa, .link);

    const ungrouped = try Elf.emit(gpa, io, atoms.items, .{ .entry = start, .debug = debug.items });
    defer gpa.free(ungrouped);
    try groupByOwner(gpa, &atoms, &owners, &debug);
    const fresh = try Elf.emit(gpa, io, atoms.items, .{ .entry = start, .debug = debug.items });
    defer gpa.free(fresh);
    // The input order matters to the layout, which is why both builds
    // link one order.
    try std.testing.expect(!std.mem.eql(u8, ungrouped, fresh));

    // Grouped and deduplicated: no key twice, each owner's atoms adjacent.
    var keys: std.AutoHashMapUnmanaged(SymbolKey, void) = .empty;
    defer keys.deinit(gpa);
    var closed: std.AutoHashMapUnmanaged(Zcu.AnalUnit, void) = .empty;
    defer closed.deinit(gpa);
    for (atoms.items, owners.items, 0..) |a, o, i| {
        try std.testing.expect(!(try keys.getOrPut(gpa, a.key)).found_existing);
        if (i > 0 and std.meta.eql(owners.items[i - 1], o)) continue;
        if (i > 0) if (owners.items[i - 1] == .unit) try closed.put(gpa, owners.items[i - 1].unit, {});
        if (o == .unit) try std.testing.expect(!closed.contains(o.unit));
    }

    // Record as `Incremental.record` does, one node per owner, and relink
    // from the pack with the manifest's numbered symbols.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pack: cache.Pack = try .create(io, tmp.dir);
    defer pack.close(gpa, io);
    const refs = try gpa.alloc(cache.Pack.AtomRef, atoms.items.len);
    defer gpa.free(refs);
    try pack.append(gpa, io, atoms.items, debug.items, refs);
    {
        var b: cache.Manifest.Builder = .{ .gpa = gpa };
        defer b.deinit();
        var symbols: std.ArrayList(cache.Manifest.AtomSymbols) = .empty;
        defer symbols.deinit(gpa);
        var next_debug: usize = 0;
        var first: usize = 0;
        for (atoms.items, 0..) |a, i| {
            const file: ?[]const u8 = if (next_debug < debug.items.len and debug.items[next_debug].atom == i) f: {
                next_debug += 1;
                break :f "t.zig";
            } else null;
            try symbols.append(gpa, .{ .key = @backingInt(a.key), .targets = @ptrCast(a.targets), .file = file });
            if (i + 1 < atoms.items.len and std.meta.eql(owners.items[i + 1], owners.items[i]) and owners.items[i] != .content) continue;
            _ = try b.addNode(.{ .key = i, .result_hash = 0, .atoms = refs[first .. i + 1], .symbols = symbols.items });
            symbols.clearRetainingCapacity();
            first = i + 1;
        }
        b.entry = @backingInt(start);
        try b.write(io, tmp.dir, pack.id);
    }
    var m = (try cache.Manifest.open(gpa, io, tmp.dir)).?;
    defer m.close(gpa, io);
    const in = try m.linkInput(gpa);
    const input = try pack.linkAtoms(gpa, in.refs, in.debug_atoms, .{ .of = in.debug_files, .names = &.{m.file(0)} });
    defer input.deinit(gpa);
    const relinked = try Elf.emitInput(gpa, io, input, .{
        .entry = start,
        .symbols = .{ .atoms = in.numbered, .targets = in.targets, .targets_tail = in.targets_tail, .entry = m.entry_symbol, .len = m.symbolLen() },
    });
    defer gpa.free(relinked);
    try std.testing.expectEqualSlices(u8, fresh, relinked);
}
