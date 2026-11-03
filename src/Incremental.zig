//! Connects a compilation to the on-disk cache (`cache.zig`, "The on-disk
//! cache" in docs/architecture.md).
//!
//! - A build whose inputs did not change since the last successful one
//!   relinks from the cached Atoms and skips the frontend, Sema, and
//!   CodeGen (`relinkIfUnchanged`).
//! - Every successful build is recorded (`record`): each unit's atoms go
//!   to the global store as an entry, unless an equal entry is already
//!   there, and the compilation's manifest lists the units, their
//!   dependencies, source and result hashes, atoms (in the store packs it
//!   hard-links as base packs), input stats, error codes, and entry.
//! - The error codes of the last build are assigned first, so they stay
//!   stable across builds (`seedErrors`).
//!
//! Re-analyzing only the units an edit reaches, from the manifest's
//! reverse edges, is the next step; it needs Sema to load the results of
//! the units it does not re-analyze.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const cache = @import("cache.zig");
const Manifest = cache.Manifest;
const Pack = cache.Pack;
const Store = cache.Store;
const atoms_codec = cache.atoms;
const Hash = cache.Hash;
const Frontend = @import("Frontend.zig");
const InternPool = @import("InternPool.zig");
const Zcu = @import("Zcu.zig");
const Emit = @import("Emit.zig");
const Atom = @import("link/Atom.zig");
const Elf = @import("link/Elf.zig");

const Incremental = @This();

gpa: Allocator,
io: Io,
/// `<global cache>`, for the store.
global: Io.Dir,
/// The compilation's directory, locked by `lock` until `close`.
dir: Io.Dir,
lock: Io.File,
/// Identifies the compiler and target: part of every store key, so store
/// entries are shared by every project built by the same zap for the same
/// target.
store_seed: Hash,
/// Taken before the inputs are read; inputs modified after it are
/// recorded as needing a rehash.
build_start: Io.Timestamp,
/// The last successful build's manifest, if any.
prev: ?Manifest = null,
/// `ZAP_CACHE_TIMING`: print where the cache's time goes.
timing: bool,
/// `ZAP_CACHE_CHECK`: check that the last manifest's reverse edges predict
/// every result this build changed.
check: bool = false,
/// The recording `startRecord` runs while the build links.
recording: ?Io.Future(anyerror!Recorded) = null,

/// Opens and locks the directory of the compilation that `args` (the
/// command line after `zap`) describes, run from the current directory.
/// `zig_lib_dir` is the std that compilation uses.
pub fn open(gpa: Allocator, io: Io, dirs: Frontend.CacheDirs, args: []const []const u8, zig_lib_dir: []const u8, target: []const u8, timing: bool) !Incremental {
    const build_start = Io.Clock.real.now(io);
    // The compiler's identity: a rebuilt zap must not reuse what an older
    // one cached.
    const exe = try std.process.openExecutable(io, .{});
    const exe_stat = exe.stat(io);
    exe.close(io);
    const st = try exe_stat;
    var id: std.ArrayList(u8) = .empty;
    defer id.deinit(gpa);
    try id.print(gpa, "zap\x00{d}\x00{d}\x00{d}\x00{s}\x00", .{ st.inode, st.size, st.mtime.toNanoseconds(), target });
    const store_seed = cache.hash(0, id.items);
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    try id.print(gpa, "{s}\x00{s}\x00", .{ cwd, zig_lib_dir });
    for (args) |a| try id.print(gpa, "{s}\x00", .{a});
    const key = cache.hash(1, id.items);

    var local = try Io.Dir.cwd().createDirPathOpen(io, dirs.local, .{});
    defer local.close(io);
    cache.trimCompilations(io, local) catch {};
    const dir = try cache.compilationDir(io, local, key);
    errdefer dir.close(io);
    const lock = try cache.lock(io, dir);
    errdefer lock.close(io);
    const global = try Io.Dir.cwd().createDirPathOpen(io, dirs.global, .{});
    var inc: Incremental = .{
        .gpa = gpa,
        .io = io,
        .global = global,
        .dir = dir,
        .lock = lock,
        .store_seed = store_seed,
        .build_start = build_start,
        .timing = timing,
    };
    inc.prev = Manifest.open(gpa, io, dir) catch null;
    return inc;
}

pub fn close(inc: *Incremental) void {
    if (inc.recording) |*f| {
        var r = f.cancel(inc.io) catch null;
        if (r) |*rec| rec.discard(inc);
    }
    if (inc.prev) |*m| m.close(inc.gpa, inc.io);
    inc.global.close(inc.io);
    inc.lock.close(inc.io);
    inc.dir.close(inc.io);
}

fn now(io: Io) Io.Timestamp {
    return Io.Timestamp.now(io, .awake);
}

fn ms(a: Io.Timestamp, b: Io.Timestamp) f64 {
    return @as(f64, @floatFromInt(a.durationTo(b).nanoseconds)) / 1e6;
}

