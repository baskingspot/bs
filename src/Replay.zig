//! An edit build's use of the last build's results (see "Edit builds:
//! replaying cached results" in docs/architecture.md). Zcu asks `load*`
//! before it analyzes a unit; a green unit's result is written into the
//! Zcu instead, and its function's atoms come from the pack.
//!
//! A unit is green if the manifest has it with a result, its source hash
//! is unchanged, and, if an edited input reaches it over reverse edges
//! (`outdated`), each of its dependencies has its recorded result after
//! being brought up to date. Every dependency of a green unit is brought
//! up to date (loaded or analyzed) and recorded as this build's, so the
//! build ends with the same Zcu state a full build would have, and records
//! a whole new manifest from it as a full build does.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Zir = std.zig.Zir;
const cache = @import("cache.zig");
const inline_ir = @import("codegen/inline.zig");
const Manifest = cache.Manifest;
const Pack = cache.Pack;
const results = cache.results;
const print = @import("Ir/print.zig");
const seeds = cache.seeds;
const Hash = cache.Hash;
const Frontend = @import("Frontend.zig");
const InternPool = @import("InternPool.zig");
const Zcu = @import("Zcu.zig");
const Emit = @import("Emit.zig");
const Atom = @import("link/Atom.zig");
const Incremental = @import("Incremental.zig");
const Sema = @import("Sema.zig");
const Tag = Incremental.Tag;
const Index = InternPool.Index;

const Replay = @This();

gpa: Allocator,
io: Io,
zcu: *Zcu,
emit: *Emit,
m: *const Manifest,
/// The last build's packs, mapped while the build's atoms point into them.
pack: Pack,
/// The target's unwind record format, to decode the packs' atoms.
arch: Atom.Unwind.Arch,
/// Nodes an edit reaches over reverse edges.
outdated: std.DynamicBitSetUnmanaged,
state: []State,
/// Inputs whose contents changed, with their instruction maps.
maps: seeds.InstMaps = .{},
/// Changed inputs `lateMap` tried to map.
late_mapped: std.AutoHashMapUnmanaged(u32, void) = .empty,
/// Whether `lateMap` failed for one, whose old ZIR was gone (the global
/// cache's maintenance can evict superseded ZIR at any time): its nodes'
/// subjects cannot be made, which a lazy build cannot express, so it
/// builds again eagerly (`Incremental.finishLazy`).
late_unmapped: bool = false,
/// Nodes in compiler_rt files not loaded yet that an edit reached, which
/// `settle` walks once their file loads (`walkNode`).
rt_waiting: std.ArrayList(u32) = .empty,
/// (namespace node, requester node) of those that are files' namespaces.
rt_effects: std.ArrayList([2]u32) = .empty,
changed: std.ArrayList(seeds.Changed) = .empty,
/// Each input's file in this build, once looked up: its index + 1, or 0
/// if not looked up yet, or `no_file`.
input_files: []u32,
/// How many of the frontend's files the `no_file` entries of
/// `input_files` looked among: compiler_rt's files load during analysis.
input_files_seen: usize = 0,
/// Each file's input, once looked up.
file_inputs: std.AutoHashMapUnmanaged(u32, u32) = .empty,
/// Inputs by path.
by_path: std.StringHashMapUnmanaged(u32) = .empty,
/// Each node's dependee, once decoded (`dependee`).
dependees: []?Zcu.Dependee,
/// Units' nodes, as their subjects were decoded.
unit_nodes: std.AutoHashMapUnmanaged(Zcu.AnalUnit, u32) = .empty,
decoder: results.Decoder(Resolver),
keyer: Incremental.Keyer,
/// Declarations by `Atom.SymbolKey.fromName(nav.key)`, to refresh inlined
/// callees' lines: those of the first `navs_indexed` namespaces.
navs_by_key: std.AutoHashMapUnmanaged(Atom.SymbolKey, InternPool.NavIndex) = .empty,
navs_indexed: usize = 0,
deps: std.ArrayList(Zcu.Dependee) = .empty,
/// A lazy edit build (step 4b): green units are not loaded unless an
/// analysis reads them, and their functions' atoms stay in the pack; the
/// build records only what changed (`Incremental.recordLazy`). Otherwise
/// every unit the build reaches is loaded or analyzed (step 4a).
lazy: bool = false,
/// Why a donor's build that asked to be lazy replays eagerly instead
/// (`donorEager`).
eager_why: ?[]const u8 = null,
/// The nodes `walk` reached: the units a full build would analyze, whose
/// atoms the build links.
visited: std.DynamicBitSetUnmanaged = .{},
walk_stack: std.ArrayList(u32) = .empty,
/// Green units whose results are in the Zcu.
loaded: std.DynamicBitSetUnmanaged = .{},
/// Declarations whose data a live node refers to (`walk`), which a red
/// one's must be lowered again for.
data_refs: std.DynamicBitSetUnmanaged = .{},
/// Nodes whose subject is gone: what they were about no longer exists.
dead: std.DynamicBitSetUnmanaged = .{},
/// Green functions whose line information may have moved: they or a
/// function they inline are in a changed input (`Incremental.refreshDebug`).
refresh: std.DynamicBitSetUnmanaged = .{},
stats: Stats = .{},
/// `ZAP_CACHE_CHECK`: print each green unit that could not be loaded.
check: bool = false,
/// `ZAP_CACHE_TIMING`: say why the build is built again in full.
timing: bool = false,
/// By stable hash, each type the manifest's units offered names
/// (`contributeNames`): its recorded name, from the offer that won, and
/// the least creator's offer among the units this build kept.
type_names: std.AutoArrayHashMapUnmanaged(InternPool.Hash, NameEntry) = .empty,
/// The log's nodes' offers, by type (`collectOffers`): the manifest's
/// index has only the base's.
log_offers: std.AutoHashMapUnmanaged(InternPool.Hash, std.ArrayList(u32)) = .empty,
/// By stable hash, the types whose names, or the offers that give them,
/// differ from when they were recorded (`contributeNames`).
renamed: std.AutoArrayHashMapUnmanaged(InternPool.Hash, void) = .empty,
/// File root types by stable hash, which no unit offers names
/// (`finalName`), made on first use.
root_types: ?std.AutoHashMapUnmanaged(InternPool.Hash, u32) = null,
/// For a donor's replay (`Incremental.useDonor`): the source paths this
/// build's debug info can name (`Atom.Debug.file`, `unit`, `files`). A
/// donor's function whose debug info names another path (the same source
/// in another project's directory) is analyzed again.
debug_paths: ?std.StringHashMapUnmanaged(void) = null,
/// How many of the frontend's files `debug_paths` has.
debug_paths_files: usize = 0,

const no_file = std.math.maxInt(u32);

pub const State = enum(u8) { unknown, green, red };

pub const NameEntry = struct {
    won: ?[]const u8 = null,
    /// The creator of the offer that won.
    won_creator: InternPool.Hash = 0,
    best: ?results.Names.Offer = null,
    /// The base nodes whose offers `collectOffers` reads: the least kept
    /// creator's and the winner's.
    best_node: u32 = std.math.maxInt(u32),
    won_node: u32 = std.math.maxInt(u32),
    /// `finalName`'s, once rendered.
    final: ?[]const u8 = null,
    rendering: bool = false,
};

pub const Stats = struct {
    seeds: u32 = 0,
    outdated: u32 = 0,
    changed_inputs: u32 = 0,
    loaded: u32 = 0,
    loaded_funcs: u32 = 0,
    red: u32 = 0,
    red_changed: u32 = 0,
    new: u32 = 0,
    misses: u32 = 0,
    setup_ns: u64 = 0,
};

