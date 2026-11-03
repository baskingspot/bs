//! Connects a compilation to the on-disk cache (`cache.zig`, "The on-disk
//! cache" in docs/architecture.md).
//!
//! - A build whose inputs did not change since the last successful one
//!   relinks from the cached Atoms and skips the frontend, Sema, and
//!   CodeGen (`relinkIfUnchanged`).
//! - Every successful build is recorded (`record`): each unit's atoms go
//!   to the global store as an entry, unless an equal entry is already
//!   there, and the compilation's manifest lists the units, their
//!   dependencies, source and result hashes, results (`results.zig`),
//!   atoms (in the store packs it hard-links as base packs), input stats,
//!   error codes, and entry.
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
const seeds = cache.seeds;
const results = cache.results;
const Hash = cache.Hash;
const Frontend = @import("Frontend.zig");
const InternPool = @import("InternPool.zig");
const Zcu = @import("Zcu.zig");
const Emit = @import("Emit.zig");
const Atom = @import("link/Atom.zig");
const Elf = @import("link/Elf.zig");
const Replay = @import("Replay.zig");

const Incremental = @This();

gpa: Allocator,
io: Io,
/// `<global cache>`, for the store.
global: Io.Dir,
/// `<local cache>`, whose compilation directories `record` trims.
local: Io.Dir,
/// The size limit of the store and of the local cache's compilation
/// directories (`ZAP_CACHE_MAX_SIZE`).
max_bytes: u64 = cache.default_max_bytes,
/// The compilation's directory, locked by `lock` until `close`.
dir: Io.Dir,
lock: Io.File,
/// Identifies the compiler and target: part of every store key, so store
/// entries are shared by every project built by the same zap for the same
/// target.
store_seed: Hash,
/// The target's architecture, whose unwind records cached atoms must have.
arch: Atom.Unwind.Arch,
/// Taken before the inputs are read; inputs modified after it are
/// recorded as needing a rehash.
build_start: Io.Timestamp,
/// The last successful build's manifest, if any.
prev: ?Manifest = null,
/// `ZAP_CACHE_TIMING`: print where the cache's time goes.
timing: bool,
/// `ZAP_CACHE_CHECK`: check that the last manifest's reverse edges predict
/// every result this build changed, and that the recorded references
/// reach every function. A gap fails the build (`finishRecord`).
check: bool = false,
check_failed: std.atomic.Value(bool) = .init(false),
/// `--stack`, for a relink; part of the command line that keys the
/// compilation.
stack_size: u64 = 16 * 1024 * 1024,
/// Whether a build that does not relink renews the output's mtime, as a
/// relink would: `zap run`'s programs are trimmed by it.
renew_output: bool = false,
/// `ZAP_CACHE_VERIFY`: `replay` checks an edit build that loaded units
/// by building again in full (`full`, the build's own environment then),
/// which compares its nodes with the edit build's (`verifyNodes`).
verify: enum { off, replay, full } = .off,
/// For `verify`: the command line and environment to build again with.
verify_argv: []const []const u8 = &.{},
verify_environ: ?*std.process.Environ.Map = null,
/// The recording `startRecord` runs while the build links.
recording: ?Io.Future(anyerror!Recorded) = null,
/// An edit build's replay of `prev` (`beginReplay`); the atoms it loaded
/// point into its packs until `close`.
replay: ?*Replay = null,

/// Opens and locks the directory of the compilation that `args` (the
/// command line after `zap`) describes, run from the current directory.
/// `zig_lib_dir` is the std that compilation uses.
pub fn open(gpa: Allocator, io: Io, dirs: Frontend.CacheDirs, args: []const []const u8, zig_lib_dir: []const u8, target: []const u8, timing: bool) !Incremental {
    const build_start = Io.Clock.real.now(io);
    const store_seed, const key = try compilationKey(gpa, io, args, zig_lib_dir, target);

    const local = try Io.Dir.cwd().createDirPathOpen(io, dirs.local, .{});
    errdefer local.close(io);
    const dir = try cache.compilationDir(io, local, key);
    errdefer dir.close(io);
    const lock = try cache.lock(io, dir);
    errdefer lock.close(io);
    const global = try Io.Dir.cwd().createDirPathOpen(io, dirs.global, .{});
    var inc: Incremental = .{
        .gpa = gpa,
        .io = io,
        .global = global,
        .local = local,
        .dir = dir,
        .lock = lock,
        .store_seed = store_seed,
        .arch = if (std.mem.startsWith(u8, target, "aarch64")) .aarch64 else .x86_64,
        .build_start = build_start,
        .timing = timing,
    };
    inc.prev = Manifest.open(gpa, io, dir) catch |err| prev: {
        if (timing) std.debug.print("cache: unable to open the manifest: {t}\n", .{err});
        break :prev null;
    };
    return inc;
}

/// The store seed (the compiler's identity and the target) and the key of
/// the compilation that `args` describes from the current directory (see
/// `open`).
pub fn compilationKey(gpa: Allocator, io: Io, args: []const []const u8, zig_lib_dir: []const u8, target: []const u8) !struct { Hash, Hash } {
    // The compiler's identity: a rebuilt zap must not reuse what an older
    // one cached. The ctime too, which only the kernel sets: a different
    // zap copied over this file in place, keeping its inode, with the same
    // size and its mtime restored (`cp` then `touch -d`, `rsync
    // --inplace -t`), matches on the other three.
    const exe = try std.process.openExecutable(io, .{});
    const exe_stat = exe.stat(io);
    exe.close(io);
    const st = try exe_stat;
    var id: std.ArrayList(u8) = .empty;
    defer id.deinit(gpa);
    try id.print(gpa, "zap\x00{d}\x00{d}\x00{d}\x00{d}\x00{s}\x00", .{ st.inode, st.size, st.mtime.toNanoseconds(), st.ctime.toNanoseconds(), target });
    const store_seed = cache.hash(0, id.items);
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    try id.print(gpa, "{s}\x00{s}\x00", .{ cwd, zig_lib_dir });
    for (args) |a| try id.print(gpa, "{s}\x00", .{a});
    return .{ store_seed, cache.hash(1, id.items) };
}

/// The digest naming a `--listen=-` compilation's output directory,
/// `<local cache>/o/<32 hex digits>` (std's `emit_digest`), from the
/// compilation's key: it stays the same across edits, so the output is
/// relinked in place, and the compilation's directory can find it.
/// Salted apart from upstream's digests, which share `o/`.
pub fn outputDigest(key: Hash) [16]u8 {
    return @bitCast(cache.hash(0x7a61702d6f7574, std.mem.asBytes(&key)));
}

pub fn close(inc: *Incremental) void {
    if (inc.recording) |*f| {
        var r = f.cancel(inc.io) catch null;
        if (r) |*rec| rec.discard(inc);
    }
    if (inc.replay) |r| r.destroy();
    if (inc.prev) |*m| m.close(inc.gpa, inc.io);
    inc.global.close(inc.io);
    inc.local.close(inc.io);
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
    const m = if (inc.prev) |*m| m else return inc.noRelink("no manifest", .{});
    if (inc.verify == .full) return inc.noRelink("verifying an edit build", .{});
    if (m.entry == 0) return inc.noRelink("no entry point", .{});
    var changed: std.ArrayList(u32) = .empty;
    defer changed.deinit(gpa);
    try m.changedInputs(gpa, io, &changed);
    // Inputs whose stats changed but whose contents did not (touched,
    // checked out again, or too new to trust when recorded) get their new
    // stats in the manifest's log after the relink.
    var restat: ?Manifest.Delta = null;
    defer if (restat) |*d| d.deinit();
    for (changed.items) |i| {
        const in, const path = m.input(i);
        const same = same: {
            const src = Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch break :same false;
            defer gpa.free(src);
            break :same @as(Hash, @bitCast(Frontend.hashSource(src))) == in.content_hash;
        };
        if (!same) {
            if (inc.timing) std.debug.print("cache: {d} inputs changed, first {s}\n", .{ changed.items.len, path });
            return false;
        }
        const stat = Io.Dir.cwd().statFile(io, path, .{}) catch |err| return inc.noRelink("{s}: {t}", .{ path, err });
        if (restat == null) restat = .init(gpa, m);
        try restat.?.setInput(i, path, stat, in.content_hash, inc.build_start);
    }
    const t1 = now(io);
    // Past the fold size, the inputs are rehashed until the next full build
    // writes a new base, so that the log stays bounded.
    defer if (restat) |*d| if (!m.shouldFold()) d.append(io, inc.dir) catch {};
    if (inc.outputUnchanged(out_dir, sub_path)) {
        if (inc.timing) std.debug.print("cache: no input changed and the output is as the last link left it; not relinking ({d:.2} ms, {d} rehashed)\n", .{ ms(t0, now(io)), changed.items.len });
        return true;
    }
    inc.forgetOutput();

    var pack: Pack = try .open(io, inc.dir);
    defer pack.close(gpa, io);
    if (pack.id != m.pack_id) return inc.noRelink("the pack is not the manifest's", .{});
    for (0..m.bases.len) |i| _ = pack.addBase(gpa, io, inc.dir, m.basePack(i)) catch |err|
        return inc.noRelink("base pack {s}: {t}", .{ m.basePack(i), err });
    const in = try m.linkInput(gpa);
    const files = try gpa.alloc([]const u8, m.fileCount());
    defer gpa.free(files);
    for (files, 0..) |*f, i| f.* = m.file(@intCast(i));
    const input = try pack.linkAtoms(gpa, inc.arch, in.refs, in.debug_atoms, .{ .of = in.debug_files, .names = files });
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
        .stack_size = inc.stack_size,
    }) catch |err| switch (err) {
        // A damaged pack or manifest: build from scratch instead.
        error.InvalidInput, error.InvalidSymbols, error.InvalidDebugInfo => return inc.noRelink("{t} (atom '{s}')", .{ err, diag.atom }),
        else => {
            std.debug.print("error: link failed: {t} (atom '{s}')\n", .{ err, diag.atom });
            return err;
        },
    };
    inc.noteOutput(out_dir, sub_path);
    if (inc.timing) std.debug.print("cache: no input changed; relinked {d} atoms in {d:.2} ms (manifest and {d} stats {d:.2}, {d} rehashed; packs mapped and input gathered {d:.2}, link {d:.2})\n", .{
        in.refs.len, ms(t0, now(io)), m.inputCount(), ms(t0, t1), changed.items.len, ms(t1, t2), ms(t2, now(io)),
    });
    return true;
}

