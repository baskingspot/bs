//! Connects a compilation to the on-disk cache (`cache.zig`, "The on-disk
//! cache" in docs/slop/architecture.md).
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
const ElfObject = @import("link/ElfObject.zig");
const ElfDynamic = @import("link/ElfDynamic.zig");
const Glibc = @import("link/Glibc.zig");
const Archive = @import("link/Archive.zig");
const ElfMerge = @import("link/ElfMerge.zig");
const ElfInput = @import("link/ElfInput.zig");
const ElfShared = @import("link/ElfShared.zig");
const Replay = @import("Replay.zig");

const Incremental = @This();

gpa: Allocator,
io: Io,
/// `<global cache>`, for the store.
global: Io.Dir,
/// `<local cache>`, whose compilation directories `record` trims.
local: Io.Dir,
/// The size limit of the store and of the local cache's compilation
/// directories (`BS_CACHE_MAX_SIZE`).
max_bytes: u64 = cache.default_max_bytes,
/// Whether the local cache is the global one (`bs run`, a build outside
/// a project): its compilation directories then share the global cache's
/// limit with the store (`cache.globalShares`).
local_is_global: bool = false,
/// The compilation's directory, locked by `lock` until `close`.
dir: Io.Dir,
lock: Io.File,
/// Identifies the compiler and target: part of every store key, so store
/// entries are shared by every project built by the same bs for the same
/// target.
store_seed: Hash,
/// The target's architecture, whose unwind records cached atoms must have.
arch: Atom.Unwind.Arch,
/// Taken before the inputs are read; inputs modified after it are
/// recorded as needing a rehash.
build_start: Io.Timestamp,
/// The last successful build's manifest, if any; for a first build, the
/// donor's (`useDonor`).
prev: ?Manifest = null,
/// What a donor's compilation must share with this one besides inputs
/// (`donorKey`).
donor_key: Hash,
/// `BS_CACHE_DONOR=off` turns off publishing and using donors.
donors: bool = true,
/// The name of the donor `prev` is, if it is one.
donor: ?[donor_name_len]u8 = null,
/// The program's part of its donors' names (`donorTag`), set by
/// `useDonor` and `startRecord`.
donor_tag: [16]u8 = @splat('0'),
/// What `donorTag` takes from the command: the subcommand and `--name`.
donor_tag_seed: u64,
/// `BS_CACHE_TIMING`: print where the cache's time goes.
timing: bool,
/// `BS_CACHE_CHECK`: check that the last manifest's reverse edges predict
/// every result this build changed, and that the recorded references
/// reach every function. A gap fails the build (`finishRecord`).
check: bool = false,
check_failed: std.atomic.Value(bool) = .init(false),
/// `--stack`, for a relink; part of the command line that keys the
/// compilation.
stack_size: u64 = 16 * 1024 * 1024,
/// What the build links, from the command (part of the compilation's key),
/// and the stem of a library's object's name in its archive (its root
/// source file's).
output: Manifest.Output = .exe,
archive_stem: []const u8 = "",
/// An executable that links glibc (`-lc`): its glibc version (in the
/// compilation's key, `Job.compile_args`) and zig lib directory, from
/// whose abilists a relink rebuilds the dynamic tables for the manifest's
/// imports (`Glibc.dynamicOptions`), and the symbols the build already
/// loaded, if it ran CodeGen.
glibc_version: ?std.SemanticVersion = null,
glibc_lib_dir: []const u8 = "",
glibc: ?*const Glibc = null,
/// An executable's object and archive inputs, absolute, in command-line
/// order: link-only inputs of the manifest (`link_input_prefix`), which
/// no node depends on. Their atoms are not recorded: a relink converts
/// them again (`linkWithInputs`), and a build after one changed replays
/// eagerly (`linkInputsChanged`), so that `Emit.finish` binds the externs
/// again.
link_objects: []const []const u8 = &.{},
/// Some of `link_objects` are still being made (a C source's record
/// missed, and upstream's Clang is compiling it), so they may differ from
/// the manifest's: the build replays eagerly, as after an edited object.
link_objects_pending: bool = false,
/// Such an executable's shared library inputs, absolute, in command-line
/// order: link-only inputs after `link_objects`. A relink parses them
/// again for the dynamic tables (`loadShared`), and a build after one
/// changed replays eagerly, as after a changed object: `Emit.finish` then
/// binds the externs again, and an import no library defines any more is
/// an error.
link_shared: []const []const u8 = &.{},
/// The parsed `link_shared`, if the build parsed them (main.zig does in
/// every build, for CodeGen's `exportTarget`).
shared: ?[]const ElfShared = null,
/// Such an executable's DT_RUNPATH (`Options.runpath` in main.zig).
runpath: ?[]const u8 = null,
/// Whether a build that does not relink renews the output's mtime, as a
/// relink would: `bs run`'s programs are trimmed by it.
renew_output: bool = false,
/// `BS_CACHE_VERIFY`: `replay` checks an edit build that loaded units
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
/// command line after `bs`) describes, run from the current directory.
/// `zig_lib_dir` is the std that compilation uses; `root_name` is
/// `Frontend.Options.root_name`; `tests_std` is whether it tests the std
/// module itself (`Frontend.testsStd`).
pub fn open(gpa: Allocator, io: Io, dirs: Frontend.CacheDirs, args: []const []const u8, zig_lib_dir: []const u8, root_name: []const u8, tests_std: bool, target: []const u8, timing: bool) !Incremental {
    const build_start = Io.Clock.real.now(io);
    const store_seed, const key = try compilationKey(gpa, io, args, zig_lib_dir, target);

    const local = try Io.Dir.cwd().createDirPathOpen(io, dirs.local, .{});
    errdefer local.close(io);
    const dir = try cache.compilationDir(io, local, key);
    errdefer dir.close(io);
    const lock = try cache.lock(io, dir);
    errdefer lock.close(io);
    const global = try Io.Dir.cwd().createDirPathOpen(io, dirs.global, .{});
    const local_is_global = sameDir(io, local, global);
    var inc: Incremental = .{
        .gpa = gpa,
        .io = io,
        .global = global,
        .local = local,
        .dir = dir,
        .lock = lock,
        .store_seed = store_seed,
        .donor_key = try donorKey(gpa, io, store_seed, zig_lib_dir, root_name, tests_std, args),
        .donor_tag_seed = donorTagSeed(args),
        .arch = if (std.mem.startsWith(u8, target, "aarch64")) .aarch64 else .x86_64,
        .build_start = build_start,
        .timing = timing,
        .local_is_global = local_is_global,
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
    // The compiler's identity: a rebuilt bs must not reuse what an older
    // one cached. The ctime too, which only the kernel sets: a different
    // bs copied over this file in place, keeping its inode, with the same
    // size and its mtime restored (`cp` then `touch -d`, `rsync
    // --inplace -t`), matches on the other three.
    const exe = try std.process.openExecutable(io, .{});
    const exe_stat = exe.stat(io);
    exe.close(io);
    const st = try exe_stat;
    var id: std.ArrayList(u8) = .empty;
    defer id.deinit(gpa);
    try id.print(gpa, "bs\x00{d}\x00{d}\x00{d}\x00{d}\x00{s}\x00", .{ st.inode, st.size, st.mtime.toNanoseconds(), st.ctime.toNanoseconds(), target });
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

/// `outputDigest`, then the digest of the compilation's second output
/// directory, which a `zig build --watch` session alternates with the
/// first (`serve` in main.zig): both belong to the compilation.
pub fn outputDigests(key: Hash) [2][16]u8 {
    return .{ outputDigest(key), @bitCast(cache.hash(0x7a61702d6f7577, std.mem.asBytes(&key))) };
}

pub fn close(inc: *Incremental) void {
    if (inc.recording) |*f| {
        var r = f.cancel(inc.io) catch null;
        if (r) |*rec| rec.discard(inc);
    }
    inc.maintainGlobal();
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
    if (inc.link_objects_pending) return inc.noRelink("C objects are compiling", .{});
    // Set by a first attempt that builds again (`LazyFallback`,
    // `NamesRerun`): the donor's output is another compilation's.
    if (inc.donor != null) return inc.noRelink("the manifest is a donor's", .{});
    if (inc.verify == .full) return inc.noRelink("verifying an edit build", .{});
    if (m.output != inc.output) return inc.noRelink("the manifest links another kind of output", .{});
    if (m.entry == 0 and inc.output == .exe) return inc.noRelink("no entry point", .{});
    // The same link inputs, in order: a C source's object can move.
    {
        const n_link = inc.link_objects.len + inc.link_shared.len;
        var n: usize = 0;
        for (0..m.inputCount()) |i| {
            const key = m.inputKey(@intCast(i));
            if (!isLinkInput(key)) continue;
            if (n == n_link or !std.mem.eql(u8, key[link_input_prefix.len..], inc.linkPath(n)))
                return inc.noRelink("the link inputs are not the last build's", .{});
            n += 1;
        }
        if (n != n_link) return inc.noRelink("the link inputs are not the last build's", .{});
    }
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
        if (!try inc.sameContents(m, i)) {
            if (inc.timing) std.debug.print("cache: {d} inputs changed, first {s}\n", .{ changed.items.len, path });
            return false;
        }
        const stat = Io.Dir.cwd().statFile(io, path, .{}) catch |err| return inc.noRelink("{s}: {t}", .{ path, err });
        if (restat == null) restat = .init(gpa, m);
        try restat.?.setInput(i, path, m.inputKey(i), stat, in.content_hash, inc.build_start);
    }
    const t1 = now(io);
    // Past the fold size, the inputs are rehashed until the next full build
    // writes a new base, so that the log stays bounded.
    defer if (restat) |*d| if (!m.shouldFold()) d.append(io, inc.dir) catch {};
    if (inc.outputUnchanged(out_dir, sub_path)) {
        if (inc.timing) std.debug.print("cache: no input changed and the output is as the last link left it; not relinking ({d:.2} ms, {d} rehashed)\n", .{ ms(t0, now(io)), changed.items.len });
        return true;
    }
    const linked = (try inc.linkFrom(m, out_dir, sub_path)) orelse return false;
    if (inc.timing) std.debug.print("cache: no input changed; relinked {d} atoms in {d:.2} ms (manifest and {d} stats {d:.2}, {d} rehashed; packs mapped and input gathered {d:.2}, link {d:.2})\n", .{
        linked.atoms, ms(t0, now(io)), m.inputCount(), ms(t0, t1), changed.items.len, ms(t1, linked.gathered), ms(linked.gathered, now(io)),
    });
    return true;
}

/// Link-only input `n`: of `link_objects`, then of `link_shared`.
fn linkPath(inc: *const Incremental, n: usize) []const u8 {
    return if (n < inc.link_objects.len) inc.link_objects[n] else inc.link_shared[n - inc.link_objects.len];
}

/// Whether manifest `m`'s input `i`, whose stat changed, still has the
/// contents the manifest records.
fn sameContents(inc: *const Incremental, m: *const Manifest, i: u32) !bool {
    const in, const path = m.input(i);
    const src = Io.Dir.cwd().readFileAlloc(inc.io, path, inc.gpa, .unlimited) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return false,
    };
    defer inc.gpa.free(src);
    return @as(Hash, @bitCast(Frontend.hashSource(src))) == in.content_hash;
}

/// Whether one of manifest `m`'s link-only inputs changed: its objects may
/// then need compiler_rt functions the last build did not generate, or
/// bind the externs elsewhere, which only an eager build finds out.
fn linkInputsChanged(inc: *const Incremental, m: *const Manifest) !bool {
    var changed: std.ArrayList(u32) = .empty;
    defer changed.deinit(inc.gpa);
    try m.changedInputs(inc.gpa, inc.io, &changed);
    for (changed.items) |i| if (isLinkInput(m.inputKey(i)) and !try inc.sameContents(m, i)) return true;
    return false;
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
        cache.setTimestamps(io, out_dir, sub_path, .{ .access_timestamp = .now, .modify_timestamp = .now }) catch return false;
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

/// The key prefix of a link-only input (`link_objects`): `:link:<path>`,
/// which no module's file key has (a module name is not empty).
pub const link_input_prefix = ":link:";

pub fn isLinkInput(key: []const u8) bool {
    return std.mem.startsWith(u8, key, link_input_prefix);
}

/// Links manifest `m`'s live atoms from the packs into `sub_path`, and
/// records the output's stat (`noteOutput`). Returns null, saying why
/// under `BS_CACHE_TIMING`, if the packs or the manifest are damaged.
fn linkFrom(inc: *Incremental, m: *Manifest, out_dir: Io.Dir, sub_path: []const u8) !?Linked {
    const gpa = inc.gpa;
    const io = inc.io;
    inc.forgetOutput();
    var pack: Pack = try .open(io, inc.dir);
    defer pack.close(gpa, io);
    if (pack.id != m.pack_id) return inc.noLink("the pack is not the manifest's", .{});
    for (0..m.bases.len) |i| _ = pack.addBase(gpa, io, inc.dir, m.basePack(i)) catch |err|
        return inc.noLink("base pack {s}: {t}", .{ m.basePack(i), err });
    const in = try m.linkInput(gpa);
    const files = try gpa.alloc([]const u8, m.fileCount());
    defer gpa.free(files);
    for (files, 0..) |*f, i| f.* = m.file(@intCast(i));
    var input = try pack.linkAtoms(gpa, inc.arch, in.refs, in.debug_atoms, .{ .of = in.debug_files, .names = files });
    defer input.deinit(gpa);
    input.names = in.names;
    // An object's exports and imports; its imports are 0 in the image
    // (`ElfObject.linkInput`).
    var exports: std.ArrayList(ElfObject.Export) = .empty;
    defer exports.deinit(gpa);
    var imports: std.ArrayList(ElfObject.Import) = .empty;
    defer imports.deinit(gpa);
    var values: std.ArrayList(Elf.NumberedValue) = try .initCapacity(gpa, m.errorCount() + m.link_symbols.len);
    defer values.deinit(gpa);
    for (1..m.errorCount() + 1) |code| values.appendAssumeCapacity(.{ .symbol = m.errorSymbol(@intCast(code)), .value = code });
    for (m.link_symbols) |ls| {
        const name = m.string(ls.name);
        switch (ls.kind) {
            // Flag 1: hidden, which a shared library binding to the
            // executable's definitions does not see (`Glibc.dynamicOptions`).
            .@"export" => try exports.append(gpa, .{ .key = @fromBackingInt(ls.key), .name = name, .visibility = if (ls.flags & 1 != 0) .hidden else .default }),
            .import => {
                const f: Emit.ImportFlags = .fromBits(@truncate(ls.flags));
                try imports.append(gpa, .{ .key = @fromBackingInt(ls.key), .name = name, .weak = f.weak, .hidden = f.hidden, .tls = f.tls });
                // A dynamic executable's imports get their addresses from
                // the linker (`Symbols.dynamic_imports`).
                if (inc.glibc_version == null) if (m.symbol(ls.key)) |n| values.appendAssumeCapacity(.{ .symbol = n, .value = 0 });
            },
            _ => return inc.noLink("unknown link symbol kind", .{}),
        }
    }
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const gathered = now(io);
    // The section bounds the linker defines, where atoms name them
    // (`-ffuzz`'s coverage arrays).
    var bounds: [Elf.bound_sections.len * 2]u32 = @splat(Elf.no_bound);
    for (&bounds, Elf.boundKeys()) |*b, key| b.* = m.symbol(@backingInt(key)) orelse Elf.no_bound;

    // A dynamic executable's tables, as `Emit.link` builds them.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var glibc_loaded: ?Glibc = null;
    defer if (glibc_loaded) |*g| g.deinit();
    var dynamic: ElfDynamic.Options = .{};
    var dynamic_imports: []u32 = &.{};
    var dynamic_exports: []u32 = &.{};
    const exe_dyn = inc.output == .exe and inc.glibc_version != null;
    const glibc: ?*const Glibc = if (!exe_dyn) null else inc.glibc orelse g: {
        const path = try std.fs.path.join(arena, &.{ inc.glibc_lib_dir, Glibc.abilists_path });
        const contents = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch |err|
            return inc.noLink("glibc's symbols ({s}): {t}", .{ path, err });
        glibc_loaded = Glibc.load(gpa, contents, inc.glibc_version.?) catch |err|
            return inc.noLink("glibc's symbols ({s}): {t}", .{ path, err });
        break :g &glibc_loaded.?;
    };
    // Mapped, not read: the shared libraries' names point into them, and
    // the objects' atoms, until the link returns.
    var maps: std.ArrayList(Io.File.MemoryMap) = .empty;
    defer for (maps.items) |*mm| mm.destroy(io);
    const shared: []const ElfShared = if (!exe_dyn) &.{} else inc.shared orelse (try inc.loadShared(arena, &maps)) orelse return null;
    if (inc.link_objects.len != 0 and inc.output == .exe) return inc.linkWithInputs(arena, &maps, m, &input, in.numbered, exports.items, imports.items, glibc, shared, out_dir, sub_path, cwd, gathered);
    if (glibc) |g| {
        dynamic = g.dynamicOptions(arena, imports.items, &.{}, exports.items, shared) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.NotInGlibc => return inc.noLink("an import no shared library or glibc defines", .{}),
        };
        dynamic.runpath = inc.runpath;
        dynamic_imports = try arena.alloc(u32, imports.items.len);
        for (dynamic_imports, imports.items) |*n, imp| n.* = m.symbol(@backingInt(imp.key)) orelse
            return inc.noLink("import '{s}' has no symbol number", .{imp.name});
        // The exports a shared library names (no copies without objects).
        dynamic_exports = try arena.alloc(u32, dynamic.exports.len);
        for (dynamic_exports, dynamic.exports) |*n, x| n.* = m.symbol(@backingInt(x.key)) orelse
            return inc.noLink("export '{s}' has no symbol number", .{x.name});
    }

    const aliases = try externAliases(arena, m, &input, in.numbered);
    const numbered_aliases = try arena.alloc(Elf.NumberedAlias, aliases.len);
    for (numbered_aliases, aliases) |*n, a| n.* = .{
        .symbol = m.symbol(@backingInt(a.key)).?,
        .target = m.symbol(@backingInt(a.target)) orelse return inc.noLink("an extern slot's target has no symbol number", .{}),
    };
    var diag: Elf.Diagnostic = .{};
    const options: Elf.Options = .{
        .entry = if (inc.output == .exe) @fromBackingInt(m.entry) else null,
        .dynamic = if (exe_dyn) &dynamic else null,
        .aliases = aliases,
        .symbols = .{
            .atoms = in.numbered,
            .targets = in.targets,
            .targets_tail = in.targets_tail,
            .values = values.items,
            .bounds = bounds,
            .entry = m.entry_symbol,
            .len = m.symbolLen(),
            .dynamic_imports = dynamic_imports,
            .dynamic_exports = dynamic_exports,
            .aliases = numbered_aliases,
        },
        .diag = &diag,
        .comp_dir = cwd,
        .stack_size = inc.stack_size,
    };
    const symbols: ElfObject.Symbols = .{ .exports = exports.items, .imports = imports.items };
    const result = switch (inc.output) {
        .exe => Elf.linkInput(gpa, io, out_dir, sub_path, input, options),
        .obj => if (inc.link_objects.len == 0) ElfObject.linkInput(gpa, io, out_dir, sub_path, input, options, symbols) else obj: {
            // The Zig object merged with the object inputs and the C
            // objects, as `main.writeMerged` merges them.
            const obj = ElfObject.emitInput(gpa, io, input, options, symbols) catch |err| break :obj err;
            defer gpa.free(obj);
            const inputs = try arena.alloc(ElfMerge.Input, 1 + inc.link_objects.len);
            inputs[0] = .{ .path = sub_path, .bytes = obj };
            for (inputs[1..], inc.link_objects) |*in_obj, path| in_obj.* = .{ .path = path, .bytes = try inc.mapInput(arena, &maps, path) orelse return null };
            var why: []const u8 = "";
            const merged = ElfMerge.merge(gpa, arena, inputs, &why) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                else => return inc.noLink("{s}", .{why}),
            };
            defer gpa.free(merged);
            break :obj out_dir.writeFile(io, .{ .sub_path = sub_path, .data = merged });
        },
        .lib => lib: {
            const obj = ElfObject.emitInput(gpa, io, input, options, symbols) catch |err| break :lib err;
            defer gpa.free(obj);
            // The Zig object, then the object inputs and the C objects
            // as they are, as `compileReplaying` writes them.
            const members = try arena.alloc(Archive.Input, 1 + inc.link_objects.len);
            members[0] = .{ .name = try std.fmt.allocPrint(arena, "{s}.o", .{inc.archive_stem}), .bytes = obj };
            for (members[1..], inc.link_objects) |*member, path| member.* = .{
                .name = std.fs.path.basename(path),
                .bytes = try inc.mapInput(arena, &maps, path) orelse return null,
            };
            break :lib Archive.write(gpa, io, out_dir, sub_path, members);
        },
        _ => unreachable,
    };
    result catch |err| switch (err) {
        // A damaged pack or manifest: build from scratch instead.
        error.InvalidInput, error.InvalidSymbols, error.InvalidDebugInfo => return inc.noLink("{t} (atom '{s}')", .{ err, diag.atom }),
        else => {
            std.debug.print("error: link failed: {t} (atom '{s}')\n", .{ err, diag.atom });
            return err;
        },
    };
    inc.noteOutput(out_dir, sub_path);
    return .{ .atoms = in.refs.len, .gathered = gathered };
}