/// Starts an edit build from manifest `m`: finds the inputs that changed
/// since, the seeds, and what they reach. `fe` has loaded the files.
pub fn create(gpa: Allocator, io: Io, m: *const Manifest, dir: Io.Dir, arch: Atom.Unwind.Arch, fe: *const Frontend, zcu: *Zcu, emit: *Emit, lazy: bool, donor: bool) !*Replay {
    const t0 = Io.Timestamp.now(io, .awake);
    var pack: Pack = try .open(io, dir);
    errdefer pack.close(gpa, io);
    // A donor's atoms are all in its base packs (`Incremental.useDonor`).
    if (!donor and pack.id != m.pack_id) return error.PackMismatch;
    for (0..m.bases.len) |i| _ = try pack.addBase(gpa, io, dir, m.basePack(i));
    const n = m.nodeCount();
    const r = try gpa.create(Replay);
    errdefer gpa.destroy(r);
    r.* = .{
        .gpa = gpa,
        .io = io,
        .zcu = zcu,
        .emit = emit,
        .m = m,
        .pack = pack,
        .arch = arch,
        .outdated = try .initEmpty(gpa, n),
        .state = try gpa.alloc(State, n),
        .dependees = try gpa.alloc(?Zcu.Dependee, n),
        .input_files = try gpa.alloc(u32, m.inputCount()),
        .decoder = try .init(gpa, &zcu.ip, m.resultItems(), .{ .r = undefined }),
        .keyer = .init(zcu, gpa),
        .lazy = lazy,
        .visited = try .initEmpty(gpa, n),
        .loaded = try .initEmpty(gpa, n),
        .data_refs = try .initEmpty(gpa, n),
        .dead = try .initEmpty(gpa, n),
        .refresh = try .initEmpty(gpa, n),
    };
    r.decoder.resolver = .{ .r = r };
    @memset(r.state, .unknown);
    @memset(r.dependees, null);
    @memset(r.input_files, 0);

    // Each loaded file's input, and the inputs that changed.
    for (0..m.inputCount()) |i| _ = try r.by_path.getOrPutValue(gpa, m.input(@intCast(i))[1], @intCast(i));
    var path_buf: std.ArrayList(u8) = .empty;
    defer path_buf.deinit(gpa);
    const changed = &r.changed;
    var seen = try std.DynamicBitSetUnmanaged.initEmpty(gpa, m.inputCount());
    defer seen.deinit(gpa);
    // Files match inputs by key (`Manifest.Input.key`), which is what the
    // nodes name them by: within a compilation keys and paths correspond,
    // and a donor's file (`Incremental.useDonor`) is this build's file
    // with the same key wherever it is, such as in another git worktree.
    var by_key: std.StringHashMapUnmanaged(u32) = .empty;
    defer by_key.deinit(gpa);
    for (0..m.inputCount()) |i| _ = try by_key.getOrPutValue(gpa, m.inputKey(@intCast(i)), @intCast(i));
    var key_buf: std.ArrayList(u8) = .empty;
    defer key_buf.deinit(gpa);
    // Whether a donor has inputs this build lacks.
    var missing = false;
    for (fe.files.items, 0..) |*f, fi| {
        try Incremental.inputKey(gpa, &key_buf, fe, f.module, f.sub_path);
        const i = by_key.get(key_buf.items) orelse continue;
        seen.set(i);
        r.input_files[i] = @intCast(fi + 1);
        try r.file_inputs.put(gpa, @intCast(fi), i);
        if (@as(Hash, @bitCast(f.content_hash)) != m.input(i)[0].content_hash)
            try changed.append(gpa, .{ .input = i, .file = @fromBackingInt(@as(u32, @intCast(fi))) });
    }
    // Inputs whose key names no file here: a donor's other project's
    // files, or a module this build lacks. Changed, so that their nodes
    // are outdated, whether or not the file is still on disk; inputs not
    // loaded yet whose key holds here are checked below.
    for (0..m.inputCount()) |i| {
        // Link-only inputs: no node depends on them.
        if (Incremental.isLinkInput(m.inputKey(@intCast(i)))) seen.set(i);
        if (seen.isSet(i) or try Incremental.inputKeyHolds(gpa, &path_buf, m, @intCast(i), fe)) continue;
        seen.set(i);
        missing = true;
        try changed.append(gpa, .{ .input = @intCast(i), .file = null });
    }
    // Inputs not loaded yet (embedded files, compiler_rt), by their stat
    // and then their contents.
    var stat_changed: std.ArrayList(u32) = .empty;
    defer stat_changed.deinit(gpa);
    try m.changedInputs(gpa, io, &stat_changed);
    for (stat_changed.items) |i| {
        if (seen.isSet(i)) continue;
        const in, const path = m.input(i);
        const same = same: {
            const src = Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch break :same false;
            defer gpa.free(src);
            break :same @as(Hash, @bitCast(Frontend.hashSource(src))) == in.content_hash;
        };
        if (!same) try changed.append(gpa, .{ .input = i, .file = null });
    }
    r.stats.changed_inputs = @intCast(changed.items.len);

    var seed_list: std.ArrayList(u32) = .empty;
    defer seed_list.deinit(gpa);
    _ = try seeds.compute(gpa, m, fe, changed.items, &seed_list, &r.maps);
    r.stats.seeds = @intCast(seed_list.items.len);
    var stack = seed_list;
    seed_list = .empty;
    defer stack.deinit(gpa);
    // Nodes an earlier lazy build left unchecked, as if edited again.
    if (lazy) for (0..n) |i| if (m.flags(@intCast(i)).stale) try stack.append(gpa, @intCast(i));
    for (stack.items) |i| r.outdated.set(i);
    while (stack.pop()) |i| for (m.rdeps(i)) |part| for (part) |d| if (!r.outdated.isSet(d)) {
        r.outdated.set(d);
        try stack.append(gpa, d);
    };
    r.stats.outdated = @intCast(r.outdated.count());
    if (donor) {
        r.debug_paths = .empty;
        const d = &r.debug_paths.?;
        for (fe.modules.items) |*mod| {
            const unit = try std.fs.path.join(gpa, &.{ mod.root_dir, mod.root_file });
            const gop = d.getOrPut(gpa, unit) catch |err| {
                gpa.free(unit);
                return err;
            };
            if (gop.found_existing) gpa.free(unit);
        }
    }
    if (donor and lazy) if (try r.donorEager(fe, missing)) |why| {
        r.lazy = false;
        r.eager_why = why;
    } else {
        // Its log's atoms go to a pack of this compilation's own, under
        // the id the donor's manifest names: the donor's own pack holds
        // none of its atoms.
        const own: ?Pack = own: {
            Pack.writeEmpty(io, dir, m.pack_id) catch break :own null;
            var p = Pack.open(io, dir) catch break :own null;
            for (0..m.bases.len) |i| _ = p.addBase(gpa, io, dir, m.basePack(i)) catch {
                p.close(gpa, io);
                break :own null;
            };
            break :own p;
        };
        if (own) |p| {
            r.pack.close(gpa, io);
            r.pack = p;
        } else {
            r.lazy = false;
            r.eager_why = "its pack could not be made";
        }
    };
    r.stats.setup_ns = @intCast(t0.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds);
    return r;
}

/// Why a donor's build must replay eagerly, or null if it can be lazy and
/// log what differs from the donor (`Incremental.finishLazy`): the
/// donor's inputs this build lacks, or debug paths this build does not
/// write (`Incremental.donorPathsKnown`).
fn donorEager(r: *Replay, fe: *const Frontend, missing: bool) !?[]const u8 {
    if (missing) return "the donor has files this build lacks";
    for (r.m.atom_refs) |ref| if (ref.pack == 0) return "the donor's atoms are not all in store packs";
    if (!try Incremental.donorPathsKnown(r.gpa, r.m, fe)) return "the donor's debug info names paths this build does not";
    return null;
}

pub fn destroy(r: *Replay) void {
    const gpa = r.gpa;
    r.pack.close(gpa, r.io);
    r.outdated.deinit(gpa);
    r.visited.deinit(gpa);
    r.walk_stack.deinit(gpa);
    r.loaded.deinit(gpa);
    r.type_names.deinit(gpa);
    r.renamed.deinit(gpa);
    if (r.root_types) |*m| m.deinit(gpa);
    {
        var it = r.log_offers.valueIterator();
        while (it.next()) |l| l.deinit(gpa);
        r.log_offers.deinit(gpa);
    }
    r.data_refs.deinit(gpa);
    r.dead.deinit(gpa);
    r.refresh.deinit(gpa);
    r.late_mapped.deinit(gpa);
    r.rt_waiting.deinit(gpa);
    r.rt_effects.deinit(gpa);
    if (r.debug_paths) |*d| {
        var it = d.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        d.deinit(gpa);
    }
    gpa.free(r.state);
    gpa.free(r.dependees);
    r.maps.deinit(gpa);
    r.changed.deinit(gpa);
    gpa.free(r.input_files);
    r.file_inputs.deinit(gpa);
    r.by_path.deinit(gpa);
    r.unit_nodes.deinit(gpa);
    r.decoder.deinit();
    r.keyer.deinit();
    r.navs_by_key.deinit(gpa);
    r.deps.deinit(gpa);
    gpa.destroy(r);
}

pub fn printStats(r: *const Replay) void {
    const s = r.stats;
    std.debug.print("cache: replayed {d} units ({d} functions) from the last build; analyzed {d} again ({d} changed, {d} not decodable) and {d} new; {d} inputs changed, {d} seeds reach {d} of {d} nodes; setup {d:.2} ms\n", .{
        s.loaded, s.loaded_funcs, s.red, s.red_changed, s.misses, s.new, s.changed_inputs, s.seeds, s.outdated, r.m.nodeCount(), @as(f64, @floatFromInt(s.setup_ns)) / 1e6,
    });
    if (r.lazy) std.debug.print("cache: the walk reached {d} nodes; {d} are gone\n", .{ r.visited.count(), r.dead.count() });
}

// ---------------------------------------------------------------------------
// The hook

/// `Zcu.ensureNavVal`, with the declaration marked in progress: whether
/// its value was loaded.
pub fn loadNav(r: *Replay, nav_index: InternPool.NavIndex) bool {
    return r.loadNavFallible(nav_index) catch false;
}

fn loadNavFallible(r: *Replay, nav_index: InternPool.NavIndex) !bool {
    const unit: Zcu.AnalUnit = .{ .nav_val = nav_index };
    const g = try r.greenNode(unit) orelse return false;
    errdefer r.deps.shrinkRetainingCapacity(g.deps_start);
    const got = try results.decodeNav(&r.decoder, r.m.result(g.node)) orelse return r.miss(g, "result");
    const refs: []const Ref = if (r.lazy) &.{} else try r.resolveRefs(g, false) orelse return r.miss(g, "references");
    defer r.gpa.free(refs);
    const nav = r.zcu.ip.getNav(nav_index);
    nav.ty = got.ty;
    nav.val = got.val;
    nav.is_const = got.is_const;
    nav.is_threadlocal = got.is_threadlocal;
    nav.linkage = got.linkage;
    nav.alignment = got.alignment;
    try r.commit(unit, g, refs);
    return true;
}

/// `Zcu.ensureStructLayout`, with the layout marked in progress: whether
/// it was loaded.
pub fn loadLayout(r: *Replay, ty: Index) bool {
    return r.loadLayoutFallible(ty) catch false;
}

fn loadLayoutFallible(r: *Replay, ty: Index) !bool {
    const unit: Zcu.AnalUnit = .{ .type_layout = ty };
    const g = try r.greenNode(unit) orelse return false;
    errdefer r.deps.shrinkRetainingCapacity(g.deps_start);
    const info = r.zcu.ip.structInfo(ty);
    const got = try results.decodeLayout(&r.decoder, r.zcu.ip.arena(Zcu.tid), r.m.result(g.node)) orelse return r.miss(g, "result");
    if (got.status != .have_layout) return r.miss(g, "no layout");
    const refs: []const Ref = if (r.lazy) &.{} else try r.resolveRefs(g, false) orelse return r.miss(g, "references");
    defer r.gpa.free(refs);
    // A struct's non-`comptime` defaults are the `struct_defaults` unit's
    // (a reified struct has them already).
    if (info.defaults_status == .resolved and r.zcu.ip.indexToKey(ty) == .struct_type and info.field_defaults.len == got.field_defaults.len) {
        for (@constCast(got.field_defaults), info.field_defaults, 0..) |*d, old, i| {
            if (!(got.field_is_comptime.len != 0 and got.field_is_comptime[i])) d.* = old;
        }
    }
    const namespace = info.namespace;
    const defaults_status = info.defaults_status;
    info.* = got;
    info.namespace = namespace;
    info.defaults_status = defaults_status;
    try r.commit(unit, g, refs);
    return true;
}