/// The file in the compilation's directory that holds the stat the last
/// link left its output with (`OutputStat`, then the output's path), so
/// that a build with nothing to do neither relinks nor touches the output:
/// a `zig build` runner copies and rehashes an output whose mtime moved.
const output_name = "output";

const OutputStat = extern struct { inode: u64, size: u64, mtime: i64 };

/// Whether `sub_path` still has the stat `noteOutput` recorded for it.
/// With `renew_output`, also renews its mtime, recording the new stat.
fn outputUnchanged(inc: *Incremental, out_dir: Io.Dir, sub_path: []const u8) bool {
    const io = inc.io;
    var buf: [@sizeOf(OutputStat) + 4096]u8 = undefined;
    const bytes = inc.dir.readFile(io, output_name, &buf) catch return false;
    if (bytes.len < @sizeOf(OutputStat) or !std.mem.eql(u8, bytes[@sizeOf(OutputStat)..], sub_path)) return false;
    const want = std.mem.bytesToValue(OutputStat, bytes[0..@sizeOf(OutputStat)]);
    const stat = out_dir.statFile(io, sub_path, .{}) catch return false;
    if (stat.inode != want.inode or stat.size != want.size or stat.mtime.toNanoseconds() != want.mtime) return false;
    if (inc.renew_output) {
        out_dir.setTimestampsNow(io, sub_path, .{}) catch return false;
        inc.noteOutput(out_dir, sub_path);
    }
    return true;
}

/// Records the stat of the output a link just wrote. Best effort.
pub fn noteOutput(inc: *const Incremental, out_dir: Io.Dir, sub_path: []const u8) void {
    const io = inc.io;
    if (sub_path.len > 4096) return;
    const stat = out_dir.statFile(io, sub_path, .{}) catch return;
    const os: OutputStat = .{ .inode = @intCast(stat.inode), .size = stat.size, .mtime = @intCast(stat.mtime.toNanoseconds()) };
    cache.writeReplace(io, inc.dir, output_name, &.{ std.mem.asBytes(&os), sub_path }) catch {};
}

/// Forgets the output's stat before a link replaces the output, so that
/// a link that fails halfway does not leave it matching.
fn forgetOutput(inc: *const Incremental) void {
    inc.dir.deleteFile(inc.io, output_name) catch {};
}

/// Returns false for `relinkIfUnchanged`, saying why under
/// `ZAP_CACHE_TIMING`.
fn noRelink(inc: *const Incremental, comptime fmt: []const u8, args: anytype) bool {
    if (inc.timing) std.debug.print("cache: not relinking: " ++ fmt ++ "\n", args);
    return false;
}

/// Makes this an edit build: analysis loads the units the edits since the
/// last build left green from it (see "Edit builds: replaying cached
/// results" in docs/architecture.md). Call after `seedErrors`, before
/// analysis. `ZAP_CACHE_REPLAY=off` turns it off.
pub fn beginReplay(inc: *Incremental, fe: *const Frontend, zcu: *Zcu, emit: *Emit, off: bool) !void {
    const m = if (inc.prev) |*m| m else return;
    if (off or inc.verify == .full) return;
    const r = Replay.create(inc.gpa, inc.io, m, inc.dir, inc.arch, fe, zcu, emit) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (inc.timing) std.debug.print("cache: not replaying: {t}\n", .{err});
            return;
        },
    };
    r.check = inc.check;
    inc.replay = r;
    zcu.replay = r;
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
    source: Manifest.Source = .none,
    source_name: ?[]const u8 = null,
    /// `Manifest.Edge` words, by node index ascending and distinct; set by
    /// `Recorder.group`.
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
    struct_defaults,
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
            .struct_defaults => |t| mix(4, @backingInt(t)),
        };
    }
    pub fn eql(_: UnitContext, a: Zcu.AnalUnit, b: Zcu.AnalUnit) bool {
        return std.meta.eql(a, b);
    }
};

/// Also Sema's, for the set of dependencies a unit declared.
/// A dependee to position map, as Sema keeps per unit (see `Zcu.dep_maps`).
pub const DependeeMap = std.HashMapUnmanaged(Zcu.Dependee, u32, DependeeContext, std.hash_map.default_max_load_percentage);

pub const DependeeContext = struct {
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
            .struct_defaults => |t| mix(8, @backingInt(t)),
        };
    }
    pub fn eql(_: DependeeContext, a: Zcu.Dependee, b: Zcu.Dependee) bool {
        return std.meta.eql(a, b);
    }
};