const Linked = struct { atoms: usize, gathered: Io.Timestamp };

/// Maps link input `path` into `maps`, or returns null after saying why.
fn mapInput(inc: *const Incremental, arena: Allocator, maps: *std.ArrayList(Io.File.MemoryMap), path: []const u8) !?[]const u8 {
    const io = inc.io;
    const mapped = map: {
        const f = Io.Dir.cwd().openFile(io, path, .{}) catch |err| break :map err;
        defer f.close(io);
        const len = f.length(io) catch |err| break :map err;
        if (len == 0) break :map error.EmptyFile;
        try maps.ensureUnusedCapacity(arena, 1);
        break :map cache.mapOpenFile(io, f, len, true);
    } catch |err| {
        _ = inc.noRelink("{s}: {t}", .{ path, err });
        return null;
    };
    maps.appendAssumeCapacity(mapped);
    return mapped.memory;
}

/// Parses `link_shared`, mapped into `maps`, or returns null after saying
/// why.
fn loadShared(inc: *const Incremental, arena: Allocator, maps: *std.ArrayList(Io.File.MemoryMap)) !?[]const ElfShared {
    const shared = try arena.alloc(ElfShared, inc.link_shared.len);
    for (shared, inc.link_shared) |*lib, path| {
        const bytes = try inc.mapInput(arena, maps, path) orelse return null;
        lib.* = ElfShared.parse(arena, path, bytes) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            _ = inc.noRelink("{s}: {t}", .{ path, err });
            return null;
        };
    }
    return shared;
}

/// The aliases of the `Emit.externAddrKey`s the linked atoms reference,
/// each bound as its symbol's slot is (`Emit.lowerExternSlots`): the
/// slot atom's one relocation's target and addend. Every name the
/// manifest's references hold is a candidate; a manifest with no such
/// key costs one lookup per name. A key only unlinked atoms still use
/// may have no linked slot, and gets no alias.
fn externAliases(arena: Allocator, m: *const Manifest, pack_atoms: *const Pack.LinkAtoms, numbered: []const Elf.NumberedAtom) ![]const Emit.Alias {
    var slots: std.AutoArrayHashMapUnmanaged(u32, Atom.SymbolKey) = .empty;
    for (0..m.refNameCount()) |i| {
        const name = m.refName(@intCast(i));
        if (m.symbol(@backingInt(Emit.externAddrKey(name))) == null) continue;
        const slot = m.symbol(@backingInt(Emit.externSlotKey(name))) orelse continue;
        try slots.put(arena, slot, Emit.externAddrKey(name));
    }
    if (slots.count() == 0) return &.{};
    var aliases: std.ArrayList(Emit.Alias) = try .initCapacity(arena, slots.count());
    for (numbered, 0..) |na, i| {
        const key = slots.get(na.symbol) orelse continue;
        const a = pack_atoms.atom(i);
        // An undefined weak symbol's slot has no relocation; nothing
        // strong refers to it through `extaddr`.
        if (a.relocs.len == 0) continue;
        aliases.appendAssumeCapacity(.{ .key = key, .target = a.targets[a.relocs[0].info.target], .addend = a.relocs[0].addend });
    }
    return aliases.items;
}

/// `linkFrom` for an executable with object and archive inputs, whose
/// atoms the manifest does not hold: it converts them again, as
/// `Emit.finish` does, and appends them to the manifest's atoms, where a
/// full build's `groupByOwner` puts them (`Emit.Owner.input`). The objects
/// are the last full build's (`linkInputsChanged`), so the manifest's
/// extern slots, compiler_rt functions and imports are what they need.
/// The link goes by key, which C objects' local symbols need; a keyed
/// link of the same atoms gives the numbered one's bytes.
fn linkWithInputs(
    inc: *Incremental,
    arena: Allocator,
    maps: *std.ArrayList(Io.File.MemoryMap),
    m: *Manifest,
    pack_atoms: *const Pack.LinkAtoms,
    numbered: []const Elf.NumberedAtom,
    exports: []const ElfObject.Export,
    imports: []ElfObject.Import,
    glibc: ?*const Glibc,
    shared: []const ElfShared,
    out_dir: Io.Dir,
    sub_path: []const u8,
    cwd: []const u8,
    gathered: Io.Timestamp,
) !?Linked {
    const gpa = inc.gpa;
    const io = inc.io;
    var objects: ElfInput = .{ .arena = arena, .dynamic = glibc != null };
    for (inc.link_objects) |path| {
        const bytes = try inc.mapInput(arena, maps, path) orelse return null;
        const is_archive = std.mem.startsWith(u8, bytes, "!<arch>\n") or std.mem.startsWith(u8, bytes, "!<thin>\n");
        (if (is_archive) objects.addArchive(path, bytes) else objects.addObject(path, bytes)) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => return inc.noLink("{s}: {t}", .{ path, err }),
        };
    }
    // How `Emit.InputResolver` resolves what the objects leave undefined,
    // from the manifest.
    const Resolver = struct {
        exports: *const std.StringHashMapUnmanaged(Atom.SymbolKey),
        glibc: ?*const Glibc,
        shared: []const ElfShared,
        copies: *std.StringArrayHashMapUnmanaged(u64),
        arena: Allocator,

        pub fn zigExport(r: @This(), name: []const u8) !?Atom.SymbolKey {
            return r.exports.get(name);
        }

        pub fn rtExport(_: @This(), name: []const u8) !?Atom.SymbolKey {
            if (Emit.arrayBound(name)) |key| return key;
            const e = Zcu.compilerRtExport(name) orelse return null;
            var buf: [128]u8 = undefined;
            return .fromName(Zcu.compilerRtKey(&buf, e.file, e.decl));
        }

        pub fn importSym(r: @This(), name: []const u8, weak: bool) !?Atom.SymbolKey {
            _ = weak;
            const g = r.glibc orelse return null;
            if (Glibc.sharedSymbol(r.shared, name) == null and g.get(name) == null) return null;
            return Emit.importKey(name);
        }

        pub fn copySym(r: @This(), name: []const u8) !?Atom.SymbolKey {
            const size: u64 = if (Glibc.sharedSymbol(r.shared, name)) |s|
                if (s.sym.object) s.sym.size else 0
            else s: {
                const sym = r.glibc.?.get(name).?;
                break :s if (sym.object) sym.size else 0;
            };
            if (size == 0) return null;
            try r.copies.put(r.arena, try r.arena.dupe(u8, name), size);
            return Emit.importKey(name);
        }
    };
    var export_keys: std.StringHashMapUnmanaged(Atom.SymbolKey) = .empty;
    for (exports) |x| _ = try export_keys.getOrPutValue(arena, x.name, x.key);
    var copies: std.StringArrayHashMapUnmanaged(u64) = .empty;
    const resolver: Resolver = .{ .exports = &export_keys, .glibc = glibc, .shared = shared, .copies = &copies, .arena = arena };
    // The archive members the Zig code's externs pull: those of the
    // linked nodes and the link's own atoms.
    var externs: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (0..m.nodeCount()) |i_usize| {
        const i: u32 = @intCast(i_usize);
        if (m.node(i).tag != @backingInt(Tag.link) and (m.atoms(i).len == 0 or m.flags(i).unlinked)) continue;
        for (m.nodeRefs(i)) |ref| if (ref.kind == .ext or ref.kind == .ext_weak) try externs.put(arena, m.refName(ref.value), {});
    }
    _ = try objects.pull(externs.keys(), resolver);
    const converted = try objects.convert(resolver);
    if (objects.errors.items.len != 0) return inc.noLink("{s}", .{objects.errors.items[0]});

    // The converted atoms and the glibc data copies, without those whose
    // key an earlier atom has, as `groupByOwner` drops them.
    var live = try std.DynamicBitSetUnmanaged.initEmpty(arena, m.symbolLen());
    for (numbered) |na| live.set(na.symbol);
    var extra: std.ArrayList(Atom) = try .initCapacity(arena, converted.atoms.len + copies.count());
    extra.appendSliceAssumeCapacity(converted.atoms);
    for (copies.keys(), copies.values()) |name, size| extra.appendAssumeCapacity(.{
        .key = Emit.importKey(name),
        .name = name,
        .section = .bss,
        .alignment = .fromByteUnits(@as(u64, 1) << @min(@ctz(size), 5)),
        .zero_fill = size,
    });
    var seen: std.AutoHashMapUnmanaged(Atom.SymbolKey, void) = .empty;
    var kept: usize = 0;
    for (extra.items) |a| {
        if (m.symbol(@backingInt(a.key))) |n| if (live.isSet(n)) continue;
        if ((try seen.getOrPut(arena, a.key)).found_existing) continue;
        extra.items[kept] = a;
        kept += 1;
    }
    extra.shrinkRetainingCapacity(kept);

    // The objects' link-time values, then the error codes (`Emit.finish`).
    var values: std.ArrayList(Elf.Value) = try .initCapacity(arena, converted.values.len + m.errorCount());
    values.appendSliceAssumeCapacity(converted.values);
    for (1..m.errorCount() + 1) |code| values.appendAssumeCapacity(.{ .key = Emit.errorKeyFromName(m.errorName(@intCast(code))), .value = code });
    var dynamic: ElfDynamic.Options = .{};
    if (glibc) |g| {
        // As `Emit.link`: the copied imports go to the end.
        var n: usize = 0;
        for (imports, 0..) |imp, i| if (!copies.contains(imp.name)) {
            std.mem.swap(ElfObject.Import, &imports[n], &imports[i]);
            n += 1;
        };
        // The Zig exports and the objects' definitions, which the shared
        // libraries may name, as `Emit.convertInputs` gathers them.
        const defined = if (shared.len == 0) exports else try std.mem.concat(arena, ElfObject.Export, &.{ exports, try objects.dynamicExports(resolver) });
        dynamic = g.dynamicOptions(arena, imports[0..n], imports[n..], defined, shared) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.NotInGlibc => return inc.noLink("an import no shared library or glibc defines", .{}),
        };
        dynamic.runpath = inc.runpath;
    }
    var diag: Elf.Diagnostic = .{};
    const options: Elf.Options = .{
        .entry = @fromBackingInt(m.entry),
        .values = values.items,
        .diag = &diag,
        .comp_dir = cwd,
        .stack_size = inc.stack_size,
        .local_symbols = converted.symbols,
        .input_sections = converted.sections,
        .aliases = try externAliases(arena, m, pack_atoms, numbered),
        .dynamic = if (glibc != null) &dynamic else null,
    };
    Elf.linkInput(gpa, io, out_dir, sub_path, WithInputs{ .pack = pack_atoms, .extra = extra.items }, options) catch |err| switch (err) {
        // A damaged pack or manifest, or objects that no longer fit it:
        // a build reports what is wrong.
        error.InvalidInput, error.InvalidSymbols, error.InvalidDebugInfo, error.UndefinedSymbol, error.DuplicateSymbol, error.InvalidRelocation, error.RelocationOverflow, error.AlignmentTooLarge => return inc.noLink("{t} (atom '{s}')", .{ err, diag.atom }),
        else => {
            std.debug.print("error: link failed: {t} (atom '{s}')\n", .{ err, diag.atom });
            return err;
        },
    };
    inc.noteOutput(out_dir, sub_path);
    return .{ .atoms = numbered.len + extra.items.len, .gathered = gathered };
}

/// The manifest's atoms, then the link inputs' (`linkWithInputs`).
const WithInputs = struct {
    pack: *const Pack.LinkAtoms,
    extra: []const Atom,

    pub inline fn len(s: WithInputs) usize {
        return s.pack.len() + s.extra.len;
    }

    pub inline fn check(s: WithInputs, i: usize) bool {
        return i >= s.pack.len() or s.pack.check(i);
    }

    pub inline fn atom(s: WithInputs, i: usize) Atom {
        return if (i < s.pack.len()) s.pack.atom(i) else s.extra[i - s.pack.len()];
    }

    pub inline fn debugLen(s: WithInputs) usize {
        return s.pack.debugLen();
    }

    pub inline fn debugAtom(s: WithInputs, j: usize) u32 {
        return s.pack.debugAtom(j);
    }

    pub inline fn debug(s: WithInputs, j: usize) Atom.Debug {
        return s.pack.debug(j);
    }

    pub inline fn prefetch(s: WithInputs, i: usize, comptime keys: bool) void {
        if (i < s.pack.len()) s.pack.prefetch(i, keys);
    }

    pub inline fn prefetchDebug(s: WithInputs, j: usize) void {
        s.pack.prefetchDebug(j);
    }
};

fn noLink(inc: *const Incremental, comptime fmt: []const u8, args: anytype) ?Linked {
    _ = inc.noRelink(fmt, args);
    return null;
}

/// Returns false for `relinkIfUnchanged`, saying why under
/// `BS_CACHE_TIMING`.
fn noRelink(inc: *const Incremental, comptime fmt: []const u8, args: anytype) bool {
    if (inc.timing) std.debug.print("cache: not relinking: " ++ fmt ++ "\n", args);
    return false;
}

/// Makes this an edit build: analysis loads the units the edits since the
/// last build left green from it (see "Edit builds: replaying cached
/// results" in docs/slop/architecture.md). Call after `seedErrors`, before
/// analysis. `mode` is `BS_CACHE_REPLAY`: `off` turns it off, `eager`
/// loads every green node it can before analysis instead of only those
/// the build reaches.
pub fn beginReplay(inc: *Incremental, fe: *const Frontend, zcu: *Zcu, emit: *Emit, mode: []const u8) !void {
    const m = if (inc.prev) |*m| m else return;
    if (std.mem.eql(u8, mode, "off") or inc.verify == .full) return;
    // A build whose objects or archives or shared libraries changed
    // records in full (`linkInputsChanged`, `link_objects_pending`), and so
    // does a donor's with any: the log would keep the donor's paths. A
    // donor's build is lazy only where `Replay.donorEager` allows; its log
    // then follows the donor's manifest (`finishLazy`).
    const has_inputs = inc.link_objects.len + inc.link_shared.len != 0;
    const lazy = !std.mem.eql(u8, mode, "eager") and
        (!has_inputs or (inc.donor == null and !inc.link_objects_pending and !try inc.linkInputsChanged(m)));
    const r = Replay.create(inc.gpa, inc.io, m, inc.dir, inc.arch, fe, zcu, emit, lazy, inc.donor != null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (inc.timing) std.debug.print("cache: not replaying: {t}\n", .{err});
            return;
        },
    };
    if (r.eager_why) |why| if (inc.timing) std.debug.print("cache: replaying the donor eagerly: {s}\n", .{why});
    r.check = inc.check;
    r.timing = inc.timing;
    inc.replay = r;
    zcu.replay = r;
    emit.lazy = r.lazy;
    emit.inputs_deferred = r.lazy and inc.link_objects.len != 0 and inc.output == .exe;
}

// ---------------------------------------------------------------------------
// First builds: donors

/// Under `<global cache>`: manifests that other compilations published,
/// each in a directory with hard links to the store packs it names
/// (`publishDonor`), which a first build replays (`useDonor`). Inside the
/// store's directory, so that its maintenance counts and trims them.
const donors_path = "bs/store/" ++ Store.donors_dir;
/// `<donor key, 32 hex digits>-<the program's tag (`donorTag`), 16 hex
/// digits><16 random hex digits>`.
const donor_name_len = 65;
/// Donors kept per donor key, one per program; `publishDonor` deletes
/// the oldest past it. Their space counts toward the store's cap like a
/// pack's (`Store.maintain`); this only bounds `useDonor`'s scan.
const max_donors_per_key = 128;
/// A donor's manifest mtime is its last use, renewed at most this often.
const donor_renew_ns = std.time.ns_per_hour;