/// `Zcu.ensureStructDefaults`, with the defaults marked in progress:
/// whether they were loaded.
pub fn loadDefaults(r: *Replay, ty: Index) bool {
    return r.loadDefaultsFallible(ty) catch false;
}

fn loadDefaultsFallible(r: *Replay, ty: Index) !bool {
    const unit: Zcu.AnalUnit = .{ .struct_defaults = ty };
    const g = try r.greenNode(unit) orelse return false;
    errdefer r.deps.shrinkRetainingCapacity(g.deps_start);
    const got = try results.decodeDefaults(&r.decoder, r.gpa, r.m.result(g.node)) orelse return r.miss(g, "result");
    defer r.gpa.free(got.defaults);
    const info = r.zcu.ip.structInfo(ty);
    if (!got.resolved or got.defaults.len != info.field_defaults.len) return r.miss(g, "defaults");
    const refs: []const Ref = if (r.lazy) &.{} else try r.resolveRefs(g, false) orelse return r.miss(g, "references");
    defer r.gpa.free(refs);
    const defaults = try r.zcu.ip.arena(Zcu.tid).dupe(Index, info.field_defaults);
    for (defaults, got.defaults, 0..) |*d, v, i| {
        if (!info.fieldIsComptime(i)) d.* = v;
    }
    info.field_defaults = defaults;
    try r.commit(unit, g, refs);
    return true;
}

/// `Zcu.analyzeAll`'s `comptime` declaration: whether it was loaded (it
/// has no result; its dependencies and references are this build's).
pub fn loadComptime(r: *Replay, c: Zcu.ComptimeDecl) bool {
    return r.loadComptimeFallible(c) catch false;
}

fn loadComptimeFallible(r: *Replay, c: Zcu.ComptimeDecl) !bool {
    const unit: Zcu.AnalUnit = .{ .comptime_decl = c };
    const g = try r.greenNode(unit) orelse return false;
    errdefer r.deps.shrinkRetainingCapacity(g.deps_start);
    if (r.lazy) {
        try r.commitLazy(g, false);
        return true;
    }
    const refs = try r.resolveRefs(g, false) orelse return r.miss(g, "references");
    defer r.gpa.free(refs);
    try r.commit(unit, g, refs);
    return true;
}

/// A queued function's body, from `Zcu.analyzeAll` or
/// `Zcu.ensureFuncIes`, marked in progress: whether it was loaded (its
/// atoms are in Emit, its inferred errors set, its references requested).
pub fn loadFunc(r: *Replay, func: Index) bool {
    return r.loadFuncFallible(func) catch false;
}

fn loadFuncFallible(r: *Replay, func: Index) !bool {
    const zcu = r.zcu;
    const ip = &zcu.ip;
    const m = r.m;
    const unit: Zcu.AnalUnit = .{ .func = func };
    const g = try r.greenNode(unit) orelse return false;
    errdefer r.deps.shrinkRetainingCapacity(g.deps_start);
    if (m.atoms(g.node).len == 0 or m.flags(g.node).unlinked) return r.miss(g, "no atoms");
    // The inferred error set, if the function has one: from its node,
    // which every non-empty set has (`Incremental.record`), so no node
    // means an empty set.
    const f = ip.indexToKey(func).func;
    var ies: ?results.IesResult = null;
    const owner = ip.getNav(f.owner_nav);
    const zir = &zcu.file(owner.file).zir;
    const has_ies = switch (zir.instructions.items(.tag)[@backingInt(f.zir_inst)]) {
        .func_inferred => true,
        .func_fancy => zir.extraData(Zir.Inst.FuncFancy, zir.instructions.items(.data)[@backingInt(f.zir_inst)].pl_node.payload_index).data.bits.is_inferred_error,
        else => false,
    };
    if (has_ies) {
        if (m.find(try r.keyer.keyOf(.func_ies, &.{try r.keyer.unitKeyString(unit)}))) |ies_node| {
            const words = m.result(ies_node);
            if (words.len == 0) return r.miss(g, "inferred errors");
            ies = try results.decodeIes(ip, zcu.arena.allocator(), words);
        }
    }
    // Whether it is inlinable, from its node, which every inlinable
    // function has (`Incremental.record`).
    var inline_result: ?Zcu.InlineResult = null;
    if (zcu.inline_salt != 0) if (m.find(try r.keyer.keyOf(.func_inline, &.{try r.keyer.unitKeyString(unit)}))) |n| {
        const words = m.result(n);
        if (words.len == 1) inline_result = .{ .size = words[0], .hash = m.node(n).result_hash };
    };
    if (r.lazy) {
        if (ies) |got| {
            if (got.is_anyerror) try zcu.anyerror_ies.put(zcu.gpa, func, {});
            if (!got.is_anyerror or got.names.len != 0) try zcu.inferred_errors.put(zcu.gpa, func, got.names);
        }
        try r.commitLazy(g, false);
        if (inline_result) |res| try zcu.inline_results.put(zcu.gpa, func, res);
        r.stats.loaded_funcs += 1;
        return true;
    }
    // The atoms, decoded before anything is committed.
    var atoms: std.ArrayList(struct { atom: Atom, debug: ?Atom.Debug }) = .empty;
    defer atoms.deinit(r.gpa);
    const changed_file = r.isChangedFile(owner.file);
    // Records keep no names: the manifest does.
    const names = m.atomNames(g.node);
    for (m.atoms(g.node), 0..) |ref, k| {
        var d = r.pack.decode(ref, r.arch) catch return r.miss(g, "atom");
        d.atom.name = names.name(k);
        var debug = d.debug;
        if (debug) |*dbg| {
            if (!try r.knowsDebugPaths(dbg)) return r.miss(g, "debug paths");
            if (changed_file) dbg.base_line = zcu.file(owner.file).zir.getDeclaration(owner.zir_inst).src_line;
            if (dbg.inlines.len != 0) dbg.inlines = try r.refreshInlines(dbg) orelse return r.miss(g, "inlined callee's line");
        }
        try atoms.append(r.gpa, .{ .atom = d.atom, .debug = debug });
    }
    var content: std.ArrayList(Atom) = .empty;
    defer content.deinit(r.gpa);
    for (m.deps(g.node)) |e| {
        const d = Manifest.Edge.nodeOf(e);
        if (m.node(d).tag != @backingInt(Tag.content)) continue;
        const content_names = m.atomNames(d);
        for (m.atoms(d), 0..) |ref, k| {
            var a = (r.pack.decode(ref, r.arch) catch return r.miss(g, "content atom")).atom;
            a.name = content_names.name(k);
            try content.append(r.gpa, a);
        }
    }
    const refs = try r.resolveRefs(g, true) orelse return r.miss(g, "references");
    defer r.gpa.free(refs);

    if (ies) |got| {
        // An `anyerror` set keeps the names found before it became one.
        if (got.is_anyerror) try zcu.anyerror_ies.put(zcu.gpa, func, {});
        if (!got.is_anyerror or got.names.len != 0) try zcu.inferred_errors.put(zcu.gpa, func, got.names);
    }
    const emit = r.emit;
    const saved = emit.owner;
    defer emit.owner = saved;
    emit.owner = .{ .unit = unit };
    for (atoms.items) |a| {
        if (a.debug) |d| try emit.addFunction(a.atom, d) else try emit.addAtom(a.atom);
    }
    // The constants the code uses, unless this build emitted them already.
    for (content.items) |a| {
        try emit.content_uses.append(emit.gpa, .{ .unit = unit, .key = a.key });
        if ((try emit.content_keys.getOrPut(emit.gpa, a.key)).found_existing) continue;
        emit.owner = .content;
        defer emit.owner = .{ .unit = unit };
        try emit.addAtom(a);
    }
    try r.commit(unit, g, refs);
    if (inline_result) |res| try zcu.inline_results.put(zcu.gpa, func, res);
    r.stats.loaded_funcs += 1;
    return true;
}

/// Inlined callees' base lines, for those in changed files, as CodeGen
/// would now write them; null if a callee in a changed file has no
/// declaration in this build yet (one in a container a green unit makes,
/// such as a struct in a test), whose line is then unknown.
pub fn refreshInlines(r: *Replay, d: *const Atom.Debug) !?[]const Atom.Debug.Inline {
    const zcu = r.zcu;
    var out: ?[]Atom.Debug.Inline = null;
    for (d.inlines, 0..) |in, i| {
        const nav_index = (try r.navByKey(d.inline_callees[i])) orelse {
            if (r.isChangedPath(debugPath(d, in.file))) return null;
            continue;
        };
        const nav = zcu.ip.getNav(nav_index);
        if (!r.isChangedFile(nav.file)) continue;
        const line = zcu.file(nav.file).zir.getDeclaration(nav.zir_inst).src_line;
        if (line == in.base_line) continue;
        if (out == null) out = try r.emit.allocator().dupe(Atom.Debug.Inline, d.inlines);
        out.?[i].base_line = line;
    }
    return out orelse d.inlines;
}

/// The declaration whose key is `key`, among the namespaces created so far.
fn navByKey(r: *Replay, key: Atom.SymbolKey) !?InternPool.NavIndex {
    const zcu = r.zcu;
    for (zcu.namespaces.items[r.navs_indexed..]) |*ns| for (ns.decls.values()) |n| {
        try r.navs_by_key.put(r.gpa, .fromName(zcu.ip.stringSlice(zcu.ip.getNav(n).key)), n);
    };
    r.navs_indexed = zcu.namespaces.items.len;
    return r.navs_by_key.get(key);
}