/// If no input changed since the last successful build, links its Atoms
/// into `sub_path` and returns true. Otherwise returns false, and the
/// caller builds.
pub fn relinkIfUnchanged(inc: *Incremental, out_dir: Io.Dir, sub_path: []const u8) !bool {
    const gpa = inc.gpa;
    const io = inc.io;
    const t0 = now(io);
    const m = if (inc.prev) |*m| m else return false;
    if (m.entry == 0) return false;
    var changed: std.ArrayList(u32) = .empty;
    defer changed.deinit(gpa);
    try m.changedInputs(gpa, io, &changed);
    if (changed.items.len != 0) {
        if (inc.timing) std.debug.print("cache: {d} inputs changed, first {s}\n", .{ changed.items.len, m.input(changed.items[0])[1] });
        return false;
    }
    const t1 = now(io);

    var pack: Pack = try .open(io, inc.dir);
    defer pack.close(gpa, io);
    if (pack.id != m.pack_id) return false;
    for (0..m.bases.len) |i| _ = pack.addBase(gpa, io, inc.dir, m.basePack(i)) catch return false;
    const in = try m.linkInput(gpa);
    const files = try gpa.alloc([]const u8, m.fileCount());
    defer gpa.free(files);
    for (files, 0..) |*f, i| f.* = m.file(@intCast(i));
    const input = try pack.linkAtoms(gpa, in.refs, in.debug_atoms, .{ .of = in.debug_files, .names = files });
    defer input.deinit(gpa);
    const values = try gpa.alloc(Elf.NumberedValue, m.errorCount());
    defer gpa.free(values);
    for (values, 1..) |*v, code| v.* = .{ .symbol = m.errorSymbol(@intCast(code)), .value = code };
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const t2 = now(io);

    var diag: Elf.Diagnostic = .{};
    Elf.linkInput(gpa, io, out_dir, sub_path, input, .{
        .entry = @fromBackingInt(m.entry),
        .symbols = .{
            .atoms = in.numbered,
            .targets = in.targets,
            .targets_tail = in.targets_tail,
            .values = values,
            .entry = m.entry_symbol,
            .len = m.symbolLen(),
        },
        .diag = &diag,
        .comp_dir = cwd,
    }) catch |err| switch (err) {
        // A damaged pack or manifest: build from scratch instead.
        error.InvalidInput, error.InvalidSymbols, error.InvalidDebugInfo => return false,
        else => {
            std.debug.print("error: link failed: {t} (atom '{s}')\n", .{ err, diag.atom });
            return err;
        },
    };
    if (inc.timing) std.debug.print("cache: no input changed; relinked {d} atoms in {d:.2} ms (manifest and {d} stats {d:.2}, packs mapped and input gathered {d:.2}, link {d:.2})\n", .{
        in.refs.len, ms(t0, now(io)), m.inputCount(), ms(t0, t1), ms(t1, t2), ms(t2, now(io)),
    });
    return true;
}

/// Assigns the last build's error codes first, so that they keep their
/// values. Call before analysis.
pub fn seedErrors(inc: *const Incremental, zcu: *Zcu) !void {
    const m = if (inc.prev) |*m| m else return;
    const ip = &zcu.ip;
    for (1..m.errorCount() + 1) |code| {
        const v = try ip.errorValue(try ip.getString(Zcu.tid, m.errorName(@intCast(code))));
        if (v != code) return; // A different assignment already started.
    }
}

const Node = struct {
    key: Hash,
    result_hash: Hash = 0,
    /// The result hash, plus what may change without the result changing:
    /// the debug info's `base_line`, which moves when lines above the
    /// declaration are added or removed. A store entry is reused only if
    /// this matches.
    exact_hash: Hash = 0,
    src_hash: Hash = 0,
    tag: Tag,
    /// Node indices, ascending and distinct; set by `Recorder.group`.
    deps: []const u32 = &.{},
    /// Indices into `Emit.atoms`, ascending; set by `Recorder.group`.
    atoms: []const u32 = &.{},
};

/// `Manifest.Node.tag`.
pub const Tag = enum(u8) {
    nav_val,
    type_layout,
    func,
    comptime_decl,
    nav_ty,
    func_body,
    func_ies,
    namespace_name,
    namespace,
    content,
    link,
    embed_file,
};

/// Keys that are hashes already.
const HashContext = struct {
    pub fn hash(_: HashContext, k: Hash) u64 {
        return @truncate(k);
    }
    pub fn eql(_: HashContext, a: Hash, b: Hash) bool {
        return a == b;
    }
};

/// Hashes two words with one multiply: unit and dependee keys are a tag
/// and a few indices, and hashing them byte by byte cost more than the
/// rest of recording an edge.
fn mix(a: u64, b: u64) u64 {
    const m = @as(u128, a ^ 0x9e3779b97f4a7c15) * (b ^ 0xbf58476d1ce4e5b9);
    return @truncate(m ^ (m >> 64));
}

const UnitContext = struct {
    pub fn hash(_: UnitContext, u: Zcu.AnalUnit) u64 {
        return switch (u) {
            .nav_val => |n| mix(0, @backingInt(n)),
            .type_layout => |t| mix(1, @backingInt(t)),
            .func => |f| mix(2, @backingInt(f)),
            .comptime_decl => |c| mix(3 | @as(u64, c.file) << 8 | @as(u64, c.namespace) << 32, @as(u64, @backingInt(c.inst)) << 32 | c.ordinal),
        };
    }
    pub fn eql(_: UnitContext, a: Zcu.AnalUnit, b: Zcu.AnalUnit) bool {
        return std.meta.eql(a, b);
    }
};

const DependeeContext = struct {
    pub fn hash(_: DependeeContext, d: Zcu.Dependee) u64 {
        return switch (d) {
            .nav_val => |n| mix(0, @backingInt(n)),
            .nav_ty => |n| mix(1, @backingInt(n)),
            .type_layout => |t| mix(2, @backingInt(t)),
            .func_body => |f| mix(3, @backingInt(f)),
            .func_ies => |f| mix(4, @backingInt(f)),
            .namespace_name => |nn| mix(5 | @as(u64, nn.namespace) << 8, @backingInt(nn.name)),
            .namespace => |ns| mix(6, ns),
            .embed_file => |i| mix(7, i),
        };
    }
    pub fn eql(_: DependeeContext, a: Zcu.Dependee, b: Zcu.Dependee) bool {
        return std.meta.eql(a, b);
    }
};

