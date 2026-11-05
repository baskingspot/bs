//! Cache storage benchmark: `zig build bench-cache`. Builds a synthetic
//! compilation the size docs/slop/architecture.md targets (30k units, about 100k
//! Atoms shaped like bench-link's mixed set, 60k dependency nodes with 10
//! dependencies per unit, 600 input files, 2000 error names), saves it as a
//! manifest and pack, and times what rebuilds would do with them:
//!
//! - no-edit rebuild: lock, map the manifest, stat every input;
//! - relink: map the manifest and pack, `Elf.emitInput` reading the records
//!   in place (`Pack.LinkAtoms`) with the manifest's numbered symbols
//!   (checked against an emit of the original Atoms), and by keys for
//!   comparison;
//! - edit rebuild storage work: append a unit's new Atoms, find its
//!   dependents, write the next manifest;
//! - compaction, and the global store (a first build's puts and commit,
//!   lookups as a project's first build would do them, maintenance, and
//!   concurrent builds).
//!
//! Works in /tmp/bs-bench-cache, with a warm page cache.

const std = @import("std");
const Io = std.Io;
const Atom = @import("link/Atom.zig");
const Elf = @import("link/Elf.zig");
const cache = @import("cache.zig");
const Manifest = cache.Manifest;
const Pack = cache.Pack;
const Store = cache.Store;