/// Path `file` of the files debug info `d` names: 0 is its own.
fn debugPath(d: *const Atom.Debug, file: u32) []const u8 {
    if (file == 0) return d.file;
    var it = std.mem.splitScalar(u8, d.files, 0);
    for (1..file) |_| _ = it.next();
    return it.next() orelse "";
}

/// Whether the file with display path `path` changed, or is unknown. A
/// file the frontend has not loaded (compiler_rt's load on demand) is the
/// last build's input at that path, whose contents `create` checked.
fn isChangedPath(r: *Replay, path: []const u8) bool {
    const fe = r.zcu.fe;
    for (fe.files.items, 0..) |*f, i| if (std.mem.eql(u8, f.display_path, path)) return r.isChangedFile(@intCast(i));
    var path_buf: std.ArrayList(u8) = .empty;
    defer path_buf.deinit(r.gpa);
    for (fe.modules.items) |*mod| {
        const dir = mod.root_dir;
        if (path.len <= dir.len or !std.mem.startsWith(u8, path, dir) or path[dir.len] != std.fs.path.sep) continue;
        path_buf.clearRetainingCapacity();
        path_buf.print(r.gpa, "{s}{c}{s}", .{ mod.abs_root_dir orelse dir, std.fs.path.sep, path[dir.len + 1 ..] }) catch return true;
        const input = r.by_path.get(path_buf.items) orelse continue;
        return r.maps.maps.contains(input);
    }
    return true;
}

fn isChangedFile(r: *Replay, file: u32) bool {
    const input = r.inputOf(file) orelse return true;
    return r.maps.maps.contains(input);
}

/// File `file`'s input in the last build, if it had it.
fn inputOf(r: *Replay, file: u32) ?u32 {
    if (r.file_inputs.get(file)) |i| return i;
    var path_buf: std.ArrayList(u8) = .empty;
    defer path_buf.deinit(r.gpa);
    const f = r.zcu.fe.files.items[file];
    Incremental.inputPath(r.gpa, &path_buf, r.zcu.fe, f.module, f.sub_path) catch return null;
    const i = r.by_path.get(path_buf.items) orelse return null;
    r.file_inputs.put(r.gpa, file, i) catch return null;
    if (r.input_files[i] == 0 or r.input_files[i] == no_file) r.input_files[i] = file + 1;
    return i;
}

/// Whether node `node` is in a compiler_rt file this build has not loaded
/// yet. A unit that requested a compiler_rt helper reaches the helper's
/// function and its file's root namespace (`Incremental.addRtReach`).
/// Replaying the unit's request (its `rt` reference) brings both back
/// once analysis resolves the request, which loads the file. Replay
/// cannot load it itself: files load only when the pool drains, since
/// CodeGen workers read `Frontend.files`.
fn inUnloadedCompilerRt(r: *Replay, node: u32) bool {
    const input = r.m.source(node).input;
    if (input == Manifest.Source.no_input) return false;
    const key = r.m.inputKey(input);
    const name = r.zcu.fe.module(.compiler_rt).name;
    if (!std.mem.startsWith(u8, key, name) or key.len == name.len or key[name.len] != ':') return false;
    return r.fileOf(input) == null;
}

const Green = struct {
    unit: Zcu.AnalUnit,
    node: u32,
    /// Where this unit's dependencies start in `deps`.
    deps_start: usize,
};

/// The node of `unit` if it can be loaded: the manifest has it, its
/// source is unchanged, and, if it is outdated, its dependencies' results
/// are; null if it must be analyzed. Brings every plain dependency up to
/// date and appends them to `deps` (nested loads push and pop theirs
/// above).
fn greenNode(r: *Replay, unit: Zcu.AnalUnit) !?Green {
    const m = r.m;
    const node = r.unit_nodes.get(unit) orelse m.find(try r.keyer.keyOf(Incremental.Recorder.unitTag(unit), &.{try r.keyer.unitKeyString(unit)})) orelse {
        r.stats.new += 1;
        return null;
    };
    if (r.state[node] == .red) return null;
    var analyze = false;
    for (m.nodeRefs(node)) |ref| switch (ref.kind) {
        .analyze => analyze = true,
        // Before any return: an instance analyzed again keeps the quota
        // its loaded callers gave it.
        .quota => {
            const gop = try r.zcu.branch_quotas.getOrPut(r.zcu.gpa, unit.func);
            if (!gop.found_existing or gop.value_ptr.* < ref.value) gop.value_ptr.* = ref.value;
        },
        else => {},
    };
    const g: Green = .{ .unit = unit, .node = node, .deps_start = r.deps.items.len };
    const is_outdated = r.outdated.isSet(node);
    // A lazy build leaves a unit alone unless an edit reached it: its
    // recorded result and dependencies are current, and its effects (an
    // `analyze` reference) are in the manifest. A result written into the
    // Zcu, though, brings its dependencies up to date first, as analysis
    // would have: what it names (a declaration's address, say) is read by
    // what reads it.
    const materialize = switch (unit) {
        .func, .comptime_decl => false,
        else => true,
    };
    if (r.lazy and !is_outdated and !r.dead.isSet(node) and !materialize) return g;
    // A unit with effects (`@export`) runs again in an eager build, which
    // makes the effects again; a lazy one keeps them in the manifest, so
    // the unit stays green there if its dependencies' results did
    // (`Incremental.recordDelta` falls back if a function it exports is
    // generated again).
    if (analyze and !r.lazy) return r.red(node);
    const n = m.node(node);
    const has_result = switch (unit) {
        .func, .comptime_decl => true,
        else => m.result(node).len != 0,
    };
    if (n.src_hash != r.keyer.unitSrcHash(unit) or !has_result) return r.red(node);
    errdefer r.deps.shrinkRetainingCapacity(g.deps_start);
    for (m.deps(node)) |e| {
        const edge: Manifest.Edge = @bitCast(e);
        // Conditional edges: the unit does not resolve those itself.
        if (edge.kind != .plain) continue;
        const d = edge.node;
        const dn = m.node(d);
        const dtag = std.enums.fromInt(Tag, dn.tag) orelse return r.redAt(g);
        switch (dtag) {
            // Constants the function's code uses: from the pack.
            .content => continue,
            .func, .link, .comptime_decl => return r.redAt(g),
            else => {},
        }
        if (r.lazy and !materialize and !r.outdated.isSet(d)) continue;
        const dep = try r.dependee(d, dtag) orelse {
            r.noteMiss(unit, @tagName(dtag));
            return r.redAt(g);
        };
        if (!r.ensure(dep)) return r.redAt(g);
        // The subject decoded to an item with the recorded stable hash, so
        // only an outdated unit needs its dependencies' results compared.
        if (is_outdated) {
            const di = switch (dep) {
                .nav_val => |nav| try r.keyer.unitInfo(.{ .nav_val = nav }),
                .type_layout => |ty| try r.keyer.unitInfo(.{ .type_layout = ty }),
                .struct_defaults => |ty| try r.keyer.unitInfo(.{ .struct_defaults = ty }),
                else => try r.keyer.dependeeInfo(dep),
            };
            if (di.key != dn.key) {
                r.noteMiss(unit, "dependee key");
                return r.redAt(g);
            }
            if (di.result_hash != dn.result_hash) {
                r.stats.red_changed += 1;
                return r.redAt(g);
            }
            // Decided: an edit reached it, but its result is as recorded.
            if (r.state[d] == .unknown) r.state[d] = .green;
        }
        try r.deps.append(r.gpa, dep);
    }
    return g;
}

const Ref = union(enum) {
    func: Index,
    nav: InternPool.NavIndex,
    /// A container type the unit evaluated, which loading it makes again.
    effects: Index,
    other: Manifest.Ref,
};

/// A loaded unit's references with their targets resolved, or null if one
/// cannot be. Only a function's code makes requests other than queueing
/// functions: other units' data is lowered again by Emit, which makes them.
fn resolveRefs(r: *Replay, g: Green, is_func: bool) !?[]Ref {
    var out: std.ArrayList(Ref) = .empty;
    defer out.deinit(r.gpa);
    for (r.m.nodeRefs(g.node)) |ref| switch (ref.kind) {
        .func => {
            if (r.inUnloadedCompilerRt(ref.value)) continue;
            const dep = try r.dependee(ref.value, .func) orelse return null;
            try out.append(r.gpa, .{ .func = dep.func_body });
        },
        .nav => if (is_func) {
            const dep = try r.dependee(ref.value, .nav_val) orelse return null;
            r.zcu.ensureNavVal(dep.nav_val) catch return null;
            try out.append(r.gpa, .{ .nav = dep.nav_val });
        },
        .effects => {
            if (r.inUnloadedCompilerRt(ref.value)) continue;
            const dep = try r.dependee(ref.value, .namespace) orelse return null;
            try out.append(r.gpa, .{ .effects = r.zcu.namespaces.items[dep.namespace].owner_type });
        },
        // `Zcu.ensureStructLayout` queues the defaults again.
        .analyze, .quota, .root, .defaults => {},
        else => if (is_func) try out.append(r.gpa, .{ .other = ref }),
    };
    return try out.toOwnedSlice(r.gpa);
}

/// A green unit in a lazy build: it is live, and its result is in the
/// Zcu if `loaded`.
fn commitLazy(r: *Replay, g: Green, loaded: bool) !void {
    r.deps.shrinkRetainingCapacity(g.deps_start);
    r.state[g.node] = .green;
    if (loaded) r.loaded.set(g.node);
    r.stats.loaded += 1;
    try r.visit(g.node);
}