const Recorder = struct {
    gpa: Allocator,
    zcu: *Zcu,
    nodes: std.ArrayList(Node) = .empty,
    map: std.HashMapUnmanaged(Hash, u32, HashContext, std.hash_map.default_max_load_percentage) = .empty,
    /// Each distinct unit and dependee, by index into `unit_list` and
    /// `dependee_list`, whose `Info` (key and hashes) `prepare` computes
    /// on every core before `unitNode` and `dependeeNode` make nodes of
    /// them. Dependees that are units (`nav_val`, `type_layout`) are only
    /// in `units`.
    units: std.HashMapUnmanaged(Zcu.AnalUnit, u32, UnitContext, std.hash_map.default_max_load_percentage) = .empty,
    dependees: std.HashMapUnmanaged(Zcu.Dependee, u32, DependeeContext, std.hash_map.default_max_load_percentage) = .empty,
    unit_list: std.ArrayList(Zcu.AnalUnit) = .empty,
    dependee_list: std.ArrayList(Zcu.Dependee) = .empty,
    /// The unit item that produces each dependee, or `no_node`.
    dependee_producer: std.ArrayList(u32) = .empty,
    unit_info: []Info = &.{},
    dependee_info: []Info = &.{},
    /// (node, dependency) and (node, atom index) pairs, grouped into the
    /// nodes' `deps` and `atoms` by `group`: one array each instead of two
    /// small lists per node.
    edges: std.ArrayList([2]u32) = .empty,
    atom_pairs: std.ArrayList([2]u32) = .empty,
    storage: []u32 = &.{},

    const no_node = std.math.maxInt(u32);

    const Ref = union(enum) { unit: u32, dependee: u32 };

    /// What a unit's or dependee's node gets, and the node once made.
    const Info = struct {
        key: Hash = 0,
        src_hash: Hash = 0,
        result_hash: Hash = 0,
        node: u32 = no_node,
    };

    fn deinit(r: *Recorder) void {
        const gpa = r.gpa;
        r.edges.deinit(gpa);
        r.atom_pairs.deinit(gpa);
        gpa.free(r.storage);
        r.nodes.deinit(gpa);
        r.map.deinit(gpa);
        r.units.deinit(gpa);
        r.dependees.deinit(gpa);
        r.unit_list.deinit(gpa);
        r.dependee_list.deinit(gpa);
        r.dependee_producer.deinit(gpa);
        gpa.free(r.unit_info);
        gpa.free(r.dependee_info);
    }

    fn node(r: *Recorder, key: Hash, tag: Tag) !struct { u32, bool } {
        const gop = try r.map.getOrPut(r.gpa, key);
        if (gop.found_existing) return .{ gop.value_ptr.*, false };
        gop.value_ptr.* = @intCast(r.nodes.items.len);
        try r.nodes.append(r.gpa, .{ .key = key, .tag = tag });
        return .{ gop.value_ptr.*, true };
    }

    /// The unit's index in `unit_list`.
    fn addUnit(r: *Recorder, unit: Zcu.AnalUnit) !u32 {
        const gop = try r.units.getOrPut(r.gpa, unit);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(r.unit_list.items.len);
            try r.unit_list.append(r.gpa, unit);
        }
        return gop.value_ptr.*;
    }

    /// A `Ref` to the dependee: a unit, or its index in `dependee_list`.
    fn addDependee(r: *Recorder, d: Zcu.Dependee) !Ref {
        const producer: u32 = switch (d) {
            .nav_val => |nav| return .{ .unit = try r.addUnit(.{ .nav_val = nav }) },
            .type_layout => |ty| return .{ .unit = try r.addUnit(.{ .type_layout = ty }) },
            // With an edge to the unit that produces them.
            .nav_ty => |nav| try r.addUnit(.{ .nav_val = nav }),
            .func_ies => |func| try r.addUnit(.{ .func = func }),
            .func_body, .namespace_name, .namespace, .embed_file => no_node,
        };
        const gop = try r.dependees.getOrPut(r.gpa, d);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(r.dependee_list.items.len);
            try r.dependee_list.append(r.gpa, d);
            try r.dependee_producer.append(r.gpa, producer);
        }
        return .{ .dependee = gop.value_ptr.* };
    }

    /// Computes every listed unit's and dependee's `Info`, on every core:
    /// rendering and hashing keys and reading source and result hashes is
    /// most of recording the graph, and only reads the Zcu.
    fn prepare(r: *Recorder, io: Io) !void {
        const gpa = r.gpa;
        r.unit_info = try gpa.alloc(Info, r.unit_list.items.len);
        @memset(r.unit_info, .{});
        r.dependee_info = try gpa.alloc(Info, r.dependee_list.items.len);
        @memset(r.dependee_info, .{});
        try forChunks(io, r.unit_list.items.len + r.dependee_list.items.len, struct {
            r: *const Recorder,

            fn run(c: @This(), lo: usize, hi: usize, _: usize) !void {
                var k: Keyer = .{ .zcu = c.r.zcu, .key_buf = .init(c.r.gpa), .unit_buf = .init(c.r.gpa) };
                defer k.key_buf.deinit();
                defer k.unit_buf.deinit();
                const n_units = c.r.unit_list.items.len;
                for (lo..hi) |i| {
                    if (i < n_units)
                        c.r.unit_info[i] = try k.unitInfo(c.r.unit_list.items[i])
                    else
                        c.r.dependee_info[i - n_units] = try k.dependeeInfo(c.r.dependee_list.items[i - n_units]);
                }
            }
        }{ .r = r });
    }

    /// The node of unit `i` (an index in `unit_list`).
    fn unitNode(r: *Recorder, i: u32) !u32 {
        const info = &r.unit_info[i];
        if (info.node != no_node) return info.node;
        const index, const new = try r.node(info.key, unitTag(r.unit_list.items[i]));
        if (new) {
            r.nodes.items[index].src_hash = info.src_hash;
            r.nodes.items[index].result_hash = info.result_hash;
        }
        info.node = index;
        return index;
    }

    /// The node of what a unit read, with an edge to the unit that
    /// produces it, if any.
    fn dependeeNode(r: *Recorder, ref: Ref) !u32 {
        const i = switch (ref) {
            .unit => |u| return r.unitNode(u),
            .dependee => |i| i,
        };
        const info = &r.dependee_info[i];
        if (info.node != no_node) return info.node;
        const tag: Tag = switch (r.dependee_list.items[i]) {
            .nav_val, .type_layout => unreachable,
            .nav_ty => .nav_ty,
            .func_ies => .func_ies,
            .func_body => .func_body,
            .namespace_name => .namespace_name,
            .namespace => .namespace,
            .embed_file => .embed_file,
        };
        const index, const new = try r.node(info.key, tag);
        info.node = index;
        if (new) {
            r.nodes.items[index].result_hash = info.result_hash;
            const producer = r.dependee_producer.items[i];
            if (producer != no_node) try r.edges.append(r.gpa, .{ index, try r.unitNode(producer) });
        }
        return index;
    }

    fn unitTag(unit: Zcu.AnalUnit) Tag {
        return switch (unit) {
            .nav_val => .nav_val,
            .type_layout => .type_layout,
            .func => .func,
            .comptime_decl => .comptime_decl,
        };
    }

    /// Sets each node's `deps` (sorted, without repeats) and `atoms` (in
    /// order) from the pairs, with stable counting sorts: O(pairs + nodes).
    fn group(r: *Recorder) !void {
        const gpa = r.gpa;
        const n = r.nodes.items.len;
        const tmp = try gpa.alloc([2]u32, @max(r.edges.items.len, r.atom_pairs.items.len));
        defer gpa.free(tmp);
        const counts = try gpa.alloc(u32, n + 1);
        defer gpa.free(counts);
        // By dependency, then stably by node: sorted pairs.
        countingSort(r.edges.items, 1, counts, tmp);
        countingSort(tmp[0..r.edges.items.len], 0, counts, r.edges.items);
        countingSort(r.atom_pairs.items, 0, counts, tmp);
        r.storage = try gpa.alloc(u32, r.edges.items.len + r.atom_pairs.items.len);
        var at: usize = 0;
        var i: usize = 0;
        const edges = r.edges.items;
        while (i < edges.len) {
            const node_index = edges[i][0];
            const start = at;
            while (i < edges.len and edges[i][0] == node_index) : (i += 1) {
                if (at > start and r.storage[at - 1] == edges[i][1]) continue;
                r.storage[at] = edges[i][1];
                at += 1;
            }
            r.nodes.items[node_index].deps = r.storage[start..at];
        }
        const atom_pairs = tmp[0..r.atom_pairs.items.len];
        i = 0;
        while (i < atom_pairs.len) {
            const node_index = atom_pairs[i][0];
            const start = at;
            while (i < atom_pairs.len and atom_pairs[i][0] == node_index) : (i += 1) {
                r.storage[at] = atom_pairs[i][1];
                at += 1;
            }
            r.nodes.items[node_index].atoms = r.storage[start..at];
        }
    }

    fn countingSort(in: []const [2]u32, comptime field: usize, counts: []u32, out: [][2]u32) void {
        @memset(counts, 0);
        for (in) |p| counts[p[field] + 1] += 1;
        for (1..counts.len) |k| counts[k] += counts[k - 1];
        for (in) |p| {
            out[counts[p[field]]] = p;
            counts[p[field]] += 1;
        }
    }
};