/// What another compilation must share with this one for its graph to be
/// replayed here, beyond what the graph checks itself (inputs and
/// red-green): bs and the target (`store_seed`), the std, and options
/// Zcu reads without recording a dependency: `-fsingle-threaded` (whether
/// declarations are threadlocal), test filters (which tests exist), the
/// root module's `-M` name (`Frontend.displayName`: `@src()` and messages
/// show it; the root module's own name, which keys its files, is the same
/// in every compilation so that `@import("root")` carries over), and
/// whether the build links an object (`build-obj`, `build-lib`), whose
/// code CodeGen generates differently: a symbol the build does not export
/// is an import, not compiler_rt's; the glibc a `-lc` executable links,
/// for the same reason; and whether a test build tests std itself
/// (`tests_std`): only the module under test has tests among its roots,
/// so that decides which of std's containers have effects
/// (`Sema.noteEffects`), and a donor's unit that evaluated one without
/// them has no `effects` reference to its namespace, through which the
/// recorded graph reaches the container's tests.
/// The builtin module is an input, so a donor whose builtin differs is
/// valid, but loses most of std; `useDonor` ranks those last.
fn donorKey(gpa: Allocator, io: Io, store_seed: Hash, zig_lib_dir: []const u8, root_name: []const u8, tests_std: bool, args: []const []const u8) !Hash {
    var h: std.hash.Wyhash = .init(0x646f6e6f72);
    h.update(std.mem.asBytes(&store_seed));
    h.update(root_name);
    h.update("\x00");
    if (tests_std) h.update("tests std\x00");
    // Resolved: `--zig-lib-dir zig-lib` names another std in another
    // directory.
    if (Io.Dir.cwd().realPathFileAlloc(io, zig_lib_dir, gpa)) |lib| {
        defer gpa.free(lib);
        h.update(lib);
    } else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => h.update(zig_lib_dir),
    }
    var single_threaded = false;
    var object = false;
    for (args, 0..) |a, i| {
        if (i == 0 and (std.mem.eql(u8, a, "build-obj") or std.mem.eql(u8, a, "build-lib"))) object = true;
        if (std.mem.eql(u8, a, "-fsingle-threaded")) single_threaded = true;
        if (std.mem.eql(u8, a, "-fno-single-threaded")) single_threaded = false;
        if (std.mem.eql(u8, a, "--test-filter") and i + 1 < args.len) {
            h.update("\x00filter\x00");
            h.update(args[i + 1]);
        }
        // -lc and its glibc version (`Job.compile_args`): CodeGen resolves
        // names glibc defines to imports instead of compiler_rt
        // (`Emit.exportTarget`).
        if (std.mem.startsWith(u8, a, "--bs-glibc=")) {
            h.update("\x00glibc\x00");
            h.update(a);
        }
    }
    h.update(if (single_threaded) "\x00st" else "\x00mt");
    h.update(if (object) "\x00obj" else "\x00exe");
    return cache.hash(3, std.mem.asBytes(&h.final()));
}

/// Names the program among the donors of its donor key: a hash of the
/// subcommand, `--name` (`donorTagSeed`), its main module and its other
/// modules' names and root files, absolute. The same program built into
/// another cache directory or output shares it, so that its newer donor
/// replaces the older; a project's test and executable from one root
/// file do not. The same project in another worktree does not either,
/// but its donor is then the one that shares the most files.
fn donorTag(inc: *const Incremental, fe: *const Frontend) [16]u8 {
    var h: std.hash.Wyhash = .init(inc.donor_tag_seed);
    const main = fe.module(fe.main_module);
    for ([_][]const Frontend.Module{ main[0..1], fe.modules.items }) |mods| for (mods) |*mod| {
        h.update(mod.name);
        h.update("\x00");
        h.update(mod.abs_root_dir orelse mod.root_dir);
        h.update("\x00");
        h.update(mod.root_file);
        h.update("\x00");
    };
    return std.fmt.bytesToHex(std.mem.asBytes(&h.final()).*, .lower);
}

fn donorTagSeed(args: []const []const u8) u64 {
    var h: std.hash.Wyhash = .init(0x746167);
    if (args.len != 0) h.update(args[0]);
    for (args, 0..) |a, i| if (std.mem.eql(u8, a, "--name") and i + 1 < args.len) {
        h.update("\x00");
        h.update(args[i + 1]);
    };
    return h.final();
}

fn linkOrCopy(from: Io.Dir, name: []const u8, to: Io.Dir, io: Io) !void {
    from.hardLink(name, to, name, io, .{}) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        error.CrossDevice, error.OperationUnsupported => try from.copyFile(name, to, name, io, .{}),
        else => |e| return e,
    };
}

/// For a first build (no manifest): takes as `prev` the donor with this
/// compilation's donor key that has the same builtin module, then shares
/// the most files with this build (same key and content; then the
/// newest), and links its store
/// packs into the compilation's directory. The build replays it as an edit
/// build (`beginReplay`, eagerly, so that it links and records in full):
/// the donor's other files are changed inputs (`Replay.create`), so what
/// this build loads is what it shares with the donor, typically std.
/// Without a donor, or if its packs cannot be linked, the build is cold.
pub fn useDonor(inc: *Incremental, fe: *const Frontend) !void {
    inc.donor_tag = inc.donorTag(fe);
    if (inc.prev != null or !inc.donors or inc.verify == .full) return;
    const gpa = inc.gpa;
    const io = inc.io;
    const t0 = now(io);
    var donors = inc.global.openDir(io, donors_path, .{ .iterate = true }) catch return;
    defer donors.close(io);
    var key_buf: std.ArrayList(u8) = .empty;
    defer key_buf.deinit(gpa);
    // This build's files by key, as `Replay.create` matches them.
    var by_key: std.StringHashMapUnmanaged(u32) = .empty;
    defer {
        var it = by_key.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        by_key.deinit(gpa);
    }
    for (fe.files.items, 0..) |*f, fi| {
        try inputKey(gpa, &key_buf, fe, f.module, f.sub_path);
        const gop = try by_key.getOrPut(gpa, key_buf.items);
        if (!gop.found_existing) gop.key_ptr.* = try gpa.dupe(u8, key_buf.items);
        gop.value_ptr.* = @intCast(fi);
    }
    const Candidate = struct { name: [donor_name_len]u8, m: Manifest, builtin: bool, lazy: bool, own: bool, shared: u32, mtime: Io.Timestamp };
    var candidates: std.ArrayList(Candidate) = .empty;
    defer {
        for (candidates.items) |*c| c.m.close(gpa, io);
        candidates.deinit(gpa);
    }
    const prefix = std.fmt.hex(inc.donor_key);
    // The program's own donor first: if it can be replayed lazily with
    // the same builtin, nothing ranks above it, and the others' manifests
    // stay closed (a key can hold many).
    var names: std.ArrayList([donor_name_len]u8) = .empty;
    defer names.deinit(gpa);
    var it = donors.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .directory or e.name.len != donor_name_len or !std.mem.startsWith(u8, e.name, &prefix)) continue;
        try names.append(gpa, e.name[0..donor_name_len].*);
        if (std.mem.eql(u8, e.name[33..49], &inc.donor_tag)) std.mem.swap([donor_name_len]u8, &names.items[0], &names.items[names.items.len - 1]);
    }
    for (names.items) |*name| {
        const own = std.mem.eql(u8, name[33..49], &inc.donor_tag);
        if (!own and candidates.items.len != 0) {
            const first = &candidates.items[0];
            if (first.own and first.builtin and first.lazy and first.shared != 0) break;
        }
        var d = donors.openDir(io, name, .{}) catch continue;
        defer d.close(io);
        const stat = d.statFile(io, "manifest", .{}) catch continue;
        var m = (Manifest.open(gpa, io, d) catch continue) orelse continue;
        var c: Candidate = .{
            .name = name.*,
            .m = m,
            .builtin = false,
            .lazy = true,
            .own = own,
            .shared = 0,
            .mtime = stat.mtime,
        };
        for (0..m.inputCount()) |i| {
            const in, _ = m.input(@intCast(i));
            const fi = by_key.get(m.inputKey(@intCast(i))) orelse {
                // As `Replay.create`: an input that names no file here.
                if (c.lazy and !isLinkInput(m.inputKey(@intCast(i))) and !(inputKeyHolds(gpa, &key_buf, &m, @intCast(i), fe) catch false)) c.lazy = false;
                continue;
            };
            const f = fe.file(@fromBackingInt(fi));
            if (@as(Hash, @bitCast(f.content_hash)) != in.content_hash) continue;
            c.shared += 1;
            if (f.module == .builtin) c.builtin = true;
        }
        // Ranking only: a failure counts as eager.
        if (c.lazy) c.lazy = donorPathsKnown(gpa, &m, fe) catch false;
        candidates.append(gpa, c) catch |err| {
            m.close(gpa, io);
            return err;
        };
    }
    std.mem.sortUnstable(Candidate, candidates.items, {}, struct {
        fn better(_: void, a: Candidate, b: Candidate) bool {
            if (a.builtin != b.builtin) return a.builtin;
            // One this build can replay lazily (`Replay.donorEager`).
            if (a.lazy != b.lazy) return a.lazy;
            // This program's own, made from the same root file.
            if (a.own != b.own) return a.own;
            if (a.shared != b.shared) return a.shared > b.shared;
            return a.mtime.compare(.gt, b.mtime);
        }
    }.better);
    for (candidates.items, 0..) |*c, ci| {
        if (c.shared == 0) break;
        var d = donors.openDir(io, &c.name, .{}) catch continue;
        defer d.close(io);
        // The packs, linked from the donor's own links: the store may have
        // merged or trimmed them since.
        const linked = for (0..c.m.bases.len) |i| {
            linkOrCopy(d, c.m.basePack(i), inc.dir, io) catch break false;
        } else true;
        if (!linked) continue;
        if (c.mtime.durationTo(Io.Clock.real.now(io)).toNanoseconds() > donor_renew_ns) cache.setTimestamps(io, d, "manifest", .{ .access_timestamp = .now, .modify_timestamp = .now }) catch {};
        if (inc.timing) std.debug.print("cache: first build: replaying donor {s}, {s} ({d} of its {d} inputs are this build's, builtin {s}; {d} candidates) in {d:.2} ms\n", .{
            &c.name, if (c.own) "the program's own" else "another program's", c.shared, c.m.inputCount(), if (c.builtin) "the same" else "different", candidates.items.len, ms(t0, now(io)),
        });
        inc.prev = c.m;
        inc.donor = c.name;
        _ = candidates.orderedRemove(ci);
        return;
    }
    if (inc.timing) std.debug.print("cache: first build: no usable donor ({d} candidates)\n", .{candidates.items.len});
}

/// Whether every debug path donor manifest `m`'s atoms name is one this
/// build writes. A lazy donor build links the green functions' atoms as
/// the donor recorded them, so their paths must be this build's: each is
/// a file's as the compiler opened it, its module's directory joined with
/// its path in the module (`Frontend`), and `m`'s path table lists every
/// one, compile units and inlined callees' files included
/// (`Manifest.AtomSymbols.other_files`).
pub fn donorPathsKnown(gpa: Allocator, m: *const Manifest, fe: *const Frontend) !bool {
    var paths: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = paths.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        paths.deinit(gpa);
    }
    const add = struct {
        fn add(g: Allocator, set: *std.StringHashMapUnmanaged(void), parts: []const []const u8) !void {
            const p = try std.fs.path.join(g, parts);
            const gop = set.getOrPut(g, p) catch |err| {
                g.free(p);
                return err;
            };
            if (gop.found_existing) g.free(p);
        }
    }.add;
    for (fe.modules.items) |*mod| try add(gpa, &paths, &.{ mod.root_dir, mod.root_file });
    for (0..m.inputCount()) |i| {
        const key = m.inputKey(@intCast(i));
        if (isLinkInput(key)) continue;
        const colon = std.mem.indexOfScalar(u8, key, ':') orelse continue;
        const mod = for (fe.modules.items) |*mod| {
            if (std.mem.eql(u8, mod.name, key[0..colon])) break mod;
        } else continue;
        const sub = key[colon + 1 ..];
        try add(gpa, &paths, &.{ mod.root_dir, if (sub.len == 0) mod.root_file else sub });
    }
    for (0..m.fileCount()) |i| if (!paths.contains(m.file(@intCast(i)))) return false;
    return true;
}

/// Makes the donor's manifest this compilation's base, which a lazy donor
/// build's log follows (`finishLazy`): hard-linked, as `publishDonor`
/// links a compilation's base into the donors. Bases are replaced, never
/// written in place.
fn installDonorBase(inc: *Incremental) !void {
    const io = inc.io;
    var buf: [donors_path.len + 1 + donor_name_len]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ donors_path, &inc.donor.? }) catch unreachable;
    var d = try inc.global.openDir(io, path, .{});
    defer d.close(io);
    inc.dir.deleteFile(io, "manifest.log") catch {};
    inc.dir.deleteFile(io, "manifest") catch {};
    try linkOrCopy(d, "manifest", inc.dir, io);
}

/// Undoes `installDonorBase` in a donor build that does not finish lazily:
/// the compilation had no manifest, and the donor's would pass for its
/// own (a relink of the donor's output, say).
fn dropDonorBase(inc: *Incremental) void {
    if (inc.donor == null) return;
    inc.dir.deleteFile(inc.io, "manifest.log") catch {};
    inc.dir.deleteFile(inc.io, "manifest") catch {};
}

/// After a full record is placed: publishes the manifest as a donor for
/// other compilations' first builds (`useDonor`). Every atom of a full
/// record is in a store pack, so the donor is the manifest plus links to
/// the packs it names, which keep them alive when the store merges or
/// trims them. Built under a temporary name and renamed into place, so
/// readers only see complete donors.
fn publishDonor(inc: *Incremental, base_names: []const []const u8) !void {
    if (!inc.donors or inc.verify == .full) return;
    const gpa = inc.gpa;
    const io = inc.io;
    var donors = try inc.global.createDirPathOpen(io, donors_path, .{ .open_options = .{ .iterate = true } });
    defer donors.close(io);
    var rand: [16]u8 = undefined;
    io.random(&rand);
    var name: [donor_name_len]u8 = undefined;
    _ = std.fmt.bufPrint(&name, "{s}-{s}{s}", .{ &std.fmt.hex(inc.donor_key), &inc.donor_tag, &std.fmt.bytesToHex(rand[0..8].*, .lower) }) catch unreachable;
    var tmp_name: [Store.donor_tmp_prefix.len + 32]u8 = undefined;
    _ = std.fmt.bufPrint(&tmp_name, "{s}{s}", .{ Store.donor_tmp_prefix, &std.fmt.bytesToHex(rand, .lower) }) catch unreachable;
    {
        var tmp = try donors.createDirPathOpen(io, &tmp_name, .{});
        defer tmp.close(io);
        errdefer donors.deleteTree(io, &tmp_name) catch {};
        try linkOrCopy(inc.dir, "manifest", tmp, io);
        for (base_names) |n| try linkOrCopy(inc.dir, n, tmp, io);
    }
    donors.rename(&tmp_name, donors, &name, io) catch |err| {
        donors.deleteTree(io, &tmp_name) catch {};
        return err;
    };
    // This program's older donors, which this one supersedes: they would
    // take the slots of other programs' (a program's own donor is the one
    // its first build in a fresh cache can replay lazily). Then
    // the oldest donors of this key past the limit.
    const Old = struct { name: [donor_name_len]u8, mtime: Io.Timestamp };
    var same: std.ArrayList(Old) = .empty;
    defer same.deinit(gpa);
    var superseded: std.ArrayList([donor_name_len]u8) = .empty;
    defer superseded.deinit(gpa);
    var it = donors.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .directory or e.name.len != donor_name_len or !std.mem.startsWith(u8, e.name, name[0..32])) continue;
        var path: [donor_name_len + "/manifest".len]u8 = undefined;
        _ = std.fmt.bufPrint(&path, "{s}/manifest", .{e.name}) catch unreachable;
        if (std.mem.eql(u8, e.name, &name)) continue;
        if (std.mem.eql(u8, e.name[33..49], &inc.donor_tag)) {
            try superseded.append(gpa, e.name[0..donor_name_len].*);
            continue;
        }
        const stat = donors.statFile(io, &path, .{}) catch continue;
        try same.append(gpa, .{ .name = e.name[0..donor_name_len].*, .mtime = stat.mtime });
    }
    for (superseded.items) |*o| donors.deleteTree(io, o) catch {};
    if (same.items.len < max_donors_per_key) return;
    std.mem.sortUnstable(Old, same.items, {}, struct {
        fn newer(_: void, a: Old, b: Old) bool {
            return a.mtime.compare(.gt, b.mtime);
        }
    }.newer);
    for (same.items[max_donors_per_key - 1 ..]) |o| donors.deleteTree(io, &o.name) catch {};
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
    func_inline,
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
            .func_inline => |f| mix(9, @backingInt(f)),
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
            .func_ies, .func_inline => |func| try r.addUnit(.{ .func = func }),
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
            .func_inline => .func_inline,
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
                    .result_hash = if (nav.status == .resolved) ip.stableHash(ip.typeOf(nav.val)) else if (nav.ty_status == .resolved) ip.stableHash(nav.ty) else 0,
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
            .func_inline => |func| return .{
                .key = try k.keyOf(.func_inline, &.{try k.unitKeyString(.{ .func = func })}),
                .result_hash = if (k.zcu.inline_results.get(func)) |res| res.hash else k.zcu.inline_salt ^ 1,
            },
            .namespace_name => |nn| {
                const ns = k.zcu.namespacePtr(nn.namespace);
                var key: std.ArrayList(u8) = .empty;
                defer key.deinit(k.zcu.gpa);
                const found = ns.decls.getIndex(nn.name);
                return .{
                    .key = try k.keyOf(.namespace_name, &.{ ns.key, ip.stringSlice(nn.name) }),
                    // Which declaration the name finds, if any, and
                    // whether it is `pub` (`@hasDecl`, and access from
                    // other files, read that).
                    .result_hash = if (found) |i| cache.hash(3, try k.zcu.declKey(k.zcu.gpa, ns, i, &key)) ^ @intFromBool(k.zcu.declIsPub(ns, i)) else 0,
                    .source = k.namespaceSource(ns),
                    .source_name = ip.stringSlice(nn.name),
                };
            },
            .namespace => |ns_index| {
                const ns = k.zcu.namespacePtr(ns_index);
                // The names, and which are `pub`: `@typeInfo`'s
                // `decl_names` lists only those.
                var h: Hash = 0;
                for (ns.decls.keys(), 0..) |name, i| {
                    h = cache.hash(@as(u64, @truncate(h)) ^ @intFromBool(k.zcu.declIsPub(ns, i)), ip.stringSlice(name)) ^ h;
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
    inc.donor_tag = inc.donorTag(fe);
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
            std.debug.print("error: BS_CACHE_VERIFY: the edit build's nodes differ from a full build's\n", .{});
        } else std.debug.print("error: BS_CACHE_CHECK found gaps in the recorded dependencies or references\n", .{});
        std.process.exit(1);
    }
    const waited = ms(t0, now(inc.io));
    if (!linked) return r.discard(inc);
    defer r.discard(inc);
    try Manifest.Builder.place(&r.manifest, inc.io, inc.dir);
    if (r.empty_pack) |id| try Pack.writeEmpty(inc.io, inc.dir, @bitCast(id));
    inc.publishDonor(r.base_names) catch |err| if (inc.timing) std.debug.print("cache: could not publish a donor: {t}\n", .{err});
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

/// `BS_CACHE_VERIFY`: builds again in full in a child bs, which compares
/// its nodes with this edit build's manifest, and exits if they differ.
fn verifyReplay(inc: *Incremental) !void {
    const io = inc.io;
    const env = inc.verify_environ.?;
    const old = env.get("BS_CACHE_VERIFY") orelse "1";
    try env.put("BS_CACHE_VERIFY", "full");
    defer env.put("BS_CACHE_VERIFY", old) catch {};
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
    std.debug.print("error: BS_CACHE_VERIFY: the full build of this edit build failed or differed\n", .{});
    std.process.exit(1);
}

// ---------------------------------------------------------------------------
// A lazy edit build's end (step 4b)