/// Records a loaded unit's dependencies and replays its references.
fn commit(r: *Replay, unit: Zcu.AnalUnit, g: Green, refs: []const Ref) !void {
    if (r.lazy) return r.commitLazy(g, true);
    const zcu = r.zcu;
    const m = r.m;
    try zcu.recordDeps(unit, r.deps.items[g.deps_start..], &.{});
    r.deps.shrinkRetainingCapacity(g.deps_start);
    r.state[g.node] = .green;
    r.loaded.set(g.node);
    r.stats.loaded += 1;
    const emit = r.emit;
    const saved = emit.owner;
    defer emit.owner = saved;
    emit.owner = .{ .unit = unit };
    for (refs) |ref| switch (ref) {
        .func => |func| _ = try zcu.queueFuncFrom(unit, func),
        .nav => |nav| _ = try emit.navKey(nav),
        .effects => |ty| try zcu.effect_uses.put(zcu.gpa, .{ .unit = unit, .ty = ty }, {}),
        .other => |o| switch (o.kind) {
            .err => _ = try emit.useError(try zcu.ip.getString(Zcu.tid, m.errorName(o.value))),
            .ext, .ext_weak => _ = try emit.useExtern(m.refName(o.value), o.kind == .ext_weak),
            .import => {
                const name, const flags = Incremental.parseImportRef(m.refName(o.value)) orelse return error.InvalidImportRef;
                _ = try emit.useImport(name, flags);
            },
            .rt => {
                const file, const name = Zcu.compilerRtKeyParts(m.refName(o.value));
                _ = try emit.requestCompilerRt(file, name);
            },
            .error_names => try emit.useErrorNames(),
            .func, .nav, .analyze, .quota, .effects, .root, .defaults => unreachable,
        },
    };
}

/// Counts a green unit that could not be loaded, which `ZAP_CACHE_CHECK`
/// prints: something its result or dependencies name could not be found
/// or made in this build.
fn noteMiss(r: *Replay, unit: Zcu.AnalUnit, what: []const u8) void {
    r.stats.misses += 1;
    if (!r.check) return;
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    r.zcu.unitKey(unit, &w) catch {};
    const dm = r.decoder.miss;
    std.debug.print("cache replay: could not load {t} {s}: {s}", .{ unit, w.buffered(), what });
    if (dm.reason != .none) std.debug.print(" (item {d}, {t}: {t})", .{ dm.id, dm.tag, dm.reason });
    std.debug.print("\n", .{});
    r.decoder.miss = .{};
}

fn red(r: *Replay, node: u32) ?Green {
    if (r.state[node] != .red) r.stats.red += 1;
    r.state[node] = .red;
    return null;
}

fn redAt(r: *Replay, g: Green) ?Green {
    r.deps.shrinkRetainingCapacity(g.deps_start);
    return r.red(g.node);
}

fn miss(r: *Replay, g: Green, what: []const u8) bool {
    r.noteMiss(g.unit, what);
    _ = r.redAt(g);
    return false;
}

/// The live dependee of node `d` (of kind `tag`), from its subject.
/// Memoized: many units share each dependency.
fn dependee(r: *Replay, d: u32, tag: Tag) !?Zcu.Dependee {
    if (r.dependees[d]) |dep| return dep;
    const dep = try r.decodeDependee(d, tag) orelse return null;
    r.dependees[d] = dep;
    return dep;
}

fn decodeDependee(r: *Replay, d: u32, tag: Tag) !?Zcu.Dependee {
    const words = r.m.subject(d);
    if (words.len == 0) return null;
    const s = try results.decodeSubject(&r.decoder, words) orelse return null;
    const zcu = r.zcu;
    // A unit's node, for `greenNode` to find without rendering its key.
    switch (tag) {
        .nav_val => if (s == .nav) try r.unit_nodes.put(r.gpa, .{ .nav_val = s.nav }, d),
        .type_layout => if (s == .ty) try r.unit_nodes.put(r.gpa, .{ .type_layout = s.ty }, d),
        .struct_defaults => if (s == .ty) try r.unit_nodes.put(r.gpa, .{ .struct_defaults = s.ty }, d),
        .func => if (s == .func) try r.unit_nodes.put(r.gpa, .{ .func = s.func }, d),
        else => {},
    }
    return switch (tag) {
        .nav_val => .{ .nav_val = if (s == .nav) s.nav else return null },
        .nav_ty => .{ .nav_ty = if (s == .nav) s.nav else return null },
        .type_layout => .{ .type_layout = if (s == .ty) s.ty else return null },
        .struct_defaults => .{ .struct_defaults = if (s == .ty) s.ty else return null },
        .func, .func_body => .{ .func_body = if (s == .func) s.func else return null },
        .func_ies => .{ .func_ies = if (s == .func) s.func else return null },
        .func_inline => .{ .func_inline = if (s == .func) s.func else return null },
        .namespace_name => blk: {
            if (s != .namespace_name) return null;
            const ns = zcu.ip.structInfo(s.namespace_name.owner).namespace;
            if (ns == Zcu.Namespace.none) return null;
            break :blk .{ .namespace_name = .{ .namespace = ns, .name = try zcu.ip.getString(Zcu.tid, s.namespace_name.name) } };
        },
        .namespace => blk: {
            if (s != .namespace) return null;
            const ns = zcu.ip.structInfo(s.namespace).namespace;
            if (ns == Zcu.Namespace.none) return null;
            break :blk .{ .namespace = ns };
        },
        .embed_file => blk: {
            if (s != .embed_file) return null;
            const key = s.embed_file;
            const colon = std.mem.indexOfScalar(u8, key, ':') orelse return null;
            const mod = for (zcu.fe.modules.items, 0..) |mo, i| {
                if (std.mem.eql(u8, mo.name, key[0..colon])) break @as(Frontend.Module.Index, @fromBackingInt(@as(u32, @intCast(i))));
            } else return null;
            break :blk .{ .embed_file = zcu.embedFile(mod, key[colon + 1 ..]) catch return null };
        },
        .comptime_decl, .content, .link => null,
    };
}

/// Brings `dep` up to date as analysis would before reading it.
fn ensure(r: *Replay, dep: Zcu.Dependee) bool {
    const zcu = r.zcu;
    switch (dep) {
        .nav_val => |nav| zcu.ensureNavVal(nav) catch return false,
        .nav_ty => |nav| zcu.ensureNavTy(nav) catch return false,
        .type_layout => |ty| zcu.ensureStructLayout(ty) catch return false,
        .struct_defaults => |ty| zcu.ensureStructDefaults(ty) catch return false,
        .func_ies => |func| _ = zcu.ensureFuncIes(func) catch return false,
        // Decided now, analyzing the function out of order if needed; when
        // that cannot happen now, the reader is analyzed again. Out of
        // order, speculatively: the reader is in progress, which analysis
        // never is when it decides inlining (after the reader's body), so a
        // loop back to it (an inferred error set it reads) ends the
        // speculation instead of failing the callee.
        .func_inline => |func| {
            zcu.speculating += 1;
            defer zcu.speculating -= 1;
            if ((r.emit.inlineFate(func) catch return false) != .fate) return false;
        },
        .func_body, .namespace_name, .namespace, .embed_file => {},
    }
    return true;
}

// ---------------------------------------------------------------------------
// A lazy build's walk

const link_key = cache.hash(2, &.{@backingInt(Tag.link)});

/// Marks node `n` live and queues it for `walk`.
fn visit(r: *Replay, n: u32) !void {
    if (r.visited.isSet(n)) return;
    r.visited.set(n);
    try r.walk_stack.append(r.gpa, n);
}

/// Starts the walk from the root files' namespaces and the link's own
/// atoms, as `Incremental.reachNext` describes. Call once the root files'
/// types exist.
pub fn startWalk(r: *Replay) !void {
    const zcu = r.zcu;
    for (zcu.rootFiles()) |root| if (root) |f| {
        if (f >= zcu.file_root_types.items.len) continue;
        const ty = zcu.file_root_types.items[f];
        if (ty == .none) continue;
        const info = try r.keyer.dependeeInfo(.{ .namespace = zcu.ip.structInfo(ty).namespace });
        if (r.m.find(info.key)) |n| try r.visit(n);
    };
    if (r.m.find(link_key)) |n| try r.visit(n);
}

pub fn walking(r: *const Replay) bool {
    return r.walk_stack.items.len != 0;
}

/// Follows the walk's edges from the nodes it reached: a green node's
/// from the manifest, without loading it. A node an edit reached goes to
/// analysis instead, which walks on from it if it is green, and whose
/// queues reach what a red one refers to now.
pub fn walk(r: *Replay) !void {
    var next: std.ArrayList(u32) = .empty;
    defer next.deinit(r.gpa);
    while (r.walk_stack.pop()) |n| {
        next.clearRetainingCapacity();
        try r.walkNode(n, &next);
        for (next.items) |d| try r.visit(d);
    }
}