const n_text = 80_000;
const n_rodata = 15_000;
const n_data = 4_000;
const n_bss = 1_000;
const n_hot = 512;
const n_units = 30_000;
const n_other_nodes = 30_000;
const deps_per_unit = 10;
const n_inputs = 600;
const n_errors = 2000;
const runs = 15;
const work_path = "/tmp/bs-bench-cache";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const cwd = Io.Dir.cwd();
    cwd.deleteTree(io, work_path) catch {}; // ziglint-ignore: Z026 -- cleanup is best effort
    const work = try cwd.createDirPathOpen(io, work_path, .{});

    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const rand = prng.random();
    const keys = try arena.alloc(Atom.SymbolKey, n_text + n_rodata + n_data + n_bss);
    const names = try arena.alloc([]const u8, keys.len);
    for (keys, names, 0..) |*k, *n, i| {
        n.* = try arena.print("bench:file{d}.zig:decl{d}", .{ i % 500, i });
        k.* = .fromName(n.*);
    }
    const all_atoms, const all_debug = try generate(arena, rand, keys, names);
    // What the link keeps: the first of the atoms sharing a key. A
    // compilation's manifest holds each key once.
    const atoms, const debug = try dedupe(arena, all_atoms, all_debug);
    const debug_of = try arena.alloc(?*const Atom.Debug, atoms.len);
    @memset(debug_of, null);
    for (debug) |*d| debug_of[d.atom] = d;
    var atom_bytes: usize = 0;
    for (atoms) |*a| atom_bytes += a.bytes.len;

    // Input files.
    const inputs_dir = try work.createDirPathOpen(io, "src", .{});
    const input_paths = try arena.alloc([]const u8, n_inputs);
    for (input_paths, 0..) |*p, i| {
        const name = try arena.print("file{d}.zig", .{i});
        try inputs_dir.writeFile(io, .{ .sub_path = name, .data = "pub fn f() void {}\n" });
        // Old enough to trust their stats.
        try inputs_dir.setTimestamps(io, name, .{ .modify_timestamp = .{ .new = .fromNanoseconds(1_000_000_000 * std.time.ns_per_s) } });
        p.* = try arena.print("{s}/src/{s}", .{ work_path, name });
    }

    const local = try work.createDirPathOpen(io, "local", .{});
    const dir = try cache.compilationDir(io, local, 0x1234);

    // ---- Cold save.
    var t = now(io);
    var lock = try cache.lock(io, dir);
    var pack: Pack = try .create(io, dir);
    const refs = try arena.alloc(Pack.AtomRef, atoms.len);
    try pack.append(gpa, io, atoms, debug, refs);
    const t_append = since(io, t);
    t = now(io);
    var builder: Manifest.Builder = .{ .gpa = gpa };
    const symbols = try arena.alloc(Manifest.AtomSymbols, atoms.len);
    for (symbols, atoms, debug_of) |*s, a, d| s.* = .{ .key = @backingInt(a.key), .targets = @ptrCast(a.targets), .file = if (d) |x| x.file else null, .name = a.name };
    var n_targets: usize = 0;
    for (atoms) |a| n_targets += a.targets.len;
    try builder.ensureUnusedCapacity(atoms.len, n_targets);
    for (0..n_units) |u| {
        const lo = u * atoms.len / n_units;
        const hi = (u + 1) * atoms.len / n_units;
        var deps: [deps_per_unit]u32 = undefined;
        for (&deps) |*d| d.* = rand.uintLessThan(u32, n_units + n_other_nodes);
        _ = try builder.addNode(.{ .key = rand.int(u128), .result_hash = rand.int(u128), .src_hash = rand.int(u128), .deps = &deps, .atoms = refs[lo..hi], .symbols = symbols[lo..hi] });
    }
    for (0..n_other_nodes) |_| _ = try builder.addNode(.{ .key = rand.int(u128), .result_hash = rand.int(u128) });
    const build_start = Io.Clock.real.now(io);
    for (input_paths) |p| try builder.addInput(p, p, try cwd.statFile(io, p, .{}), rand.int(u128), build_start);
    for (0..n_errors) |i| {
        const name = try arena.print("Error{d}", .{i});
        _ = try builder.addErrorName(name, @backingInt(Atom.SymbolKey.fromName(try arena.print("error.{s}", .{name}))));
    }
    builder.entry = @backingInt(keys[0]);
    const t_fill = since(io, t);
    try builder.write(io, dir, pack.id);
    builder.deinit();
    const t_manifest = since(io, t);
    pack.close(gpa, io);
    lock.close(io);
    const manifest_size = (try dir.statFile(io, "manifest", .{})).size;
    const pack_size = (try dir.statFile(io, "pack", .{})).size;

    // ---- No-edit rebuild.
    var noedit: Stats = .{};
    var changed: std.ArrayList(u32) = .empty;
    defer changed.deinit(gpa);
    for (0..runs) |_| {
        const t0 = now(io);
        var l = try cache.lock(io, dir);
        const t1 = now(io);
        var m = (try Manifest.open(gpa, io, dir)).?;
        const t2 = now(io);
        changed.clearRetainingCapacity();
        try m.changedInputs(gpa, io, null, &changed);
        const t3 = now(io);
        if (changed.items.len != 0) @panic("inputs changed");
        m.close(gpa, io);
        l.close(io);
        const t4 = now(io);
        noedit.add(.{ ns(t0, t1), ns(t1, t2), ns(t2, t3), ns(t0, t4) });
    }

    // ---- Relink from the pack, numbered by the manifest, and by keys.
    const parallel: Elf.Options = .{ .entry = keys[0], .comp_dir = "/bench", .debug = debug };
    const expected = try Elf.emit(gpa, io, all_atoms, .{ .entry = keys[0], .comp_dir = "/bench", .debug = all_debug });
    defer gpa.free(expected);
    var relink: Stats = .{};
    var relink_keys: Stats = .{};
    var emit_memory: Stats = .{};
    for (0..runs) |i| {
        relink.add(try relinkOnce(gpa, io, dir, keys[0], if (i == 0) expected else null));

        const t0 = now(io);
        var m = (try Manifest.open(gpa, io, dir)).?;
        var p: Pack = try .open(io, dir);
        const in = try m.linkInput(gpa);
        var files: [512][]const u8 = undefined;
        for (files[0..m.fileCount()], 0..) |*f, j| f.* = m.file(@intCast(j));
        var input = try p.linkAtoms(gpa, .x86_64, in.refs, in.debug_atoms, .{ .of = in.debug_files, .names = files[0..m.fileCount()] });
        input.names = in.names;
        defer input.deinit(gpa);
        const t1 = now(io);
        const out = try Elf.emitInput(gpa, io, input, parallel);
        const t2 = now(io);
        if (i == 0 and !std.mem.eql(u8, out, expected)) @panic("relink by keys differs");
        gpa.free(out);
        p.close(gpa, io);
        m.close(gpa, io);
        relink_keys.add(.{ 0, ns(t0, t1), ns(t1, t2), ns(t0, t2) });

        const t4 = now(io);
        const out2 = try Elf.emit(gpa, io, atoms, parallel);
        emit_memory.add(.{ ns(t4, now(io)), 0, 0, 0 });
        gpa.free(out2);
    }

    // ---- Edit rebuild: unit 1234 changed; its atoms are regenerated and
    // its new state goes to the manifest's log.
    var edit: Stats = .{};
    var closure_size: usize = 0;
    for (0..runs) |_| {
        var m = (try Manifest.open(gpa, io, dir)).?;
        var p: Pack = try .open(io, dir);
        const node: u32 = 1234;
        const old_refs = m.atoms(node);
        const new_atoms = try gpa.alloc(Atom, old_refs.len);
        defer gpa.free(new_atoms);
        var new_debug: std.ArrayList(Atom.Debug) = .empty;
        defer new_debug.deinit(gpa);
        for (old_refs, new_atoms, 0..) |r, *a, k| {
            const d = try p.decode(r, .x86_64);
            a.* = d.atom;
            if (d.debug) |dbg| {
                var e = dbg;
                e.atom = @intCast(k);
                try new_debug.append(gpa, e);
            }
        }
        const new_refs = try gpa.alloc(Pack.AtomRef, old_refs.len);
        defer gpa.free(new_refs);
        const t0 = now(io);
        try p.append(gpa, io, new_atoms, new_debug.items, new_refs);
        const t1 = now(io);
        // Everything that transitively depends on the unit, without early
        // cutoff: an upper bound on the walk.
        var seen: std.bit_set.Dynamic = try .initEmpty(gpa, m.nodeCount());
        defer seen.deinit(gpa);
        var stack: std.ArrayList(u32) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, node);
        seen.set(node);
        while (stack.pop()) |n| for (m.rdeps(n)) |part| for (part) |r| if (!seen.isSet(r)) {
            seen.set(r);
            try stack.append(gpa, r);
        };
        closure_size = seen.count();
        const t2 = now(io);
        const new_symbols = try gpa.alloc(Manifest.AtomSymbols, new_atoms.len);
        defer gpa.free(new_symbols);
        for (new_symbols, new_atoms) |*s, a| s.* = .{ .key = @backingInt(a.key), .targets = @ptrCast(a.targets), .name = a.name };
        for (new_debug.items) |dbg| new_symbols[dbg.atom].file = dbg.file;
        var d: Manifest.Delta = .init(gpa, &m);
        try d.update(node, .{ .key = m.node(node).key, .result_hash = rand.int(u128), .src_hash = rand.int(u128), .deps = m.deps(node), .atoms = new_refs, .symbols = new_symbols });
        try d.append(io, dir);
        d.deinit();
        const t3 = now(io);
        p.close(gpa, io);
        m.close(gpa, io);
        edit.add(.{ ns(t0, t1), ns(t1, t2), ns(t2, t3), ns(t0, t3) });
    }

    // ---- Opening with the edits' log records, and folding them into a new base.
    var open_logged: Stats = .{};
    for (0..runs) |_| {
        const t0 = now(io);
        var m = (try Manifest.open(gpa, io, dir)).?;
        _ = try m.linkInput(gpa);
        open_logged.add(.{ since(io, t0), 0, 0, 0 });
        m.close(gpa, io);
    }
    var relink_logged: Stats = .{};
    for (0..runs) |i| relink_logged.add(try relinkOnce(gpa, io, dir, keys[0], if (i == 0) expected else null));
    const log_size: u64 = (try dir.statFile(io, "manifest.log", .{})).size;
    var fold_ns: u64 = 0;
    {
        var m = (try Manifest.open(gpa, io, dir)).?;
        defer m.close(gpa, io);
        const t0 = now(io);
        var b: Manifest.Builder = try .initFrom(gpa, &m);
        defer b.deinit();
        try b.write(io, dir, m.pack_id);
        fold_ns = since(io, t0);
    }

    // ---- Compaction: every atom appended again, so half the pack is
    // dead, then a manifest renumbered in link order.
    var compaction_ns: u64 = 0;
    var renumber_ns: u64 = 0;
    var compacted_size: u64 = 0;
    var uncompacted_size: u64 = 0;
    {
        var m = (try Manifest.open(gpa, io, dir)).?;
        defer m.close(gpa, io);
        var p: Pack = try .open(io, dir);
        defer p.close(gpa, io);
        // The units' atoms are in key order, as the manifest links them.
        const new_refs = try gpa.alloc(Pack.AtomRef, atoms.len);
        defer gpa.free(new_refs);
        try p.append(gpa, io, atoms, debug, new_refs);
        try p.append(gpa, io, atoms, debug, new_refs);
        uncompacted_size = p.len;
        if (!p.shouldCompact(Pack.liveBytes(new_refs))) @panic("expected to compact");
        const t0 = now(io);
        try p.compact(gpa, io, dir, new_refs);
        compaction_ns = since(io, t0);
        compacted_size = p.len;
        const t1 = now(io);
        var b: Manifest.Builder = try .initFrom(gpa, &m);
        defer b.deinit();
        try b.setAtomRefs(new_refs);
        try b.write(io, dir, p.id);
        renumber_ns = since(io, t1);
    }
    var relink_packed: Stats = .{};
    for (0..runs) |i| relink_packed.add(try relinkOnce(gpa, io, dir, keys[0], if (i == 0) expected else null));

    var n_relocs: usize = 0;
    var n_edges: usize = 0;
    for (atoms) |a| n_relocs += a.relocs.len;
    {
        var m = (try Manifest.open(gpa, io, dir)).?;
        n_edges = m.edges.len;
        m.close(gpa, io);
    }
    const print = std.debug.print;
    print("{d} units, {d} nodes, {d} edges, {d} inputs, {d} error names; {d} atoms, {d:.1} MiB of atom bytes, {d} relocations\n", .{
        n_units, n_units + n_other_nodes, n_edges, n_inputs, n_errors, atoms.len, mib(atom_bytes), n_relocs,
    });
    print("files: manifest {d:.1} MiB, pack {d:.1} MiB\n", .{ mib(manifest_size), mib(pack_size) });
    print("cold save: pack append {d:.2} ms, manifest {d:.2} ms (fill the builder {d:.2}, write {d:.2})\n", .{ ms(t_append), ms(t_manifest), ms(t_fill), ms(t_manifest - t_fill) });
    print("no-edit rebuild (median / best of {d}): {d:.3} / {d:.3} ms\n", .{ runs, ms(noedit.median(3)), ms(noedit.best(3)) });
    print("  lock {d:.3}, map manifest {d:.3}, stat {d} inputs {d:.3}\n", .{ ms(noedit.median(0)), ms(noedit.median(1)), n_inputs, ms(noedit.median(2)) });
    print("relink, numbered by the manifest (median / best): {d:.2} / {d:.2} ms\n", .{ ms(relink.median(3)), ms(relink.best(3)) });
    print("  map manifest and pack {d:.3}, gather the input of {d} atoms {d:.3}, Elf.emitInput from the mapping {d:.2}\n", .{
        ms(relink.median(0)), atoms.len, ms(relink.median(1)), ms(relink.median(2)),
    });
    print("  by keys instead: {d:.2} / {d:.2} ms (gather {d:.2}, Elf.emitInput {d:.2}; Elf.emit from memory {d:.2})\n", .{
        ms(relink_keys.median(3)), ms(relink_keys.best(3)), ms(relink_keys.median(1)), ms(relink_keys.median(2)), ms(emit_memory.median(0)),
    });
    print("edit rebuild storage work (median / best): {d:.2} / {d:.2} ms\n", .{ ms(edit.median(3)), ms(edit.best(3)) });
    print("  append atoms {d:.3}, dependents walk ({d} nodes, no early cutoff) {d:.2}, manifest log record {d:.3}\n", .{
        ms(edit.median(0)), closure_size, ms(edit.median(1)), ms(edit.median(2)),
    });
    print("open with {d} log records ({d:.1} KiB) and gather atom refs (median): {d:.3} ms; fold into a new base: {d:.2} ms\n", .{
        runs, @as(f64, @floatFromInt(log_size)) / 1024, ms(open_logged.median(0)), ms(fold_ns),
    });
    print("relink with the log's records: {d:.2} / {d:.2} ms (gather {d:.2}, Elf.emitInput {d:.2})\n", .{
        ms(relink_logged.median(3)), ms(relink_logged.best(3)), ms(relink_logged.median(1)), ms(relink_logged.median(2)),
    });
    print("compaction: {d:.1} -> {d:.1} MiB in {d:.2} ms, manifest renumbered in link order {d:.2} ms\n", .{ mib(uncompacted_size), mib(compacted_size), ms(compaction_ns), ms(renumber_ns) });
    print("relink after compaction, numbered and packed: {d:.2} / {d:.2} ms (map {d:.3}, gather {d:.2}, Elf.emitInput {d:.2})\n", .{
        ms(relink_packed.median(3)), ms(relink_packed.best(3)), ms(relink_packed.median(0)), ms(relink_packed.median(1)), ms(relink_packed.median(2)),
    });
    try benchStores(gpa, io, arena, rand, work, atoms, debug, keys[0]);
}