/// Renders and hashes keys, and reads source and result hashes, for one
/// thread of `Recorder.prepare`.
const Keyer = struct {
    zcu: *Zcu,
    key_buf: std.Io.Writer.Allocating,
    unit_buf: std.Io.Writer.Allocating,

    /// A key for `parts`, distinct per `tag`.
    fn keyOf(k: *Keyer, tag: Tag, parts: []const []const u8) !Hash {
        k.key_buf.clearRetainingCapacity();
        const w = &k.key_buf.writer;
        try w.writeByte(@backingInt(tag));
        for (parts) |p| {
            try w.writeAll(p);
            try w.writeByte(0);
        }
        return cache.hash(2, k.key_buf.written());
    }

    /// Valid until the next call.
    fn unitKeyString(k: *Keyer, unit: Zcu.AnalUnit) ![]const u8 {
        k.unit_buf.clearRetainingCapacity();
        try k.zcu.unitKey(unit, &k.unit_buf.writer);
        return k.unit_buf.written();
    }

    fn srcHash(k: *Keyer, file: u32, inst: std.zig.Zir.Inst.Index) Hash {
        const h = k.zcu.file(file).zir.getAssociatedSrcHash(inst) orelse return 0;
        return @bitCast(h);
    }

    fn unitInfo(k: *Keyer, unit: Zcu.AnalUnit) !Recorder.Info {
        const ip = &k.zcu.ip;
        var info: Recorder.Info = .{ .key = try k.keyOf(Recorder.unitTag(unit), &.{try k.unitKeyString(unit)}) };
        switch (unit) {
            .nav_val => |nav_index| {
                const nav = ip.getNav(nav_index);
                info.src_hash = k.srcHash(nav.file, nav.zir_inst);
                if (nav.status == .resolved) info.result_hash = ip.stableHash(nav.val);
            },
            .type_layout => |ty| {
                const c = ip.containerType(ty).?;
                info.src_hash = k.srcHash(c.file, c.zir_inst);
                // The type's identity; its layout is not hashed yet.
                info.result_hash = ip.stableHash(ty);
            },
            .func => |func| {
                const owner = ip.getNav(ip.indexToKey(func).func.owner_nav);
                info.src_hash = k.srcHash(owner.file, owner.zir_inst);
                // The result is the function's atom, hashed in `record`.
            },
            .comptime_decl => |c| info.src_hash = k.srcHash(c.file, c.inst),
        }
        return info;
    }

    fn dependeeInfo(k: *Keyer, d: Zcu.Dependee) !Recorder.Info {
        const ip = &k.zcu.ip;
        switch (d) {
            .nav_val, .type_layout => unreachable, // Units.
            .nav_ty => |nav_index| {
                const nav = ip.getNav(nav_index);
                return .{
                    .key = try k.keyOf(.nav_ty, &.{ip.stringSlice(nav.key)}),
                    .result_hash = if (nav.status == .resolved) ip.stableHash(ip.typeOf(nav.val)) else 0,
                };
            },
            .func_body => |func| {
                const owner = ip.getNav(ip.indexToKey(func).func.owner_nav);
                return .{
                    .key = try k.keyOf(.func_body, &.{try k.unitKeyString(.{ .func = func })}),
                    .result_hash = k.srcHash(owner.file, owner.zir_inst),
                };
            },
            .func_ies => |func| {
                var h: Hash = @intFromBool(k.zcu.anyerror_ies.contains(func));
                if (k.zcu.inferred_errors.get(func)) |names| {
                    // Order-independent: the set, not the discovery order.
                    for (names) |name| h +%= cache.hash(3, ip.stringSlice(name));
                }
                return .{ .key = try k.keyOf(.func_ies, &.{try k.unitKeyString(.{ .func = func })}), .result_hash = h };
            },
            .namespace_name => |nn| {
                const ns = k.zcu.namespacePtr(nn.namespace);
                return .{
                    .key = try k.keyOf(.namespace_name, &.{ ns.key, ip.stringSlice(nn.name) }),
                    // Which declaration the name finds, if any.
                    .result_hash = if (ns.decls.get(nn.name)) |nav| cache.hash(3, ip.stringSlice(ip.getNav(nav).key)) else 0,
                };
            },
            .namespace => |ns_index| {
                const ns = k.zcu.namespacePtr(ns_index);
                var h: Hash = 0;
                for (ns.decls.keys()) |name| h = cache.hash(@truncate(h), ip.stringSlice(name)) ^ h;
                return .{ .key = try k.keyOf(.namespace, &.{ns.key}), .result_hash = h };
            },
            // The file's contents, by its path in its module.
            .embed_file => |i| {
                const f = k.zcu.embed_files.values()[i];
                return .{ .key = try k.keyOf(.embed_file, &.{f.key}), .result_hash = f.hash };
            },
        }
    }
};