pub const Recorder = struct {
    gpa: Allocator,
    zcu: *Zcu,
    nodes: std.ArrayList(Node) = .empty,
    map: std.HashMapUnmanaged(Hash, u32, HashContext, std.hash_map.default_max_load_percentage) = .empty,
    /// Each distinct unit and dependee, by index into `unit_list` and
    /// `dependee_list`, whose `Info` (key and hashes) `prepare` computes
    /// on every core before `unitNode` and `dependeeNode` make nodes of
    /// them. Dependees that are units (`nav_val`, `type_layout`,
    /// `struct_defaults`) are only in `units`.
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
    /// small lists per node. A dependency is its node index times two,
    /// plus one if it is conditional (`edge`).
    edges: std.ArrayList([2]u32) = .empty,
    atom_pairs: std.ArrayList([2]u32) = .empty,
    storage: []u32 = &.{},

    const no_node = std.math.maxInt(u32);

    const Ref = union(enum) { unit: u32, dependee: u32 };

    /// The second word of an `edges` pair.
    fn edge(dep: u32, conditional: bool) u32 {
        return dep << 1 | @intFromBool(conditional);
    }

    /// What a unit's or dependee's node gets, and the node once made.
    pub const Info = struct {
        key: Hash = 0,
        src_hash: Hash = 0,
        result_hash: Hash = 0,
        source: Manifest.Source = .none,
        source_name: ?[]const u8 = null,
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
            .struct_defaults => |ty| return .{ .unit = try r.addUnit(.{ .struct_defaults = ty }) },
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
            r.nodes.items[index].source = info.source;
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
            .nav_val, .type_layout, .struct_defaults => unreachable,
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
            r.nodes.items[index].source = info.source;
            r.nodes.items[index].source_name = info.source_name;
            const producer = r.dependee_producer.items[i];
            if (producer != no_node) try r.edges.append(r.gpa, .{ index, edge(try r.unitNode(producer), false) });
        }
        return index;
    }

    pub fn unitTag(unit: Zcu.AnalUnit) Tag {
        return switch (unit) {
            .nav_val => .nav_val,
            .type_layout => .type_layout,
            .func => .func,
            .comptime_decl => .comptime_decl,
            .struct_defaults => .struct_defaults,
        };
    }

    /// Sets each node's `deps` (sorted, without repeats, plain over
    /// conditional) and `atoms` (in order) from the pairs, with stable
    /// counting sorts: O(pairs + nodes).
    fn group(r: *Recorder) !void {
        const gpa = r.gpa;
        const n = r.nodes.items.len;
        const tmp = try gpa.alloc([2]u32, @max(r.edges.items.len, r.atom_pairs.items.len));
        defer gpa.free(tmp);
        const counts = try gpa.alloc(u32, 2 * n + 1);
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
                // A plain edge sorts before a conditional one to the same
                // node, and wins.
                const dep = edges[i][1] >> 1;
                if (at > start and Manifest.Edge.nodeOf(r.storage[at - 1]) == dep) continue;
                r.storage[at] = Manifest.Edge.init(dep, if (edges[i][1] & 1 != 0) .conditional else .plain);
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
pub const Keyer = struct {
    zcu: *Zcu,
    key_buf: std.Io.Writer.Allocating,
    unit_buf: std.Io.Writer.Allocating,

    /// A key for `parts`, distinct per `tag`.
    pub fn init(zcu: *Zcu, gpa: Allocator) Keyer {
        return .{ .zcu = zcu, .key_buf = .init(gpa), .unit_buf = .init(gpa) };
    }

    pub fn deinit(k: *Keyer) void {
        k.key_buf.deinit();
        k.unit_buf.deinit();
    }

    pub fn keyOf(k: *Keyer, tag: Tag, parts: []const []const u8) !Hash {
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
    pub fn unitKeyString(k: *Keyer, unit: Zcu.AnalUnit) ![]const u8 {
        k.unit_buf.clearRetainingCapacity();
        try k.zcu.unitKey(unit, &k.unit_buf.writer);
        return k.unit_buf.written();
    }

    fn source(file: u32, inst: std.zig.Zir.Inst.Index) Manifest.Source {
        return .{ .input = file, .inst = @backingInt(inst) };
    }

    /// A namespace's container: where its declarations' names are.
    fn namespaceSource(k: *Keyer, ns: *const Zcu.Namespace) Manifest.Source {
        return source(ns.file, k.zcu.ip.containerType(ns.owner_type).?.zir_inst);
    }

    fn srcHash(k: *Keyer, file: u32, inst: std.zig.Zir.Inst.Index) Hash {
        const h = k.zcu.file(file).zir.getAssociatedSrcHash(inst) orelse return 0;
        return @bitCast(h);
    }

    /// `unitInfo(unit).src_hash`, without the rest.
    pub fn unitSrcHash(k: *Keyer, unit: Zcu.AnalUnit) Hash {
        const ip = &k.zcu.ip;
        return switch (unit) {
            .nav_val => |nav_index| k.srcHash(ip.getNav(nav_index).file, ip.getNav(nav_index).zir_inst),
            .type_layout, .struct_defaults => |ty| k.srcHash(ip.containerType(ty).?.file, ip.containerType(ty).?.zir_inst),
            .func => |func| blk: {
                const owner = ip.getNav(ip.indexToKey(func).func.owner_nav);
                break :blk k.srcHash(owner.file, owner.zir_inst);
            },
            .comptime_decl => |c| k.srcHash(c.file, c.inst),
        };
    }

    pub fn unitInfo(k: *Keyer, unit: Zcu.AnalUnit) !Recorder.Info {
        const ip = &k.zcu.ip;
        var info: Recorder.Info = .{ .key = try k.keyOf(Recorder.unitTag(unit), &.{try k.unitKeyString(unit)}) };
        switch (unit) {
            .nav_val => |nav_index| {
                const nav = ip.getNav(nav_index);
                info.src_hash = k.srcHash(nav.file, nav.zir_inst);
                info.source = source(nav.file, nav.zir_inst);
                if (nav.status == .resolved) info.result_hash = navResultHash(ip, nav);
            },
            .type_layout => |ty| {
                const c = ip.containerType(ty).?;
                info.src_hash = k.srcHash(c.file, c.zir_inst);
                info.source = source(c.file, c.zir_inst);
                info.result_hash = layoutResultHash(ip, ty);
            },
            .func => |func| {
                const owner = ip.getNav(ip.keyPayload(.func, func).owner_nav);
                info.src_hash = k.srcHash(owner.file, owner.zir_inst);
                info.source = source(owner.file, owner.zir_inst);
                // The result is the function's atom, hashed in `record`.
            },
            .comptime_decl => |c| {
                info.src_hash = k.srcHash(c.file, c.inst);
                info.source = source(c.file, c.inst);
            },
            .struct_defaults => |ty| {
                const c = ip.containerType(ty).?;
                info.src_hash = k.srcHash(c.file, c.zir_inst);
                info.source = source(c.file, c.zir_inst);
                info.result_hash = defaultsResultHash(ip, ty);
            },
        }
        return info;
    }

    pub fn dependeeInfo(k: *Keyer, d: Zcu.Dependee) !Recorder.Info {
        const ip = &k.zcu.ip;
        switch (d) {
            .nav_val, .type_layout, .struct_defaults => unreachable, // Units.
            .nav_ty => |nav_index| {
                const nav = ip.getNav(nav_index);
                return .{
                    .key = try k.keyOf(.nav_ty, &.{ip.stringSlice(nav.key)}),
                    .result_hash = if (nav.status == .resolved) ip.stableHash(ip.typeOf(nav.val)) else 0,
                };
            },
            .func_body => |func| {
                const owner = ip.getNav(ip.keyPayload(.func, func).owner_nav);
                return .{
                    .key = try k.keyOf(.func_body, &.{try k.unitKeyString(.{ .func = func })}),
                    .result_hash = k.srcHash(owner.file, owner.zir_inst),
                    .source = source(owner.file, owner.zir_inst),
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
                    // Which declaration the name finds, if any, and
                    // whether it is `pub` (`@hasDecl`, and access from
                    // other files, read that).
                    .result_hash = if (ns.decls.get(nn.name)) |nav| cache.hash(3, ip.stringSlice(ip.getNav(nav).key)) ^ @intFromBool(ip.getNav(nav).is_pub) else 0,
                    .source = k.namespaceSource(ns),
                    .source_name = ip.stringSlice(nn.name),
                };
            },
            .namespace => |ns_index| {
                const ns = k.zcu.namespacePtr(ns_index);
                // The names, and which are `pub`: `@typeInfo`'s
                // `decl_names` lists only those.
                var h: Hash = 0;
                for (ns.decls.keys(), ns.decls.values()) |name, nav| {
                    h = cache.hash(@as(u64, @truncate(h)) ^ @intFromBool(ip.getNav(nav).is_pub), ip.stringSlice(name)) ^ h;
                }
                return .{ .key = try k.keyOf(.namespace, &.{ns.key}), .result_hash = h, .source = k.namespaceSource(ns) };
            },
            // The file's contents, by its path in its module.
            .embed_file => |i| {
                const f = k.zcu.embed_files.values()[i];
                // Embedded files' inputs follow the source files'.
                return .{
                    .key = try k.keyOf(.embed_file, &.{f.key}),
                    .result_hash = f.hash,
                    .source = .{ .input = @intCast(k.zcu.fe.files.items.len + i), .inst = Manifest.Source.no_inst },
                };
            },
        }
    }
};

/// A resolved declaration's result: its value, and what dependents read
/// besides it.
fn navResultHash(ip: *const InternPool, nav: *const InternPool.Nav) Hash {
    var h = std.hash.Wyhash.init(8);
    h.update(std.mem.asBytes(&ip.stableHash(nav.val)));
    h.update(&.{ @intFromBool(nav.is_const), @intFromBool(nav.is_threadlocal), @backingInt(nav.linkage) });
    h.update(std.mem.asBytes(&nav.alignment));
    const lo = h.final();
    return @as(Hash, ip.stableHash(nav.val) >> 64 ^ lo) << 64 | lo;
}

/// A container type's layout result: everything its `ContainerInfo` tells
/// dependents, with types by identity, so that early cutoff stops only
/// when the layout is truly unchanged. `comptime_only` is in it: a field
/// type gaining a `type` field can leave sizes and offsets alone. Before
/// the layout is known (an opaque type, a failed one), the type's
/// identity.
fn layoutResultHash(ip: *const InternPool, ty: InternPool.Index) Hash {
    const id = ip.stableHash(ty);
    const kind = std.meta.activeTag(ip.indexToKey(ty));
    if (kind == .opaque_type) return id;
    const info = ip.structInfo(ty);
    if (info.status != .have_layout) return id;
    var h = std.hash.Wyhash.init(9);
    const Helper = struct {
        fn index(hh: *std.hash.Wyhash, pool: *const InternPool, i: InternPool.Index) void {
            const x: Hash = if (i == .none) 0 else pool.stableHash(i);
            hh.update(std.mem.asBytes(&x));
        }
    };
    h.update(std.mem.asBytes(&id));
    h.update(&.{ @backingInt(info.layout), @intFromBool(info.nonexhaustive), @intFromBool(info.has_runtime_tag) });
    for (info.field_names) |n| {
        h.update(ip.stringSlice(n));
        h.update(&.{0});
    }
    for (info.field_types) |t| Helper.index(&h, ip, t);
    // Only `comptime` fields' values; the other defaults are the
    // `struct_defaults` unit's result. Enums' tag values are all here.
    const is_struct = kind == .struct_type;
    for (info.field_defaults, 0..) |d, i| Helper.index(&h, ip, if (!is_struct or info.fieldIsComptime(i)) d else .none);
    h.update(std.mem.sliceAsBytes(info.field_offsets));
    h.update(std.mem.sliceAsBytes(info.field_is_comptime));
    h.update(std.mem.sliceAsBytes(info.field_aligns));
    Helper.index(&h, ip, info.tag_type);
    h.update(std.mem.asBytes(&info.size));
    h.update(std.mem.asBytes(&info.alignment));
    // Sema sets it when a struct's or union's layout resolves; enums and
    // the rest are never comptime-only.
    if (kind == .struct_type or kind == .union_type) std.debug.assert(info.comptime_only == .yes or info.comptime_only == .no);
    h.update(&.{@intFromBool(info.comptime_only == .yes)});
    const lo = h.final();
    return @as(Hash, id >> 64 ^ lo) << 64 | lo;
}

/// A struct's `struct_defaults` result: its non-`comptime` fields' default
/// values, 0 for a field without one. Before they are resolved, the
/// type's identity.
fn defaultsResultHash(ip: *const InternPool, ty: InternPool.Index) Hash {
    const id = ip.stableHash(ty);
    const info = ip.structInfo(ty);
    if (info.defaults_status != .resolved) return id;
    var h = std.hash.Wyhash.init(10);
    h.update(std.mem.asBytes(&id));
    for (info.field_defaults, 0..) |d, i| {
        const x: Hash = if (d == .none or info.fieldIsComptime(i)) 0 else ip.stableHash(d);
        h.update(std.mem.asBytes(&x));
    }
    const lo = h.final();
    return @as(Hash, id >> 64 ^ lo) << 64 | lo;
}

/// Starts recording the build that `emit` is about to link, on another
/// thread: `record` needs only the atoms and the Zcu, which the link does
/// not change, so it runs alongside the link. `finishRecord` keeps or
/// discards it. `fe`, `zcu`, and `emit` must not change until then.
pub fn startRecord(inc: *Incremental, fe: *const Frontend, zcu: *Zcu, emit: *const Emit) void {
    inc.forgetOutput();
    if (inc.timing) if (inc.replay) |r| r.printStats();
    std.debug.assert(inc.recording == null);
    inc.recording = inc.io.async(record, .{ inc, fe, zcu, emit });
}

/// Waits for the recording `startRecord` started, and if the link
/// succeeded, makes it the compilation's manifest. A failed link discards
/// it, so the next build starts from the last successful one. (Its store
/// entries stay: they are valid results whichever way the link went.) A
/// recording that fails, on a full disk for one, costs the next build its
/// reuse but not this build its success: it is reported as a warning.
pub fn finishRecord(inc: *Incremental, linked: bool) void {
    inc.finishRecordFallible(linked) catch |err|
        std.log.warn("the cache did not record this build: {t}", .{err});
}

fn finishRecordFallible(inc: *Incremental, linked: bool) !void {
    const t0 = now(inc.io);
    var r = try inc.recording.?.await(inc.io);
    inc.recording = null;
    if (inc.check_failed.load(.monotonic)) {
        // Loudly, so that a conformance run with the check on cannot hide
        // a gap; the gaps are printed above.
        r.discard(inc);
        if (inc.verify == .full) {
            std.debug.print("error: ZAP_CACHE_VERIFY: the edit build's nodes differ from a full build's\n", .{});
        } else std.debug.print("error: ZAP_CACHE_CHECK found gaps in the recorded dependencies or references\n", .{});
        std.process.exit(1);
    }
    const waited = ms(t0, now(inc.io));
    if (!linked) return r.discard(inc);
    defer r.discard(inc);
    try Manifest.Builder.place(&r.manifest, inc.io, inc.dir);
    // Base packs the new manifest does not name.
    var it = inc.dir.iterate();
    while (it.next(inc.io) catch null) |e| {
        if (!std.mem.endsWith(u8, e.name, ".zsp")) continue;
        for (r.base_names) |name| {
            if (std.mem.eql(u8, name, e.name)) break;
        } else inc.dir.deleteFile(inc.io, e.name) catch {};
    }
    if (inc.timing) std.debug.print("{s}; after the link, waited {d:.2} ms and placed in {d:.2} ms\n", .{ r.report, waited, ms(t0, now(inc.io)) - waited });
    switch (inc.verify) {
        .off => {},
        .replay => if (inc.replay != null) try inc.verifyReplay(),
        // Verified; the edit build that started this one runs the result.
        .full => std.process.exit(0),
    }
}

/// `ZAP_CACHE_VERIFY`: builds again in full in a child zap, which compares
/// its nodes with this edit build's manifest, and exits if they differ.
fn verifyReplay(inc: *Incremental) !void {
    const io = inc.io;
    const env = inc.verify_environ.?;
    const old = env.get("ZAP_CACHE_VERIFY") orelse "1";
    try env.put("ZAP_CACHE_VERIFY", "full");
    defer env.put("ZAP_CACHE_VERIFY", old) catch {};
    const argv = try inc.gpa.dupe([]const u8, inc.verify_argv);
    defer inc.gpa.free(argv);
    const self = try std.process.executablePathAlloc(io, inc.gpa);
    defer inc.gpa.free(self);
    argv[0] = self;
    // The child takes the compilation's lock.
    inc.lock.close(io);
    var child = try std.process.spawn(io, .{ .argv = argv, .environ_map = env });
    const term = child.wait(io);
    inc.lock = try cache.lock(io, inc.dir);
    switch (try term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    std.debug.print("error: ZAP_CACHE_VERIFY: the full build of this edit build failed or differed\n", .{});
    std.process.exit(1);
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
    // The ZIR caches' garbage, beside the rest. (`Putter.writePack`
    // applies the local cache's size limit.)
    var trimming = io.async(Frontend.trimCaches, .{fe});
    defer trimming.await(io);
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
    // Every non-empty inferred error set, read or not: a loaded function
    // takes its set from this node, and an edit build may add its first
    // reader (`Replay.loadFunc` reads no node as an empty set).
    var ies_items: std.ArrayList(Recorder.Ref) = .empty;
    defer ies_items.deinit(gpa);
    {
        var it = zcu.inferred_errors.iterator();
        while (it.next()) |e| if (e.value_ptr.len != 0) {
            try ies_items.append(gpa, try r.addDependee(.{ .func_ies = e.key_ptr.* }));
        };
        var it_any = zcu.anyerror_ies.keyIterator();
        while (it_any.next()) |f| try ies_items.append(gpa, try r.addDependee(.{ .func_ies = f.* }));
    }
    const use_units = try gpa.alloc(u32, emit.content_uses.items.len);
    defer gpa.free(use_units);
    for (emit.content_uses.items, use_units) |use, *u| u.* = try r.addUnit(use.unit);
    // References: Sema's queued functions and Emit's requests, as unit
    // items for now.
    const func_ref_items = try gpa.alloc([2]u32, zcu.func_refs.count());
    defer gpa.free(func_ref_items);
    for (zcu.func_refs.keys(), func_ref_items) |fr, *it| it.* = .{ try r.addUnit(fr.from), try r.addUnit(.{ .func = fr.func }) };
    // Units an edit build must analyze, and generic instances' branch
    // quotas (see `Manifest.Ref.Kind`).
    var analyze_items: std.ArrayList(u32) = .empty;
    defer analyze_items.deinit(gpa);
    for (zcu.effect_uses.keys()) |use| if (!loadMakes(zcu, use)) try analyze_items.append(gpa, try r.addUnit(use.unit));
    for (zcu.exports.items) |e| if (e.unit) |unit| try analyze_items.append(gpa, try r.addUnit(unit));
    var quota_items: std.ArrayList([2]u32) = .empty;
    defer quota_items.deinit(gpa);
    var it_quota = zcu.branch_quotas.iterator();
    while (it_quota.next()) |q| if (zcu.deps.contains(.{ .func = q.key_ptr.* }))
        try quota_items.append(gpa, .{ try r.addUnit(.{ .func = q.key_ptr.* }), q.value_ptr.* });
    const unit_ref_items = try gpa.alloc([2]u32, emit.unit_refs.items.len);
    defer gpa.free(unit_ref_items);
    for (emit.unit_refs.items, unit_ref_items) |ur, *it| it.* = .{
        try r.addUnit(ur.unit),
        if (ur.ref == .nav) try r.addUnit(.{ .nav_val = ur.ref.nav }) else Recorder.no_node,
    };
    // `ZAP_CACHE_CHECK`: the units analysis starts from, for
    // `checkReferences`.
    var root_items: std.ArrayList(u32) = .empty;
    defer root_items.deinit(gpa);
    if (inc.check) {
        for (zcu.comptime_decls.keys()) |c| try root_items.append(gpa, try r.addUnit(.{ .comptime_decl = c }));
        for (zcu.exports.items) |e| if (e.target == .nav) {
            try root_items.append(gpa, try r.addUnit(.{ .nav_val = e.target.nav }));
            const val = ip.getNav(e.target.nav).val;
            if (ip.keyTag(val) == .func) try root_items.append(gpa, try r.addUnit(.{ .func = val }));
        };
        for (zcu.test_functions.items) |nav| {
            try root_items.append(gpa, try r.addUnit(.{ .nav_val = nav }));
            const val = ip.getNav(nav).val;
            if (val != .none and ip.keyTag(val) == .func) try root_items.append(gpa, try r.addUnit(.{ .func = val }));
        }
    }
    const t_collect = now(io);
    try r.prepare(io);
    const t_keys = now(io);

    // The units' results, for an edit build to load, encoded on another
    // thread while this one makes the graph and looks up the store.
    var enc: results.Encoder = .{ .gpa = gpa, .zcu = zcu };
    defer enc.deinit();
    var result_words: std.ArrayList(u32) = .empty;
    defer result_words.deinit(gpa);
    const item_results = try gpa.alloc(Encoded.Ranges, r.unit_list.items.len + r.dependee_list.items.len);
    defer gpa.free(item_results);
    var encoding = io.async(encodeResults, .{ io, &r, &enc, &result_words, item_results });
    defer if (encoding.cancel(io)) |_| {} else |_| {};

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
    for (zcu.deps.keys(), zcu.deps.values(), dep_units) |unit, dependees, u| {
        const index = try r.unitNode(u);
        // Ascending indices into `dependees`.
        const conditional = zcu.conditional_deps.get(unit) orelse &.{};
        var next_conditional: usize = 0;
        for (dep_refs[n_refs..][0..dependees.len], 0..) |ref, j| {
            const is_conditional = next_conditional < conditional.len and conditional[next_conditional] == j;
            next_conditional += @intFromBool(is_conditional);
            try r.edges.append(gpa, .{ index, Recorder.edge(try r.dependeeNode(ref), is_conditional) });
        }
        n_refs += dependees.len;
    }
    for (emit.content_uses.items, use_units) |use, u| {
        const index = try r.unitNode(u);
        try r.edges.append(gpa, .{ index, Recorder.edge(r.map.get(@backingInt(use.key)).?, false) });
    }
    // Nodes for the references' units, so that every node exists before
    // the store and manifest passes.
    for (func_ref_items) |it| {
        _ = try r.unitNode(it[0]);
        _ = try r.unitNode(it[1]);
    }
    for (unit_ref_items) |it| {
        _ = try r.unitNode(it[0]);
        if (it[1] != Recorder.no_node) _ = try r.unitNode(it[1]);
    }
    for (analyze_items.items) |*it| it.* = try r.unitNode(it.*);
    for (quota_items.items) |*it| it[0] = try r.unitNode(it[0]);
    for (root_items.items) |*it| it.* = try r.unitNode(it.*);
    for (ies_items.items) |ref| _ = try r.dependeeNode(ref);
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
                    // What the atoms' records hold besides their contents:
                    // a store entry is reused only if its records are
                    // these, byte for byte.
                    var rest: Hash = 0;
                    for (n.atoms) |ai| {
                        const a = &c.atoms[ai];
                        h = h *% 31 +% contentsHash(a);
                        rest = rest *% 31 +% cache.hash(@truncate(@backingInt(a.key)), a.name);
                        if (c.debug_of[ai]) |d| {
                            h +%= cache.hash(@truncate(h), d.lines);
                            rest = rest *% 31 +% d.base_line +% cache.hash(6, d.file) +% cache.hash(7, d.name);
                            rest = rest *% 31 +% cache.hash(8, d.unit);
                            // Inline calls carry their callees' base lines,
                            // which move without the caller changing.
                            if (d.inlines.len | d.patches.len | d.files.len != 0) {
                                rest = rest *% 31 +% cache.hash(9, d.files) +% cache.hash(10, d.inline_names) +%
                                    cache.hash(11, @ptrCast(d.inlines)) +% cache.hash(12, @ptrCast(d.inline_callees)) +% cache.hash(13, @ptrCast(d.patches));
                            }
                        }
                    }
                    n.result_hash = h;
                    n.exact_hash = h ^ cache.hash(5, std.mem.asBytes(&rest));
                },
                else => n.exact_hash = n.result_hash,
            };
        }
    }{ .nodes = r.nodes.items, .atoms = emit.atoms.items, .debug_of = debug_of });
    const t1 = now(io);

    if (inc.check) inc.checkPrediction(&r, fe);

    // Store: find equal entries on every core; the others go into one new
    // pack, encoded straight into the file on other threads while this one
    // builds the manifest, so that they are never all in memory.
    var store: Store = try .open(gpa, io, inc.global);
    defer store.close(gpa, io);
    store.max_bytes = inc.max_bytes;
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
    // A linked store pack stays on disk, whole, for as long as the
    // compilation's directory does, even after the store drops it. Where
    // this build uses less of a large pack than the rest of it (the rule
    // `Pack.compact` applies to dead bytes), its entries are written again
    // into the new pack instead: a small program whose std entries landed
    // in a big unit's 555 MB pack must not pin it.
    {
        const used = try gpa.alloc(u64, store.packs.len);
        defer gpa.free(used);
        @memset(used, 0);
        for (where, r.nodes.items) |w, *n| if (w == .hit) {
            used[w.hit.pack] += putter.entryLen(n);
        };
        for (where, r.nodes.items) |*w, *n| if (w.* == .hit) {
            const size = store.packSize(w.hit.pack);
            if (size >= min_pinned_pack and used[w.hit.pack] < size / 2) w.* = .{ .put = .{ .len = putter.entryLen(n) } };
        };
    }
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
    const encoded = try encoding.await(io);
    const result_of = try gpa.alloc(Encoded.Ranges, r.nodes.items.len);
    defer gpa.free(result_of);
    @memset(result_of, .{});
    for (r.unit_info, item_results[0..r.unit_info.len]) |info, res| result_of[info.node] = res;
    for (r.dependee_info, item_results[r.unit_info.len..]) |info, res| result_of[info.node] = res;
    if (inc.check and !checkResults(gpa, zcu, &r, &enc, result_words.items, result_of, encoded.unencodable)) inc.check_failed.store(true, .monotonic);
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
    // Each node's references, sorted by node and deduplicated.
    const NodeRef = struct {
        node: u32,
        ref: Manifest.Ref,
        fn lessThan(_: void, x: @This(), y: @This()) bool {
            if (x.node != y.node) return x.node < y.node;
            if (x.ref.kind != y.ref.kind) return @backingInt(x.ref.kind) < @backingInt(y.ref.kind);
            return x.ref.value < y.ref.value;
        }
    };
    var node_refs: std.ArrayList(NodeRef) = try .initCapacity(gpa, func_ref_items.len + unit_ref_items.len + analyze_items.items.len + quota_items.items.len);
    defer node_refs.deinit(gpa);
    for (analyze_items.items) |n| node_refs.appendAssumeCapacity(.{ .node = n, .ref = .{ .kind = .analyze, .value = 0 } });
    for (quota_items.items) |q| node_refs.appendAssumeCapacity(.{ .node = q[0], .ref = .{ .kind = .quota, .value = q[1] } });
    for (func_ref_items) |it| {
        const from = try r.unitNode(it[0]);
        const to = try r.unitNode(it[1]);
        if (from != to) node_refs.appendAssumeCapacity(.{ .node = from, .ref = .{ .kind = .func, .value = to } });
    }
    for (emit.unit_refs.items, unit_ref_items) |ur, it| node_refs.appendAssumeCapacity(.{ .node = try r.unitNode(it[0]), .ref = switch (ur.ref) {
        .nav => .{ .kind = .nav, .value = try r.unitNode(it[1]) },
        .err => |name| .{ .kind = .err, .value = try ip.errorValue(name) },
        .ext => |e| .{ .kind = if (e.weak) .ext_weak else .ext, .value = try b.addRefName(e.name) },
        .rt => |key| .{ .kind = .rt, .value = try b.addRefName(key) },
        .error_names => .{ .kind = .error_names, .value = 0 },
    } });
    std.mem.sortUnstable(NodeRef, node_refs.items, {}, NodeRef.lessThan);
    var refs_of: std.ArrayList(Manifest.Ref) = .empty;
    defer refs_of.deinit(gpa);
    var next_ref: usize = 0;
    for (r.nodes.items, where, 0..) |n, w, ni| {
        refs_of.clearRetainingCapacity();
        while (next_ref < node_refs.items.len and node_refs.items[next_ref].node == ni) : (next_ref += 1) {
            const nr = node_refs.items[next_ref].ref;
            if (refs_of.items.len == 0 or !std.meta.eql(refs_of.items[refs_of.items.len - 1], nr)) try refs_of.append(gpa, nr);
        }
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
        const res = result_of[ni];
        _ = try b.addNode(.{
            .key = n.key,
            .result_hash = n.result_hash,
            .src_hash = n.src_hash,
            .tag = @backingInt(n.tag),
            .deps = n.deps,
            .atoms = refs.items,
            .symbols = symbols.items,
            .refs = refs_of.items,
            .source = n.source,
            .source_name = n.source_name,
            .result = result_words.items[res.result[0]..][0..res.result[1]],
            .subject = result_words.items[res.subject[0]..][0..res.subject[1]],
        });
    }
    if (inc.check and !checkReferences(gpa, &r, root_items.items, &b)) inc.check_failed.store(true, .monotonic);
    if (inc.verify == .full and !try inc.verifyNodes(&r, &b, emit, debug_of)) inc.check_failed.store(true, .monotonic);
    for (base_names.items) |name| _ = try b.addBasePack(name);
    b.items = enc.words.items;
    b.item_starts = enc.starts.items;
    b.entry = @backingInt(emit.entry.?);
    for (ip.error_names.items[1..]) |name| _ = try b.addErrorName(ip.stringSlice(name), @backingInt(Emit.errorKey(ip, name)));
    const t3 = now(io);
    var path_buf: std.ArrayList(u8) = .empty;
    defer path_buf.deinit(gpa);
    // Input `i` is file `i` (`Manifest.Source.input`), then the embedded
    // files.
    for (fe.files.items) |*f| {
        try inputPath(gpa, &path_buf, fe, f.module, f.sub_path);
        if (Io.Dir.cwd().statFile(io, path_buf.items, .{})) |stat|
            try b.addInput(path_buf.items, stat, @bitCast(f.content_hash), inc.build_start)
        else |_|
            try b.addUnstattedInput(path_buf.items, @bitCast(f.content_hash));
    }
    // `@embedFile`d files are inputs too. Every input's content hash is
    // `Frontend.hashSource`'s, which `relinkIfUnchanged` checks a touched
    // input against.
    for (zcu.embed_files.values()) |f| {
        try inputPath(gpa, &path_buf, fe, f.module, f.sub_path);
        const content_hash: Hash = @bitCast(Frontend.hashSource(f.bytes));
        if (Io.Dir.cwd().statFile(io, path_buf.items, .{})) |stat|
            try b.addInput(path_buf.items, stat, content_hash, inc.build_start)
        else |_|
            try b.addUnstattedInput(path_buf.items, content_hash);
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
    const report = try std.fmt.allocPrint(gpa, "cache: recorded {d} nodes, {d} atoms, {d} references, {d} inputs in {d:.2} ms alongside the link (graph {d:.2}: items {d:.2}, keys {d:.2}; store lookups {d:.2}: {d} reused, {d} put, beside results {d:.2}: {d} units, {d} not encodable, {d} items, {d} KB; manifest {d:.2} while the store writes: nodes and symbols {d:.2}, inputs {d:.2}, write {d:.2}; store's remainder {d:.2})", .{
        r.nodes.items.len,                                         emit.atoms.items.len, b.refs.items.len,      fe.files.items.len,  ms(t0, t6),
        ms(t0, t1),                                                ms(t0, t_collect),    ms(t_collect, t_keys), ms(t1, t2),          reused,
        n_put,                                                     encoded.ms,           encoded.units,         encoded.unencodable, enc.starts.items.len,
        (enc.words.items.len + result_words.items.len) * 4 / 1024, ms(t2, t5),           ms(t2, t3),            ms(t3, t4),          ms(t4, t5),
        ms(t5, t6),
    });
    return .{ .manifest = manifest, .base_names = names, .report = report };
}