fn walkNode(r: *Replay, n: u32, next: *std.ArrayList(u32)) !void {
    const m = r.m;
    const tag = std.enums.fromInt(Tag, m.node(n).tag) orelse return;
    // In a compiler_rt file not loaded yet: its subject names nothing yet.
    // If an edit reached it, its requester requests it again (below), and
    // analysis decides it once the file loads.
    if (r.inUnloadedCompilerRt(n) and (r.outdated.isSet(n) or r.inChangedInput(n)) and r.state[n] == .unknown) {
        r.visited.unset(n);
        try r.rt_waiting.append(r.gpa, n);
        return;
    }
    if (r.outdated.isSet(n) and r.state[n] == .unknown) switch (tag) {
        // Analysis decides it; a green one is visited again as it loads,
        // and walked on from then.
        .nav_val, .type_layout, .struct_defaults => {
            r.visited.unset(n);
            const dep = try r.dependee(n, tag) orelse return r.die(n);
            _ = r.ensure(dep);
            return;
        },
        .func => {
            r.visited.unset(n);
            const dep = try r.dependee(n, tag) orelse return r.die(n);
            _ = try r.zcu.queueFunc(dep.func_body);
            return;
        },
        // Its namespace's scan makes it (below), and analysis decides.
        .comptime_decl => {
            r.visited.unset(n);
            return;
        },
        else => {},
    };
    if (r.dead.isSet(n) or r.state[n] == .red) return;
    // A namespace whose container an edit reached, or one of whose roots
    // it did, is made again: its scan queues the roots as they are now,
    // and analysis decides each.
    if (tag == .namespace and r.namespaceOutdated(n)) {
        _ = try r.dependee(n, .namespace) orelse return r.die(n);
    }
    try Incremental.reachNext(m.deps(n), m.nodeRefs(n), next, r.gpa);
    for (m.nodeRefs(n)) |ref| if (ref.kind == .nav) r.data_refs.set(ref.value);
    // A kept unit's compiler_rt helpers in a file an edit reached, which
    // is not loaded yet: requested again, as analysis would (`Emit.
    // requestCompilerRt`), which loads the file and analyzes them there.
    const rt_edited = for (m.nodeRefs(n)) |ref| {
        if ((ref.kind == .func or ref.kind == .effects) and r.inUnloadedCompilerRt(ref.value) and
            (r.outdated.isSet(ref.value) or r.inChangedInput(ref.value))) break true;
    } else false;
    if (rt_edited) for (m.nodeRefs(n)) |ref| switch (ref.kind) {
        .rt => _ = try r.emit.requestRtKey(m.refName(ref.value)),
        .effects => if (r.inUnloadedCompilerRt(ref.value)) try r.rt_effects.append(r.gpa, .{ ref.value, n }),
        else => {},
    };
    // A function's lines: its own declaration's, and those of the
    // functions it inlines, which it depends on. Those are made now, so
    // that their namespaces exist as in a full build.
    if (tag == .func and r.maps.maps.count() != 0) {
        var moved = r.inChangedInput(n);
        for (m.deps(n)) |e| {
            const d = Manifest.Edge.nodeOf(e);
            const dtag = std.enums.fromInt(Tag, m.node(d).tag) orelse continue;
            // Sema's inline calls depend on the callee's body, the
            // backend's on whether it inlines (whose producer is the
            // callee's unit).
            const in_changed = switch (dtag) {
                .func_body => r.inChangedInput(d),
                .func_inline => try r.inlineMoved(d, inline_ir.budget),
                else => continue,
            };
            if (!in_changed) continue;
            moved = true;
            _ = try r.dependee(d, dtag);
        }
        if (moved) r.refresh.set(n);
    }
}

/// Whether the function of `func_inline` node `d` is inlined, and it, or
/// one it inlines in turn (at most `depth` levels down, which the budget
/// bounds), is in a changed input; makes the dependees of those it
/// inlines that are.
fn inlineMoved(r: *Replay, d: u32, depth: u32) !bool {
    const m = r.m;
    // Not inlinable (no size): its callers keep the call.
    if (m.result(d).len == 0) return false;
    for (m.deps(d)) |pe| {
        const p = Manifest.Edge.nodeOf(pe);
        if (r.inChangedInput(p)) return true;
        if (depth == 0) continue;
        var moved = false;
        for (m.deps(p)) |e| {
            const dd = Manifest.Edge.nodeOf(e);
            if (m.node(dd).tag != @backingInt(Tag.func_inline) or !try r.inlineMoved(dd, depth - 1)) continue;
            moved = true;
            _ = try r.dependee(dd, .func_inline);
        }
        if (moved) return true;
    }
    return false;
}

fn inChangedInput(r: *Replay, n: u32) bool {
    const src = r.m.source(n);
    return src.input != Manifest.Source.no_input and r.maps.maps.contains(src.input);
}

fn namespaceOutdated(r: *Replay, n: u32) bool {
    if (r.outdated.isSet(n)) return true;
    const src = r.m.source(n);
    if (src.input != Manifest.Source.no_input and r.maps.maps.contains(src.input)) return true;
    for (r.m.nodeRefs(n)) |ref| if (ref.kind == .root and r.outdated.isSet(ref.value)) return true;
    return false;
}

fn die(r: *Replay, n: u32) void {
    r.dead.set(n);
    r.state[n] = .red;
}

/// `Zcu.analyzeAll` with nothing else to do in a lazy build: requests the
/// data of red declarations that live nodes refer to, and lowers the data
/// requested so far, which can reach more units. Returns whether that
/// gave analysis more to do.
pub fn settle(r: *Replay) !bool {
    const emit = r.emit;
    const before = emit.navs_done;
    // Nodes in compiler_rt files that have loaded since the walk reached
    // them, walked now.
    var kept: usize = 0;
    for (r.rt_waiting.items) |n| {
        if (r.inUnloadedCompilerRt(n)) {
            r.rt_waiting.items[kept] = n;
            kept += 1;
        } else try r.visit(n);
    }
    r.rt_waiting.shrinkRetainingCapacity(kept);
    // Their requesters' reach of their files' namespaces, which a full
    // build records (`Incremental.addRtReach`), as the effects uses an
    // eager build replays: the namespace is then decided as in a full
    // build, not left for the next build.
    kept = 0;
    for (r.rt_effects.items) |pair| {
        const ns_node, const from = pair;
        if (r.inUnloadedCompilerRt(ns_node)) {
            r.rt_effects.items[kept] = pair;
            kept += 1;
            continue;
        }
        const ns = try r.dependee(ns_node, .namespace) orelse continue;
        const unit: Zcu.AnalUnit = switch (std.enums.fromInt(Tag, r.m.node(from).tag) orelse continue) {
            .func => .{ .func = (try r.dependee(from, .func) orelse continue).func_body },
            .nav_val => .{ .nav_val = (try r.dependee(from, .nav_val) orelse continue).nav_val },
            else => continue,
        };
        try r.zcu.effect_uses.put(r.zcu.gpa, .{ .unit = unit, .ty = r.zcu.namespaces.items[ns.namespace].owner_type }, {});
    }
    r.rt_effects.shrinkRetainingCapacity(kept);
    var it = r.data_refs.iterator(.{});
    while (it.next()) |n| {
        if (r.state[n] != .red or r.dead.isSet(n) or r.m.node(@intCast(n)).tag != @backingInt(Tag.nav_val)) continue;
        const dep = try r.dependee(@intCast(n), .nav_val) orelse continue;
        const saved = emit.owner;
        defer emit.owner = saved;
        // Not a reference of any unit's: the node that refers to it keeps
        // its own.
        emit.owner = .content;
        _ = try emit.navKey(dep.nav_val);
    }
    try emit.lowerNavs();
    return emit.navs_done != before or r.walking();
}

/// For `Emit.lowerNavs`: whether declaration `nav`'s data is in the pack
/// already, in a lazy build (it is then live). Otherwise makes sure it is
/// resolved, to be lowered.
pub fn keepsNavData(r: *Replay, nav: InternPool.NavIndex) !bool {
    if (!r.lazy) return false;
    const unit: Zcu.AnalUnit = .{ .nav_val = nav };
    const node = r.unit_nodes.get(unit) orelse r.m.find(try r.keyer.keyOf(.nav_val, &.{try r.keyer.unitKeyString(unit)}));
    if (node) |n| if ((r.state[n] == .green or (r.state[n] == .unknown and !r.outdated.isSet(n))) and r.m.atoms(n).len != 0 and !r.m.flags(n).unlinked) {
        r.data_refs.set(n);
        try r.visit(n);
        return true;
    };
    r.zcu.ensureNavVal(nav) catch return true;
    return false;
}

// ---------------------------------------------------------------------------
// Resolving items that name source