/// Ends a lazy edit build (`Replay.lazy`), in place of `startRecord`, the
/// link, and `finishRecord`: appends what the build changed to the
/// manifest's log (`recordDelta`), and links from the manifest. Returns
/// null if this is not a lazy build, else whether it linked, or
/// `error.LazyFallback` if the log cannot express the build's changes
/// (the log is then as it was): the caller builds again eagerly.
pub fn finishLazy(inc: *Incremental, fe: *const Frontend, zcu: *Zcu, emit: *const Emit, out_dir: Io.Dir, sub_path: []const u8) !?bool {
    const r = inc.replay orelse return null;
    if (!r.lazy) return null;
    if (emit.needs_inputs) {
        if (inc.timing) std.debug.print("cache: building again eagerly: a declaration's data takes the address of a link input's symbol\n", .{});
        return inc.fallBack();
    }
    if (r.late_unmapped) {
        if (inc.timing) std.debug.print("cache: building again eagerly: a compiler_rt file that loaded late has no old ZIR to map\n", .{});
        return inc.fallBack();
    }
    const gpa = inc.gpa;
    const io = inc.io;
    if (inc.timing) r.printStats();
    const t0 = now(io);
    const m = &inc.prev.?;
    const old_log = m.overlay.len;
    if (inc.donor != null) inc.installDonorBase() catch |err| {
        if (inc.timing) std.debug.print("cache: building again eagerly: the donor's manifest could not be linked: {t}\n", .{err});
        return inc.fallBack();
    };
    errdefer inc.dropDonorBase();
    inc.recordDelta(fe, zcu, emit, r) catch |err| switch (err) {
        error.Fallback => return inc.fallBack(),
        else => return err,
    };
    const t1 = now(io);
    // The manifest with the record applied.
    var now_m = (try Manifest.open(gpa, io, inc.dir)) orelse return error.ManifestGone;
    defer now_m.close(gpa, io);
    const linked = try inc.linkFrom(&now_m, out_dir, sub_path) orelse {
        inc.dropLog(old_log);
        return inc.fallBack();
    };
    const t2 = now(io);
    var folded: enum { no, yes, compacted } = .no;
    if (now_m.shouldFold()) {
        var b: Manifest.Builder = try .initFrom(gpa, &now_m);
        defer b.deinit();
        // The edits appended their atoms to the pack; the records they
        // replaced are dead. Rewrite the pack's own records when those
        // outgrow the live ones, so that the pack stays bounded by the
        // folds as the log is.
        const refs = try b.nodeAtomRefs();
        defer gpa.free(refs);
        if (r.pack.shouldCompactOwn(refs)) {
            try r.pack.compactOwn(gpa, io, inc.dir, refs);
            try b.setAtomRefs(refs);
            folded = .compacted;
        } else folded = .yes;
        try b.write(io, inc.dir, r.pack.id);
    }
    if (inc.timing) std.debug.print("cache: recorded the edits in {d:.2} ms; linked {d} atoms from the manifest in {d:.2} ms (gathered {d:.2}){s}; {d:.2} ms in all\n", .{
        ms(t0, t1),      linked.atoms, ms(t1, t2), ms(t1, linked.gathered),
        switch (folded) {
            .no => "",
            .yes => "; folded the log into a new base",
            .compacted => "; folded the log into a new base and compacted the pack",
        },
        ms(t0, now(io)),
    });
    if (inc.verify == .replay) try inc.verifyReplay();
    return true;
}

/// Whether manifest `m`'s input `in` has file `f`'s path and stat.
fn sameInput(inc: *const Incremental, m: *const Manifest, in: u32, fe: *const Frontend, f: *const Frontend.File) !bool {
    var path_buf: std.ArrayList(u8) = .empty;
    defer path_buf.deinit(inc.gpa);
    try inputPath(inc.gpa, &path_buf, fe, f.module, f.sub_path);
    const rec, const path = m.input(in);
    if (!std.mem.eql(u8, path, path_buf.items)) return false;
    const stat = Io.Dir.cwd().statFile(inc.io, path, .{}) catch return false;
    return rec.matches(stat);
}

/// Truncates the manifest's log to `len` bytes, dropping the records
/// appended since (0: no log).
fn dropLog(inc: *Incremental, len: u64) void {
    if (len == 0) return inc.dir.deleteFile(inc.io, "manifest.log") catch {};
    const f = inc.dir.openFile(inc.io, "manifest.log", .{ .mode = .write_only }) catch return;
    defer f.close(inc.io);
    f.setLength(inc.io, len) catch {};
}

/// Ends the lazy replay, for the caller to build again eagerly.
fn fallBack(inc: *Incremental) error{LazyFallback} {
    inc.dropDonorBase();
    inc.endReplay();
    return error.LazyFallback;
}

/// Ends the replay of a build that the caller builds again
/// (`Zcu.finalizeNames`).
pub fn endReplay(inc: *Incremental) void {
    if (inc.replay) |r| r.destroy();
    inc.replay = null;
}

/// Why `recordDelta` falls back to an eager build, under
/// `BS_CACHE_TIMING`.
fn lazyFallback(inc: *const Incremental, comptime fmt: []const u8, args: anytype) error{Fallback} {
    if (inc.timing) std.debug.print("cache: building again eagerly: " ++ fmt ++ "\n", args);
    return error.Fallback;
}

/// Appends a lazy edit build's changes to the manifest's log: the nodes of
/// the units it analyzed and of the dependees whose results changed, the
/// new atoms (appended to the pack), the changed and new inputs with the
/// sources and result items that name their instructions mapped to the
/// new ZIR, new error names, and which nodes are live (`unlinked`) and
/// which an edit reached without the build deciding them (`stale`).
fn recordDelta(inc: *Incremental, fe: *const Frontend, zcu: *Zcu, emit: *const Emit, rp: *Replay) !void {
    const gpa = inc.gpa;
    const io = inc.io;
    const ip = &zcu.ip;
    const m = rp.m;
    const n_prev = m.nodeCount();

    // What the log cannot express yet: exports that ran again (their
    // symbols are the link's), and declarations whose data this build
    // lowered without analyzing them (green, but never lowered before).
    for (zcu.exports.items) |e| if (e.unit != null) return inc.lazyFallback("an @export ran again", .{});
    for (emit.atom_owners.items) |owner| switch (owner) {
        .unit => |u| if (!zcu.deps.contains(u)) return inc.lazyFallback("a declaration's data is new", .{}),
        .content, .link, .input => {},
    };

    var g: Graph = .{ .r = .{ .gpa = gpa, .zcu = zcu } };
    defer g.deinit();
    const r = &g.r;
    try g.collect(io, zcu, emit);
    try g.makeNodes(io, zcu, emit);
    const nodes = r.nodes.items;

    // Each node's index in the manifest: its own, or a new one.
    const final = try gpa.alloc(u32, nodes.len);
    defer gpa.free(final);
    var n_new: u32 = 0;
    for (nodes, final) |n, *f| f.* = m.find(n.key) orelse blk: {
        n_new += 1;
        break :blk n_prev + n_new - 1;
    };
    const new_tags = try gpa.alloc(Tag, n_new);
    defer gpa.free(new_tags);
    for (nodes, final) |n, f| if (f >= n_prev) {
        new_tags[f - n_prev] = n.tag;
    };
    // Which nodes to write: the units analyzed, every new node, and
    // dependees whose results changed (their references too, for
    // namespaces' roots).
    var d: Manifest.Delta = .init(gpa, m);
    defer d.deinit();
    var node_refs = try g.nodeRefs(emit, &d);
    defer node_refs.deinit(gpa);
    const ref_starts = try gpa.alloc(u32, nodes.len + 1);
    defer gpa.free(ref_starts);
    {
        var j: usize = 0;
        for (0..nodes.len + 1) |ni| {
            while (j < node_refs.items.len and node_refs.items[j].node < ni) j += 1;
            ref_starts[ni] = @intCast(j);
        }
    }
    var refs_buf: std.ArrayList(Manifest.Ref) = .empty;
    defer refs_buf.deinit(gpa);
    const write = try gpa.alloc(bool, nodes.len);
    defer gpa.free(write);
    @memset(write, false);
    for (r.unit_list.items, r.unit_info) |u, info| {
        if (zcu.deps.contains(u)) write[info.node] = true;
    }
    for (nodes, final, write, 0..) |n, f, *w, ni| {
        if (n.tag == .link) {
            w.* = false;
            continue;
        }
        if (f >= n_prev) {
            w.* = true;
            continue;
        }
        if (w.* or n.tag == .content) continue;
        switch (n.tag) {
            .nav_val, .type_layout, .struct_defaults, .func, .comptime_decl => continue,
            else => {},
        }
        // A dependee: its result, and its references.
        try mappedRefs(gpa, node_refs.items[ref_starts[ni]..ref_starts[ni + 1]], final, &refs_buf);
        const refs_eql = refsEql(m, m.nodeRefs(f), refs_buf.items, &d);
        // Namespaces' roots: comptime declarations come and go, but the
        // link's own atoms list the exports and tests.
        if (!refs_eql and n.tag == .namespace and !onlyComptimeRootsDiffer(m, m.nodeRefs(f), refs_buf.items, n_prev, new_tags))
            return inc.lazyFallback("exports or tests changed", .{});
        if (!refs_eql or m.node(f).result_hash != n.result_hash) w.* = true;
    }
    // A function generated again that a unit left green exports
    // (`Replay.greenNode`): its atom's name would be the declaration's,
    // since `Emit.nameAtoms` names functions from this build's exports.
    {
        var exported = try std.DynamicBitSetUnmanaged.initEmpty(gpa, n_prev);
        defer exported.deinit(gpa);
        for (0..n_prev) |i| {
            const refs = m.nodeRefs(@intCast(i));
            for (refs) |ref| {
                if (ref.kind != .analyze) continue;
                for (refs) |fr| if (fr.kind == .func and fr.value < n_prev) exported.set(fr.value);
                break;
            }
        }
        for (nodes, final, write) |n, f, w| if (w and f < n_prev and n.tag == .func and exported.isSet(f))
            return inc.lazyFallback("a function an @export names was generated again", .{});
    }
    // Tests or exports in a new namespace: as above.
    for (nodes, final, 0..) |n, f, ni| if (f >= n_prev and n.tag == .namespace) {
        for (node_refs.items[ref_starts[ni]..ref_starts[ni + 1]]) |nr| {
            if (nr.ref.kind == .root and nodes[nr.ref.value].tag != .comptime_decl) return inc.lazyFallback("exports or tests changed", .{});
        }
    };

    // The atoms of the nodes written, appended to the pack.
    var new_atoms: std.ArrayList(Atom) = .empty;
    defer new_atoms.deinit(gpa);
    var new_debug: std.ArrayList(Atom.Debug) = .empty;
    defer new_debug.deinit(gpa);
    const atom_at = try gpa.alloc(u32, emit.atoms.items.len);
    defer gpa.free(atom_at);
    for (nodes, write) |n, w| if (w) for (n.atoms) |ai| {
        atom_at[ai] = @intCast(new_atoms.items.len);
        if (g.debug_of[ai]) |dbg| {
            var copy = dbg.*;
            copy.atom = @intCast(new_atoms.items.len);
            try new_debug.append(gpa, copy);
        }
        try new_atoms.append(gpa, emit.atoms.items[ai]);
    };
    const new_refs = try gpa.alloc(Pack.AtomRef, new_atoms.items.len);
    defer gpa.free(new_refs);
    if (new_atoms.items.len != 0) try rp.pack.append(gpa, io, new_atoms.items, new_debug.items, new_refs);

    // Inputs: each file's, the changed ones' new stats, and new ones.
    var path_buf: std.ArrayList(u8) = .empty;
    defer path_buf.deinit(gpa);
    var key_buf: std.ArrayList(u8) = .empty;
    defer key_buf.deinit(gpa);
    const file_inputs = try gpa.alloc(u32, fe.files.items.len);
    defer gpa.free(file_inputs);
    var n_inputs = m.inputCount();
    var changed_input = try std.DynamicBitSetUnmanaged.initEmpty(gpa, n_inputs);
    defer changed_input.deinit(gpa);
    for (rp.changed.items) |c| changed_input.set(c.input);
    for (fe.files.items, file_inputs, 0..) |*f, *fi, i| {
        if (rp.file_inputs.get(@intCast(i))) |in| {
            fi.* = in;
            // A donor's file with this build's contents may be elsewhere
            // (another worktree) or have another stat.
            if (!changed_input.isSet(in)) if (inc.donor == null or try inc.sameInput(m, in, fe, f)) continue;
        } else {
            fi.* = n_inputs;
            n_inputs += 1;
        }
        try inputPath(gpa, &path_buf, fe, f.module, f.sub_path);
        try inputKey(gpa, &key_buf, fe, f.module, f.sub_path);
        const known = fi.* < m.inputCount();
        if (Io.Dir.cwd().statFile(io, path_buf.items, .{})) |stat|
            try d.setInput(if (known) fi.* else null, path_buf.items, key_buf.items, stat, @bitCast(f.content_hash), inc.build_start)
        else |_|
            return inc.lazyFallback("{s} is gone", .{path_buf.items});
    }
    // Embedded files: by path and key (`embedInput`).
    const embed_inputs = try gpa.alloc(u32, zcu.embed_files.count());
    defer gpa.free(embed_inputs);
    for (zcu.embed_files.values(), embed_inputs) |f, *ei| {
        try inputPath(gpa, &path_buf, fe, f.module, f.sub_path);
        const content_hash: Hash = @bitCast(Frontend.hashSource(f.bytes));
        const known = embedInput(m, rp, path_buf.items, f.key);
        ei.* = known orelse n_inputs;
        if (known) |in| {
            if (m.input(in)[0].content_hash == content_hash) continue;
        } else n_inputs += 1;
        const stat = Io.Dir.cwd().statFile(io, path_buf.items, .{}) catch return inc.lazyFallback("{s} is gone", .{path_buf.items});
        try d.setInput(known, path_buf.items, f.key, stat, content_hash, inc.build_start);
    }

    // Results, with this build's items after the manifest's: those it
    // decoded keep their ids.
    var enc: results.Encoder = .{ .gpa = gpa, .zcu = zcu, .id_base = m.itemCount(), .file_inputs = file_inputs };
    defer enc.deinit();
    for (rp.decoder.decoded, 0..) |v, id| if (v != 0) try enc.ids.put(gpa, @fromBackingInt(v - 1), @intCast(id));
    var result_words: std.ArrayList(u32) = .empty;
    defer result_words.deinit(gpa);
    const item_results = try gpa.alloc(Encoded.Ranges, r.unit_list.items.len + r.dependee_list.items.len);
    defer gpa.free(item_results);
    _ = try encodeResults(io, r, &enc, &result_words, item_results);
    const result_of = try gpa.alloc(Encoded.Ranges, nodes.len);
    defer gpa.free(result_of);
    @memset(result_of, .{});
    for (r.unit_info, item_results[0..r.unit_info.len]) |info, res| result_of[info.node] = res;
    for (r.dependee_info, item_results[r.unit_info.len..]) |info, res| result_of[info.node] = res;
    try d.addItems(enc.words.items, enc.starts.items);
    var name_words: std.ArrayList(u32) = .empty;
    defer name_words.deinit(gpa);
    const names_of = try gpa.alloc([2]u32, nodes.len);
    defer gpa.free(names_of);
    try encodeNames(r, rp, &name_words, names_of);

    // Which nodes a walk from the roots reaches now, which also takes the
    // assumed nodes no longer reached out of the walk's.
    var reached = try inc.reachedNow(rp, nodes, final, write, node_refs.items, ref_starts, n_new);
    defer reached.deinit(gpa);
    // Which nodes are live now: those the walk reached, and those written
    // with what they depend on.
    var live = try std.DynamicBitSetUnmanaged.initEmpty(gpa, n_prev + n_new);
    defer live.deinit(gpa);
    {
        var it = rp.visited.iterator(.{});
        while (it.next()) |i| live.set(i);
    }
    for (nodes, final, write) |n, f, w| if (w) {
        live.set(f);
        for (n.deps) |e| live.set(final[Manifest.Edge.nodeOf(e)]);
    };
    if (inc.check) try inc.checkLiveReach(rp, nodes, final, write, node_refs.items, ref_starts, &live, &reached);
    // The link's inputs must not change: the symbols it resolves outside
    // the atoms, and the error name table.
    try inc.checkLinkInputs(rp, &live, nodes, final, write, node_refs.items, ref_starts, &d);

    // The nodes.
    var deps_buf: std.ArrayList(u32) = .empty;
    defer deps_buf.deinit(gpa);
    var atom_refs: std.ArrayList(Pack.AtomRef) = .empty;
    defer atom_refs.deinit(gpa);
    var symbols: std.ArrayList(Manifest.AtomSymbols) = .empty;
    defer symbols.deinit(gpa);
    var n_written: usize = 0;
    // New nodes go in order, after the manifest's.
    var order: std.ArrayList(u32) = .empty;
    defer order.deinit(gpa);
    for (write, 0..) |w, ni| if (w) try order.append(gpa, @intCast(ni));
    std.mem.sortUnstable(u32, order.items, final, struct {
        fn lessThan(f: []const u32, a: u32, b: u32) bool {
            return f[a] < f[b];
        }
    }.lessThan);
    for (order.items) |ni| {
        const n = &nodes[ni];
        const f = final[ni];
        deps_buf.clearRetainingCapacity();
        for (n.deps) |e| {
            const edge: Manifest.Edge = @bitCast(e);
            try deps_buf.append(gpa, Manifest.Edge.init(final[edge.node], edge.kind));
        }
        try mappedRefs(gpa, node_refs.items[ref_starts[ni]..ref_starts[ni + 1]], final, &refs_buf);
        atom_refs.clearRetainingCapacity();
        symbols.clearRetainingCapacity();
        for (n.atoms) |ai| {
            const a = &emit.atoms.items[ai];
            try atom_refs.append(gpa, new_refs[atom_at[ai]]);
            try symbols.append(gpa, named(ip, emit, ai, .{ .key = @backingInt(a.key), .targets = @ptrCast(a.targets), .file = if (g.debug_of[ai]) |dbg| dbg.file else null, .other_files = if (g.debug_of[ai]) |dbg| .{ dbg.unit, dbg.files } else .{ "", "" } }));
        }
        var source = n.source;
        if (source.input != Manifest.Source.no_input) {
            source.input = if (source.input < file_inputs.len) file_inputs[source.input] else embed_inputs[source.input - file_inputs.len];
        }
        const res = result_of[ni];
        const init: Manifest.NodeInit = .{
            .key = n.key,
            .result_hash = n.result_hash,
            .src_hash = n.src_hash,
            .tag = @backingInt(n.tag),
            .deps = deps_buf.items,
            .atoms = atom_refs.items,
            .symbols = symbols.items,
            .refs = refs_buf.items,
            .source = source,
            .source_name = n.source_name,
            .result = result_words.items[res.result[0]..][0..res.result[1]],
            .subject = result_words.items[res.subject[0]..][0..res.subject[1]],
            .names = name_words.items[names_of[ni][0]..][0..names_of[ni][1]],
            .flags = .{ .unlinked = n.atoms.len != 0 and !live.isSet(f), .reached = reached.isSet(f) },
        };
        if (f < n_prev) try d.update(f, init) else _ = try d.addNode(init);
        n_written += 1;
    }
    var written = try std.DynamicBitSetUnmanaged.initEmpty(gpa, n_prev);
    defer written.deinit(gpa);
    for (final, write) |f, w| if (w and f < n_prev) written.set(f);
    // The nodes this build's graph has: decided, written or not.
    var in_graph = try std.DynamicBitSetUnmanaged.initEmpty(gpa, n_prev);
    defer in_graph.deinit(gpa);
    for (final) |f| if (f < n_prev) in_graph.set(f);

    // The others' flags, and the sources and lines in changed inputs.
    for (0..n_prev) |i_usize| {
        const i: u32 = @intCast(i_usize);
        if (written.isSet(i)) continue;
        const old = m.flags(i);
        var flags = old;
        flags.unlinked = m.atoms(i).len != 0 and !live.isSet(i);
        flags.reached = reached.isSet(i);
        if (rp.state[i] != .unknown or in_graph.isSet(i)) {
            flags.stale = false;
        } else if (rp.outdated.isSet(i) and !rp.dead.isSet(i)) flags.stale = true;
        if (@as(u8, @bitCast(flags)) != @as(u8, @bitCast(old))) try d.setFlags(i, flags);
        const src = m.source(i);
        if (src.input == Manifest.Source.no_input or src.inst == Manifest.Source.no_inst or src.input >= changed_input.bit_length or !changed_input.isSet(src.input)) continue;
        const inst = rp.mapInst(src.input, @fromBackingInt(src.inst));
        const new_inst: u32 = if (inst) |x| @backingInt(x) else Manifest.Source.no_inst;
        if (new_inst != src.inst) try d.setSource(i, .{ .input = src.input, .inst = new_inst });
    }
    // Green nodes whose lines moved; and nodes, linked or not, whose
    // atoms are named after a type whose name changed or whose recorded
    // winning offers changed, so that a node that comes back to life
    // later has them right too.
    {
        var rewrite = try std.DynamicBitSetUnmanaged.initEmpty(gpa, n_prev);
        defer rewrite.deinit(gpa);
        var it = rp.refresh.iterator(.{});
        while (it.next()) |i| if (i < n_prev and !written.isSet(i) and live.isSet(i) and m.atoms(@intCast(i)).len != 0) rewrite.set(i);
        var finals: Finals = .empty;
        defer finals.deinit(gpa);
        if (rp.renamed.count() != 0) for (0..n_prev) |i_usize| {
            const i: u32 = @intCast(i_usize);
            if (written.isSet(i)) continue;
            if (rp.offersRenamed(i) or try atomsRenamed(gpa, rp, &finals, i)) rewrite.set(i);
        };
        it = rewrite.iterator(.{});
        while (it.next()) |i| try inc.rewriteKept(rp, &d, @intCast(i), &finals);
    }
    try inc.remapItems(rp, &d, &changed_input);
    for (m.errorCount() + 1..ip.error_names.items.len) |code| {
        const name = ip.error_names.items[code];
        _ = try d.addErrorName(ip.stringSlice(name), @backingInt(Emit.errorKey(ip, name)));
    }
    try d.append(io, inc.dir);
    if (inc.timing) std.debug.print("cache: wrote {d} nodes ({d} new), {d} atoms, {d} items, {d} flags, {d} sources to the log\n", .{
        n_written, n_new, new_atoms.items.len, enc.starts.items.len, d.flags.items.len, d.sources.items.len,
    });
}