const Encoded = struct {
    units: usize = 0,
    unencodable: usize = 0,
    /// Nodes whose subject could not be encoded.
    no_subject: usize = 0,
    ms: f64 = 0,

    /// Where a unit's or dependee's result and subject are in the words.
    const Ranges = struct { result: [2]u32 = .{ 0, 0 }, subject: [2]u32 = .{ 0, 0 } };
};

/// Encodes the results and subjects of `r`'s units and dependees
/// (`results.zig`) into `words`, the ranges of each in `ranges` (units
/// first, as in `unit_list` and `dependee_list`; empty for none). Reads
/// only the lists, which do not change once `prepare` ran.
fn encodeResults(io: Io, r: *const Recorder, enc: *results.Encoder, words: *std.ArrayList(u32), ranges: []Encoded.Ranges) !Encoded {
    const t0 = now(io);
    const gpa = r.gpa;
    const zcu = r.zcu;
    const ip = &zcu.ip;
    @memset(ranges, .{});
    var e: Encoded = .{};
    try enc.ids.ensureTotalCapacity(gpa, @intCast(4 * r.unit_list.items.len));
    for (r.unit_list.items, ranges[0..r.unit_list.items.len]) |unit, *range| {
        const subject: ?results.Subject = switch (unit) {
            .nav_val => |nav| .{ .nav = nav },
            .type_layout, .struct_defaults => |ty| .{ .ty = ty },
            .func => |func| .{ .func = func },
            .comptime_decl => null,
        };
        if (subject) |sj| {
            const start = words.items.len;
            if (try results.encodeSubject(enc, words, sj)) {
                range.subject = .{ @intCast(start), @intCast(words.items.len - start) };
            } else e.no_subject += 1;
        }
        const start = words.items.len;
        const ok = switch (unit) {
            .nav_val => |nav_index| blk: {
                const nav = ip.getNav(nav_index);
                if (nav.status != .resolved) continue;
                break :blk try results.encodeNav(enc, words, nav);
            },
            .type_layout => |ty| try results.encodeLayout(enc, words, ty),
            .struct_defaults => |ty| try results.encodeDefaults(enc, words, ty),
            .func, .comptime_decl => continue,
        };
        if (!ok) {
            e.unencodable += 1;
            continue;
        }
        range.result = .{ @intCast(start), @intCast(words.items.len - start) };
        e.units += 1;
    }
    for (r.dependee_list.items, ranges[r.unit_list.items.len..]) |d, *range| {
        const subject: results.Subject = switch (d) {
            .nav_val, .type_layout, .struct_defaults => unreachable, // Units.
            .nav_ty => |nav| .{ .nav = nav },
            .func_body, .func_ies => |func| .{ .func = func },
            .namespace_name => |nn| .{ .namespace_name = .{ .owner = zcu.namespacePtr(nn.namespace).owner_type, .name = ip.stringSlice(nn.name) } },
            .namespace => |ns| .{ .namespace = zcu.namespacePtr(ns).owner_type },
            .embed_file => |i| .{ .embed_file = zcu.embed_files.values()[i].key },
        };
        const sj_start = words.items.len;
        if (try results.encodeSubject(enc, words, subject)) {
            range.subject = .{ @intCast(sj_start), @intCast(words.items.len - sj_start) };
        } else e.no_subject += 1;
        if (d == .func_ies) {
            const start = words.items.len;
            try results.encodeIes(gpa, zcu, words, d.func_ies);
            range.result = .{ @intCast(start), @intCast(words.items.len - start) };
            e.units += 1;
        }
    }
    e.ms = ms(t0, now(io));
    return e;
}