/// Starts recording the build that `emit` is about to link, on another
/// thread: `record` needs only the atoms and the Zcu, which the link does
/// not change, so it runs alongside the link. `finishRecord` keeps or
/// discards it. `fe`, `zcu`, and `emit` must not change until then.
pub fn startRecord(inc: *Incremental, fe: *const Frontend, zcu: *Zcu, emit: *const Emit) void {
    std.debug.assert(inc.recording == null);
    inc.recording = inc.io.async(record, .{ inc, fe, zcu, emit });
}

/// Waits for the recording `startRecord` started, and if the link
/// succeeded, makes it the compilation's manifest. A failed link discards
/// it, so the next build starts from the last successful one. (Its store
/// entries stay: they are valid results whichever way the link went.)
pub fn finishRecord(inc: *Incremental, linked: bool) !void {
    const t0 = now(inc.io);
    var r = try inc.recording.?.await(inc.io);
    inc.recording = null;
    const waited = ms(t0, now(inc.io));
    if (!linked) return r.discard(inc);
    defer r.discard(inc);
    try Manifest.Builder.place(&r.manifest, inc.io, inc.dir);
    // Base packs the new manifest does not name.
    var it = inc.dir.iterate();
    while (try it.next(inc.io)) |e| {
        if (!std.mem.endsWith(u8, e.name, ".zsp")) continue;
        for (r.base_names) |name| {
            if (std.mem.eql(u8, name, e.name)) break;
        } else inc.dir.deleteFile(inc.io, e.name) catch {};
    }
    if (inc.timing) std.debug.print("{s}; after the link, waited {d:.2} ms and placed in {d:.2} ms\n", .{ r.report, waited, ms(t0, now(inc.io)) - waited });
}

/// A recorded build, its manifest written but not placed.
const Recorded = struct {
    manifest: Io.File.Atomic,
    /// The base packs the manifest names.
    base_names: []const []const u8,
    /// For `ZAP_CACHE_TIMING`.
    report: []const u8,

    fn discard(r: *Recorded, inc: *Incremental) void {
        r.manifest.deinit(inc.io);
        for (r.base_names) |n| inc.gpa.free(n);
        inc.gpa.free(r.base_names);
        inc.gpa.free(r.report);
    }
};