/// `refs` (`Recorder` nodes) as manifest references, in `out`, sorted and
/// deduplicated as a base's are.
fn mappedRefs(gpa: Allocator, refs: []const NodeRef, final: []const u32, out: *std.ArrayList(Manifest.Ref)) !void {
    out.clearRetainingCapacity();
    for (refs) |nr| {
        var ref = nr.ref;
        switch (ref.kind) {
            .func, .nav, .effects, .root, .defaults => ref.value = final[ref.value],
            else => {},
        }
        try out.append(gpa, ref);
    }
    std.mem.sortUnstable(Manifest.Ref, out.items, {}, struct {
        fn lessThan(_: void, x: Manifest.Ref, y: Manifest.Ref) bool {
            if (x.kind != y.kind) return @backingInt(x.kind) < @backingInt(y.kind);
            return x.value < y.value;
        }
    }.lessThan);
    var n: usize = 0;
    for (out.items) |ref| {
        if (n != 0 and std.meta.eql(out.items[n - 1], ref)) continue;
        out.items[n] = ref;
        n += 1;
    }
    out.shrinkRetainingCapacity(n);
}

/// Whether two nodes' references are the same, names compared by name.
fn refsEql(m: *const Manifest, old: []const Manifest.Ref, new: []const Manifest.Ref, d: *const Manifest.Delta) bool {
    _ = d;
    if (old.len != new.len) return false;
    for (old, new) |a, b| {
        if (a.kind != b.kind) return false;
        switch (a.kind) {
            .ext, .ext_weak, .rt, .import => if (b.value >= m.refNameCount() or a.value != b.value) return false,
            .quota, .effects => {},
            else => if (a.value != b.value) return false,
        }
    }
    return true;
}

/// Whether a namespace's old and new roots differ only in `comptime`
/// declarations.
fn onlyComptimeRootsDiffer(m: *const Manifest, old: []const Manifest.Ref, new: []const Manifest.Ref, n_prev: u32, new_tags: []const Tag) bool {
    const Ctx = struct {
        fn other(mm: *const Manifest, refs: []const Manifest.Ref, i: *usize, np: u32, nt: []const Tag) ?u32 {
            while (i.* < refs.len) : (i.* += 1) {
                const ref = refs[i.*];
                if (ref.kind != .root) continue;
                const tag: Tag = if (ref.value < np) @fromBackingInt(mm.node(ref.value).tag) else nt[ref.value - np];
                if (tag == .comptime_decl) continue;
                i.* += 1;
                return ref.value;
            }
            return null;
        }
    };
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        const a = Ctx.other(m, old, &i, n_prev, new_tags);
        const b = Ctx.other(m, new, &j, n_prev, new_tags);
        if (a == null and b == null) return true;
        if (a == null or b == null or a.? != b.?) return false;
    }
}

/// Whether a reference names a symbol outside the build.
fn externalRef(kind: Manifest.Ref.Kind) bool {
    return switch (kind) {
        .ext, .ext_weak, .import => true,
        else => false,
    };
}

/// The `refName` of an import: its name, NUL, and its flags as a digit
/// (`Manifest.Ref.value`), so that a change in flags alone is a changed
/// reference.
fn addImportRefName(gpa: Allocator, namer: anytype, name: []const u8, flags: Emit.ImportFlags) !u32 {
    const ref_name = try std.fmt.allocPrint(gpa, "{s}\x00{d}", .{ name, flags.bits() });
    defer gpa.free(ref_name);
    return namer.addRefName(ref_name);
}

/// The name and flags of an import `refName` (`addImportRefName`).
pub fn parseImportRef(ref_name: []const u8) ?struct { []const u8, Emit.ImportFlags } {
    if (ref_name.len < 2 or ref_name[ref_name.len - 2] != 0) return null;
    const digit = ref_name[ref_name.len - 1];
    if (digit < '0' or digit > '7') return null;
    return .{ ref_name[0 .. ref_name.len - 2], .fromBits(@intCast(digit - '0')) };
}

/// The input of the file embedded as `key` from `path`: its own, not that
/// of a module's file at the same path (a file that embeds itself), which
/// `Replay.by_path` finds first.
fn embedInput(m: *const Manifest, rp: *const Replay, path: []const u8, key: []const u8) ?u32 {
    const first = rp.by_path.get(path) orelse return null;
    if (std.mem.eql(u8, m.inputKey(first), key)) return first;
    for (first + 1..m.inputCount()) |i| {
        if (std.mem.eql(u8, m.inputKey(@intCast(i)), key) and std.mem.eql(u8, m.input(@intCast(i))[1], path)) return @intCast(i);
    }
    return null;
}

/// Falls back if the link's inputs outside the atoms change with the live set:
/// the symbols it resolves outside the build (`ext`, `ext_weak`), an
/// object's imports (`import`, with their flags; the manifest lists them),
/// whether it writes the error name table, and if so, the error names.
fn checkLinkInputs(inc: *Incremental, rp: *Replay, live: *const std.DynamicBitSetUnmanaged, nodes: []const Node, final: []const u32, write: []const bool, node_refs: []const NodeRef, ref_starts: []const u32, d: *Manifest.Delta) !void {
    const gpa = inc.gpa;
    const m = rp.m;
    const n_prev = m.nodeCount();
    const Set = struct {
        names: std.StringArrayHashMapUnmanaged(void) = .empty,
        error_names: bool = false,

        fn add(s: *@This(), a: Allocator, kind: Manifest.Ref.Kind, name: []const u8) !void {
            switch (kind) {
                .ext => try s.names.put(a, name, {}),
                // Weak and strong references to one name resolve alike
                // unless every one is weak.
                .ext_weak => try s.names.put(a, try std.fmt.allocPrint(a, "{s}\x00weak", .{name}), {}),
                // Any change of an import's flags falls back, even one
                // that merges to the same flags.
                .import => try s.names.put(a, try std.fmt.allocPrint(a, "\x00import\x00{s}", .{name}), {}),
                .error_names => s.error_names = true,
                else => {},
            }
        }
    };
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var old: Set = .{};
    var new: Set = .{};
    var written = try std.DynamicBitSetUnmanaged.initEmpty(arena, n_prev);
    for (final, write) |f, w| if (w and f < n_prev) written.set(f);
    for (0..n_prev) |i_usize| {
        const i: u32 = @intCast(i_usize);
        const is_link = m.node(i).tag == @backingInt(Tag.link);
        const has_atoms = m.atoms(i).len != 0;
        const refs = m.nodeRefs(i);
        if (is_link or (has_atoms and !m.flags(i).unlinked)) for (refs) |ref| try old.add(arena, ref.kind, if (externalRef(ref.kind)) m.refName(ref.value) else "");
        if (written.isSet(i)) continue;
        if (is_link or (has_atoms and live.isSet(i))) for (refs) |ref| try new.add(arena, ref.kind, if (externalRef(ref.kind)) m.refName(ref.value) else "");
    }
    for (nodes, write, 0..) |n, w, ni| if (w and n.atoms.len != 0) for (node_refs[ref_starts[ni]..ref_starts[ni + 1]]) |nr| {
        const name = switch (nr.ref.kind) {
            .ext, .ext_weak, .import => if (nr.ref.value < m.refNameCount()) m.refName(nr.ref.value) else d.strings.items[d.ref_names.items[nr.ref.value - m.refNameCount()].off..][0..d.ref_names.items[nr.ref.value - m.refNameCount()].len],
            else => "",
        };
        try new.add(arena, nr.ref.kind, name);
    };
    // A name both weak and strong in a set counts as strong.
    for ([_]*Set{ &old, &new }) |s| {
        var i: usize = 0;
        while (i < s.names.count()) {
            const k = s.names.keys()[i];
            if (std.mem.endsWith(u8, k, "\x00weak") and s.names.contains(k[0 .. k.len - 5])) {
                s.names.swapRemoveAt(i);
            } else i += 1;
        }
    }
    if (old.error_names != new.error_names) {
        return inc.lazyFallback("the error name table comes or goes", .{});
    }
    if (new.error_names and rp.zcu.ip.error_names.items.len - 1 != m.errorCount()) {
        return inc.lazyFallback("the error name table changed", .{});
    }
    if (old.names.count() != new.names.count()) {
        return inc.lazyFallback("external symbols changed", .{});
    }
    for (old.names.keys()) |k| if (!new.names.contains(k)) {
        return inc.lazyFallback("external symbols changed", .{});
    };
}

/// Types' final names by stable hash (`Replay.finalTypeName`), for
/// `rewriteKept`.
const Finals = std.AutoHashMapUnmanaged(Hash, ?[]const u8);

fn finalOf(gpa: Allocator, rp: *Replay, finals: *Finals, ty: Hash) !?[]const u8 {
    const gop = try finals.getOrPut(gpa, ty);
    if (!gop.found_existing) gop.value_ptr.* = rp.finalTypeName(ty) catch |err| {
        _ = finals.remove(ty);
        return err;
    };
    return gop.value_ptr.*;
}

/// Atom `k` of node `i`'s name, renamed after its parent type's final
/// name if that changed, or null if it did not.
fn renamedAtom(gpa: Allocator, rp: *Replay, finals: *Finals, names: Manifest.AtomNames, k: usize) !?[]const u8 {
    const an = names.names[k];
    if (an.parentHash() == 0) return null;
    const name = names.name(k);
    const final = try finalOf(gpa, rp, finals, an.parentHash()) orelse return null;
    if (an.prefix_len > name.len or std.mem.eql(u8, final, name[0..an.prefix_len])) return null;
    return final;
}

fn atomsRenamed(gpa: Allocator, rp: *Replay, finals: *Finals, i: u32) !bool {
    const names = rp.m.atomNames(i);
    for (0..names.names.len) |k| if (try renamedAtom(gpa, rp, finals, names, k) != null) return true;
    return false;
}

/// Writes green node `i` again if what a full build would record for it
/// changed: the lines of its atoms' debug info, when it or a function it
/// inlines is in a changed input (as `Replay.loadFunc` does for an eager
/// build); its atoms' names, when a type they are named after was renamed;
/// and its recorded winning type name offers (`Replay.renamed`).
fn rewriteKept(inc: *Incremental, rp: *Replay, d: *Manifest.Delta, i: u32, finals: *Finals) !void {
    const gpa = inc.gpa;
    const m = rp.m;
    var src = m.source(i);
    const refresh = rp.refresh.isSet(i);
    var line: ?u32 = null;
    var moved_inst = false;
    if (refresh and src.input != Manifest.Source.no_input and rp.maps.maps.contains(src.input)) blk: {
        const inst = rp.mapInst(src.input, @fromBackingInt(src.inst)) orelse break :blk;
        const file = rp.fileOf(src.input) orelse break :blk;
        const zir = &rp.zcu.file(file).zir;
        if (zir.instructions.items(.tag)[@backingInt(inst)] != .declaration) break :blk;
        line = zir.getDeclaration(inst).src_line;
        src.inst = @backingInt(inst);
        moved_inst = true;
    }
    var atoms: std.ArrayList(Atom) = .empty;
    defer atoms.deinit(gpa);
    var debug: std.ArrayList(Atom.Debug) = .empty;
    defer debug.deinit(gpa);
    var moved = false;
    for (m.atoms(i)) |ref| {
        const dec = rp.pack.decode(ref, rp.arch) catch |err| return inc.lazyFallback("a kept function's atom could not be decoded: {t}", .{err});
        if (dec.debug) |dbg| {
            var copy = dbg;
            copy.atom = @intCast(atoms.items.len);
            if (line) |l| if (copy.base_line != l) {
                moved = true;
                copy.base_line = l;
            };
            if (refresh and copy.inlines.len != 0) {
                copy.inlines = try rp.refreshInlines(&copy) orelse
                    return inc.lazyFallback("a kept function inlines a callee in a changed file that has no declaration yet: {s}", .{copy.name});
                if (copy.inlines.ptr != dbg.inlines.ptr) moved = true;
            }
            try debug.append(gpa, copy);
        }
        try atoms.append(gpa, dec.atom);
    }
    // A function whose lines did not move keeps its instruction too, as
    // before.
    if (!moved and moved_inst) src = m.source(i);
    const names = m.atomNames(i);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const symbols = try gpa.alloc(Manifest.AtomSymbols, atoms.items.len);
    defer gpa.free(symbols);
    var renamed = false;
    for (symbols, atoms.items, names.names, 0..) |*s, a, an, k| {
        s.* = .{
            .key = @backingInt(a.key),
            .targets = @ptrCast(a.targets),
            .name = names.name(k),
            .parent = an.parentHash(),
            .prefix_len = an.prefix_len,
        };
        if (rp.renamed.count() == 0) continue;
        if (try renamedAtom(gpa, rp, finals, names, k)) |final| {
            s.name = try std.mem.concat(arena.allocator(), u8, &.{ final, s.name[an.prefix_len..] });
            s.prefix_len = @intCast(final.len);
            renamed = true;
        }
    }
    for (debug.items) |dbg| {
        symbols[dbg.atom].file = dbg.file;
        symbols[dbg.atom].other_files = .{ dbg.unit, dbg.files };
    }
    var type_names = m.typeNames(i);
    var rewritten: std.ArrayList(u32) = .empty;
    defer rewritten.deinit(gpa);
    var won_changed = false;
    if (rp.offersRenamed(i)) {
        try results.Names.rewriteWon(gpa, &rewritten, type_names, rp);
        won_changed = !std.mem.eql(u32, rewritten.items, type_names);
        if (won_changed) type_names = rewritten.items;
    }
    if (!moved and !renamed and !won_changed) return;
    // Records keep no names: only moved lines need new ones.
    const refs = try gpa.alloc(Pack.AtomRef, atoms.items.len);
    defer gpa.free(refs);
    if (moved) try rp.pack.append(gpa, inc.io, atoms.items, debug.items, refs) else @memcpy(refs, m.atoms(i));
    const n = m.node(i);
    try d.update(i, .{
        .key = n.key,
        .result_hash = n.result_hash,
        .src_hash = n.src_hash,
        .tag = n.tag,
        .deps = m.deps(i),
        .atoms = refs,
        .symbols = symbols,
        .refs = m.nodeRefs(i),
        .source = src,
        .source_name = m.sourceName(i),
        .result = m.result(i),
        .subject = m.subject(i),
        .names = type_names,
        // Changed flags come after the nodes (`Delta.setFlags`).
        .flags = m.flags(i),
    });
}

/// Rewrites the manifest's result items that name instructions of changed
/// inputs to name them in the new ZIR (or none, if they are gone), so that
/// the inputs' new contents describe them.
fn remapItems(inc: *Incremental, rp: *Replay, d: *Manifest.Delta, changed: *const std.DynamicBitSetUnmanaged) !void {
    if (changed.count() == 0) return;
    const gpa = inc.gpa;
    const m = rp.m;
    const items = m.resultItems();
    const n = items.count();
    const file_of = try gpa.alloc(u32, n);
    defer gpa.free(file_of);
    @memset(file_of, std.math.maxInt(u32));
    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(gpa);
    const Ctx = struct {
        rp: *Replay,
        changed: *const std.DynamicBitSetUnmanaged,
        pub fn map(c: @This(), input: u32, inst: u32) ?u32 {
            if (input >= c.changed.bit_length or !c.changed.isSet(input)) return null;
            const x = c.rp.mapInst(input, @fromBackingInt(inst)) orelse return Manifest.Source.no_inst;
            return @backingInt(x);
        }
    };
    for (0..n) |id_usize| {
        const id: u32 = @intCast(id_usize);
        const words, const at = items.at(id);
        out.clearRetainingCapacity();
        if (try results.remapSource(words, at, id, file_of, &out, gpa, Ctx{ .rp = rp, .changed = changed })) try d.overrideItem(id, out.items);
    }
}

