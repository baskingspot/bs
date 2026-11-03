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
    const atoms = try gpa.alloc(Atom, in.refs.len);
    defer gpa.free(atoms);
    var debug: std.ArrayList(Atom.Debug) = .empty;
    defer debug.deinit(gpa);
    const files = try gpa.alloc([]const u8, m.fileCount());
    defer gpa.free(files);
    for (files, 0..) |*f, i| f.* = m.file(@intCast(i));
    pack.decodeAll(gpa, io, in.refs, atoms, &debug, .{ .of = in.debug_files, .names = files }) catch |err| switch (err) {
        error.CorruptAtom => return false,
        else => |e| return e,
    };
    const t2 = now(io);

    const values = try gpa.alloc(Elf.NumberedValue, m.errorCount());
    defer gpa.free(values);
    for (values, 1..) |*v, code| v.* = .{ .symbol = m.errorSymbol(@intCast(code)), .value = code };
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    var diag: Elf.Diagnostic = .{};
    Elf.link(gpa, io, out_dir, sub_path, atoms, .{
        .entry = @fromBackingInt(m.entry),
        .symbols = .{ .atoms = in.numbered, .targets = in.targets, .values = values, .entry = m.entry_symbol, .len = m.symbolLen() },
        .diag = &diag,
        .debug = debug.items,
        .comp_dir = cwd,
    }) catch |err| {
        std.debug.print("error: link failed: {t} (atom '{s}')\n", .{ err, diag.atom });
        return err;
    };
    if (inc.timing) std.debug.print("cache: no input changed; relinked {d} atoms in {d:.2} ms (manifest and {d} stats {d:.2}, decode {d:.2}, link {d:.2})\n", .{
        atoms.len, ms(t0, now(io)), m.inputCount(), ms(t0, t1), ms(t1, t2), ms(t2, now(io)),
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
    deps: std.ArrayList(u32) = .empty,
    /// Indices into `Emit.atoms`, in order.
    atoms: std.ArrayList(u32) = .empty,
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
};

const Recorder = struct {
    gpa: Allocator,
    zcu: *Zcu,
    nodes: std.ArrayList(Node) = .empty,
    map: std.AutoHashMapUnmanaged(Hash, u32) = .empty,
    key_buf: std.Io.Writer.Allocating,

    fn deinit(r: *Recorder) void {
        for (r.nodes.items) |*n| {
            n.deps.deinit(r.gpa);
            n.atoms.deinit(r.gpa);
        }
        r.nodes.deinit(r.gpa);
        r.map.deinit(r.gpa);
        r.key_buf.deinit();
    }

    fn node(r: *Recorder, key: Hash, tag: Tag) !struct { u32, bool } {
        const gop = try r.map.getOrPut(r.gpa, key);
        if (gop.found_existing) return .{ gop.value_ptr.*, false };
        gop.value_ptr.* = @intCast(r.nodes.items.len);
        try r.nodes.append(r.gpa, .{ .key = key, .tag = tag });
        return .{ gop.value_ptr.*, true };
    }

    /// A key for `parts`, distinct per `tag`.
    fn keyOf(r: *Recorder, tag: Tag, parts: []const []const u8) !Hash {
        r.key_buf.clearRetainingCapacity();
        const w = &r.key_buf.writer;
        try w.writeByte(@backingInt(tag));
        for (parts) |p| {
            try w.writeAll(p);
            try w.writeByte(0);
        }
        return cache.hash(2, r.key_buf.written());
    }

    fn unitKeyString(r: *Recorder, unit: Zcu.AnalUnit) ![]const u8 {
        var aw: std.Io.Writer.Allocating = .init(r.zcu.arena.allocator());
        try r.zcu.unitKey(unit, &aw.writer);
        return aw.written();
    }

    fn srcHash(r: *Recorder, file: u32, inst: std.zig.Zir.Inst.Index) Hash {
        const h = r.zcu.file(file).zir.getAssociatedSrcHash(inst) orelse return 0;
        return @bitCast(h);
    }

    fn unitNode(r: *Recorder, unit: Zcu.AnalUnit) !u32 {
        const ip = &r.zcu.ip;
        const tag: Tag = switch (unit) {
            .nav_val => .nav_val,
            .type_layout => .type_layout,
            .func => .func,
            .comptime_decl => .comptime_decl,
        };
        const index, const new = try r.node(try r.keyOf(tag, &.{try r.unitKeyString(unit)}), tag);
        if (!new) return index;
        const n = &r.nodes.items[index];
        switch (unit) {
            .nav_val => |nav_index| {
                const nav = ip.getNav(nav_index);
                n.src_hash = r.srcHash(nav.file, nav.zir_inst);
                if (nav.status == .resolved) n.result_hash = ip.stableHash(nav.val);
            },
            .type_layout => |ty| {
                const c = ip.containerType(ty).?;
                n.src_hash = r.srcHash(c.file, c.zir_inst);
                // The type's identity; its layout is not hashed yet.
                n.result_hash = ip.stableHash(ty);
            },
            .func => |func| {
                const owner = ip.getNav(ip.indexToKey(func).func.owner_nav);
                n.src_hash = r.srcHash(owner.file, owner.zir_inst);
                // The result is the function's atom, hashed in `record`.
            },
            .comptime_decl => |c| n.src_hash = r.srcHash(c.file, c.inst),
        }
        return index;
    }

    /// The node of what a unit read, with an edge to the unit that
    /// produces it, if any.
    fn dependeeNode(r: *Recorder, d: Zcu.Dependee) !u32 {
        const ip = &r.zcu.ip;
        switch (d) {
            .nav_val => |nav| return r.unitNode(.{ .nav_val = nav }),
            .type_layout => |ty| return r.unitNode(.{ .type_layout = ty }),
            .nav_ty => |nav_index| {
                const nav = ip.getNav(nav_index);
                const index, const new = try r.node(try r.keyOf(.nav_ty, &.{ip.stringSlice(nav.key)}), .nav_ty);
                if (new) {
                    if (nav.status == .resolved) r.nodes.items[index].result_hash = ip.stableHash(ip.typeOf(nav.val));
                    const producer = try r.unitNode(.{ .nav_val = nav_index });
                    try r.nodes.items[index].deps.append(r.gpa, producer);
                }
                return index;
            },
            .func_body => |func| {
                const index, const new = try r.node(try r.keyOf(.func_body, &.{try r.unitKeyString(.{ .func = func })}), .func_body);
                if (new) {
                    const owner = ip.getNav(ip.indexToKey(func).func.owner_nav);
                    r.nodes.items[index].result_hash = r.srcHash(owner.file, owner.zir_inst);
                }
                return index;
            },
            .func_ies => |func| {
                const index, const new = try r.node(try r.keyOf(.func_ies, &.{try r.unitKeyString(.{ .func = func })}), .func_ies);
                if (new) {
                    var h: Hash = 0;
                    if (r.zcu.inferred_errors.get(func)) |list| {
                        // Order-independent: the set, not the discovery order.
                        for (list.items) |name| h +%= cache.hash(3, ip.stringSlice(name));
                    }
                    r.nodes.items[index].result_hash = h;
                    const producer = try r.unitNode(.{ .func = func });
                    try r.nodes.items[index].deps.append(r.gpa, producer);
                }
                return index;
            },
            .namespace_name => |nn| {
                const ns = r.zcu.namespacePtr(nn.namespace);
                const name = ip.stringSlice(nn.name);
                const index, const new = try r.node(try r.keyOf(.namespace_name, &.{ ns.key, name }), .namespace_name);
                if (new) {
                    // Which declaration the name finds, if any.
                    r.nodes.items[index].result_hash = if (ns.decls.get(nn.name)) |nav| cache.hash(3, ip.stringSlice(ip.getNav(nav).key)) else 0;
                }
                return index;
            },
            .namespace => |ns_index| {
                const ns = r.zcu.namespacePtr(ns_index);
                const index, const new = try r.node(try r.keyOf(.namespace, &.{ns.key}), .namespace);
                if (new) {
                    var h: Hash = 0;
                    for (ns.decls.keys()) |name| h = cache.hash(@truncate(h), ip.stringSlice(name)) ^ h;
                    r.nodes.items[index].result_hash = h;
                }
                return index;
            },
        }
    }
};

/// Records a successful build. `emit` has linked its atoms.
pub fn record(inc: *Incremental, fe: *const Frontend, zcu: *Zcu, emit: *const Emit) !void {
    const gpa = inc.gpa;
    const io = inc.io;
    const t0 = now(io);
    const ip = &zcu.ip;
    var r: Recorder = .{ .gpa = gpa, .zcu = zcu, .key_buf = .init(gpa) };
    defer r.deinit();

    // Nodes in the order of their first atom, so that a relink lays out
    // the output as this build did.
    const link_key = try r.keyOf(.link, &.{});
    for (emit.atom_owners.items, emit.atoms.items, 0..) |owner, atom, i| {
        const index = switch (owner) {
            .unit => |u| try r.unitNode(u),
            .content => (try r.node(@backingInt(atom.key), .content))[0],
            .link => (try r.node(link_key, .link))[0],
        };
        try r.nodes.items[index].atoms.append(gpa, @intCast(i));
    }
    for (zcu.deps.keys(), zcu.deps.values()) |unit, dependees| {
        const index = try r.unitNode(unit);
        for (dependees) |d| {
            const dep = try r.dependeeNode(d);
            try r.nodes.items[index].deps.append(gpa, dep);
        }
    }
    for (emit.content_uses.items) |use| {
        const index = try r.unitNode(use.unit);
        const dep = r.map.get(@backingInt(use.key)).?;
        try r.nodes.items[index].deps.append(gpa, dep);
    }

    // Each atom's debug info, and the atoms' hashes as their owners'
    // results where nothing else is.
    const debug_of = try gpa.alloc(?*const Atom.Debug, emit.atoms.items.len);
    defer gpa.free(debug_of);
    @memset(debug_of, null);
    for (emit.debug.items) |*d| debug_of[d.atom] = d;
    for (r.nodes.items) |*n| {
        std.mem.sortUnstable(u32, n.deps.items, {}, std.sort.asc(u32));
        var kept: usize = 0;
        for (n.deps.items) |d| {
            if (kept > 0 and n.deps.items[kept - 1] == d) continue;
            n.deps.items[kept] = d;
            kept += 1;
        }
        n.deps.items.len = kept;
        switch (n.tag) {
            .func, .link, .content => {
                var h: Hash = 0;
                var lines: Hash = 0;
                for (n.atoms.items) |ai| {
                    const a = &emit.atoms.items[ai];
                    h = h *% 31 +% @backingInt(Atom.SymbolKey.fromContents(a.section, a.alignment, a.bytes, a.targets, a.relocs));
                    if (debug_of[ai]) |d| {
                        h +%= cache.hash(@truncate(h), d.lines) +% @backingInt(d.frame);
                        lines = lines *% 31 +% d.base_line;
                    }
                }
                n.result_hash = h;
                n.exact_hash = h ^ cache.hash(5, std.mem.asBytes(&lines));
            },
            else => n.exact_hash = n.result_hash,
        }
    }
    const t1 = now(io);

    if (inc.check) inc.checkPrediction(r.nodes.items);

    // Store: reuse equal entries, put the rest in one new pack.
    var store: Store = try .open(gpa, io, inc.global);
    defer store.close(gpa, io);
    const Where = struct { pack: u32, entry_offset: u64 };
    const where = try gpa.alloc(?Where, r.nodes.items.len);
    defer gpa.free(where);
    @memset(where, null);
    // Store pack index -> base pack index + 1.
    const store_bases = try gpa.alloc(u32, store.packs.len);
    defer gpa.free(store_bases);
    @memset(store_bases, 0);
    var pack: Pack = try .open(io, inc.dir);
    defer pack.close(gpa, io);
    var base_names: std.ArrayList([]const u8) = .empty;
    defer base_names.deinit(gpa);
    var batch: Store.Batch = .{};
    defer batch.deinit(gpa);
    const in_batch: u32 = std.math.maxInt(u32);
    var store_deps: std.ArrayList(Store.Dep) = .empty;
    defer store_deps.deinit(gpa);
    var entry_atoms: std.ArrayList(Atom) = .empty;
    defer entry_atoms.deinit(gpa);
    var entry_debug: std.ArrayList(Atom.Debug) = .empty;
    defer entry_debug.deinit(gpa);
    var reused: usize = 0;
    for (r.nodes.items, where) |n, *w| {
        if (n.atoms.items.len == 0) continue;
        const store_key = storeKey(inc.store_seed, n.key, n.src_hash);
        if (try store.get(gpa, io, store_key)) |e| hit: {
            if (e.resultHash() != n.exact_hash or e.atomCount() != n.atoms.items.len or e.deps().len != n.deps.items.len) break :hit;
            if (store_bases[e.pack] == 0) {
                const name = store.packName(e.pack);
                store_bases[e.pack] = pack.linkBase(gpa, io, store.dir, name, inc.dir) catch break :hit;
                try base_names.append(gpa, name);
            }
            w.* = .{ .pack = store_bases[e.pack], .entry_offset = e.offset };
            reused += 1;
            continue;
        }
        store_deps.clearRetainingCapacity();
        for (n.deps.items) |d| try store_deps.append(gpa, .{ .key = r.nodes.items[d].key, .result_hash = r.nodes.items[d].result_hash });
        entry_atoms.clearRetainingCapacity();
        entry_debug.clearRetainingCapacity();
        for (n.atoms.items, 0..) |ai, j| {
            try entry_atoms.append(gpa, emit.atoms.items[ai]);
            if (debug_of[ai]) |d| {
                var copy = d.*;
                copy.atom = @intCast(j);
                try entry_debug.append(gpa, copy);
            }
        }
        const off = try batch.put(gpa, store_key, .{
            .src_hash = n.src_hash,
            .result_hash = n.exact_hash,
            .deps = store_deps.items,
            .atoms = entry_atoms.items,
            .debug = entry_debug.items,
        });
        w.* = .{ .pack = in_batch, .entry_offset = Store.pack_header_len + off };
    }
    const n_put = batch.index.items.len;
    const t2 = now(io);
    const new_pack = try store.commit(gpa, io, (&batch)[0..1], inc.dir);
    var new_base: u32 = 0;
    if (new_pack) |*name| {
        new_base = try pack.addBase(gpa, io, inc.dir, name);
        try base_names.append(gpa, name);
    }
    const t3 = now(io);

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
        if (w) |loc| {
            const base_pack = if (loc.pack == in_batch) new_base else loc.pack;
            var off = loc.entry_offset + Store.atomsOffset(n.deps.items.len);
            for (n.atoms.items) |ai| {
                const a = &emit.atoms.items[ai];
                const len = atoms_codec.encodedLen(a, debug_of[ai]);
                try refs.append(gpa, .initIn(base_pack, off, @intCast(len)));
                try symbols.append(gpa, .{ .key = @backingInt(a.key), .targets = @ptrCast(a.targets), .file = if (debug_of[ai]) |d| d.file else null });
                off += len;
            }
        }
        _ = try b.addNode(.{ .key = n.key, .result_hash = n.result_hash, .src_hash = n.src_hash, .tag = @backingInt(n.tag), .deps = n.deps.items, .atoms = refs.items, .symbols = symbols.items });
    }
    for (base_names.items) |name| _ = try b.addBasePack(name);
    b.entry = @backingInt(emit.entry.?);
    for (ip.error_names.items[1..]) |name| _ = try b.addErrorName(ip.stringSlice(name), @backingInt(Emit.errorKey(ip, name)));
    var path_buf: std.ArrayList(u8) = .empty;
    defer path_buf.deinit(gpa);
    for (fe.files.items) |*f| {
        const mod = fe.module(f.module);
        path_buf.clearRetainingCapacity();
        try path_buf.print(gpa, "{s}{c}{s}", .{ mod.abs_root_dir orelse mod.root_dir, std.fs.path.sep, f.sub_path });
        const stat = Io.Dir.cwd().statFile(io, path_buf.items, .{}) catch continue;
        try b.addInput(path_buf.items, stat, @bitCast(f.content_hash), inc.build_start);
    }
    try b.write(io, inc.dir, pack.id);
    // Base packs the new manifest does not name.
    var it = inc.dir.iterate();
    while (try it.next(io)) |e| {
        if (!std.mem.endsWith(u8, e.name, ".zsp")) continue;
        for (base_names.items) |name| {
            if (std.mem.eql(u8, name, e.name)) break;
        } else inc.dir.deleteFile(io, e.name) catch {};
    }
    if (inc.timing) std.debug.print("cache: recorded {d} nodes, {d} atoms, {d} inputs in {d:.2} ms (graph {d:.2}, store: {d} reused, {d} put {d:.2}, commit {d:.2}; manifest {d:.2})\n", .{
        r.nodes.items.len, emit.atoms.items.len, fe.files.items.len, ms(t0, now(io)), ms(t0, t1), reused, n_put, ms(t1, t2), ms(t2, t3), ms(t3, now(io)),
    });
}

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

fn storeKey(seed: Hash, node_key: Hash, src_hash: Hash) Store.Key {
    var buf: [48]u8 = undefined;
    buf[0..16].* = @bitCast(seed);
    buf[16..32].* = @bitCast(node_key);
    buf[32..48].* = @bitCast(src_hash);
    return cache.hash(4, &buf);
}