/// Records a successful build into an unplaced manifest; see
/// `startRecord`.
fn record(inc: *Incremental, fe: *const Frontend, zcu: *Zcu, emit: *const Emit) anyerror!Recorded {
    const gpa = inc.gpa;
    const io = inc.io;
    const t0 = now(io);
    const ip = &zcu.ip;
    var r: Recorder = .{ .gpa = gpa, .zcu = zcu };
    defer r.deinit();
    // About one node per atom, unit, and dependee.
    const expected_nodes: u32 = @intCast(emit.atoms.items.len + 2 * zcu.deps.count());
    try r.nodes.ensureTotalCapacity(gpa, expected_nodes);
    try r.map.ensureTotalCapacity(gpa, expected_nodes);
    try r.units.ensureTotalCapacity(gpa, @intCast(zcu.deps.count()));
    try r.dependees.ensureTotalCapacity(gpa, @intCast(zcu.deps.count()));
    try r.atom_pairs.ensureTotalCapacity(gpa, emit.atoms.items.len);
    var n_edges: usize = emit.content_uses.items.len;
    for (zcu.deps.values()) |dependees| n_edges += dependees.len;
    try r.edges.ensureTotalCapacity(gpa, n_edges + n_edges / 4);

    // Every distinct unit and dependee, as `Recorder` items, keyed on
    // every core.
    const atom_units = try gpa.alloc(u32, emit.atoms.items.len);
    defer gpa.free(atom_units);
    for (emit.atom_owners.items, atom_units) |owner, *u| u.* = switch (owner) {
        .unit => |unit| try r.addUnit(unit),
        .content, .link => Recorder.no_node,
    };
    const dep_units = try gpa.alloc(u32, zcu.deps.count());
    defer gpa.free(dep_units);
    const dep_refs = try gpa.alloc(Recorder.Ref, n_edges);
    defer gpa.free(dep_refs);
    var n_refs: usize = 0;
    for (zcu.deps.keys(), zcu.deps.values(), dep_units) |unit, dependees, *u| {
        u.* = try r.addUnit(unit);
        for (dependees) |d| {
            dep_refs[n_refs] = try r.addDependee(d);
            n_refs += 1;
        }
    }
    const use_units = try gpa.alloc(u32, emit.content_uses.items.len);
    defer gpa.free(use_units);
    for (emit.content_uses.items, use_units) |use, *u| u.* = try r.addUnit(use.unit);
    const t_collect = now(io);
    try r.prepare(io);
    const t_keys = now(io);

    // Nodes in the order of their first atom, so that a relink lays out
    // the output as this build did.
    const link_key = cache.hash(2, &.{@backingInt(Tag.link)});
    for (emit.atom_owners.items, emit.atoms.items, atom_units, 0..) |owner, atom, u, i| {
        const index = switch (owner) {
            .unit => try r.unitNode(u),
            .content => (try r.node(@backingInt(atom.key), .content))[0],
            .link => (try r.node(link_key, .link))[0],
        };
        r.atom_pairs.appendAssumeCapacity(.{ index, @intCast(i) });
    }
    n_refs = 0;
    for (zcu.deps.values(), dep_units) |dependees, u| {
        const index = try r.unitNode(u);
        for (dep_refs[n_refs..][0..dependees.len]) |ref| try r.edges.append(gpa, .{ index, try r.dependeeNode(ref) });
        n_refs += dependees.len;
    }
    for (emit.content_uses.items, use_units) |use, u| {
        const index = try r.unitNode(u);
        try r.edges.append(gpa, .{ index, r.map.get(@backingInt(use.key)).? });
    }
    try r.group();

    // Each atom's debug info, and the atoms' hashes as their owners'
    // results where nothing else is.
    const debug_of = try gpa.alloc(?*const Atom.Debug, emit.atoms.items.len);
    defer gpa.free(debug_of);
    @memset(debug_of, null);
    for (emit.debug.items) |*d| debug_of[d.atom] = d;
    try forChunks(io, r.nodes.items.len, struct {
        nodes: []Node,
        atoms: []const Atom,
        debug_of: []const ?*const Atom.Debug,

        fn run(c: @This(), lo: usize, hi: usize, _: usize) !void {
            for (c.nodes[lo..hi]) |*n| switch (n.tag) {
                .func, .link, .content => {
                    var h: Hash = 0;
                    var lines: Hash = 0;
                    for (n.atoms) |ai| {
                        h = h *% 31 +% contentsHash(&c.atoms[ai]);
                        if (c.debug_of[ai]) |d| {
                            h +%= cache.hash(@truncate(h), d.lines) +% @backingInt(d.frame);
                            lines = lines *% 31 +% d.base_line;
                        }
                    }
                    n.result_hash = h;
                    n.exact_hash = h ^ cache.hash(5, std.mem.asBytes(&lines));
                },
                else => n.exact_hash = n.result_hash,
            };
        }
    }{ .nodes = r.nodes.items, .atoms = emit.atoms.items, .debug_of = debug_of });
    const t1 = now(io);

    if (inc.check) inc.checkPrediction(r.nodes.items);

    // Store: find equal entries on every core; the others go into one new
    // pack, encoded straight into the file on other threads while this one
    // builds the manifest, so that they are never all in memory.
    var store: Store = try .open(gpa, io, inc.global);
    defer store.close(gpa, io);
    var pack: Pack = try .open(io, inc.dir);
    defer pack.close(gpa, io);
    const where = try gpa.alloc(Where, r.nodes.items.len);
    defer gpa.free(where);
    @memset(where, .none);
    const putter: Putter = .{ .inc = inc, .store = &store, .nodes = r.nodes.items, .emit = emit, .debug_of = debug_of, .where = where };
    try forChunks(io, r.nodes.items.len, Putter.Lookup{ .p = putter });
    // Link the store packs of the hits into the compilation's directory;
    // an entry whose pack cannot be linked is put again. Then lay out the
    // new pack.
    var base_names: std.ArrayList([]const u8) = .empty;
    defer base_names.deinit(gpa);
    const store_bases = try gpa.alloc(u32, store.packs.len);
    defer gpa.free(store_bases);
    @memset(store_bases, 0);
    var reused: usize = 0;
    var entries: std.ArrayList(Store.IndexEntry) = .empty;
    defer entries.deinit(gpa);
    var end: u64 = Store.pack_header_len;
    for (where, r.nodes.items) |*w, *n| switch (w.*) {
        .none => {},
        .hit => |h| {
            if (store_bases[h.pack] == 0) {
                const name = store.packName(h.pack);
                if (pack.linkBase(gpa, io, store.dir, name, inc.dir)) |base| {
                    store_bases[h.pack] = base;
                    try base_names.append(gpa, name);
                } else |_| {
                    w.* = .{ .put = .{ .len = putter.entryLen(n) } };
                }
            }
            if (w.* == .hit) {
                w.* = .{ .hit = .{ .pack = store_bases[h.pack], .offset = h.offset } };
                reused += 1;
            }
        },
        .put => {},
    };
    for (where, r.nodes.items) |*w, *n| switch (w.*) {
        .put => |*p| {
            p.offset = end;
            try entries.append(gpa, .init(storeKey(inc.store_seed, n.key, n.src_hash), end, p.len));
            end += std.mem.alignForward(u64, p.len, 16);
        },
        .none, .hit => {},
    };
    const n_put = entries.items.len;
    // The new pack is named now, so that the manifest is written while
    // the store writes it.
    var new_name: ?Store.PackName = null;
    if (n_put != 0 or store.forward.items.len != 0) {
        new_name = store.reserveName(io);
        try base_names.append(gpa, &new_name.?);
    }
    const new_base: u32 = @intCast(base_names.items.len);
    const t2 = now(io);
    var committing = io.async(Putter.writePack, .{ putter, io, entries.items, end, new_name != null });
    defer if (committing.cancel(io)) |_| {} else |_| {};

    // The manifest.
    var b: Manifest.Builder = .{ .gpa = gpa };
    defer b.deinit();
    var refs: std.ArrayList(Pack.AtomRef) = .empty;
    defer refs.deinit(gpa);
    var symbols: std.ArrayList(Manifest.AtomSymbols) = .empty;
    defer symbols.deinit(gpa);
    var n_targets: usize = 0;
    for (emit.atoms.items) |*a| n_targets += a.targets.len;
    try b.ensureUnusedCapacity(emit.atoms.items.len, n_targets);
    for (r.nodes.items, where) |n, w| {
        refs.clearRetainingCapacity();
        symbols.clearRetainingCapacity();
        const loc: ?struct { u32, u64 } = switch (w) {
            .none => null,
            .hit => |h| .{ h.pack, h.offset },
            .put => |p| .{ new_base, p.offset },
        };
        if (loc) |l| {
            var off = l[1] + Store.atomsOffset(n.deps.len);
            for (n.atoms) |ai| {
                const a = &emit.atoms.items[ai];
                const len = atoms_codec.encodedLen(a, debug_of[ai]);
                try refs.append(gpa, .initIn(l[0], off, @intCast(len)));
                try symbols.append(gpa, .{ .key = @backingInt(a.key), .targets = @ptrCast(a.targets), .file = if (debug_of[ai]) |d| d.file else null });
                off += len;
            }
        }
        _ = try b.addNode(.{ .key = n.key, .result_hash = n.result_hash, .src_hash = n.src_hash, .tag = @backingInt(n.tag), .deps = n.deps, .atoms = refs.items, .symbols = symbols.items });
    }
    for (base_names.items) |name| _ = try b.addBasePack(name);
    b.entry = @backingInt(emit.entry.?);
    for (ip.error_names.items[1..]) |name| _ = try b.addErrorName(ip.stringSlice(name), @backingInt(Emit.errorKey(ip, name)));
    const t3 = now(io);
    var path_buf: std.ArrayList(u8) = .empty;
    defer path_buf.deinit(gpa);
    for (fe.files.items) |*f| {
        const mod = fe.module(f.module);
        path_buf.clearRetainingCapacity();
        try path_buf.print(gpa, "{s}{c}{s}", .{ mod.abs_root_dir orelse mod.root_dir, std.fs.path.sep, f.sub_path });
        const stat = Io.Dir.cwd().statFile(io, path_buf.items, .{}) catch continue;
        try b.addInput(path_buf.items, stat, @bitCast(f.content_hash), inc.build_start);
    }
    // `@embedFile`d files are inputs too.
    for (zcu.embed_files.values()) |f| {
        const mod = fe.module(f.module);
        path_buf.clearRetainingCapacity();
        try path_buf.print(gpa, "{s}{c}{s}", .{ mod.abs_root_dir orelse mod.root_dir, std.fs.path.sep, f.sub_path });
        const stat = Io.Dir.cwd().statFile(io, path_buf.items, .{}) catch continue;
        try b.addInput(path_buf.items, stat, f.hash, inc.build_start);
    }
    const t4 = now(io);
    var manifest = try b.writeUnplaced(io, inc.dir, pack.id);
    errdefer manifest.deinit(io);
    const t5 = now(io);
    const committed = try committing.await(io);
    if (new_name) |name| if (!std.mem.eql(u8, &committed.?, &name)) return error.StoreCommitFailed;
    const t6 = now(io);

    const names = try gpa.alloc([]const u8, base_names.items.len);
    var n_names: usize = 0;
    errdefer {
        for (names[0..n_names]) |n| gpa.free(n);
        gpa.free(names);
    }
    for (names, base_names.items) |*out, name| {
        out.* = try gpa.dupe(u8, name);
        n_names += 1;
    }
    const report = try std.fmt.allocPrint(gpa, "cache: recorded {d} nodes, {d} atoms, {d} inputs in {d:.2} ms alongside the link (graph {d:.2}: items {d:.2}, keys {d:.2}; store lookups {d:.2}: {d} reused, {d} put; manifest {d:.2} while the store writes: nodes and symbols {d:.2}, inputs {d:.2}, write {d:.2}; store's remainder {d:.2})", .{
        r.nodes.items.len, emit.atoms.items.len, fe.files.items.len,    ms(t0, t6),
        ms(t0, t1),        ms(t0, t_collect),    ms(t_collect, t_keys), ms(t1, t2),
        reused,            n_put,                ms(t2, t5),            ms(t2, t3),
        ms(t3, t4),        ms(t4, t5),           ms(t5, t6),
    });
    return .{ .manifest = manifest, .base_names = names, .report = report };
}