/// A recorded build, its manifest written but not placed.
const Recorded = struct {
    manifest: Io.File.Atomic,
    /// The base packs the manifest names.
    base_names: []const []const u8,
    /// The id of the empty pack the manifest names in place of the
    /// compilation's pack, if that held records. (Bytes: std.Io.Threaded
    /// frees an async result aligned past its Future's alignment with the
    /// wrong alignment.)
    empty_pack: ?[@sizeOf(Hash)]u8,
    /// For `BS_CACHE_TIMING`.
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
/// A reference `record` adds for `reach`, from a unit, a dependee, or the
/// link's own atoms.
const ReachItem = struct {
    from: union(enum) { ref: Recorder.Ref, link },
    kind: Manifest.Ref.Kind,
    to: Recorder.Ref,
};

/// `from` requested compiler_rt helper `key`: it reaches the helper's
/// function or variable and its file's roots.
fn addRtReach(r: *Recorder, items: *std.ArrayList(ReachItem), from: @FieldType(ReachItem, "from"), key: []const u8) !void {
    const zcu = r.zcu;
    const ip = &zcu.ip;
    const nav_index = zcu.rt_helpers.get(key) orelse return;
    if (nav_index == .none) return;
    const nav = ip.getNav(nav_index);
    const root = zcu.file_root_types.items[nav.file];
    if (root != .none) try items.append(r.gpa, .{ .from = from, .kind = .effects, .to = try r.addDependee(.{ .namespace = ip.structInfo(root).namespace }) });
    if (nav.status != .resolved) return;
    if (ip.keyTag(nav.val) == .func) {
        try items.append(r.gpa, .{ .from = from, .kind = .func, .to = .{ .unit = try r.addUnit(.{ .func = nav.val }) } });
    } else {
        // A variable's data (`Emit.finish`).
        try items.append(r.gpa, .{ .from = from, .kind = .nav, .to = .{ .unit = try r.addUnit(.{ .nav_val = nav_index }) } });
    }
}

/// The graph of a build's units, dependees, and atoms that `record`
/// makes from its Zcu and Emit: `collect` adds and keys every item,
/// `makeNodes` makes the nodes, their edges, and their atoms' hashes.
const Graph = struct {
    r: Recorder,
    atom_units: []u32 = &.{},
    dep_units: []u32 = &.{},
    dep_refs: []Recorder.Ref = &.{},
    use_units: []u32 = &.{},
    func_ref_items: [][2]u32 = &.{},
    unit_ref_items: [][2]u32 = &.{},
    ies_items: std.ArrayList(Recorder.Ref) = .empty,
    analyze_items: std.ArrayList(u32) = .empty,
    reach_items: std.ArrayList(ReachItem) = .empty,
    quota_items: std.ArrayList([2]u32) = .empty,
    root_ns_items: std.ArrayList(Recorder.Ref) = .empty,
    root_nodes: []u32 = &.{},
    reach_nodes: [][2]u32 = &.{},
    debug_of: []?*const Atom.Debug = &.{},

    fn deinit(g: *Graph) void {
        const gpa = g.r.gpa;
        g.freeTables();
        g.r.deinit();
        gpa.free(g.debug_of);
    }

    /// Frees all but the nodes (with their `deps` and `atoms`) and the
    /// atoms' debug info, which the store's writer reads until it commits
    /// (`Putter`): once the manifest has the nodes, `record` needs nothing
    /// else, and writing the manifest is its peak.
    fn freeTables(g: *Graph) void {
        const gpa = g.r.gpa;
        const r = &g.r;
        r.map.clearAndFree(gpa);
        r.units.clearAndFree(gpa);
        r.dependees.clearAndFree(gpa);
        r.unit_list.clearAndFree(gpa);
        r.dependee_list.clearAndFree(gpa);
        r.dependee_producer.clearAndFree(gpa);
        gpa.free(r.unit_info);
        r.unit_info = &.{};
        gpa.free(r.dependee_info);
        r.dependee_info = &.{};
        r.edges.clearAndFree(gpa);
        r.atom_pairs.clearAndFree(gpa);
        gpa.free(g.atom_units);
        gpa.free(g.dep_units);
        gpa.free(g.dep_refs);
        gpa.free(g.use_units);
        gpa.free(g.func_ref_items);
        gpa.free(g.unit_ref_items);
        g.ies_items.deinit(gpa);
        g.analyze_items.deinit(gpa);
        g.reach_items.deinit(gpa);
        g.quota_items.deinit(gpa);
        g.root_ns_items.deinit(gpa);
        gpa.free(g.root_nodes);
        gpa.free(g.reach_nodes);
        g.* = .{ .r = g.r, .debug_of = g.debug_of };
    }

    fn collect(g: *Graph, io: Io, zcu: *Zcu, emit: *const Emit) !void {
        const gpa = g.r.gpa;
        const ip = &zcu.ip;
        const r = &g.r;
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
        g.atom_units = try gpa.alloc(u32, emit.atoms.items.len);
        for (emit.atom_owners.items, g.atom_units) |owner, *u| u.* = switch (owner) {
            .unit => |unit| try r.addUnit(unit),
            .content, .link, .input => Recorder.no_node,
        };
        g.dep_units = try gpa.alloc(u32, zcu.deps.count());
        g.dep_refs = try gpa.alloc(Recorder.Ref, n_edges);
        var n_refs: usize = 0;
        for (zcu.deps.keys(), zcu.deps.values(), g.dep_units) |unit, dependees, *u| {
            u.* = try r.addUnit(unit);
            for (dependees) |d| {
                g.dep_refs[n_refs] = try r.addDependee(d);
                n_refs += 1;
            }
        }
        // Every non-empty inferred error set, read or not: a loaded function
        // takes its set from this node, and an edit build may add its first
        // reader (`Replay.loadFunc` reads no node as an empty set).
        {
            var it = zcu.inferred_errors.iterator();
            while (it.next()) |e| if (e.value_ptr.len != 0) {
                try g.ies_items.append(gpa, try r.addDependee(.{ .func_ies = e.key_ptr.* }));
            };
            var it_any = zcu.anyerror_ies.keyIterator();
            while (it_any.next()) |f| try g.ies_items.append(gpa, try r.addDependee(.{ .func_ies = f.* }));
            // Every inlinable function's result too: an edit build loading
            // the function reads no node as not inlinable.
            var it_inline = zcu.inline_results.keyIterator();
            while (it_inline.next()) |f| try g.ies_items.append(gpa, try r.addDependee(.{ .func_inline = f.* }));
        }
        g.use_units = try gpa.alloc(u32, emit.content_uses.items.len);
        for (emit.content_uses.items, g.use_units) |use, *u| u.* = try r.addUnit(use.unit);
        // References: Sema's queued functions and Emit's requests, as unit
        // items for now.
        g.func_ref_items = try gpa.alloc([2]u32, zcu.func_refs.count());
        for (zcu.func_refs.keys(), g.func_ref_items) |fr, *it| it.* = .{ try r.addUnit(fr.from), try r.addUnit(.{ .func = fr.func }) };
        // Units an edit build must analyze, and generic instances' branch
        // quotas (see `Manifest.Ref.Kind`).
        for (zcu.effect_uses.keys()) |use| {
            const ns = ip.structInfo(use.ty).namespace;
            if (zcu.namespaces.items[ns].effects and !loadMakes(zcu, use)) try g.analyze_items.append(gpa, try r.addUnit(use.unit));
        }
        // What makes the atoms live (`reach`): the roots of each namespace,
        // the units that make namespaces, and the functions analysis queued
        // itself (exports, tests, compiler_rt helpers).
        for (zcu.effect_uses.keys()) |use| try g.reach_items.append(gpa, .{
            .from = .{ .ref = .{ .unit = try r.addUnit(use.unit) } },
            .kind = .effects,
            .to = try r.addDependee(.{ .namespace = ip.structInfo(use.ty).namespace }),
        });
        // A struct's layout reaches its defaults, which analysis queued.
        for (zcu.defaults_queue.items) |ty| if (ip.structInfo(ty).defaults_status == .resolved) try g.reach_items.append(gpa, .{
            .from = .{ .ref = .{ .unit = try r.addUnit(.{ .type_layout = ty }) } },
            .kind = .defaults,
            .to = .{ .unit = try r.addUnit(.{ .struct_defaults = ty }) },
        });
        for (zcu.comptime_decls.keys()) |c| try g.reach_items.append(gpa, .{
            .from = .{ .ref = try r.addDependee(.{ .namespace = c.namespace }) },
            .kind = .root,
            .to = .{ .unit = try r.addUnit(.{ .comptime_decl = c }) },
        });
        for (zcu.exports.items) |e| {
            if (e.target != .nav) continue;
            const nav = ip.getNav(e.target.nav);
            if (nav.status != .resolved) continue;
            const target: Recorder.Ref = .{ .unit = try r.addUnit(.{ .nav_val = e.target.nav }) };
            const from: Recorder.Ref = if (e.unit) |u| .{ .unit = try r.addUnit(u) } else from: {
                try g.reach_items.append(gpa, .{ .from = .{ .ref = try r.addDependee(.{ .namespace = nav.namespace }) }, .kind = .root, .to = target });
                break :from target;
            };
            if (ip.keyTag(nav.val) == .func) try g.reach_items.append(gpa, .{ .from = .{ .ref = from }, .kind = .func, .to = .{ .unit = try r.addUnit(.{ .func = nav.val }) } });
        }
        for (zcu.test_functions.items) |nav_index| {
            const nav = ip.getNav(nav_index);
            const target: Recorder.Ref = .{ .unit = try r.addUnit(.{ .nav_val = nav_index }) };
            try g.reach_items.append(gpa, .{ .from = .{ .ref = try r.addDependee(.{ .namespace = nav.namespace }) }, .kind = .root, .to = target });
            if (nav.status == .resolved and ip.keyTag(nav.val) == .func) try g.reach_items.append(gpa, .{ .from = .{ .ref = target }, .kind = .func, .to = .{ .unit = try r.addUnit(.{ .func = nav.val }) } });
        }
        // A compiler_rt helper's requester reaches its function and the roots
        // of its file, which `resolveCompilerRt` makes.
        for (emit.unit_refs.items) |ur| if (ur.ref == .rt) try addRtReach(r, &g.reach_items, .{ .ref = .{ .unit = try r.addUnit(ur.unit) } }, ur.ref.rt);
        for (emit.link_refs.items) |lr| switch (lr) {
            .rt => |key| try addRtReach(r, &g.reach_items, .link, key),
            .nav => |nav| try g.reach_items.append(gpa, .{ .from = .link, .kind = .nav, .to = .{ .unit = try r.addUnit(.{ .nav_val = nav }) } }),
            else => {},
        };
        for (zcu.exports.items) |e| if (e.unit) |unit| try g.analyze_items.append(gpa, try r.addUnit(unit));
        var it_quota = zcu.branch_quotas.iterator();
        while (it_quota.next()) |q| if (zcu.deps.contains(.{ .func = q.key_ptr.* }))
            try g.quota_items.append(gpa, .{ try r.addUnit(.{ .func = q.key_ptr.* }), q.value_ptr.* });
        g.unit_ref_items = try gpa.alloc([2]u32, emit.unit_refs.items.len);
        for (emit.unit_refs.items, g.unit_ref_items) |ur, *it| it.* = .{
            try r.addUnit(ur.unit),
            if (ur.ref == .nav) try r.addUnit(.{ .nav_val = ur.ref.nav }) else Recorder.no_node,
        };
        // The namespaces of the files analysis starts from (`Zcu.analyzeAll`),
        // which with the link's own atoms are where `reach` starts.
        for (zcu.rootFiles()) |f| if (f) |file| {
            const ty = zcu.file_root_types.items[file];
            if (ty != .none) try g.root_ns_items.append(gpa, try r.addDependee(.{ .namespace = ip.structInfo(ty).namespace }));
        };
        try r.prepare(io);
        // Every item is listed: free the tables that found them.
        r.units.clearAndFree(gpa);
        r.dependees.clearAndFree(gpa);
    }

    fn makeNodes(g: *Graph, io: Io, zcu: *Zcu, emit: *const Emit) !void {
        const gpa = g.r.gpa;
        const r = &g.r;

        // Nodes in the order of their first atom, so that a relink lays out
        // the output as this build did.
        const link_key = cache.hash(2, &.{@backingInt(Tag.link)});
        for (emit.atom_owners.items, emit.atoms.items, g.atom_units, 0..) |owner, atom, u, i| {
            const index = switch (owner) {
                .unit => try r.unitNode(u),
                .content => (try r.node(@backingInt(atom.key), .content))[0],
                .link => (try r.node(link_key, .link))[0],
                // Converted again by every build (`linkFrom`).
                .input => continue,
            };
            r.atom_pairs.appendAssumeCapacity(.{ index, @intCast(i) });
        }
        var n_refs: usize = 0;
        for (zcu.deps.keys(), zcu.deps.values(), g.dep_units) |unit, dependees, u| {
            const index = try r.unitNode(u);
            // Ascending indices into `dependees`.
            const conditional = zcu.conditional_deps.get(unit) orelse &.{};
            var next_conditional: usize = 0;
            for (g.dep_refs[n_refs..][0..dependees.len], 0..) |ref, j| {
                const is_conditional = next_conditional < conditional.len and conditional[next_conditional] == j;
                next_conditional += @intFromBool(is_conditional);
                try r.edges.append(gpa, .{ index, Recorder.edge(try r.dependeeNode(ref), is_conditional) });
            }
            n_refs += dependees.len;
        }
        for (emit.content_uses.items, g.use_units) |use, u| {
            const index = try r.unitNode(u);
            try r.edges.append(gpa, .{ index, Recorder.edge(r.map.get(@backingInt(use.key)).?, false) });
        }
        // Nodes for the references' units, so that every node exists before
        // the store and manifest passes.
        for (g.func_ref_items) |it| {
            _ = try r.unitNode(it[0]);
            _ = try r.unitNode(it[1]);
        }
        for (g.unit_ref_items) |it| {
            _ = try r.unitNode(it[0]);
            if (it[1] != Recorder.no_node) _ = try r.unitNode(it[1]);
        }
        for (g.analyze_items.items) |*it| it.* = try r.unitNode(it.*);
        for (g.quota_items.items) |*it| it[0] = try r.unitNode(it[0]);
        g.root_nodes = try gpa.alloc(u32, g.root_ns_items.items.len);
        for (g.root_ns_items.items, g.root_nodes) |ref, *n| n.* = try r.dependeeNode(ref);
        for (g.ies_items.items) |ref| _ = try r.dependeeNode(ref);
        g.reach_nodes = try gpa.alloc([2]u32, g.reach_items.items.len);
        for (g.reach_items.items, g.reach_nodes) |it, *rn| rn.* = .{ switch (it.from) {
            .ref => |f| try r.dependeeNode(f),
            .link => (try r.node(link_key, .link))[0],
        }, try r.dependeeNode(it.to) };
        if (emit.link_content_uses.items.len != 0) {
            const index = (try r.node(link_key, .link))[0];
            for (emit.link_content_uses.items) |key| try r.edges.append(gpa, .{ index, Recorder.edge(r.map.get(@backingInt(key)).?, false) });
        }
        try r.group();
        // Grouped into the nodes, and every node made.
        r.edges.clearAndFree(gpa);
        r.atom_pairs.clearAndFree(gpa);
        inline for (.{ "atom_units", "dep_units", "dep_refs", "use_units" }) |field| {
            gpa.free(@field(g, field));
            @field(g, field) = &.{};
        }

        // Each atom's debug info, and the atoms' hashes as their owners'
        // results where nothing else is.
        g.debug_of = try gpa.alloc(?*const Atom.Debug, emit.atoms.items.len);
        @memset(g.debug_of, null);
        for (emit.debug.items) |*d| g.debug_of[d.atom] = d;
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
                            rest = rest *% 31 +% cache.hash(@truncate(@backingInt(a.key)), "");
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
                    else => {
                        n.exact_hash = n.result_hash;
                        // A declaration's data follows from its value but
                        // for the targets of addresses the link binds,
                        // such as an input object's definition of an
                        // extern symbol (`Emit.externDataTarget`), which
                        // move without the value changing.
                        var h: Hash = 0;
                        for (n.atoms) |ai| {
                            const a = &c.atoms[ai];
                            if (a.relocs.len != 0) h = h *% 31 +% cache.hash(a.relocs.len, @ptrCast(a.targets)) +% cache.hash(0, @ptrCast(a.relocs));
                        }
                        if (h != 0) n.exact_hash ^= cache.hash(14, std.mem.asBytes(&h));
                    },
                };
            }
        }{ .nodes = r.nodes.items, .atoms = emit.atoms.items, .debug_of = g.debug_of });
    }

    /// Each node's references, sorted by node and then reference; names
    /// come from `namer` (a `Manifest.Builder` or `Manifest.Delta`).
    fn nodeRefs(g: *Graph, emit: *const Emit, namer: anytype) !std.ArrayList(NodeRef) {
        const gpa = g.r.gpa;
        const r = &g.r;
        const ip = &r.zcu.ip;
        var node_refs: std.ArrayList(NodeRef) = try .initCapacity(gpa, g.func_ref_items.len + g.unit_ref_items.len + g.analyze_items.items.len + g.quota_items.items.len);
        errdefer node_refs.deinit(gpa);
        for (g.analyze_items.items) |n| node_refs.appendAssumeCapacity(.{ .node = n, .ref = .{ .kind = .analyze, .value = 0 } });
        for (g.quota_items.items) |q| node_refs.appendAssumeCapacity(.{ .node = q[0], .ref = .{ .kind = .quota, .value = q[1] } });
        for (g.func_ref_items) |it| {
            const from = try r.unitNode(it[0]);
            const to = try r.unitNode(it[1]);
            if (from != to) node_refs.appendAssumeCapacity(.{ .node = from, .ref = .{ .kind = .func, .value = to } });
        }
        for (emit.unit_refs.items, g.unit_ref_items) |ur, it| node_refs.appendAssumeCapacity(.{ .node = try r.unitNode(it[0]), .ref = switch (ur.ref) {
            .nav => .{ .kind = .nav, .value = try r.unitNode(it[1]) },
            .err => |name| .{ .kind = .err, .value = try ip.errorValue(name) },
            .ext => |e| .{ .kind = if (e.weak) .ext_weak else .ext, .value = try namer.addRefName(e.name) },
            .import => |e| .{ .kind = .import, .value = try addImportRefName(gpa, namer, e.name, e.flags) },
            .rt => |key| .{ .kind = .rt, .value = try namer.addRefName(key) },
            .error_names => .{ .kind = .error_names, .value = 0 },
        } });
        for (g.reach_items.items, g.reach_nodes) |it, rn| if (rn[0] != rn[1]) try node_refs.append(gpa, .{ .node = rn[0], .ref = .{ .kind = it.kind, .value = rn[1] } });
        std.mem.sortUnstable(NodeRef, node_refs.items, {}, NodeRef.lessThan);
        return node_refs;
    }
};