/// Offers the types this build has the candidate names that the units it
/// kept without analyzing them offered when they were analyzed
/// (`Manifest.typeNames`), before `Zcu.finalizeNames` settles them, so
/// that each type gets the name a full build gives it (docs/architecture.md,
/// "Type names in the cache"). Then lists in `renamed` the types whose
/// name, or the offer that gives it, differs from when it was recorded:
/// one this build has, or one whose least creator left. Each type's
/// recorded name is in its winning offer. The atoms named after them, or
/// after types whose names have them, and the kept units' recorded
/// winners are then out of date: an eager build writes them all again,
/// a lazy one rewrites those (`Incremental.rewriteKept`). A kept unit
/// that read a name that changed must be analyzed again: the build is
/// built again in full (`error.NamesFullBuild`).
pub fn contributeNames(r: *Replay, zcu: *Zcu) !void {
    const gpa = r.gpa;
    const ip = &zcu.ip;
    const Names = results.Names;
    const types = &r.type_names;
    const t0 = std.Io.Clock.awake.now(r.io);
    defer if (r.timing) std.debug.print("cache: contributed type names of {d} types in {d:.2} ms\n", .{ types.count(), @as(f64, @floatFromInt(t0.durationTo(std.Io.Clock.awake.now(r.io)).toNanoseconds())) / 1e6 });
    // The types that matter: those this build has, and those whose
    // winning offer is in a node the build did not keep (its least
    // creator may have left). Most of the manifest's are neither.
    var wanted: std.AutoArrayHashMapUnmanaged(InternPool.Hash, void) = .empty;
    defer wanted.deinit(gpa);
    for (0..ip.locals.len) |local| for (ip.localNames(local)) |name| {
        if (name.ty != .none) try wanted.put(gpa, ip.stableHash(name.ty), {});
    };
    // Nodes the build did not keep: the analyzed ones, and the dead.
    // A lazy build keeps the nodes its walk reached but the red ones; an
    // eager one, those it loaded.
    {
        const n = r.m.nodeCount();
        var it = (if (r.lazy) r.visited else r.loaded).iterator(.{ .kind = .unset });
        while (it.next()) |i| if (i < n) try r.addOrphans(&wanted, @intCast(i));
        if (r.lazy) for (r.state, 0..) |st, i| if (st == .red and r.visited.isSet(i)) try r.addOrphans(&wanted, @intCast(i));
    }
    {
        var it = r.m.overlay.nodes.iterator();
        while (it.next()) |e| {
            var reader: Names.Reader = .init(e.value_ptr.names);
            while (reader.nextOffer()) |o| {
                const gop = try r.log_offers.getOrPut(gpa, o.ty);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(gpa, e.key_ptr.*);
            }
        }
    }
    try r.collectOffers(wanted.keys());
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    var holes: std.ArrayList(InternPool.Template.Hole) = .empty;
    defer holes.deinit(gpa);
    // `finalName` may add entries: by index.
    var ti: usize = 0;
    while (ti < wanted.count()) : (ti += 1) {
        const h = wanted.keys()[ti];
        const best = types.get(h).?.best orelse continue;
        const ty = try ip.indexOfHash(h) orelse continue;
        // A hole whose type this build does not have takes that type's
        // final name, as text.
        bytes.clearRetainingCapacity();
        holes.clearRetainingCapacity();
        var from: usize = 0;
        for (0..best.holeCount()) |k| {
            const at, const hole_hash = best.hole(k);
            try bytes.appendSlice(gpa, best.bytes[from..at]);
            from = at;
            if (try ip.indexOfHash(hole_hash)) |hole_ty| {
                try holes.append(gpa, .{ .at = @intCast(bytes.items.len), .ty = hole_ty });
            } else {
                try bytes.appendSlice(gpa, try r.finalName(hole_hash) orelse return r.fullBuild("a type's name has a hole that is unknown"));
            }
        }
        try bytes.appendSlice(gpa, best.bytes[from..]);
        try zcu.offerName(ty, .{ .creator = best.creator, .template = .{ .bytes = bytes.items, .holes = holes.items } });
    }
    // Types that analyzed units offered names: their templates may differ
    // from the recorded ones under the same creator (an anonymous type's
    // name has its instruction's index).
    var fresh: std.AutoHashMapUnmanaged(InternPool.Index, void) = .empty;
    defer fresh.deinit(gpa);
    for (zcu.name_offers.keys()) |o| try fresh.put(gpa, o.ty, {});
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    // A type whose holes' names changed is not listed: its holes are.
    for (wanted.keys()) |h| {
        const e = types.get(h).?;
        const why: []const u8 = if (try ip.indexOfHash(h)) |ty| why: {
            // A type that kept units offered names without one that won.
            const won = e.won orelse break :why if (e.best != null) "no recorded winner" else continue;
            // Another creator, even with the same name, leaves the offers'
            // recorded winners out of date.
            if (ip.nameOf(ty).creator != e.won_creator) break :why "another creator";
            if (!fresh.contains(ty)) continue;
            aw.clearRetainingCapacity();
            print.writeTypeName(ip, ty, &aw.writer, .render) catch return error.OutOfMemory;
            if (!std.mem.eql(u8, aw.written(), won)) break :why "another template";
            continue;
        } else if (e.best) |b| why: {
            // Absent, so nothing in this build offered it a name: its
            // least creator is a kept unit's, the same as last time
            // unless the one whose name won left. (No kept unit offering
            // it: no live unit makes it.)
            if (b.won.len == 0) break :why "its least creator left";
            continue;
        } else continue;
        if (r.timing and r.renamed.count() < 5) std.debug.print("cache: a type's name may have changed: {s} ({s})\n", .{ e.won orelse "?", why });
        try r.renamed.put(gpa, h, {});
    }
    if (r.renamed.count() == 0) return;
    try r.checkNameReads(zcu);
}

/// For a build in which names changed: returns `error.NamesFullBuild` if
/// a unit it kept read a name that changed, whose result is then out of
/// date.
fn checkNameReads(r: *Replay, zcu: *Zcu) !void {
    const ip = &zcu.ip;
    var it = (if (r.lazy) r.visited else r.loaded).iterator(.{});
    while (it.next()) |i| {
        if (!r.keeps(@intCast(i))) continue;
        var reader: results.Names.Reader = .init(r.m.typeNames(@intCast(i)));
        while (reader.nextOffer()) |_| {}
        while (reader.nextRead()) |rd| {
            const ty = try ip.indexOfHash(rd.ty) orelse {
                // A name renders the names of the named types in it, and
                // so a renamed type's old name if it changed.
                for (r.renamed.keys()) |h| {
                    const old = r.type_names.get(h).?.won orelse return r.fullBuild("a kept unit read a name that may have changed");
                    if (std.mem.indexOf(u8, rd.name, old) != null) return r.fullBuild("a kept unit read a name that may have changed");
                }
                continue;
            };
            const name = try print.typeAlloc(ip, ty, r.gpa);
            defer r.gpa.free(name);
            if (!std.mem.eql(u8, name, rd.name)) return r.fullBuild("a name that a kept unit read changed");
        }
    }
}

/// The name of the file root type with stable hash `ty`, if it is one.
fn rootName(r: *Replay, ty: InternPool.Hash) !?[]const u8 {
    const zcu = r.zcu;
    if (r.root_types == null) {
        r.root_types = .empty;
        for (0..zcu.fe.files.items.len) |i| try r.root_types.?.put(r.gpa, InternPool.rootStructHash(try zcu.fileKey(@intCast(i))), @intCast(i));
    }
    const file = r.root_types.?.get(ty) orelse return null;
    return try zcu.fileFqn(file);
}

/// The final name of the type with stable hash `ty`, whether this build
/// has it or not; null if unknown (`finalName`).
pub fn finalTypeName(r: *Replay, ty: InternPool.Hash) !?[]const u8 {
    const ip = &r.zcu.ip;
    if (try ip.indexOfHash(ty)) |index| {
        var aw: std.Io.Writer.Allocating = .init(r.zcu.arena.allocator());
        print.writeTypeName(ip, index, &aw.writer, .render) catch return error.OutOfMemory;
        return aw.written();
    }
    return r.finalName(ty);
}

/// Whether node `i`'s recorded type name offers may be out of date: it
/// offered a type in `renamed`.
pub fn offersRenamed(r: *Replay, i: u32) bool {
    var reader: results.Names.Reader = .init(r.m.typeNames(i));
    while (reader.nextOffer()) |o| if (r.renamed.contains(o.ty)) return true;
    return false;
}

/// For a kept unit's offer, in a build in which names changed: the type's
/// final name if the offer gives it, else empty (`results.Names.rewriteWon`).
pub fn wonName(r: *Replay, o: results.Names.Offer) ![]const u8 {
    const ip = &r.zcu.ip;
    if (try ip.indexOfHash(o.ty)) |ty| {
        if (ip.nameOf(ty).creator != o.creator) return "";
        var aw: std.Io.Writer.Allocating = .init(r.zcu.arena.allocator());
        print.writeTypeName(ip, ty, &aw.writer, .render) catch return error.OutOfMemory;
        return aw.written();
    }
    if (!r.type_names.contains(o.ty)) try r.collectOffers(&.{o.ty});
    const best = r.type_names.get(o.ty).?.best orelse return "";
    if (best.creator != o.creator) return "";
    return try r.finalName(o.ty) orelse "";
}

/// The final name of the type with stable hash `ty`, which this build
/// does not have: its least kept creator's template, with each hole's
/// final name, or its recorded name if no kept unit offered it one; null
/// if no unit did, or a hole's name is unknown.
pub fn finalName(r: *Replay, ty: InternPool.Hash) !?[]const u8 {
    if (!r.type_names.contains(ty)) try r.collectOffers(&.{ty});
    const e = r.type_names.getPtr(ty).?;
    if (e.final) |f| return f;
    const best = e.best orelse return e.won orelse try r.rootName(ty);
    // Holes name other types, never the type itself.
    if (e.rendering) return null;
    e.rendering = true;
    const ip = &r.zcu.ip;
    var aw: std.Io.Writer.Allocating = .init(r.zcu.arena.allocator());
    const w = &aw.writer;
    var from: usize = 0;
    for (0..best.holeCount()) |k| {
        const at, const hole_hash = best.hole(k);
        w.writeAll(best.bytes[from..at]) catch return error.OutOfMemory;
        from = at;
        if (try ip.indexOfHash(hole_hash)) |hole_ty| {
            print.writeTypeName(ip, hole_ty, w, .render) catch return error.OutOfMemory;
        } else {
            const name = try r.finalName(hole_hash) orelse {
                r.type_names.getPtr(ty).?.rendering = false;
                return null;
            };
            w.writeAll(name) catch return error.OutOfMemory;
        }
    }
    w.writeAll(best.bytes[from..]) catch return error.OutOfMemory;
    // `finalName` may have grown the table.
    const after = r.type_names.getPtr(ty).?;
    after.rendering = false;
    after.final = aw.written();
    return after.final;
}

/// Gathers into `type_names` the offers the manifest's nodes made the
/// types with stable hashes `tys`: each one's recorded name, and the kept
/// nodes' least creator's offer. Reads each node once: one node may offer
/// names to thousands of types.
fn collectOffers(r: *Replay, tys: []const InternPool.Hash) !void {
    const gpa = r.gpa;
    const m = r.m;
    const changed = &m.overlay.nodes;
    var nodes: std.AutoArrayHashMapUnmanaged(u32, void) = .empty;
    defer nodes.deinit(gpa);
    for (tys) |ty| {
        const gop = try r.type_names.getOrPut(gpa, ty);
        if (gop.found_existing) continue;
        gop.value_ptr.* = .{};
        const e = gop.value_ptr;
        // The base's offers through its index, least creator first, then
        // the log's nodes.
        var best: ?u32 = null;
        var won: ?u32 = null;
        for (m.typeNameNodes(ty)) |t| {
            if (changed.count() != 0 and changed.contains(t.node)) continue;
            if (won == null and t.won != 0) won = t.node;
            if (best == null and r.keeps(t.node)) best = t.node;
            if (best != null and won != null) break;
        }
        if (best) |n| {
            e.best_node = n;
            try nodes.put(gpa, n, {});
        }
        if (won) |n| {
            e.won_node = n;
            try nodes.put(gpa, n, {});
        }
        if (r.log_offers.get(ty)) |log_nodes| for (log_nodes.items) |n| try nodes.put(gpa, n, {});
    }
    for (nodes.keys()) |n| {
        const in_log = changed.count() != 0 and changed.contains(n);
        const kept = r.keeps(n);
        var reader: results.Names.Reader = .init(m.typeNames(n));
        while (reader.nextOffer()) |o| {
            const e = r.type_names.getPtr(o.ty) orelse continue;
            if (!in_log and e.best_node != n and e.won_node != n) continue;
            if (o.won.len != 0) {
                e.won = o.won;
                e.won_creator = o.creator;
            }
            if (!kept) continue;
            if (e.best) |b| {
                if (o.creator < b.creator) e.best = o;
            } else e.best = o;
        }
    }
}