/// Where a node's store entry is.
const Where = union(enum) {
    none,
    /// In a store pack, by store pack index until `record` hard-links it,
    /// then by base pack index.
    hit: struct { pack: u32, offset: u64 },
    /// To be written to the new pack, `len` bytes at `offset`.
    put: struct { len: usize, offset: u64 = 0 },
};

const max_chunks = 64;

/// Runs `ctx.run(lo, hi, chunk)` over chunks of `0..len` on every core.
fn forChunks(io: Io, len: usize, ctx: anytype) !void {
    const n = @min(max_chunks, @max(1, len / 1024), 4 * (std.Thread.getCpuCount() catch 1));
    const Chunk = struct {
        err: ?anyerror = null,
        fn run(c: *@This(), x: @TypeOf(ctx), lo: usize, hi: usize, i: usize) void {
            x.run(lo, hi, i) catch |e| {
                c.err = e;
            };
        }
    };
    var chunks: [max_chunks]Chunk = @splat(.{});
    var group: Io.Group = .init;
    for (1..n) |i| group.async(io, Chunk.run, .{ &chunks[i], ctx, i * len / n, (i + 1) * len / n, i });
    chunks[0].run(ctx, 0, len / n, 0);
    try group.await(io);
    for (chunks[0..n]) |c| if (c.err) |e| return e;
}

