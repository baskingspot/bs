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
const Manifest = cache.Manifest;
const Pack = cache.Pack;
const results = cache.results;
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
/// Each input's file in this build, once looked up: its index + 1, or 0
/// if not looked up yet, or `no_file`.
input_files: []u32,
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
stats: Stats = .{},
/// `ZAP_CACHE_CHECK`: print each green unit that could not be loaded.
check: bool = false,

const no_file = std.math.maxInt(u32);

const State = enum(u8) { unknown, green, red };

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
pub fn create(gpa: Allocator, io: Io, m: *const Manifest, dir: Io.Dir, arch: Atom.Unwind.Arch, fe: *const Frontend, zcu: *Zcu, emit: *Emit) !*Replay {
    const t0 = Io.Timestamp.now(io, .awake);
    var pack: Pack = try .open(io, dir);
    errdefer pack.close(gpa, io);
    if (pack.id != m.pack_id) return error.PackMismatch;
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
        .decoder = try .init(gpa, &zcu.ip, m.items, m.item_starts, .{ .r = undefined }),
        .keyer = .init(zcu, gpa),
    };
    r.decoder.resolver = .{ .r = r };
    @memset(r.state, .unknown);
    @memset(r.dependees, null);
    @memset(r.input_files, 0);

    // Each loaded file's input, and the inputs that changed.
    for (0..m.inputCount()) |i| _ = try r.by_path.getOrPutValue(gpa, m.input(@intCast(i))[1], @intCast(i));
    var path_buf: std.ArrayList(u8) = .empty;
    defer path_buf.deinit(gpa);
    var changed: std.ArrayList(seeds.Changed) = .empty;
    defer changed.deinit(gpa);
    var seen = try std.DynamicBitSetUnmanaged.initEmpty(gpa, m.inputCount());
    defer seen.deinit(gpa);
    for (fe.files.items, 0..) |*f, fi| {
        try Incremental.inputPath(gpa, &path_buf, fe, f.module, f.sub_path);
        const i = r.by_path.get(path_buf.items) orelse continue;
        seen.set(i);
        r.input_files[i] = @intCast(fi + 1);
        try r.file_inputs.put(gpa, @intCast(fi), i);
        if (@as(Hash, @bitCast(f.content_hash)) != m.input(i)[0].content_hash)
            try changed.append(gpa, .{ .input = i, .file = @fromBackingInt(@as(u32, @intCast(fi))) });
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
    for (stack.items) |i| r.outdated.set(i);
    while (stack.pop()) |i| for (m.rdeps(i)) |part| for (part) |d| if (!r.outdated.isSet(d)) {
        r.outdated.set(d);
        try stack.append(gpa, d);
    };
    r.stats.outdated = @intCast(r.outdated.count());
    r.stats.setup_ns = @intCast(t0.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds);
    return r;
}

pub fn destroy(r: *Replay) void {
    const gpa = r.gpa;
    r.pack.close(gpa, r.io);
    r.outdated.deinit(gpa);
    gpa.free(r.state);
    gpa.free(r.dependees);
    r.maps.deinit(gpa);
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
    const refs = try r.resolveRefs(g, false) orelse return r.miss(g, "references");
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
    const refs = try r.resolveRefs(g, false) orelse return r.miss(g, "references");
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
    const refs = try r.resolveRefs(g, false) orelse return r.miss(g, "references");
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
    if (m.atoms(g.node).len == 0) return r.miss(g, "no atoms");
    // The inferred error set, if the function has one: from its node.
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
    // The atoms, decoded before anything is committed.
    var atoms: std.ArrayList(struct { atom: Atom, debug: ?Atom.Debug }) = .empty;
    defer atoms.deinit(r.gpa);
    const changed_file = r.isChangedFile(owner.file);
    for (m.atoms(g.node)) |ref| {
        const d = r.pack.decode(ref, r.arch) catch return r.miss(g, "atom");
        var debug = d.debug;
        if (debug) |*dbg| {
            if (changed_file) dbg.base_line = zcu.file(owner.file).zir.getDeclaration(owner.zir_inst).src_line;
            if (dbg.inlines.len != 0) dbg.inlines = try r.refreshInlines(dbg);
        }
        try atoms.append(r.gpa, .{ .atom = d.atom, .debug = debug });
    }
    var content: std.ArrayList(Atom) = .empty;
    defer content.deinit(r.gpa);
    for (m.deps(g.node)) |e| {
        const d = Manifest.Edge.nodeOf(e);
        if (m.node(d).tag != @backingInt(Tag.content)) continue;
        for (m.atoms(d)) |ref| try content.append(r.gpa, (r.pack.decode(ref, r.arch) catch return r.miss(g, "content atom")).atom);
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
    r.stats.loaded_funcs += 1;
    return true;
}

/// Inlined callees' base lines, for those in changed files, as CodeGen
/// would now write them.
fn refreshInlines(r: *Replay, d: *const Atom.Debug) ![]const Atom.Debug.Inline {
    const zcu = r.zcu;
    var out: ?[]Atom.Debug.Inline = null;
    for (d.inlines, 0..) |in, i| {
        const nav_index = (try r.navByKey(d.inline_callees[i])) orelse continue;
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
    if (r.input_files[i] == 0) r.input_files[i] = file + 1;
    return i;
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
    if (analyze) return r.red(node);
    const n = m.node(node);
    const has_result = switch (unit) {
        .func, .comptime_decl => true,
        else => m.result(node).len != 0,
    };
    if (n.src_hash != r.keyer.unitSrcHash(unit) or !has_result) return r.red(node);
    const g: Green = .{ .unit = unit, .node = node, .deps_start = r.deps.items.len };
    errdefer r.deps.shrinkRetainingCapacity(g.deps_start);
    const is_outdated = r.outdated.isSet(node);
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
        const dep = try r.dependee(d, dtag) orelse {
            r.noteMiss(unit, @tagName(dtag));
            return r.redAt(g);
        };
        // A declaration in progress, which analysis reads only for its
        // address (`Sema.navRef`): its result cannot have changed if this
        // unit's dependencies did not.
        const in_progress = dep == .nav_val and r.zcu.ip.getNav(dep.nav_val).status == .resolving;
        if (in_progress and is_outdated) return r.redAt(g);
        if (!in_progress and !r.ensure(dep)) return r.redAt(g);
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
        }
        try r.deps.append(r.gpa, dep);
    }
    return g;
}