/// A relink as `Incremental` does it: map the manifest and pack, and
/// `Elf.emitInput` from the mapped records with the manifest's numbered
/// symbols. Checks the output against `expected`, if given. Returns open,
/// input gathering, emit, and total times.
fn relinkOnce(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, entry: Atom.SymbolKey, expected: ?[]const u8) ![4]u64 {
    const t0 = now(io);
    var m = (try Manifest.open(gpa, io, dir)).?;
    defer m.close(gpa, io);
    var p: Pack = try .open(io, dir);
    defer p.close(gpa, io);
    if (p.id != m.pack_id) @panic("pack id mismatch");
    const t1 = now(io);
    const in = try m.linkInput(gpa);
    var names: [512][]const u8 = undefined;
    for (names[0..m.fileCount()], 0..) |*f, i| f.* = m.file(@intCast(i));
    var input = try p.linkAtoms(gpa, .x86_64, in.refs, in.debug_atoms, .{ .of = in.debug_files, .names = names[0..m.fileCount()] });
    input.names = in.names;
    defer input.deinit(gpa);
    var values: [n_errors]Elf.NumberedValue = undefined;
    for (&values, 1..) |*v, code| v.* = .{ .symbol = m.errorSymbol(@intCast(code)), .value = code };
    const t2 = now(io);
    const out = try Elf.emitInput(gpa, io, input, .{
        .entry = entry,
        .comp_dir = "/bench",
        .symbols = .{
            .atoms = in.numbered,
            .targets = in.targets,
            .targets_tail = in.targets_tail,
            .values = &values,
            .entry = m.entry_symbol,
            .len = m.symbolLen(),
        },
    });
    defer gpa.free(out);
    const t3 = now(io);
    if (expected) |e| if (!std.mem.eql(u8, out, e)) @panic("numbered relink from the pack differs");
    return .{ ns(t0, t1), ns(t1, t2), ns(t2, t3), ns(t0, t3) };
}