/// A reference of node `node` (a `Recorder` node).
const NodeRef = struct {
    node: u32,
    ref: Manifest.Ref,
    fn lessThan(_: void, x: @This(), y: @This()) bool {
        if (x.node != y.node) return x.node < y.node;
        if (x.ref.kind != y.ref.kind) return @backingInt(x.ref.kind) < @backingInt(y.ref.kind);
        return x.ref.value < y.ref.value;
    }
};

fn record(inc: *Incremental, fe: *const Frontend, zcu: *Zcu, emit: *const Emit) anyerror!Recorded {
    const gpa = inc.gpa;
    const io = inc.io;
    const t0 = now(io);
    // The ZIR caches' garbage, beside the rest. (`Putter.writePack`
    // applies the local cache's size limit.)
    var trimming = io.async(Frontend.trimCaches, .{fe});
    defer trimming.await(io);
    const ip = &zcu.ip;
    var g: Graph = .{ .r = .{ .gpa = gpa, .zcu = zcu } };
    defer g.deinit();
    const r = &g.r;
    try g.collect(io, zcu, emit);
    const t_collect = now(io);
    const t_keys = t_collect;

    // The units' results, for an edit build to load, encoded on another
    // thread while this one makes the graph and looks up the store.
    var enc: results.Encoder = .{ .gpa = gpa, .zcu = zcu };
    defer enc.deinit();
    var result_words: std.ArrayList(u32) = .empty;
    defer result_words.deinit(gpa);
    const item_results = try gpa.alloc(Encoded.Ranges, r.unit_list.items.len + r.dependee_list.items.len);
    defer gpa.free(item_results);
    var encoding = io.async(encodeResults, .{ io, r, &enc, &result_words, item_results });
    defer if (encoding.cancel(io)) |_| {} else |_| {};

    try g.makeNodes(io, zcu, emit);
    const root_nodes = g.root_nodes;
    const debug_of = g.debug_of;
    const t1 = now(io);

    if (inc.check) inc.checkPrediction(r, fe);

    // Store: find equal entries on every core; the others go into one new
    // pack, encoded straight into the file on other threads while this one
    // builds the manifest, so that they are never all in memory.
    var store: Store = try .open(gpa, io, inc.global);
    defer store.close(gpa, io);
    store.max_bytes = cache.globalShares(inc.max_bytes).store;
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
    if (inc.check and !checkResults(gpa, zcu, r, &enc, result_words.items, result_of, encoded.unencodable)) inc.check_failed.store(true, .monotonic);
    const t2 = now(io);
    var name_words: std.ArrayList(u32) = .empty;
    defer name_words.deinit(gpa);
    const names_of = try gpa.alloc([2]u32, r.nodes.items.len);
    defer gpa.free(names_of);
    try encodeNames(r, inc.replay, &name_words, names_of);
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
    var node_refs = try g.nodeRefs(emit, &b);
    defer node_refs.deinit(gpa);
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
                try symbols.append(gpa, named(ip, emit, ai, .{ .key = @backingInt(a.key), .targets = @ptrCast(a.targets), .file = if (debug_of[ai]) |d| d.file else null, .other_files = if (debug_of[ai]) |d| .{ d.unit, d.files } else .{ "", "" } }));
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
            .names = name_words.items[names_of[ni][0]..][0..names_of[ni][1]],
        });
    }
    if (!try markReached(gpa, r, root_nodes, &b, inc.check)) inc.check_failed.store(true, .monotonic);
    if (inc.verify == .full and !try inc.verifyNodes(r, &b, emit, debug_of)) inc.check_failed.store(true, .monotonic);
    // Copied into the manifest.
    g.freeTables();
    node_refs.clearAndFree(gpa);
    result_words.clearAndFree(gpa);
    name_words.clearAndFree(gpa);
    for (base_names.items) |name| _ = try b.addBasePack(name);
    b.items = enc.words.items;
    b.item_starts = enc.starts.items;
    b.entry = if (emit.entry) |e| @backingInt(e) else 0;
    b.output = inc.output;
    for (emit.exports.items) |x| try b.addLinkSymbol(.@"export", @backingInt(x.key), x.name, @intFromBool(x.visibility == .hidden));
    for (emit.imports.keys(), emit.imports.values()) |name, flags| try b.addLinkSymbol(.import, @backingInt(Emit.importKey(name)), name, flags.bits());
    for (ip.error_names.items[1..]) |name| _ = try b.addErrorName(ip.stringSlice(name), @backingInt(Emit.errorKey(ip, name)));
    const t3 = now(io);
    var path_buf: std.ArrayList(u8) = .empty;
    defer path_buf.deinit(gpa);
    // Input `i` is file `i` (`Manifest.Source.input`), then the embedded
    // files.
    var key_buf: std.ArrayList(u8) = .empty;
    defer key_buf.deinit(gpa);
    for (fe.files.items) |*f| {
        try inputPath(gpa, &path_buf, fe, f.module, f.sub_path);
        try inputKey(gpa, &key_buf, fe, f.module, f.sub_path);
        if (Io.Dir.cwd().statFile(io, path_buf.items, .{})) |stat|
            try b.addInput(path_buf.items, key_buf.items, stat, @bitCast(f.content_hash), inc.build_start)
        else |_|
            try b.addUnstattedInput(path_buf.items, key_buf.items, @bitCast(f.content_hash));
    }
    // `@embedFile`d files are inputs too. Every input's content hash is
    // `Frontend.hashSource`'s, which `relinkIfUnchanged` checks a touched
    // input against.
    for (zcu.embed_files.values()) |f| {
        try inputPath(gpa, &path_buf, fe, f.module, f.sub_path);
        const content_hash: Hash = @bitCast(Frontend.hashSource(f.bytes));
        if (Io.Dir.cwd().statFile(io, path_buf.items, .{})) |stat|
            try b.addInput(path_buf.items, f.key, stat, content_hash, inc.build_start)
        else |_|
            try b.addUnstattedInput(path_buf.items, f.key, content_hash);
    }
    // Link-only inputs, by the same rule.
    for (0..inc.link_objects.len + inc.link_shared.len) |n| {
        const path = inc.linkPath(n);
        const bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
        defer gpa.free(bytes);
        key_buf.clearRetainingCapacity();
        try key_buf.print(gpa, "{s}{s}", .{ link_input_prefix, path });
        const stat = try Io.Dir.cwd().statFile(io, path, .{});
        try b.addInput(path, key_buf.items, stat, @bitCast(Frontend.hashSource(bytes)), inc.build_start);
    }
    const t4 = now(io);
    // Every atom is in a store pack, so the pack's own records, which
    // lazy edit builds appended, are all dead: the manifest names a new,
    // empty pack, which `finishRecord` writes once it is placed.
    var empty_pack: ?[@sizeOf(Hash)]u8 = null;
    if (!pack.isEmpty()) {
        var id: [@sizeOf(Hash)]u8 = undefined;
        io.random(&id);
        empty_pack = id;
    }
    var manifest = try b.writeUnplaced(io, inc.dir, if (empty_pack) |id| @bitCast(id) else pack.id);
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
    return .{ .manifest = manifest, .base_names = names, .empty_pack = empty_pack, .report = report };
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
            .func_body, .func_ies, .func_inline => |func| .{ .func = func },
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
        // An inlinable function's size; none when it is not inlinable.
        if (d == .func_inline) if (zcu.inline_results.get(d.func_inline)) |res| {
            range.result = .{ @intCast(words.items.len), 1 };
            try words.append(gpa, res.size);
        };
    }
    e.ms = ms(t0, now(io));
    return e;
}

/// Each unit node's type names (`results.Names`) in `words`, its range in
/// `ranges` (by node index): the offers and name reads its analysis made
/// in this build. A unit an eager edit build loaded made none, and keeps
/// the manifest's: its candidates are the same as when it was analyzed.
fn encodeNames(r: *const Recorder, replay: ?*Replay, words: *std.ArrayList(u32), ranges: [][2]u32) !void {
    const gpa = r.gpa;
    const zcu = r.zcu;
    @memset(ranges, .{ 0, 0 });
    const Lists = struct { offers: std.ArrayList(u32) = .empty, reads: std.ArrayList(InternPool.Index) = .empty };
    var by_unit: std.AutoHashMapUnmanaged(Zcu.AnalUnit, Lists) = .empty;
    defer {
        var it = by_unit.valueIterator();
        while (it.next()) |l| {
            l.offers.deinit(gpa);
            l.reads.deinit(gpa);
        }
        by_unit.deinit(gpa);
    }
    for (zcu.name_offers.keys(), 0..) |o, i| {
        const gop = try by_unit.getOrPut(gpa, o.unit);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        try gop.value_ptr.offers.append(gpa, @intCast(i));
    }
    for (zcu.name_reads.keys()) |rd| {
        const gop = try by_unit.getOrPut(gpa, rd.unit);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        try gop.value_ptr.reads.append(gpa, rd.ty);
    }
    const loaded_from: ?*Replay = if (replay) |rp| if (rp.lazy) null else rp else null;
    var offers: std.ArrayList(Zcu.NameOffer) = .empty;
    defer offers.deinit(gpa);
    var templates: std.ArrayList(InternPool.Template) = .empty;
    defer templates.deinit(gpa);
    for (r.unit_list.items, r.unit_info) |unit, info| {
        const start = words.items.len;
        if (by_unit.get(unit)) |l| {
            offers.clearRetainingCapacity();
            templates.clearRetainingCapacity();
            for (l.offers.items) |i| {
                try offers.append(gpa, zcu.name_offers.keys()[i]);
                try templates.append(gpa, zcu.name_offers.values()[i]);
            }
            try results.Names.encode(gpa, &zcu.ip, words, offers.items, templates.items, l.reads.items);
        } else if (loaded_from) |rp| {
            const old = rp.m.find(r.nodes.items[info.node].key) orelse continue;
            if (!rp.loaded.isSet(old)) continue;
            // Which offers won, and the names they gave, are this build's.
            if (rp.renamed.count() != 0) {
                try results.Names.rewriteWon(gpa, words, rp.m.typeNames(old), rp);
            } else try words.appendSlice(gpa, rp.m.typeNames(old));
        }
        ranges[info.node] = .{ @intCast(start), @intCast(words.items.len - start) };
    }
}

/// The local cache's size limit and trimming (`Store.commit` maintains the
/// store). Best effort.
fn maintainLocal(inc: *const Incremental) void {
    // A new compilation directory is how the local cache grows.
    const t0 = now(inc.io);
    const limit = if (inc.local_is_global) cache.globalShares(inc.max_bytes).compilations else inc.max_bytes;
    const r = cache.maintainCompilations(inc.gpa, inc.io, inc.local, limit, inc.prev == null or inc.donor != null) catch null;
    if (inc.timing) if (r) |m| std.debug.print("cache: local cache {d} directories, {d} MiB; deleted {d}, leaving {d} MiB, in {d:.2} ms beside the link\n", .{ m.scanned, m.bytes >> 20, m.deleted, m.bytes_after >> 20, ms(t0, now(inc.io)) });
}

/// The global cache's limit, for every build, whether or not it wrote a
/// store pack: its compilation directories and tools (`bs/o`: the
/// translate-c and build runner executables, the C++ runtime libraries)
/// at most once a minute, and the store with its donors and ZIR when its
/// scan is due (`Store.maintainStale`). A stat each when nothing is due.
fn maintainGlobal(inc: *const Incremental) void {
    const io = inc.io;
    const t0 = now(io);
    const shares = cache.globalShares(inc.max_bytes);
    _ = cache.maintainCompilations(inc.gpa, io, inc.global, shares.compilations, false) catch null;
    var dir = inc.global.openDir(io, "bs/store", .{ .iterate = true }) catch return;
    defer dir.close(io);
    const r = Store.maintainStale(inc.gpa, io, dir, shares.store) orelse return;
    if (inc.timing) std.debug.print("cache: global store maintained: deleted {d}, evicted {d}, merged {d}, in {d:.2} ms\n", .{ r.deleted, r.evicted, r.merged, ms(t0, now(io)) });
}