const Ref = union(enum) {
    func: Index,
    nav: InternPool.NavIndex,
    other: Manifest.Ref,
};

/// A loaded unit's references with their targets resolved, or null if one
/// cannot be. Only a function's code makes requests other than queueing
/// functions: other units' data is lowered again by Emit, which makes them.
fn resolveRefs(r: *Replay, g: Green, is_func: bool) !?[]Ref {
    var out: std.ArrayList(Ref) = .empty;
    errdefer out.deinit(r.gpa);
    for (r.m.nodeRefs(g.node)) |ref| switch (ref.kind) {
        .func => {
            const dep = try r.dependee(ref.value, .func) orelse return null;
            try out.append(r.gpa, .{ .func = dep.func_body });
        },
        .nav => if (is_func) {
            const dep = try r.dependee(ref.value, .nav_val) orelse return null;
            r.zcu.ensureNavVal(dep.nav_val) catch return null;
            try out.append(r.gpa, .{ .nav = dep.nav_val });
        },
        .analyze, .quota => {},
        else => if (is_func) try out.append(r.gpa, .{ .other = ref }),
    };
    return try out.toOwnedSlice(r.gpa);
}

/// Records a loaded unit's dependencies and replays its references.
fn commit(r: *Replay, unit: Zcu.AnalUnit, g: Green, refs: []const Ref) !void {
    const zcu = r.zcu;
    const m = r.m;
    try zcu.recordDeps(unit, r.deps.items[g.deps_start..], &.{});
    r.deps.shrinkRetainingCapacity(g.deps_start);
    r.state[g.node] = .green;
    r.stats.loaded += 1;
    const emit = r.emit;
    const saved = emit.owner;
    defer emit.owner = saved;
    emit.owner = .{ .unit = unit };
    for (refs) |ref| switch (ref) {
        .func => |func| try zcu.queueFuncFrom(unit, func),
        .nav => |nav| _ = try emit.navKey(nav),
        .other => |o| switch (o.kind) {
            .err => _ = try emit.useError(try zcu.ip.getString(Zcu.tid, m.errorName(o.value))),
            .ext, .ext_weak => _ = try emit.useExtern(m.refName(o.value), o.kind == .ext_weak),
            .rt => {
                const key = m.refName(o.value);
                const rest = key["compiler_rt:compiler_rt/".len..];
                const colon = std.mem.lastIndexOfScalar(u8, rest, ':').?;
                _ = try emit.requestCompilerRt(rest[0..colon], rest[colon + 1 ..]);
            },
            .error_names => try emit.useErrorNames(),
            .func, .nav, .analyze, .quota => unreachable,
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
        .nav_val, .nav_ty => |nav| zcu.ensureNavVal(nav) catch return false,
        .type_layout => |ty| zcu.ensureStructLayout(ty) catch return false,
        .struct_defaults => |ty| zcu.ensureStructDefaults(ty) catch return false,
        .func_ies => |func| _ = zcu.ensureFuncIes(func) catch return false,
        .func_body, .namespace_name, .namespace, .embed_file => {},
    }
    return true;
}

// ---------------------------------------------------------------------------
// Resolving items that name source

/// The file input `input` is in this build, if it is loaded.
fn fileOf(r: *Replay, input: u32) ?u32 {
    if (input >= r.input_files.len) return null;
    if (r.input_files[input] == 0) {
        // Loaded since `create` (compiler_rt), or not at all.
        r.input_files[input] = no_file;
        const fe = r.zcu.fe;
        var path_buf: std.ArrayList(u8) = .empty;
        defer path_buf.deinit(r.gpa);
        const want = r.m.input(input)[1];
        for (fe.files.items, 0..) |*f, fi| {
            Incremental.inputPath(r.gpa, &path_buf, fe, f.module, f.sub_path) catch return null;
            if (!std.mem.eql(u8, path_buf.items, want)) continue;
            r.input_files[input] = @intCast(fi + 1);
            r.file_inputs.put(r.gpa, @intCast(fi), input) catch return null;
            break;
        }
    }
    const v = r.input_files[input];
    return if (v == no_file) null else v - 1;
}

/// Instruction `inst` of input `input`'s recorded ZIR, in its ZIR now.
fn mapInst(r: *Replay, input: u32, inst: Zir.Inst.Index) ?Zir.Inst.Index {
    const entry = r.maps.maps.get(input) orelse return inst;
    const map = entry orelse return null;
    return map.get(inst);
}

/// Creates the items that name source, as analysis would, without
/// resolving anything (see "Serialized results").
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
            return try zcu.ip.get(Zcu.tid, .{ .enum_type = .{
                .file = file,
                .zir_inst = inst,
                .captures = try zcu.ip.arena(Zcu.tid).dupe(Index, c.captures),
                .name = try zcu.ip.getString(Zcu.tid, c.name),
                .key = try zcu.ip.getString(Zcu.tid, c.key),
                .info = info,
            } });
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
        const ty = try zcu.createContainerType(ck, file, inst, c.captures, c.name, c.key, parent_ns, c.reified_layout);
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
};