/// The local cache's size limit and trimming (`Store.commit` maintains the
/// store). Best effort.
fn maintainLocal(inc: *const Incremental) void {
    // A new compilation directory is how the local cache grows.
    const t0 = now(inc.io);
    const r = cache.maintainCompilations(inc.gpa, inc.io, inc.local, inc.max_bytes, inc.prev == null) catch null;
    if (inc.timing) if (r) |m| std.debug.print("cache: local cache {d} directories, {d} MiB; deleted {d}, leaving {d} MiB, in {d:.2} ms beside the link\n", .{ m.scanned, m.bytes >> 20, m.deleted, m.bytes_after >> 20, ms(t0, now(inc.io)) });
}

/// Store packs at least this large are linked only if a build uses at
/// least half of one.
const min_pinned_pack = 8 << 20;

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
                const len = p.entryLen(n);
                if (try p.store.get(p.inc.gpa, p.inc.io, storeKey(p.inc.store_seed, n.key, n.src_hash))) |e| {
                    if (e.resultHash() == n.exact_hash and e.atomCount() == n.atoms.len and e.deps().len == n.deps.len and
                        e.atomsBytes() == len - Store.atomsOffset(n.deps.len))
                    {
                        w.* = .{ .hit = .{ .pack = e.pack, .offset = e.offset } };
                        continue;
                    }
                }
                w.* = .{ .put = .{ .len = len } };
            }
        }
    };

    /// Writes the entries `where` puts, laid out as `entries` up to `end`,
    /// into the pack `Store.reserveName` named, if `any`, and commits it.
    /// Then, while `record` writes the manifest, applies the local cache's
    /// size limit, so that it counts the new pack; and also when writing
    /// it fails, on a full disk say.
    fn writePack(p: Putter, io: Io, entries: []const Store.IndexEntry, end: u64, any: bool) !?Store.PackName {
        defer p.inc.maintainLocal();
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
                for (n.deps) |e| {
                    const d = Manifest.Edge.nodeOf(e);
                    try deps.append(gpa, .{ .key = p.nodes[d].key, .result_hash = p.nodes[d].result_hash });
                }
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
/// The path an input is recorded under: absolute, if the module's root is.
pub fn inputPath(gpa: Allocator, buf: *std.ArrayList(u8), fe: *const Frontend, module: Frontend.Module.Index, sub_path: []const u8) !void {
    const mod = fe.module(module);
    buf.clearRetainingCapacity();
    try buf.print(gpa, "{s}{c}{s}", .{ mod.abs_root_dir orelse mod.root_dir, std.fs.path.sep, sub_path });
}

fn checkPrediction(inc: *Incremental, r: *const Recorder, fe: *const Frontend) void {
    inc.checkPredictionFallible(r, fe) catch |err| {
        std.debug.print("cache check: could not check the prediction: {t}\n", .{err});
        inc.check_failed.store(true, .monotonic);
    };
}

/// `ZAP_CACHE_CHECK`: computes the seeds from the changed inputs' ZIR, as
/// an edit build will (`seeds.zig`), and checks that every node whose
/// result this build changed is reachable from them over the last
/// manifest's reverse edges.
fn checkPredictionFallible(inc: *Incremental, r: *const Recorder, fe: *const Frontend) !void {
    const gpa = inc.gpa;
    const io = inc.io;
    const nodes = r.nodes.items;
    const m = if (inc.prev) |*m| m else return;
    const n_prev = m.nodeCount();

    // The inputs whose contents changed, by path.
    var now_inputs: std.StringHashMapUnmanaged(struct { file: ?Frontend.File.Index, hash: Hash }) = .empty;
    defer {
        var it = now_inputs.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        now_inputs.deinit(gpa);
    }
    var path_buf: std.ArrayList(u8) = .empty;
    defer path_buf.deinit(gpa);
    for (fe.files.items, 0..) |*f, i| {
        try inputPath(gpa, &path_buf, fe, f.module, f.sub_path);
        const gop = try now_inputs.getOrPut(gpa, path_buf.items);
        if (!gop.found_existing) gop.key_ptr.* = try gpa.dupe(u8, path_buf.items);
        gop.value_ptr.* = .{ .file = @fromBackingInt(@as(u32, @intCast(i))), .hash = @bitCast(f.content_hash) };
    }
    for (r.zcu.embed_files.values()) |f| {
        try inputPath(gpa, &path_buf, fe, f.module, f.sub_path);
        const gop = try now_inputs.getOrPut(gpa, path_buf.items);
        if (!gop.found_existing) gop.key_ptr.* = try gpa.dupe(u8, path_buf.items);
        gop.value_ptr.* = .{ .file = null, .hash = @bitCast(Frontend.hashSource(f.bytes)) };
    }
    var changed: std.ArrayList(seeds.Changed) = .empty;
    defer changed.deinit(gpa);
    for (0..m.inputCount()) |j| {
        const in, const path = m.input(@intCast(j));
        // An input no longer read has no nodes in this build.
        const now_in = now_inputs.get(path) orelse continue;
        if (now_in.hash != in.content_hash) try changed.append(gpa, .{ .input = @intCast(j), .file = now_in.file });
    }
    var seed_list: std.ArrayList(u32) = .empty;
    defer seed_list.deinit(gpa);
    const t0 = now(io);
    const stats = try seeds.compute(gpa, m, fe, changed.items, &seed_list, null);
    const seeds_ms = ms(t0, now(io));

    var seen = try std.DynamicBitSetUnmanaged.initEmpty(gpa, n_prev);
    defer seen.deinit(gpa);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);
    for (seed_list.items) |i| {
        seen.set(i);
        try stack.append(gpa, i);
    }
    var added: usize = 0;
    for (nodes) |n| {
        if (m.find(n.key) == null) added += 1;
    }
    while (stack.pop()) |i| for (m.rdeps(i)) |part| for (part) |d| if (!seen.isSet(d)) {
        seen.set(d);
        try stack.append(gpa, d);
    };
    var n_changed: usize = 0;
    var missed: usize = 0;
    for (nodes) |n| {
        const i = m.find(n.key) orelse continue;
        if (m.node(i).result_hash == n.result_hash) continue;
        n_changed += 1;
        if (seen.isSet(i)) continue;
        missed += 1;
        if (missed > 10) continue;
        // Name it by its unit, if it is one.
        var name: std.Io.Writer.Allocating = .init(gpa);
        defer name.deinit();
        for (r.unit_list.items, r.unit_info) |u, info| if (info.key == n.key) {
            r.zcu.unitKey(u, &name.writer) catch {};
            break;
        };
        std.debug.print("cache check: {t} node {x} ({s}) changed its result but no changed source reaches it; it depended on:\n", .{ n.tag, n.key, name.written() });
        for (m.deps(i)) |e| {
            const dn = m.node(Manifest.Edge.nodeOf(e));
            name.clearRetainingCapacity();
            for (r.unit_list.items, r.unit_info) |u, info| if (info.key == dn.key) {
                r.zcu.unitKey(u, &name.writer) catch {};
                break;
            };
            std.debug.print("cache check:   {t} {x} {s}\n", .{ @as(Tag, @fromBackingInt(@intCast(dn.tag))), dn.key, name.written() });
        }
    }
    if (missed != 0) inc.check_failed.store(true, .monotonic);
    std.debug.print("cache check: {d} nodes ({d} new); {d} inputs changed ({d} without their old ZIR); {d} seeds from ZIR in {d:.2} ms reach {d}; {d} results changed, {d} missed\n", .{
        nodes.len, added, changed.items.len, stats.without_old_zir, seed_list.items.len, seeds_ms, seen.count(), n_changed, missed,
    });
}