/// Adds to `wanted` the types whose winning offer is node `i`'s.
fn addOrphans(r: *const Replay, wanted: *std.AutoArrayHashMapUnmanaged(InternPool.Hash, void), i: u32) !void {
    var reader: results.Names.Reader = .init(r.m.typeNames(i));
    while (reader.nextOffer()) |o| if (o.won.len != 0) try wanted.put(r.gpa, o.ty, {});
}

/// Whether node `i` is live and its unit was not analyzed in this build:
/// its type names are as recorded (`contributeNames`).
pub fn keeps(r: *const Replay, i: u32) bool {
    if (!r.lazy) return r.loaded.isSet(i);
    return r.visited.isSet(i) and r.state[i] != .red and !r.dead.isSet(i);
}

/// A build in which a kept unit read a name that changed builds again in
/// full (main).
fn fullBuild(r: *const Replay, why: []const u8) error{NamesFullBuild} {
    if (r.timing) std.debug.print("cache: building again in full: {s}\n", .{why});
    return error.NamesFullBuild;
}

pub fn fileOf(r: *Replay, input: u32) ?u32 {
    if (input >= r.input_files.len) return null;
    // Files loaded since the `no_file` entries looked (compiler_rt's) may
    // be their inputs.
    const files = r.zcu.fe.files.items.len;
    if (files != r.input_files_seen) {
        for (r.input_files) |*v| if (v.* == no_file) {
            v.* = 0;
        };
        r.input_files_seen = files;
    }
    if (r.input_files[input] == 0) {
        // Loaded since `create` (compiler_rt), or not at all.
        r.input_files[input] = no_file;
        const fe = r.zcu.fe;
        var path_buf: std.ArrayList(u8) = .empty;
        defer path_buf.deinit(r.gpa);
        const want = r.m.inputKey(input);
        for (fe.files.items, 0..) |*f, fi| {
            Incremental.inputKey(r.gpa, &path_buf, fe, f.module, f.sub_path) catch return null;
            if (!std.mem.eql(u8, path_buf.items, want)) continue;
            r.input_files[input] = @intCast(fi + 1);
            r.file_inputs.put(r.gpa, @intCast(fi), input) catch return null;
            break;
        }
    }
    const v = r.input_files[input];
    return if (v == no_file) null else v - 1;
}

/// Whether `debug` names only paths this build's debug info can: always
/// unless replaying a donor (`debug_paths`).
fn knowsDebugPaths(r: *Replay, debug: *const Atom.Debug) !bool {
    const paths = if (r.debug_paths) |*p| p else return true;
    // Files loaded since (compiler_rt's, on demand).
    const files = r.zcu.fe.files.items;
    for (files[r.debug_paths_files..]) |*f| {
        const gop = try paths.getOrPut(r.gpa, f.display_path);
        if (!gop.found_existing) gop.key_ptr.* = try r.gpa.dupe(u8, f.display_path);
    }
    r.debug_paths_files = files.len;
    if (!paths.contains(debug.file)) return false;
    if (debug.unit.len != 0 and !paths.contains(debug.unit)) return false;
    var it = std.mem.splitScalar(u8, debug.files, 0);
    while (it.next()) |p| if (p.len != 0 and !paths.contains(p)) return false;
    return true;
}

/// Instruction `inst` of input `input`'s recorded ZIR, in its ZIR now.
pub fn mapInst(r: *Replay, input: u32, inst: Zir.Inst.Index) ?Zir.Inst.Index {
    const entry = r.maps.maps.getPtr(input) orelse return inst;
    if (entry.* == null) entry.* = r.lateMap(input);
    const map = entry.* orelse return null;
    return map.get(inst);
}

/// The map of changed input `input` from its recorded ZIR to its ZIR now,
/// if its file loaded after `create` mapped the others (compiler_rt's
/// load on demand), or null.
fn lateMap(r: *Replay, input: u32) ?seeds.InstMap {
    const file = r.fileOf(input) orelse return null;
    if ((r.late_mapped.getOrPut(r.gpa, input) catch return null).found_existing) return null;
    const in, _ = r.m.input(input);
    const loaded = r.zcu.fe.loadOldZir(@fromBackingInt(file), @bitCast(in.content_hash)) catch null;
    var old = loaded orelse {
        r.late_unmapped = true;
        return null;
    };
    defer old.deinit(r.zcu.fe);
    var map: seeds.InstMap = .empty;
    seeds.mapOldZirToNew(r.gpa, &old.zir, &r.zcu.file(file).zir, &map) catch {
        map.deinit(r.gpa);
        r.late_unmapped = true;
        return null;
    };
    return map;
}

/// Creates the items that name source, as analysis would, without
/// resolving anything (see "Serialized results").
/// A type made from a result has the name the recording build gave it
/// until a creator offers one (`contributeNames`).
fn recordedName(name: []const u8) Zcu.NameCandidate {
    return .{ .creator = std.math.maxInt(InternPool.Hash), .template = .{ .bytes = name } };
}

const Resolver = struct {
    r: *Replay,

    pub fn container(res: Resolver, kind: results.KeyTag, c: results.Container) !?Index {
        const r = res.r;
        const zcu = r.zcu;
        const file = r.fileOf(c.file) orelse return null;
        const inst = r.mapInst(c.file, c.zir_inst) orelse return null;
        const zir = &zcu.file(file).zir;
        if (@backingInt(inst) >= zir.instructions.len) return null;
        if (c.parent == .none) {
            if (inst != .main_struct_inst or kind != .struct_type) return null;
            if (zcu.file_root_types.items.len < zcu.fe.files.items.len)
                try zcu.file_root_types.appendNTimes(zcu.gpa, .none, zcu.fe.files.items.len - zcu.file_root_types.items.len);
            return try zcu.fileRootType(file);
        }
        if (zir.instructions.items(.tag)[@backingInt(inst)] != .extended) return null;
        const opcode = zir.instructions.items(.data)[@backingInt(inst)].extended.opcode;
        if (c.generated_tag) |t| {
            if (kind != .enum_type or opcode != .union_decl or zcu.ip.indexToKey(t.union_type) != .union_type) return null;
            const info = try zcu.ip.createContainerInfo(Zcu.tid, .{
                .namespace = zcu.ip.structInfo(t.union_type).namespace,
                .layout = .auto,
                .status = .have_layout,
                .field_names = t.names,
                .field_defaults = t.values,
                .tag_type = t.tag_type,
                .size = t.size,
                .alignment = t.alignment,
            });
            return try zcu.internNamed(.{ .enum_type = .{
                .file = file,
                .zir_inst = inst,
                .captures = try zcu.ip.arena(Zcu.tid).dupe(Index, c.captures),
                .name = undefined,
                .key = try zcu.ip.getString(Zcu.tid, c.key),
                .info = info,
            } }, recordedName(c.name));
        }
        const ck: Zcu.ContainerKind = switch (kind) {
            .struct_type => if (opcode == .struct_decl or opcode == .reify_struct) .@"struct" else return null,
            .enum_type => if (opcode == .enum_decl or opcode == .reify_enum) .@"enum" else return null,
            .union_type => if (opcode == .union_decl or opcode == .reify_union) .@"union" else return null,
            .opaque_type => if (opcode == .opaque_decl) .@"opaque" else return null,
            else => unreachable,
        };
        if ((c.reified_layout != null) != (opcode == .reify_struct or opcode == .reify_enum or opcode == .reify_union)) return null;
        const parent_ns = if (zcu.ip.containerType(c.parent) != null) zcu.ip.structInfo(c.parent).namespace else return null;
        // A reified enum's mode is read by its tag name, which the mode
        // type's layout holds: a lazy build may not have loaded it yet.
        if (c.reified_layout != null and kind == .enum_type) {
            if (c.captures.len < 2) return null;
            zcu.ensureStructLayout(zcu.ip.typeOf(c.captures[1])) catch return null;
        }
        const ty = try zcu.createContainerType(ck, file, inst, c.captures, recordedName(c.name), c.key, parent_ns, c.reified_layout);
        // A reified type's fields come from its captures, as `@Struct` and
        // the like make them.
        if (c.reified_layout != null) try Sema.fillReifiedInfo(zcu, ty);
        return ty;
    }

    pub fn nav(res: Resolver, owner: Index, name: []const u8) !?InternPool.NavIndex {
        return results.Lookup.nav(.{ .zcu = res.r.zcu }, owner, name);
    }

    pub fn func(res: Resolver, f: InternPool.Func) !?Index {
        const r = res.r;
        const zcu = r.zcu;
        const owner = zcu.ip.getNav(f.owner_nav);
        const input = r.inputOf(owner.file) orelse return null;
        var key = f;
        key.zir_inst = r.mapInst(input, f.zir_inst) orelse return null;
        const zir = &zcu.file(owner.file).zir;
        if (@backingInt(key.zir_inst) >= zir.instructions.len) return null;
        switch (zir.instructions.items(.tag)[@backingInt(key.zir_inst)]) {
            .func, .func_inferred, .func_fancy => {},
            else => return null,
        }
        return try zcu.ip.get(Zcu.tid, .{ .func = key });
    }

    pub fn intern(res: Resolver, key: InternPool.Key) !?Index {
        return try res.r.zcu.ip.get(Zcu.tid, key);
    }

    pub fn namedTuple(res: Resolver, key: InternPool.Key, name: []const u8) !?Index {
        return try res.r.zcu.internNamed(key, recordedName(name));
    }
};