/// Whether `a` and `b` are the same directory.
fn sameDir(io: Io, a: Io.Dir, b: Io.Dir) bool {
    const sa = a.stat(io) catch return false;
    const sb = b.stat(io) catch return false;
    return sa.inode == sb.inode and sa.ctime.toNanoseconds() == sb.ctime.toNanoseconds();
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
                if (try p.store.peek(p.inc.gpa, p.inc.io, storeKey(p.inc.store_seed, n.key, n.src_hash))) |e| {
                    if (e.result_hash == n.exact_hash and e.atoms_len == n.atoms.len and e.deps_len == n.deps.len and
                        e.atoms_bytes == len - Store.atomsOffset(n.deps.len))
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

/// `Manifest.Input.key` of a file: `Zcu.fileKey`.
pub fn inputKey(gpa: Allocator, buf: *std.ArrayList(u8), fe: *const Frontend, module: Frontend.Module.Index, sub_path: []const u8) !void {
    const mod = fe.module(module);
    buf.clearRetainingCapacity();
    try buf.print(gpa, "{s}:{s}", .{ mod.name, if (std.mem.eql(u8, sub_path, mod.root_file)) "" else sub_path });
}

/// Whether input `i` of `m` would be the same file in this build: its
/// key's module exists here and puts the key at the input's path. Always
/// so for the compilation's own manifest; a donor's (`useDonor`) can name
/// the files of another project, or a module this build lacks.
pub fn inputKeyHolds(gpa: Allocator, buf: *std.ArrayList(u8), m: *const Manifest, i: u32, fe: *const Frontend) !bool {
    const key = m.inputKey(i);
    const colon = std.mem.indexOfScalar(u8, key, ':') orelse return false;
    const mod = for (fe.modules.items, 0..) |*mod, mi| {
        if (std.mem.eql(u8, mod.name, key[0..colon])) break @as(Frontend.Module.Index, @fromBackingInt(@as(u32, @intCast(mi))));
    } else return false;
    const sub_path = key[colon + 1 ..];
    try inputPath(gpa, buf, fe, mod, if (sub_path.len == 0) fe.module(mod).root_file else sub_path);
    return std.mem.eql(u8, buf.items, m.input(i)[1]);
}

fn checkPrediction(inc: *Incremental, r: *const Recorder, fe: *const Frontend) void {
    inc.checkPredictionFallible(r, fe) catch |err| {
        std.debug.print("cache check: could not check the prediction: {t}\n", .{err});
        inc.check_failed.store(true, .monotonic);
    };
}

/// `BS_CACHE_CHECK`: computes the seeds from the changed inputs' ZIR, as
/// an edit build will (`seeds.zig`), and checks that every node whose
/// result this build changed is reachable from them over the last
/// manifest's reverse edges.
fn checkPredictionFallible(inc: *Incremental, r: *const Recorder, fe: *const Frontend) !void {
    const gpa = inc.gpa;
    const io = inc.io;
    const nodes = r.nodes.items;
    const m = if (inc.prev) |*m| m else return;
    const n_prev = m.nodeCount();

    // The inputs whose contents changed, by key (as `Replay.create`).
    var now_inputs: std.StringHashMapUnmanaged(struct { file: ?Frontend.File.Index, hash: Hash }) = .empty;
    defer {
        var it = now_inputs.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        now_inputs.deinit(gpa);
    }
    var path_buf: std.ArrayList(u8) = .empty;
    defer path_buf.deinit(gpa);
    for (fe.files.items, 0..) |*f, i| {
        try inputKey(gpa, &path_buf, fe, f.module, f.sub_path);
        const gop = try now_inputs.getOrPut(gpa, path_buf.items);
        if (!gop.found_existing) gop.key_ptr.* = try gpa.dupe(u8, path_buf.items);
        gop.value_ptr.* = .{ .file = @fromBackingInt(@as(u32, @intCast(i))), .hash = @bitCast(f.content_hash) };
    }
    for (r.zcu.embed_files.values()) |f| {
        const gop = try now_inputs.getOrPut(gpa, f.key);
        if (!gop.found_existing) gop.key_ptr.* = try gpa.dupe(u8, f.key);
        gop.value_ptr.* = .{ .file = null, .hash = @bitCast(Frontend.hashSource(f.bytes)) };
    }
    var changed: std.ArrayList(seeds.Changed) = .empty;
    defer changed.deinit(gpa);
    for (0..m.inputCount()) |j| {
        const in, _ = m.input(@intCast(j));
        if (now_inputs.get(m.inputKey(@intCast(j)))) |now_in| {
            if (now_in.hash != in.content_hash) try changed.append(gpa, .{ .input = @intCast(j), .file = now_in.file });
            continue;
        }
        // As `Replay.create`: an input whose key names no file here (a
        // donor's) is changed; one this build did not read has no nodes,
        // nor has a link-only one.
        if (isLinkInput(m.inputKey(@intCast(j)))) continue;
        if (!try inputKeyHolds(gpa, &path_buf, m, @intCast(j), fe)) try changed.append(gpa, .{ .input = @intCast(j), .file = null });
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
    var keyer: Keyer = .init(r.zcu, gpa);
    defer keyer.deinit();
    const test_functions_key = try keyer.keyOf(.nav_val, &.{"builtin::test_functions"});
    for (nodes) |n| {
        const i = m.find(n.key) orelse continue;
        if (m.node(i).result_hash == n.result_hash) continue;
        n_changed += 1;
        // The link's own atoms (the error name table, extern slots) follow
        // from the whole build's error names and externs, not from edges:
        // a full or eager build writes them again, and a lazy one falls
        // back when they would change (`finishLazy`). A new error name in
        // a program that uses the table changes the node with no path
        // from a seed. The test list likewise: `populateTestFunctions`
        // sets `builtin.test_functions` from the build's tests after
        // analysis, and a lazy build falls back when the tests change.
        if (n.tag == .link or n.key == test_functions_key) continue;
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

/// `BS_CACHE_CHECK`: checks that the recorded graph reaches every function
/// this build analyzed, from the units analysis starts from, over
/// dependencies and references. A build that loads units from the cache
/// queues functions only along references, so a function this misses
/// would drop out of an edit build.
/// Appends the nodes `reach` follows from a node with dependencies `deps`
/// (`Manifest.Edge` words) and references `refs`: what analyzing the node
/// analyzed in turn (its plain dependencies, which for an inferred error
/// set or a declaration's type is the unit that produces them), the
/// functions it queued, the declarations whose data its code refers to,
/// the namespaces it made, and a namespace's roots. A build analyzes the
/// units reach finds from the root files' namespaces, and links the atoms
/// of those it finds.
pub fn reachNext(deps: []const u32, refs: []const Manifest.Ref, next: *std.ArrayList(u32), gpa: Allocator) !void {
    for (deps) |e| {
        const edge: Manifest.Edge = @bitCast(e);
        if (edge.kind == .plain) try next.append(gpa, edge.node);
    }
    for (refs) |ref| if (Manifest.reachRef(ref.kind)) try next.append(gpa, ref.value);
}

/// `BS_CACHE_CHECK`: that `reach` from the root files' namespaces and the
/// link's own atoms reaches exactly the nodes with atoms, which is what an
/// edit build links without loading the units that did not change.
/// The edges a walk follows (`reachNext`) out of node `x` of the graph a
/// lazy build leaves: a written node's new ones (`written_at`: its index
/// in `nodes`, or none), a dead node's none, and any other's recorded
/// ones; appended to `next` as manifest indices.
const NewGraph = struct {
    m: *const Manifest,
    rp: *const Replay,
    nodes: []const Node,
    final: []const u32,
    node_refs: []const NodeRef,
    ref_starts: []const u32,
    written_at: []const u32,

    const none = std.math.maxInt(u32);

    fn init(gpa: Allocator, rp: *const Replay, nodes: []const Node, final: []const u32, write: []const bool, node_refs: []const NodeRef, ref_starts: []const u32, n_all: usize) !NewGraph {
        const written_at = try gpa.alloc(u32, n_all);
        @memset(written_at, none);
        for (final, write, 0..) |f, w, ni| if (w) {
            written_at[f] = @intCast(ni);
        };
        return .{ .m = rp.m, .rp = rp, .nodes = nodes, .final = final, .node_refs = node_refs, .ref_starts = ref_starts, .written_at = written_at };
    }

    fn deinit(g: *NewGraph, gpa: Allocator) void {
        gpa.free(g.written_at);
    }

    fn next(g: *const NewGraph, gpa: Allocator, x: u32, out: *std.ArrayList(u32)) !void {
        out.clearRetainingCapacity();
        const ni = g.written_at[x];
        if (ni != none) {
            for (g.nodes[ni].deps) |e| {
                const edge: Manifest.Edge = @bitCast(e);
                if (edge.kind == .plain) try out.append(gpa, g.final[edge.node]);
            }
            for (g.node_refs[g.ref_starts[ni]..g.ref_starts[ni + 1]]) |nr| if (Manifest.reachRef(nr.ref.kind)) try out.append(gpa, g.final[nr.ref.value]);
        } else if (x < g.m.nodeCount() and !g.rp.dead.isSet(x)) {
            try reachNext(g.m.deps(x), g.m.nodeRefs(x), out, gpa);
        }
    }

    fn isDead(g: *const NewGraph, x: u32) bool {
        return x < g.m.nodeCount() and g.written_at[x] == none and g.rp.dead.isSet(x);
    }
};

/// The nodes a walk from the roots reaches in the graph a lazy build
/// leaves (`NewGraph`), as the `reached` flags record them: those the
/// walk visited, and what the nodes it left to analysis and the nodes
/// written reach now. Assumed nodes (`Replay.assumeReached`) that the
/// walked ones no longer reach are taken out, of `Replay.visited` too: the
/// candidates are those the walked nodes reached before but not now, and
/// what they reach among the assumed; a candidate stays if it is reached
/// now or another assumed node that stays reaches it. Falls back if one
/// that goes offered type names, or named a node the walk visited (it may
/// have been visited for it).
fn reachedNow(inc: *Incremental, rp: *Replay, nodes: []const Node, final: []const u32, write: []const bool, node_refs: []const NodeRef, ref_starts: []const u32, n_new: u32) !std.DynamicBitSetUnmanaged {
    const gpa = inc.gpa;
    const m = rp.m;
    const n_prev = m.nodeCount();
    const n_all = n_prev + n_new;
    var g: NewGraph = try .init(gpa, rp, nodes, final, write, node_refs, ref_starts, n_all);
    defer g.deinit(gpa);
    var reached = try std.DynamicBitSetUnmanaged.initEmpty(gpa, n_all);
    errdefer reached.deinit(gpa);
    {
        var it = rp.visited.iterator(.{});
        while (it.next()) |i| if (!g.isDead(@intCast(i))) reached.set(i);
    }
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);
    var next: std.ArrayList(u32) = .empty;
    defer next.deinit(gpa);
    // What the walk left to analysis, and the written nodes it visited,
    // reach over their edges as they are now.
    for (rp.unvisited.items) |x| if (!g.isDead(x) and !reached.isSet(x)) {
        reached.set(x);
        try stack.append(gpa, x);
    };
    for (final, write) |f, w| if (w and reached.isSet(f)) try stack.append(gpa, f);
    while (stack.pop()) |x| {
        try g.next(gpa, x, &next);
        for (next.items) |t| if (!reached.isSet(t) and !g.isDead(t)) {
            reached.set(t);
            try stack.append(gpa, t);
        };
    }
    if (rp.assumed.bit_length == 0) return reached;
    const assumed = &rp.assumed;
    // The assumed nodes the walked ones reach now, and those they reached
    // before (the cone's recorded edges).
    var entered = try std.DynamicBitSetUnmanaged.initEmpty(gpa, n_prev);
    defer entered.deinit(gpa);
    var walked = try reached.clone(gpa);
    defer walked.deinit(gpa);
    {
        var it = assumed.iterator(.{});
        while (it.next()) |i| walked.unset(i);
        var wit = walked.iterator(.{});
        while (wit.next()) |x| {
            try g.next(gpa, @intCast(x), &next);
            for (next.items) |t| if (t < n_prev and assumed.isSet(t)) entered.set(t);
        }
    }
    var lost: std.ArrayList(u32) = .empty;
    defer lost.deinit(gpa);
    {
        var it = rp.cone.iterator(.{});
        while (it.next()) |x| {
            next.clearRetainingCapacity();
            try reachNext(m.deps(@intCast(x)), m.nodeRefs(@intCast(x)), &next, gpa);
            for (next.items) |t| if (t < n_prev and assumed.isSet(t) and !entered.isSet(t)) try lost.append(gpa, t);
        }
    }
    if (lost.items.len == 0) return reached;
    // The candidates: what the lost entries reach among the assumed.
    var cand = try std.DynamicBitSetUnmanaged.initEmpty(gpa, n_prev);
    defer cand.deinit(gpa);
    for (lost.items) |t| if (!cand.isSet(t)) {
        cand.set(t);
        try stack.append(gpa, t);
    };
    var cands: std.ArrayList(u32) = .empty;
    defer cands.deinit(gpa);
    while (stack.pop()) |x| {
        try cands.append(gpa, x);
        if (g.written_at[x] != NewGraph.none) return inc.lazyFallback("a node taken as reached was written", .{});
        next.clearRetainingCapacity();
        try reachNext(m.deps(x), m.nodeRefs(x), &next, gpa);
        for (next.items) |t| if (assumed.isSet(t) and !cand.isSet(t)) {
            cand.set(t);
            try stack.append(gpa, t);
        };
    }
    // Those still reached: entered now, or named by an assumed node that
    // is not a candidate (reverse edges are a superset: each is checked),
    // and what they reach among the candidates.
    for (cands.items) |x| {
        const keep = entered.isSet(x) or keep: {
            for ([_][2][]const u32{ m.rdeps(x), m.rrefs(x) }) |parts| for (parts) |part| for (part) |p| {
                if (!assumed.isSet(p) or cand.isSet(p)) continue;
                next.clearRetainingCapacity();
                try reachNext(m.deps(p), m.nodeRefs(p), &next, gpa);
                if (std.mem.indexOfScalar(u32, next.items, x) != null) break :keep true;
            };
            break :keep false;
        };
        if (keep) try stack.append(gpa, x);
    }
    while (stack.pop()) |x| {
        if (!cand.isSet(x)) continue;
        cand.unset(x);
        next.clearRetainingCapacity();
        try reachNext(m.deps(x), m.nodeRefs(x), &next, gpa);
        for (next.items) |t| if (cand.isSet(t)) try stack.append(gpa, t);
    }
    // The rest are no longer reached.
    var it = cand.iterator(.{});
    while (it.next()) |x| {
        if (m.typeNames(@intCast(x)).len != 0) return inc.lazyFallback("a type's name came from a unit no longer reached", .{});
        // The walk entered the cone from it (`Replay.assumeReached`).
        next.clearRetainingCapacity();
        try reachNext(m.deps(@intCast(x)), m.nodeRefs(@intCast(x)), &next, gpa);
        for (next.items) |t| if (!assumed.isSet(t) and rp.visited.isSet(t))
            return inc.lazyFallback("a node no longer reached named one the walk went to", .{});
        reached.unset(x);
        rp.visited.unset(x);
    }
    return reached;
}

/// `BS_CACHE_CHECK` for a lazy build: the `reached` flags it records,
/// and the nodes with atoms it links (`live`), against a full walk of the
/// graph it leaves (`NewGraph`) from the roots.
fn checkLiveReach(inc: *Incremental, rp: *const Replay, nodes: []const Node, final: []const u32, write: []const bool, node_refs: []const NodeRef, ref_starts: []const u32, live: *const std.DynamicBitSetUnmanaged, reached: *const std.DynamicBitSetUnmanaged) !void {
    const gpa = inc.gpa;
    const m = rp.m;
    const n_all = live.bit_length;
    var g: NewGraph = try .init(gpa, rp, nodes, final, write, node_refs, ref_starts, n_all);
    defer g.deinit(gpa);
    var seen = try std.DynamicBitSetUnmanaged.initEmpty(gpa, n_all);
    defer seen.deinit(gpa);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);
    var next: std.ArrayList(u32) = .empty;
    defer next.deinit(gpa);
    for (rp.roots.items) |n| if (!seen.isSet(n)) {
        seen.set(n);
        try stack.append(gpa, n);
    };
    while (stack.pop()) |x| {
        try g.next(gpa, x, &next);
        for (next.items) |t| if (!seen.isSet(t) and !g.isDead(t)) {
            seen.set(t);
            try stack.append(gpa, t);
        };
    }
    var differ: [4]usize = @splat(0);
    for (0..n_all) |i_usize| {
        const i: u32 = @intCast(i_usize);
        const ni = g.written_at[i];
        const has_atoms = if (ni != NewGraph.none) nodes[ni].atoms.len != 0 else i < m.nodeCount() and m.atoms(i).len != 0;
        const full = seen.isSet(i);
        for ([_]bool{ false, true }) |linked| {
            if (linked and !has_atoms) continue;
            const ours = if (linked) live.isSet(i) else reached.isSet(i);
            if (ours == full) continue;
            const k = @as(usize, @intFromBool(linked)) * 2 + @intFromBool(full);
            differ[k] += 1;
            if (differ[k] > 5) continue;
            const tag: Tag = std.enums.fromInt(Tag, if (ni != NewGraph.none) @backingInt(nodes[ni].tag) else m.node(i).tag) orelse .link;
            std.debug.print("cache check: {t} node {d} is {s} {s} but a full walk {s} it ({s}, {t})\n", .{
                tag,                                            i,                                               if (linked) "linked" else "flagged reached", if (ours) "" else "not", if (full) "reaches" else "does not reach",
                if (ni != NewGraph.none) "written" else "kept", if (i < rp.state.len) rp.state[i] else .unknown,
            });
        }
    }
    std.debug.print("cache check: lazy reach: flagged reached {d} extra, {d} missed; linked {d} extra, {d} missed\n", .{ differ[0], differ[1], differ[2], differ[3] });
    if (differ[0] + differ[1] + differ[2] + differ[3] != 0) inc.check_failed.store(true, .monotonic);
}

/// Sets the `reached` flag of the nodes a walk from the roots reaches.
/// With `check` (`BS_CACHE_CHECK`), also reports nodes with atoms that
/// it does not reach, and functions without atoms that it does, and
/// returns whether every node with atoms is reached.
fn markReached(gpa: Allocator, r: *const Recorder, roots: []const u32, b: *Manifest.Builder, check: bool) !bool {
    const nodes = r.nodes.items;
    var seen = try std.DynamicBitSetUnmanaged.initEmpty(gpa, nodes.len);
    defer seen.deinit(gpa);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);
    var next: std.ArrayList(u32) = .empty;
    defer next.deinit(gpa);
    const link = r.map.get(cache.hash(2, &.{@backingInt(Tag.link)}));
    try stack.appendSlice(gpa, roots);
    if (link) |n| try stack.append(gpa, n);
    for (stack.items) |n| seen.set(n);
    while (stack.pop()) |n| {
        next.clearRetainingCapacity();
        const range = b.ref_ranges.items[n];
        try reachNext(nodes[n].deps, b.refs.items[range[0]..][0..range[1]], &next, gpa);
        for (next.items) |d| if (!seen.isSet(d)) {
            seen.set(d);
            try stack.append(gpa, d);
        };
    }
    for (b.nodes.items, 0..) |*n, i| n.flags.reached = seen.isSet(i);
    if (!check) return true;
    var with_atoms: usize = 0;
    var missed: usize = 0;
    var extra: usize = 0;
    for (nodes, 0..) |n, i| {
        const reached = seen.isSet(i);
        if (n.atoms.len != 0) with_atoms += 1;
        const what: []const u8 = if (n.atoms.len != 0 and !reached) "is not reached" else if (n.atoms.len == 0 and reached and n.tag == .func) "is reached but has no atoms" else continue;
        if (n.atoms.len != 0) missed += 1 else extra += 1;
        if (missed + extra > 10) continue;
        var name: std.Io.Writer.Allocating = .init(gpa);
        defer name.deinit();
        for (r.unit_list.items, r.unit_info) |u, info| if (info.key == n.key) {
            r.zcu.unitKey(u, &name.writer) catch {};
            break;
        };
        std.debug.print("cache check: {t} node {s} {s}\n", .{ n.tag, name.written(), what });
    }
    std.debug.print("cache check: reach finds {d} of {d} nodes with atoms, and {d} functions without\n", .{ with_atoms - missed, with_atoms, extra });
    return missed == 0;
}

/// `BS_CACHE_CHECK`: decodes every encoded result from its words alone,
/// rebuilding each item from its key rather than finding it by hash, and
/// checks that it is this build's result: the same InternPool indices, and
/// the same scalars. That is what an edit build relies on when it loads a
/// green unit. The decoder only finds container types, functions, and
/// declarations here (`results.Lookup`); creating them is replay's.
fn checkResults(gpa: Allocator, zcu: *Zcu, r: *const Recorder, enc: *const results.Encoder, words: []const u32, result_of: []const Encoded.Ranges, unencodable: usize) bool {
    const ip = &zcu.ip;
    var d = results.Decoder(results.Lookup).init(gpa, ip, .{ .base_words = enc.words.items, .base_starts = enc.starts.items }, .{ .zcu = zcu }) catch return false;
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
            .func_body, .func_ies, .func_inline => |func| .{ .func = func },
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

/// `BS_CACHE_VERIFY=full`: whether this full build's nodes are those of
/// the edit build that wrote `prev`: the same nodes with the same results,
/// source hashes, dependencies, references and atom records. (Not the
/// output's bytes: the link lays atoms out in analysis order, which an
/// edit build changes.) Prints the differences.
fn verifyNodes(inc: *Incremental, r: *const Recorder, b: *const Manifest.Builder, emit: *const Emit, debug_of: []const ?*const Atom.Debug) !bool {
    const gpa = inc.gpa;
    const m = if (inc.prev) |*m| m else return true;
    // The child of `BS_CACHE_VERIFY=1` runs once the edit build wrote
    // its manifest, so every input is as the manifest has it. Set by
    // hand after an edit, `full` would compare with the build before it.
    {
        var changed: std.ArrayList(u32) = .empty;
        defer changed.deinit(gpa);
        try m.changedInputs(gpa, inc.io, &changed);
        for (changed.items) |i| {
            if (try inc.sameContents(m, i)) continue;
            _, const path = m.input(i);
            std.debug.print("cache verify: {s} changed since the last build; BS_CACHE_VERIFY=full only compares a full build with a manifest of the same inputs (set BS_CACHE_VERIFY=1 to verify an edit build)\n", .{path});
            return false;
        }
    }
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
                    .func_body, .func_ies, .func_inline => |f| z.unitKey(.{ .func = f }, w) catch {},
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
                .func, .nav, .effects, .root, .defaults => rec.nodes.items[ref.value].key,
                .ext, .ext_weak, .rt, .import => cache.hash(0, bb.strings.items[bb.ref_names.items[ref.value].off..][0..bb.ref_names.items[ref.value].len]),
                .err, .error_names, .analyze, .quota => ref.value,
            } };
        }
        fn prevRefKey(mm: *const Manifest, ref: Manifest.Ref) [2]Hash {
            return .{ @backingInt(ref.kind), switch (ref.kind) {
                .func, .nav, .effects, .root, .defaults => mm.node(ref.value).key,
                .ext, .ext_weak, .rt, .import => cache.hash(0, mm.refName(ref.value)),
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
                .nav_ty, .func_body, .func_ies, .func_inline, .namespace_name, .namespace, .embed_file => true,
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
        if (m.flags(pi).stale) V.report(r, ni, n, "left undecided", &differ);
        if (n.atoms.len != 0 and m.flags(pi).unlinked) V.report(r, ni, n, "not linked", &differ);
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
        // and so its quota, depends on analysis order, as upstream's. Not
        // `effects` either: a memoized comptime call notes the containers
        // it evaluated only for its first caller, so which units have
        // them depends on order too (`checkReach` checks that each build's
        // reach links its atoms).
        for (b.refs.items[range[0]..][0..range[1]]) |ref| if (ref.kind != .quota and ref.kind != .effects) try mine.append(gpa, V.refKey(b, r, ref));
        for (m.nodeRefs(pi)) |ref| if (ref.kind != .quota and ref.kind != .effects) try theirs.append(gpa, V.prevRefKey(m, ref));
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
        // Symbol names, which the manifest keeps and an edit build may
        // have renamed without touching the records.
        const prev_names = m.atomNames(pi);
        for (n.atoms, 0..) |ai, k| if (!std.mem.eql(u8, emit.atoms.items[ai].name, prev_names.name(k)) or
            named(&r.zcu.ip, emit, ai, .{ .key = 0, .targets = &.{} }).parent != prev_names.names[k].parentHash())
        {
            V.report(r, ni, n, "different atom name", &differ);
            if (differ <= 20) std.debug.print("cache verify:   full build {s}\ncache verify:   edit build {s}\n", .{ emit.atoms.items[ai].name, prev_names.name(k) });
            break;
        };
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
        // A lazy edit build keeps the nodes it no longer reaches; only
        // linking them would differ.
        if (m.atoms(@intCast(pi)).len == 0 or m.flags(@intCast(pi)).unlinked) continue;
        differ += 1;
        if (differ <= 20) std.debug.print("cache verify: node {x} (kind {d}): only in the edit build\n", .{ pn.key, pn.tag });
    }
    std.debug.print("cache verify: {d} nodes compared with the edit build's, {d} differ\n", .{ r.nodes.items.len, differ });
    return differ == 0;
}

/// `s` with atom `ai`'s symbol name, which the manifest keeps
/// (`Manifest.AtomName`).
fn named(ip: *const InternPool, emit: *const Emit, ai: usize, s: Manifest.AtomSymbols) Manifest.AtomSymbols {
    var out = s;
    out.name = emit.atoms.items[ai].name;
    const an = emit.atom_names.items[ai];
    if (an.parent != .none) {
        out.parent = ip.stableHash(an.parent);
        out.prefix_len = an.prefix_len;
    }
    return out;
}

fn contentsHash(a: *const Atom) Hash {
    const unwind = @as(u64, a.unwind.probes) << 40 | @as(u64, a.unwind.epilogue) << 24 | @as(u64, @backingInt(a.unwind.kind)) << 16 | a.unwind.saved;
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