/// `ZAP_CACHE_CHECK`: checks that the recorded graph reaches every function
/// this build analyzed, from the units analysis starts from, over
/// dependencies and references. A build that loads units from the cache
/// queues functions only along references, so a function this misses
/// would drop out of an edit build.
fn checkReferences(gpa: Allocator, r: *const Recorder, roots: []const u32, b: *const Manifest.Builder) bool {
    const nodes = r.nodes.items;
    var seen = std.DynamicBitSetUnmanaged.initEmpty(gpa, nodes.len) catch return true;
    defer seen.deinit(gpa);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);
    var k: Keyer = .{ .zcu = r.zcu, .key_buf = .init(gpa), .unit_buf = .init(gpa) };
    defer k.key_buf.deinit();
    defer k.unit_buf.deinit();
    for (roots) |n| if (!seen.isSet(n)) {
        seen.set(n);
        stack.append(gpa, n) catch return true;
    };
    while (stack.pop()) |n| {
        const range = b.ref_ranges.items[n];
        var next: std.ArrayList(u32) = .empty;
        defer next.deinit(gpa);
        // A function is reached only by a reference, or by resolving its
        // inferred error set, which analyzes and emits its body: the
        // `func_ies` dependee's edge to it. A green unit loaded from the
        // cache reaches it the same way, through `ensureFuncIes`.
        for (nodes[n].deps) |e| {
            const d = Manifest.Edge.nodeOf(e);
            if (nodes[d].tag != .func or nodes[n].tag == .func_ies) next.append(gpa, d) catch return true;
        }
        for (b.refs.items[range[0]..][0..range[1]]) |ref| switch (ref.kind) {
            .func, .nav => next.append(gpa, ref.value) catch return true,
            .rt => {
                const name = b.strings.items[b.ref_names.items[ref.value].off..][0..b.ref_names.items[ref.value].len];
                const key = k.keyOf(.func, &.{name}) catch return true;
                if (r.map.get(key)) |f| next.append(gpa, f) catch return true;
            },
            else => {},
        };
        for (next.items) |d| if (!seen.isSet(d)) {
            seen.set(d);
            stack.append(gpa, d) catch return true;
        };
    }
    var funcs: usize = 0;
    var missed: usize = 0;
    for (nodes, 0..) |n, i| {
        if (n.tag != .func) continue;
        funcs += 1;
        if (seen.isSet(i)) continue;
        missed += 1;
        if (missed > 10) continue;
        var name: std.Io.Writer.Allocating = .init(gpa);
        defer name.deinit();
        for (r.unit_list.items, r.unit_info) |u, info| if (info.key == n.key) {
            r.zcu.unitKey(u, &name.writer) catch {};
            break;
        };
        std.debug.print("cache check: function {s} is not reached by references\n", .{name.written()});
    }
    std.debug.print("cache check: references reach {d} of {d} functions\n", .{ funcs - missed, funcs });
    return missed == 0;
}