/// The first of the atoms sharing a key, with their debug entries.
fn dedupe(arena: std.mem.Allocator, all: []const Atom, all_debug: []const Atom.Debug) !struct { []Atom, []Atom.Debug } {
    var seen: std.AutoHashMapUnmanaged(Atom.SymbolKey, void) = .empty;
    var kept: std.ArrayList(Atom) = .empty;
    const new_index = try arena.alloc(u32, all.len);
    for (all, new_index) |a, *ni| {
        if ((try seen.getOrPut(arena, a.key)).found_existing) {
            ni.* = std.math.maxInt(u32);
            continue;
        }
        ni.* = @intCast(kept.items.len);
        try kept.append(arena, a);
    }
    var debug: std.ArrayList(Atom.Debug) = .empty;
    for (all_debug) |d| if (new_index[d.atom] != std.math.maxInt(u32)) {
        var nd = d;
        nd.atom = new_index[d.atom];
        try debug.append(arena, nd);
    };
    return .{ kept.items, debug.items };
}

/// The global store: a first build's 30k puts and commit, lookups with 1,
/// 8, and 64 packs, maintenance, and concurrent builds writing at once.
fn benchStores(gpa: std.mem.Allocator, io: Io, arena: std.mem.Allocator, rand: std.Random, work: Io.Dir, atoms: []const Atom, debug: []const Atom.Debug, entry: Atom.SymbolKey) !void {
    const print = std.debug.print;
    const n_threads = std.Thread.getCpuCount() catch 1;
    const dep_list = try arena.alloc(Store.Dep, deps_per_unit);
    for (dep_list) |*d| d.* = .{ .key = rand.int(u128), .result_hash = rand.int(u128) };
    const payload: [64]u8 = @splat(7);
    // Each unit's debug entries, renumbered from its first atom.
    const unit_debug = try arena.alloc([]Atom.Debug, n_units);
    {
        var next: usize = 0;
        for (unit_debug, 0..) |*ud, u| {
            const lo = u * atoms.len / n_units;
            const hi = (u + 1) * atoms.len / n_units;
            const start = next;
            while (next < debug.len and debug[next].atom < hi) next += 1;
            ud.* = try arena.dupe(Atom.Debug, debug[start..next]);
            for (ud.*) |*d| d.atom -= @intCast(lo);
        }
    }
    const Units = struct {
        atoms: []const Atom,
        debug: []const []Atom.Debug,
        deps: []const Store.Dep,
        payload: []const u8,

        const Self = @This();
        fn contents(us: Self, u: usize) Store.Contents {
            const lo = u * us.atoms.len / n_units;
            const hi = (u + 1) * us.atoms.len / n_units;
            return .{ .src_hash = 1, .result_hash = 2, .deps = us.deps, .atoms = us.atoms[lo..hi], .debug = us.debug[u], .payload = us.payload };
        }
    };
    const units: Units = .{ .atoms = atoms, .debug = unit_debug, .deps = dep_list, .payload = &payload };
    const AllValid = struct {
        deps: []const Store.Dep,
        const Self = @This();
        pub fn resultHash(c: Self, key: cache.Hash) ?cache.Hash {
            for (c.deps) |d| if (d.key == key) return d.result_hash;
            return null;
        }
    };
    const n_builds = n_threads;
    // keys[b][u]: build b's key for unit u.
    const keys = try arena.alloc([]Store.Key, n_builds + 1);
    for (keys) |*ks| {
        ks.* = try arena.alloc(Store.Key, n_units);
        for (ks.*) |*k| k.* = rand.int(u128);
    }
    var entry_atoms: [64]Atom = undefined;
    var entry_debug: [64]Atom.Debug = undefined;

    // ---- Packs.
    {
        const PutBatch = struct {
            fn run(b: *Store.Batch, a: std.mem.Allocator, us: Units, ks: []const Store.Key, first: usize) void {
                for (ks, first..) |k, u| _ = b.put(a, k, us.contents(u)) catch @panic("put failed");
            }
        };
        const root = try work.createDirPathOpen(io, "packs", .{});
        var store: Store = try .open(gpa, io, root);
        var batch: Store.Batch = .{};
        defer batch.deinit(gpa);
        var t = now(io);
        for (keys[0], 0..) |k, u| _ = try batch.put(gpa, k, units.contents(u));
        const t_put_1 = since(io, t);
        batch.clear();
        // One batch per worker, as Sema's workers will have.
        const batches = try arena.alloc(Store.Batch, n_threads);
        for (batches) |*b| b.* = .{};
        defer for (batches) |*b| b.deinit(gpa);
        t = now(io);
        {
            var group: Io.Group = .init;
            for (batches, 0..) |*b, i| {
                const lo = i * n_units / n_threads;
                const hi = (i + 1) * n_units / n_threads;
                group.async(io, PutBatch.run, .{ b, gpa, units, keys[0][lo..hi], lo });
            }
            try group.await(io);
        }
        const t_put_n = since(io, t);
        var pack_bytes: usize = 0;
        for (batches) |b| pack_bytes += b.bytes.items.len;
        t = now(io);
        _ = try store.commit(gpa, io, batches, null);
        const t_commit = since(io, t);
        store.close(gpa, io);
        print("store, packs: first build 30k puts into a batch {d:.0} ms on 1 thread, {d:.0} ms on {d}, then commit ({d:.1} MiB) {d:.0} ms\n", .{
            ms(t_put_1), ms(t_put_n), n_threads, mib(pack_bytes), ms(t_commit),
        });

        // A first build that writes its Atoms once: the store pack is
        // written into the compilation's directory and hard-linked into the
        // store (copied when the store is on another file system, as
        // /dev/shm is here), and the relink reads the Atoms from it.
        {
            const PutRec = struct {
                fn run(b: *Store.Batch, a: std.mem.Allocator, us: Units, ks: []const Store.Key, first: usize, offs: []usize) void {
                    for (ks, first..) |k, u| offs[u] = b.put(a, k, us.contents(u)) catch @panic("put failed");
                }
            };
            const options: Elf.Options = .{ .entry = entry, .comp_dir = "/bench", .debug = debug };
            const expected = try Elf.emit(gpa, io, atoms, options);
            defer gpa.free(expected);
            const offs = try arena.alloc(usize, n_units);
            const refs = try arena.alloc(Pack.AtomRef, atoms.len);
            var debug_atoms: std.ArrayList(u32) = .empty;
            const shm_ok = if (Io.Dir.cwd().access(io, "/dev/shm", .{})) true else |_| false;
            for ([_]bool{ false, true }) |cross| {
                if (cross and !shm_ok) continue;
                const store_root = if (cross) shm: {
                    Io.Dir.cwd().deleteTree(io, "/dev/shm/bs-bench-cache") catch {}; // ziglint-ignore: Z026 -- cleanup is best effort
                    break :shm try Io.Dir.cwd().createDirPathOpen(io, "/dev/shm/bs-bench-cache", .{});
                } else try work.createDirPathOpen(io, if (cross) "x" else "hl-store", .{});
                const cdir = try work.createDirPathOpen(io, if (cross) "hl-c-cross" else "hl-c", .{});
                var st: Store = try .open(gpa, io, store_root);
                var group: Io.Group = .init;
                for (batches, 0..) |*b, i| {
                    const lo = i * n_units / n_threads;
                    const hi = (i + 1) * n_units / n_threads;
                    group.async(io, PutRec.run, .{ b, gpa, units, keys[0][lo..hi], lo, offs });
                }
                try group.await(io);
                // Where each batch starts in the pack.
                const batch_base = try arena.alloc(u64, n_threads);
                var base_off: u64 = Store.pack_header_len;
                for (batches, batch_base) |b, *bb| {
                    bb.* = base_off;
                    base_off += b.bytes.items.len;
                }
                t = now(io);
                const name = (try st.commit(gpa, io, batches, cdir)).?;
                const t_keep = since(io, t);
                st.close(gpa, io);
                var p: Pack = try .open(io, cdir);
                defer p.close(gpa, io);
                const base = try p.addBase(gpa, io, cdir, &name);
                debug_atoms.clearRetainingCapacity();
                for (0..n_threads) |i| {
                    const lo = i * n_units / n_threads;
                    const hi = (i + 1) * n_units / n_threads;
                    for (lo..hi) |u| {
                        const c = units.contents(u);
                        var off = batch_base[i] + offs[u] + Store.atomsOffset(c.deps.len);
                        var cursor: cache.atoms.DebugCursor = .{ .debug = c.debug };
                        const first_atom = u * atoms.len / n_units;
                        for (c.atoms, 0..) |*a, j| {
                            const d = cursor.of(j);
                            if (d != null) try debug_atoms.append(arena, @intCast(first_atom + j));
                            const len = cache.atoms.encodedLen(a, d);
                            refs[first_atom + j] = .initIn(base, off, @intCast(len));
                            off += len;
                        }
                    }
                }
                var relink: Stats = .{};
                for (0..5) |_| {
                    const t0 = now(io);
                    const input = try p.linkAtoms(gpa, .x86_64, refs, debug_atoms.items, null);
                    defer input.deinit(gpa);
                    const t1 = now(io);
                    const out = try Elf.emitInput(gpa, io, input, options);
                    const t2 = now(io);
                    if (!std.mem.eql(u8, out, expected)) @panic("relink from the store pack differs");
                    gpa.free(out);
                    relink.add(.{ ns(t0, t1), ns(t1, t2), 0, 0 });
                }
                if (cross) Io.Dir.cwd().deleteTree(io, "/dev/shm/bs-bench-cache") catch {}; // ziglint-ignore: Z026 -- cleanup is best effort
                print("  first build writing Atoms once ({s}): commit into the compilation dir and {s} {d:.0} ms; relink from it: gather {d:.2} ms, Elf.emitInput {d:.2} ms (same output)\n", .{
                    if (cross) "store on tmpfs" else "same file system", if (cross) "copy to the store" else "hard-link into the store", ms(t_keep), ms(relink.median(0)), ms(relink.median(1)),
                });
            }
        }

        // Lookups with the 30k entries spread over k packs.
        for ([_]usize{ 1, 8, 64 }) |k| {
            const sub = try arena.print("packs-{d}", .{k});
            const kroot = try work.createDirPathOpen(io, sub, .{});
            {
                var w: Store = try .open(gpa, io, kroot);
                defer w.close(gpa, io);
                for (0..k) |i| {
                    const lo = i * n_units / k;
                    const hi = (i + 1) * n_units / k;
                    for (keys[0][lo..hi], lo..) |key, u| _ = try batch.put(gpa, key, units.contents(u));
                    _ = try w.write(gpa, io, (&batch)[0..1], null);
                }
            }
            var open_s: Stats = .{};
            var get: Stats = .{};
            var miss: Stats = .{};
            for (0..5) |_| {
                const t0 = now(io);
                var st: Store = try .open(gpa, io, kroot);
                const t1 = now(io);
                if (st.packs.len != k) @panic("pack count");
                for (keys[0]) |key| {
                    const e = (try st.get(gpa, io, key)).?;
                    if (!e.isValid(1, AllValid{ .deps = dep_list })) @panic("invalid entry");
                    _ = try e.decodeAtoms(.x86_64, entry_atoms[0..e.atomCount()], &entry_debug);
                }
                const t2 = now(io);
                for (keys[2]) |key| if (try st.get(gpa, io, key) != null) @panic("unexpected hit");
                const t3 = now(io);
                st.close(gpa, io);
                open_s.add(.{ ns(t0, t1), 0, 0, 0 });
                get.add(.{ ns(t1, t2), 0, 0, 0 });
                miss.add(.{ ns(t2, t3), 0, 0, 0 });
            }
            print("  {d:>2} packs: open {d:.3} ms; get+check+decode {d:.2} us, miss {d:.3} us each (medians)\n", .{
                k, ms(open_s.median(0)), ms(get.median(0)) * 1000 / n_units, ms(miss.median(0)) * 1000 / n_units,
            });
            if (k == 8) {
                const sdir = try kroot.openDir(io, "bs/store", .{ .iterate = true });
                t = now(io);
                const r = try Store.maintain(gpa, io, sdir, .{ .trim = true, .now = Io.Clock.real.now(io) });
                const trim = since(io, t);
                if (r.deleted != 0 or r.merged != 0) @panic("trimmed");
                print("  trim scan of 8 packs: {d:.3} ms\n", .{ms(trim)});
            }
            if (k == 64) {
                // Trimming scans the packs; merging 57 of them takes the store
                // back to 8.
                const sdir = try kroot.openDir(io, "bs/store", .{ .iterate = true });
                t = now(io);
                const r1 = try Store.maintain(gpa, io, sdir, .{ .trim = true, .now = Io.Clock.real.now(io) });
                const trim = since(io, t);
                if (r1.deleted != 0) @panic("trimmed");
                print("  trim scan of 64 packs with merge to {d}: {d:.0} ms ({d} merged)\n", .{ Store.max_packs / 2, ms(trim), r1.merged });
            }
        }

        // Concurrent builds: each writes its own 30k entries on one thread
        // and commits.
        const BuildRun = struct {
            fn run(a: std.mem.Allocator, io_: Io, dir: Io.Dir, us: Units, ks: []const Store.Key) void {
                var st: Store = Store.open(a, io_, dir) catch @panic("open failed");
                defer st.close(a, io_);
                var b: Store.Batch = .{};
                defer b.deinit(a);
                for (ks, 0..) |k, u| _ = b.put(a, k, us.contents(u)) catch @panic("put failed");
                _ = st.commit(a, io_, (&b)[0..1], null) catch @panic("commit failed");
            }
        };
        const croot = try work.createDirPathOpen(io, "packs-concurrent", .{});
        t = now(io);
        {
            var group: Io.Group = .init;
            for (0..n_builds) |b| group.async(io, BuildRun.run, .{ gpa, io, croot, units, keys[b] });
            try group.await(io);
        }
        const concurrent = since(io, t);
        var st: Store = try .open(gpa, io, croot);
        defer st.close(gpa, io);
        for (keys[0..n_builds]) |ks| for (ks) |k| if (try st.get(gpa, io, k) == null) @panic("lost an entry");
        print("  {d} concurrent builds of 30k puts and a commit: {d:.0} ms\n", .{ n_builds, ms(concurrent) });
    }
}