/// Looks nodes up in the store (`Lookup`), and writes those it misses as
/// a new pack (`writePack`).
const Putter = struct {
    inc: *const Incremental,
    store: *Store,
    nodes: []const Node,
    emit: *const Emit,
    debug_of: []const ?*const Atom.Debug,
    where: []Where,

    /// The length of node `n`'s entry, as `Store.entryLen`.
    fn entryLen(p: Putter, n: *const Node) usize {
        var len = Store.atomsOffset(n.deps.len);
        for (n.atoms) |ai| len += atoms_codec.encodedLen(&p.emit.atoms.items[ai], p.debug_of[ai]);
        return len;
    }

    const Lookup = struct {
        p: Putter,

        fn run(l: Lookup, lo: usize, hi: usize, _: usize) !void {
            const p = l.p;
            for (p.nodes[lo..hi], p.where[lo..hi]) |*n, *w| {
                if (n.atoms.len == 0) continue;
                if (try p.store.get(p.inc.gpa, p.inc.io, storeKey(p.inc.store_seed, n.key, n.src_hash))) |e| {
                    if (e.resultHash() == n.exact_hash and e.atomCount() == n.atoms.len and e.deps().len == n.deps.len) {
                        w.* = .{ .hit = .{ .pack = e.pack, .offset = e.offset } };
                        continue;
                    }
                }
                w.* = .{ .put = .{ .len = p.entryLen(n) } };
            }
        }
    };

    /// Writes the entries `where` puts, laid out as `entries` up to `end`,
    /// into the pack `Store.reserveName` named, if `any`, and commits it.
    fn writePack(p: Putter, io: Io, entries: []const Store.IndexEntry, end: u64, any: bool) !?Store.PackName {
        if (!any) return null;
        var w: Store.PackWriter = undefined;
        try p.store.beginPack(io, p.inc.dir, &w);
        defer w.deinit(io);
        try forChunks(io, p.nodes.len, Writer{ .p = p, .w = &w });
        return try p.store.commitPack(p.inc.gpa, io, &w, entries, end, p.inc.dir);
    }

    /// Encodes a chunk's entries, which are contiguous in the pack, into a
    /// buffer of at most `buf_len` bytes at a time.
    const Writer = struct {
        p: Putter,
        w: *Store.PackWriter,

        const buf_len = 1 << 20;

        fn run(x: Writer, lo: usize, hi: usize, _: usize) !void {
            const p = x.p;
            const gpa = p.inc.gpa;
            var buf: std.array_list.Aligned(u8, .@"16") = .empty;
            defer buf.deinit(gpa);
            var buf_off: u64 = 0;
            var deps: std.ArrayList(Store.Dep) = .empty;
            defer deps.deinit(gpa);
            var atoms: std.ArrayList(Atom) = .empty;
            defer atoms.deinit(gpa);
            var debug: std.ArrayList(Atom.Debug) = .empty;
            defer debug.deinit(gpa);
            for (p.nodes[lo..hi], p.where[lo..hi]) |*n, w| {
                const put = switch (w) {
                    .put => |put| put,
                    .none, .hit => continue,
                };
                const padded = std.mem.alignForward(usize, put.len, 16);
                if (buf.items.len != 0 and buf.items.len + padded > buf_len) {
                    try x.w.writeAt(p.inc.io, buf.items, buf_off);
                    buf.clearRetainingCapacity();
                }
                if (buf.items.len == 0) buf_off = put.offset;
                std.debug.assert(buf_off + buf.items.len == put.offset);
                deps.clearRetainingCapacity();
                for (n.deps) |d| try deps.append(gpa, .{ .key = p.nodes[d].key, .result_hash = p.nodes[d].result_hash });
                atoms.clearRetainingCapacity();
                debug.clearRetainingCapacity();
                for (n.atoms, 0..) |ai, j| {
                    try atoms.append(gpa, p.emit.atoms.items[ai]);
                    if (p.debug_of[ai]) |d| {
                        var copy = d.*;
                        copy.atom = @intCast(j);
                        try debug.append(gpa, copy);
                    }
                }
                const start = buf.items.len;
                try buf.appendNTimes(gpa, 0, padded);
                Store.encodeEntry(.{
                    .src_hash = n.src_hash,
                    .result_hash = n.exact_hash,
                    .deps = deps.items,
                    .atoms = atoms.items,
                    .debug = debug.items,
                }, buf.items[start..][0..put.len]);
            }
            if (buf.items.len != 0) try x.w.writeAt(p.inc.io, buf.items, buf_off);
        }
    };
};

/// Compares this build's nodes with the last build's manifest: the units
/// an edit-rebuild would re-analyze are those reachable over reverse edges
/// from the nodes whose own source changed, and from the nodes computed
/// straight from source (namespaces, names, function bodies) whose result
/// changed. Every node whose result changed must be among them. Prints
/// the counts, and the nodes it missed.
fn checkPrediction(inc: *Incremental, nodes: []const Node) void {
    const gpa = inc.gpa;
    const m = if (inc.prev) |*m| m else return;
    const n_prev = m.nodeCount();
    const reached = std.DynamicBitSetUnmanaged.initEmpty(gpa, n_prev) catch return;
    var seen = reached;
    defer seen.deinit(gpa);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);
    var seeds: usize = 0;
    var added: usize = 0;
    for (nodes) |n| {
        const i = m.find(n.key) orelse {
            added += 1;
            continue;
        };
        const old = m.node(i);
        const from_source = switch (n.tag) {
            .func_body, .namespace_name, .namespace => true,
            else => false,
        };
        if (old.src_hash != n.src_hash or (from_source and old.result_hash != n.result_hash)) {
            seeds += 1;
            if (!seen.isSet(i)) {
                seen.set(i);
                stack.append(gpa, i) catch return;
            }
        }
    }
    while (stack.pop()) |i| for (m.rdeps(i)) |part| for (part) |d| if (!seen.isSet(d)) {
        seen.set(d);
        stack.append(gpa, d) catch return;
    };
    var changed: usize = 0;
    var missed: usize = 0;
    for (nodes) |n| {
        const i = m.find(n.key) orelse continue;
        if (m.node(i).result_hash == n.result_hash) continue;
        changed += 1;
        if (seen.isSet(i)) continue;
        missed += 1;
        if (missed <= 10) std.debug.print("cache check: {t} node {x} changed its result but no changed source reaches it\n", .{ n.tag, n.key });
    }
    std.debug.print("cache check: {d} nodes ({d} new); {d} seeds reach {d}; {d} results changed, {d} missed\n", .{
        nodes.len, added, seeds, seen.count(), changed, missed,
    });
}

/// Everything the linker emits for an atom but its name and key, like
/// `Atom.SymbolKey.fromContents`, with a faster hash: results need not be
/// symbol keys.
fn contentsHash(a: *const Atom) Hash {
    var h = cache.hash(@as(u64, @backingInt(a.section)) << 8 | @backingInt(a.alignment), a.bytes);
    h = h *% 31 +% cache.hash(a.zero_fill, @ptrCast(a.relocs));
    return h *% 31 +% cache.hash(a.relocs.len, @ptrCast(a.targets));
}

fn storeKey(seed: Hash, node_key: Hash, src_hash: Hash) Store.Key {
    var buf: [48]u8 = undefined;
    buf[0..16].* = @bitCast(seed);
    buf[16..32].* = @bitCast(node_key);
    buf[32..48].* = @bitCast(src_hash);
    return cache.hash(4, &buf);
}