/// `ZAP_CACHE_CHECK`: decodes every encoded result from its words alone,
/// rebuilding each item from its key rather than finding it by hash, and
/// checks that it is this build's result: the same InternPool indices, and
/// the same scalars. That is what an edit build relies on when it loads a
/// green unit. The decoder only finds container types, functions, and
/// declarations here (`results.Lookup`); creating them is replay's.
fn checkResults(gpa: Allocator, zcu: *Zcu, r: *const Recorder, enc: *const results.Encoder, words: []const u32, result_of: []const Encoded.Ranges, unencodable: usize) bool {
    const ip = &zcu.ip;
    var d = results.Decoder(results.Lookup).init(gpa, ip, enc.words.items, enc.starts.items, .{ .zcu = zcu }) catch return false;
    defer d.deinit();
    d.rebuild = true;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var checked: usize = 0;
    var mismatched: usize = 0;
    const Check = struct {
        fn report(z: *Zcu, dec: anytype, unit: anytype, what: []const u8) void {
            var name: std.Io.Writer.Allocating = .init(z.gpa);
            defer name.deinit();
            z.unitKey(unit, &name.writer) catch {};
            std.debug.print("cache check: the result of {t} {s} does not round-trip: {s}", .{ unit, name.written(), what });
            if (dec.miss.reason != .none) std.debug.print(" (item {d}, {t}: {t})", .{ dec.miss.id, dec.miss.tag, dec.miss.reason });
            std.debug.print("\n", .{});
        }
    };
    var subjects: usize = 0;
    for (r.unit_list.items, r.unit_info) |unit, info| {
        const res = result_of[info.node].result;
        const sj = result_of[info.node].subject;
        if (sj[1] != 0) {
            subjects += 1;
            d.miss = .{};
            const want: ?results.Subject = switch (unit) {
                .nav_val => |nav| .{ .nav = nav },
                .type_layout, .struct_defaults => |ty| .{ .ty = ty },
                .func => |func| .{ .func = func },
                .comptime_decl => null,
            };
            const got = results.decodeSubject(&d, words[sj[0]..][0..sj[1]]) catch null;
            if (got == null or !subjectEql(got.?, want.?)) {
                mismatched += 1;
                if (mismatched <= 10) Check.report(zcu, &d, unit, "its subject differs");
            }
        }
        if (res[1] == 0) continue;
        _ = arena_state.reset(.retain_capacity);
        const arena = arena_state.allocator();
        const w = words[res[0]..][0..res[1]];
        checked += 1;
        d.miss = .{};
        const ok, const what: []const u8 = switch (unit) {
            .nav_val => |nav_index| blk: {
                const nav = ip.getNav(nav_index);
                const got = (results.decodeNav(&d, w) catch null) orelse break :blk .{ false, "unresolved" };
                break :blk .{ got.ty == nav.ty and got.val == nav.val and got.is_const == nav.is_const and
                    got.is_threadlocal == nav.is_threadlocal and got.linkage == nav.linkage and got.alignment == nav.alignment, "different" };
            },
            .type_layout => |ty| blk: {
                const info_live = ip.structInfo(ty);
                const got = (results.decodeLayout(&d, arena, w) catch null) orelse break :blk .{ false, "unresolved" };
                const is_struct = ip.keyTag(ty) == .struct_type;
                var same = got.status == info_live.status and got.layout == info_live.layout and
                    got.nonexhaustive == info_live.nonexhaustive and got.has_runtime_tag == info_live.has_runtime_tag and
                    got.comptime_only == info_live.comptime_only and got.size == info_live.size and
                    got.alignment == info_live.alignment and got.tag_type == info_live.tag_type and
                    std.mem.eql(InternPool.String, got.field_names, info_live.field_names) and
                    std.mem.eql(InternPool.Index, got.field_types, info_live.field_types) and
                    std.mem.eql(u64, got.field_offsets, info_live.field_offsets) and
                    std.mem.eql(bool, got.field_is_comptime, info_live.field_is_comptime) and
                    std.mem.eql(u64, got.field_aligns, info_live.field_aligns) and
                    got.field_defaults.len == info_live.field_defaults.len;
                if (same) for (got.field_defaults, info_live.field_defaults, 0..) |g, l, i| {
                    if (g != (if (!is_struct or info_live.fieldIsComptime(i)) l else .none)) same = false;
                };
                break :blk .{ same, "different" };
            },
            .struct_defaults => |ty| blk: {
                const info_live = ip.structInfo(ty);
                const got = (results.decodeDefaults(&d, arena, w) catch null) orelse break :blk .{ false, "unresolved" };
                var same = got.resolved == (info_live.defaults_status == .resolved) and got.defaults.len == info_live.field_defaults.len;
                if (same) for (got.defaults, info_live.field_defaults, 0..) |g, l, i| {
                    if (g != (if (info_live.fieldIsComptime(i)) .none else l)) same = false;
                };
                break :blk .{ same, "different" };
            },
            .func, .comptime_decl => unreachable,
        };
        if (ok) continue;
        mismatched += 1;
        if (mismatched <= 10) Check.report(zcu, &d, unit, what);
    }
    for (r.dependee_list.items, r.dependee_info) |dep, info| {
        const sj = result_of[info.node].subject;
        if (sj[1] == 0) continue;
        subjects += 1;
        d.miss = .{};
        const want: results.Subject = switch (dep) {
            .nav_val, .type_layout, .struct_defaults => unreachable,
            .nav_ty => |nav| .{ .nav = nav },
            .func_body, .func_ies => |func| .{ .func = func },
            .namespace_name => |nn| .{ .namespace_name = .{ .owner = zcu.namespacePtr(nn.namespace).owner_type, .name = ip.stringSlice(nn.name) } },
            .namespace => |ns| .{ .namespace = zcu.namespacePtr(ns).owner_type },
            .embed_file => |i| .{ .embed_file = zcu.embed_files.values()[i].key },
        };
        const got = results.decodeSubject(&d, words[sj[0]..][0..sj[1]]) catch null;
        if (got != null and subjectEql(got.?, want)) continue;
        mismatched += 1;
        if (mismatched <= 10) std.debug.print("cache check: the subject of a {t} dependee does not round-trip\n", .{dep});
    }
    for (r.dependee_list.items, r.dependee_info) |dep, info| switch (dep) {
        .func_ies => |func| {
            _ = arena_state.reset(.retain_capacity);
            const res = result_of[info.node].result;
            const got = results.decodeIes(ip, arena_state.allocator(), words[res[0]..][0..res[1]]) catch return false;
            checked += 1;
            const names = zcu.inferred_errors.get(func) orelse &.{};
            if (got.is_anyerror == zcu.anyerror_ies.contains(func) and std.mem.eql(InternPool.String, got.names, names)) continue;
            mismatched += 1;
            if (mismatched <= 10) Check.report(zcu, &d, Zcu.AnalUnit{ .func = func }, "different inferred errors");
        },
        else => {},
    };
    const f = enc.fallbacks;
    std.debug.print("cache check: {d} results and {d} subjects round-trip through {d} items, {d} did not; {d} not encodable ({d} comptime pointers, {d} cycles, {d} too deep)\n", .{
        checked, subjects, enc.starts.items.len, mismatched, unencodable, f.comptime_alloc, f.cycle, f.too_deep,
    });
    return mismatched == 0;
}

fn subjectEql(a: results.Subject, b: results.Subject) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .nav => |n| n == b.nav,
        .ty => |t| t == b.ty,
        .func => |f| f == b.func,
        .namespace => |t| t == b.namespace,
        .namespace_name => |nn| nn.owner == b.namespace_name.owner and std.mem.eql(u8, nn.name, b.namespace_name.name),
        .embed_file => |k| std.mem.eql(u8, k, b.embed_file),
    };
}

/// Everything the linker emits for an atom but its name and key, like
/// `Atom.SymbolKey.fromContents`, with a faster hash: results need not be
/// symbol keys.
/// Whether loading `use.unit` in an edit build makes `use.ty`, and with it
/// its namespace's effects: if `ty` is its value, or the subject of one of
/// its plain dependencies, which an edit build brings up to date.
fn loadMakes(zcu: *Zcu, use: Zcu.EffectUse) bool {
    const ip = &zcu.ip;
    if (use.unit == .nav_val and ip.getNav(use.unit.nav_val).val == use.ty) return true;
    const deps = zcu.deps.get(use.unit) orelse return false;
    const conditional = zcu.conditional_deps.get(use.unit) orelse &.{};
    const ns = ip.structInfo(use.ty).namespace;
    for (deps, 0..) |d, i| {
        if (std.mem.indexOfScalar(u32, conditional, @intCast(i)) != null) continue;
        switch (d) {
            .type_layout, .struct_defaults => |ty| if (ty == use.ty) return true,
            .namespace => |n| if (n == ns) return true,
            .namespace_name => |nn| if (nn.namespace == ns) return true,
            else => {},
        }
    }
    return false;
}