/// Up to `runs` samples of four timings.
const Stats = struct {
    samples: [runs][4]u64 = undefined,
    len: usize = 0,

    fn add(s: *Stats, sample: [4]u64) void {
        s.samples[s.len] = sample;
        s.len += 1;
    }

    fn column(s: *const Stats, i: usize, buf: *[runs]u64) []u64 {
        for (s.samples[0..s.len], 0..) |sample, j| buf[j] = sample[i];
        std.mem.sortUnstable(u64, buf[0..s.len], {}, std.sort.asc(u64));
        return buf[0..s.len];
    }

    fn median(s: *const Stats, i: usize) u64 {
        var buf: [runs]u64 = undefined;
        const c = s.column(i, &buf);
        return c[c.len / 2];
    }

    fn best(s: *const Stats, i: usize) u64 {
        var buf: [runs]u64 = undefined;
        return s.column(i, &buf)[0];
    }
};

/// bench-link's mixed ELF set: functions with debug info calling hot and
/// random functions and referencing nearby constants, constants (a quarter
/// emitted twice), data with absolute relocations, and bss.
fn generate(arena: std.mem.Allocator, rand: std.Random, keys: []const Atom.SymbolKey, names: []const []const u8) !struct { []Atom, []Atom.Debug } {
    var atoms: std.ArrayList(Atom) = .empty;
    // Each function's debug info, by its index in `atoms` before shuffling.
    var debug: std.ArrayList(Atom.Debug) = .empty;
    var targets: std.array_hash_map.Auto(Atom.SymbolKey, void) = .empty;
    var files: [500][]const u8 = undefined;
    for (&files, 0..) |*f, j| f.* = try arena.print("src/dir{d}/file{d}.zig", .{ j % 20, j });
    for (0..n_text) |i| {
        const len = rand.intRangeAtMost(u32, 32, 512);
        const bytes = try arena.alloc(u8, len);
        rand.bytes(bytes);
        var relocs: std.ArrayList(Atom.Reloc) = .empty;
        targets.clearRetainingCapacity();
        for (0..len / 32) |j| {
            const call = rand.boolean();
            const target = switch (rand.uintLessThan(u8, 10)) {
                0...4 => blk: {
                    const u = rand.float(f64);
                    break :blk @as(usize, @intFromFloat(u * u * u * n_hot));
                },
                5, 6 => n_text + i * n_rodata / n_text + rand.uintLessThan(usize, 2),
                else => if (call) rand.uintLessThan(usize, n_text) else n_text + rand.uintLessThan(usize, n_rodata),
            };
            const gop = try targets.getOrPut(arena, keys[target]);
            try relocs.append(arena, .init(@intCast(j * 32 + 1), .x86_64_pc32, @intCast(gop.index), -4));
        }
        var lines: Atom.LineProgram = .{};
        var offset: u32 = 0;
        var line: u32 = 0;
        while (offset < len) : (offset += rand.intRangeAtMost(u32, 8, 40)) {
            try lines.addRow(arena, offset, line, rand.intRangeAtMost(u32, 4, 40));
            line += rand.intRangeAtMost(u32, 1, 3);
        }
        const name = names[i];
        try debug.append(arena, .{ .atom = @intCast(atoms.items.len), .file = files[i % files.len], .name = name[std.mem.findScalarLast(u8, name, ':').? + 1 ..], .base_line = rand.uintLessThan(u32, 5000), .lines = lines.bytes.items });
        try atoms.append(arena, .{ .key = keys[i], .name = name, .section = .text, .alignment = .@"16", .bytes = bytes, .targets = try arena.dupe(Atom.SymbolKey, targets.keys()), .relocs = relocs.items, .unwind = .frame_pointer });
    }
    for (0..n_rodata) |i| {
        const bytes = try arena.alloc(u8, rand.intRangeAtMost(u32, 8, 128));
        rand.bytes(bytes);
        const a: Atom = .{ .key = keys[n_text + i], .name = names[n_text + i], .section = .rodata, .alignment = .@"8", .bytes = bytes };
        try atoms.append(arena, a);
        if (i % 4 == 0) try atoms.append(arena, a);
    }
    for (0..n_data) |i| {
        const bytes = try arena.alloc(u8, 32);
        rand.bytes(bytes);
        const t = try arena.alloc(Atom.SymbolKey, 2);
        for (t) |*k| k.* = keys[rand.uintLessThan(usize, keys.len - n_bss)];
        if (t[0] == t[1]) t[1] = keys[0];
        const relocs = try arena.dupe(Atom.Reloc, &.{ .init(0, .x86_64_abs64, 0, 0), .init(8, .x86_64_abs64, 1, 0) });
        const k = n_text + n_rodata + i;
        try atoms.append(arena, .{ .key = keys[k], .name = names[k], .section = .data, .alignment = .@"8", .bytes = bytes, .targets = t, .relocs = relocs });
    }
    for (0..n_bss) |i| {
        const k = n_text + n_rodata + n_data + i;
        try atoms.append(arena, .{ .key = keys[k], .name = names[k], .section = .bss, .alignment = .@"8", .zero_fill = 64 });
    }
    // Shuffle, as parallel CodeGen finishes in arbitrary order; the debug
    // entries follow their atoms.
    const order = try arena.alloc(u32, atoms.items.len);
    for (order, 0..) |*o, j| o.* = @intCast(j);
    rand.shuffle(u32, order);
    const shuffled = try arena.alloc(Atom, atoms.items.len);
    const new_index = try arena.alloc(u32, atoms.items.len);
    for (order, shuffled, 0..) |o, *a, j| {
        a.* = atoms.items[o];
        new_index[o] = @intCast(j);
    }
    for (debug.items) |*d| d.atom = new_index[d.atom];
    std.mem.sort(Atom.Debug, debug.items, {}, struct {
        fn lt(_: void, a: Atom.Debug, b: Atom.Debug) bool {
            return a.atom < b.atom;
        }
    }.lt);
    return .{ shuffled, debug.items };
}

fn now(io: Io) Io.Timestamp {
    return Io.Timestamp.now(io, .awake);
}

fn ns(a: Io.Timestamp, b: Io.Timestamp) u64 {
    return @intCast(a.durationTo(b).nanoseconds);
}

fn since(io: Io, a: Io.Timestamp) u64 {
    return ns(a, now(io));
}

fn ms(n: u64) f64 {
    return @as(f64, @floatFromInt(n)) / 1e6;
}

fn mib(n: u64) f64 {
    return @as(f64, @floatFromInt(n)) / (1 << 20);
}