/// `ZAP_CACHE_VERIFY=full`: whether this full build's nodes are those of
/// the edit build that wrote `prev`: the same nodes with the same results,
/// source hashes, dependencies, references and atom records. (Not the
/// output's bytes: the link lays atoms out in analysis order, which an
/// edit build changes.) Prints the differences.
fn verifyNodes(inc: *Incremental, r: *const Recorder, b: *const Manifest.Builder, emit: *const Emit, debug_of: []const ?*const Atom.Debug) !bool {
    const gpa = inc.gpa;
    const m = if (inc.prev) |*m| m else return true;
    var pack: Pack = try .open(inc.io, inc.dir);
    defer pack.close(gpa, inc.io);
    for (0..m.bases.len) |i| _ = try pack.addBase(gpa, inc.io, inc.dir, m.basePack(i));
    var seen = try std.DynamicBitSetUnmanaged.initEmpty(gpa, m.nodeCount());
    defer seen.deinit(gpa);
    var differ: usize = 0;
    var mine: std.ArrayList([2]Hash) = .empty;
    defer mine.deinit(gpa);
    var theirs: std.ArrayList([2]Hash) = .empty;
    defer theirs.deinit(gpa);
    var buf: std.array_list.Aligned(u8, .@"16") = .empty;
    defer buf.deinit(gpa);
    const V = struct {
        fn report(rec: *const Recorder, ni: usize, n: *const Node, what: []const u8, count: *usize) void {
            count.* += 1;
            if (count.* > 20) return;
            var name: std.Io.Writer.Allocating = .init(rec.gpa);
            defer name.deinit();
            nodeName(rec, ni, &name.writer);
            std.debug.print("cache verify: {t} node {x} {s}: {s}\n", .{ n.tag, n.key, name.written(), what });
        }
        /// The unit or dependee behind node `ni`, for messages.
        fn nodeName(rec: *const Recorder, ni: usize, w: *std.Io.Writer) void {
            const z = rec.zcu;
            for (rec.unit_list.items, rec.unit_info) |unit, info| if (info.node == ni) {
                z.unitKey(unit, w) catch {};
                return;
            };
            for (rec.dependee_list.items, rec.dependee_info) |d, info| if (info.node == ni) {
                switch (d) {
                    .nav_ty => |nav| w.writeAll(z.ip.stringSlice(z.ip.getNav(nav).key)) catch {},
                    .func_body, .func_ies => |f| z.unitKey(.{ .func = f }, w) catch {},
                    .namespace_name => |nn| w.print("{s} {s}", .{ z.namespacePtr(nn.namespace).key, z.ip.stringSlice(nn.name) }) catch {},
                    .namespace => |ns| w.writeAll(z.namespacePtr(ns).key) catch {},
                    .embed_file => |i| w.writeAll(z.embed_files.values()[i].key) catch {},
                    .nav_val, .type_layout, .struct_defaults => {},
                }
                return;
            };
        }
        fn refKey(bb: *const Manifest.Builder, rec: *const Recorder, ref: Manifest.Ref) [2]Hash {
            return .{ @backingInt(ref.kind), switch (ref.kind) {
                .func, .nav => rec.nodes.items[ref.value].key,
                .ext, .ext_weak, .rt => cache.hash(0, bb.strings.items[bb.ref_names.items[ref.value].off..][0..bb.ref_names.items[ref.value].len]),
                .err, .error_names, .analyze, .quota => ref.value,
            } };
        }
        fn prevRefKey(mm: *const Manifest, ref: Manifest.Ref) [2]Hash {
            return .{ @backingInt(ref.kind), switch (ref.kind) {
                .func, .nav => mm.node(ref.value).key,
                .ext, .ext_weak, .rt => cache.hash(0, mm.refName(ref.value)),
                .err, .error_names, .analyze, .quota => ref.value,
            } };
        }
        fn lessThan(_: void, x: [2]Hash, y: [2]Hash) bool {
            return if (x[0] != y[0]) x[0] < y[0] else x[1] < y[1];
        }
        /// Whether every key of `x` is in `y`, both key-sorted lists of
        /// (key, node).
        fn subset(x: []const [2]Hash, y: []const [2]Hash) bool {
            var j: usize = 0;
            for (x) |p| {
                while (j < y.len and y[j][0] < p[0]) j += 1;
                if (j == y.len or y[j][0] != p[0]) return false;
            }
            return true;
        }
        /// Whether a node of kind `tag` exists only for its dependents'
        /// edges, which the edge check covers.
        fn isDependee(tag: u8) bool {
            const t = std.enums.fromInt(Tag, tag) orelse return false;
            return switch (t) {
                .nav_ty, .func_body, .func_ies, .namespace_name, .namespace, .embed_file => true,
                else => false,
            };
        }
        /// The full build's dependencies the edit build lacks.
        fn printDiff(rec: *const Recorder, x: []const [2]Hash, y: []const [2]Hash) void {
            var j: usize = 0;
            for (x) |p| {
                while (j < y.len and y[j][0] < p[0]) j += 1;
                if (j < y.len and y[j][0] == p[0]) continue;
                var name: std.Io.Writer.Allocating = .init(rec.gpa);
                defer name.deinit();
                nodeName(rec, @intCast(p[1]), &name.writer);
                std.debug.print("cache verify:   the edit build lacks its dependency on {t} {s}\n", .{ rec.nodes.items[@intCast(p[1])].tag, name.written() });
            }
        }
    };
    for (r.nodes.items, 0..) |*n, ni| {
        const pi = m.find(n.key) orelse {
            if (!V.isDependee(@backingInt(n.tag))) V.report(r, ni, n, "only in the full build", &differ);
            continue;
        };
        seen.set(pi);
        const pn = m.node(pi);
        if (pn.tag != @backingInt(n.tag)) V.report(r, ni, n, "different kind", &differ);
        if (pn.src_hash != n.src_hash) V.report(r, ni, n, "different source hash", &differ);
        if (pn.result_hash != n.result_hash) V.report(r, ni, n, "different result", &differ);
        mine.clearRetainingCapacity();
        theirs.clearRetainingCapacity();
        // Every edge the full build resolved itself, of either kind in the
        // edit build: which reads are conditional, and which conditional
        // edges exist, depends on when lowering for the comptime evaluator
        // happened, which call counts decide, and green units make no calls
        // (see "Edge kinds"). An extra edge only invalidates more.
        for (n.deps) |e| {
            const edge: Manifest.Edge = @bitCast(e);
            if (edge.kind == .plain) try mine.append(gpa, .{ r.nodes.items[edge.node].key, edge.node });
        }
        for (m.deps(pi)) |e| {
            const edge: Manifest.Edge = @bitCast(e);
            try theirs.append(gpa, .{ m.node(edge.node).key, edge.node });
        }
        std.mem.sortUnstable([2]Hash, mine.items, {}, V.lessThan);
        std.mem.sortUnstable([2]Hash, theirs.items, {}, V.lessThan);
        if (!V.subset(mine.items, theirs.items)) {
            V.report(r, ni, n, "missing dependencies", &differ);
            if (differ <= 20) V.printDiff(r, mine.items, theirs.items);
        }
        mine.clearRetainingCapacity();
        theirs.clearRetainingCapacity();
        const range = b.ref_ranges.items[ni];
        // Not `quota`: which caller instantiates a generic function first,
        // and so its quota, depends on analysis order, as upstream's.
        for (b.refs.items[range[0]..][0..range[1]]) |ref| if (ref.kind != .quota) try mine.append(gpa, V.refKey(b, r, ref));
        for (m.nodeRefs(pi)) |ref| if (ref.kind != .quota) try theirs.append(gpa, V.prevRefKey(m, ref));
        std.mem.sortUnstable([2]Hash, mine.items, {}, V.lessThan);
        std.mem.sortUnstable([2]Hash, theirs.items, {}, V.lessThan);
        if (!std.mem.eql([2]Hash, mine.items, theirs.items)) {
            V.report(r, ni, n, "different references", &differ);
            if (differ <= 20) std.debug.print("cache verify:   full build {any}\ncache verify:   edit build {any}\n", .{ mine.items, theirs.items });
        }
        const prev_atoms = m.atoms(pi);
        if (prev_atoms.len != n.atoms.len) {
            V.report(r, ni, n, "different atoms", &differ);
            continue;
        }
        for (n.atoms, prev_atoms) |ai, ref| {
            const a = &emit.atoms.items[ai];
            try buf.resize(gpa, atoms_codec.encodedLen(a, debug_of[ai]));
            atoms_codec.encode(a, debug_of[ai], buf.items);
            const old = pack.record(ref) catch {
                V.report(r, ni, n, "unreadable atom", &differ);
                break;
            };
            if (!std.mem.eql(u8, old, buf.items)) {
                V.report(r, ni, n, "different atom record", &differ);
                break;
            }
        }
    }
    var it = seen.iterator(.{ .kind = .unset });
    while (it.next()) |pi| {
        const pn = m.node(@intCast(pi));
        if (V.isDependee(pn.tag)) continue;
        differ += 1;
        if (differ <= 20) std.debug.print("cache verify: node {x} (kind {d}): only in the edit build\n", .{ pn.key, pn.tag });
    }
    std.debug.print("cache verify: {d} nodes compared with the edit build's, {d} differ\n", .{ r.nodes.items.len, differ });
    return differ == 0;
}

fn contentsHash(a: *const Atom) Hash {
    const unwind = @as(u64, @backingInt(a.unwind.kind)) << 32 | @as(u64, a.unwind.saved) << 16 | a.unwind.stack_size;
    var h = cache.hash(unwind << 16 | @as(u64, @backingInt(a.section)) << 8 | @backingInt(a.alignment), a.bytes);
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
