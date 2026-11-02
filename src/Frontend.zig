//! Source to ZIR. Loads the root file, parses it with `std.zig.Ast`, lowers it
//! with `std.zig.AstGen`, and follows its `@import`s until every reachable
//! file has ZIR. Like upstream, this happens eagerly for all reachable files;
//! semantic analysis later touches only what it references.
//!
//! Files are lowered in parallel from a work queue: lowering a file reveals
//! its imports, which become new work. With a cache (`enableCache`), ZIR is
//! stored on disk per file, named by the hash of the file's contents, and a
//! per-cache-directory stat index maps each path to the content hash it had
//! at a given (inode, size, mtime). A file whose stat matches is neither read
//! nor hashed; its ZIR is mapped from the cache. Sources and syntax trees are
//! not kept; they are reloaded on demand (`tree`, `source`) to render errors.
//!
//! Files live in one flat table indexed by `File.Index` so that later stages
//! (Sema, the on-disk cache) can refer to them by a stable u32. Indices are
//! assigned in breadth-first import order from the root file, independent of
//! which thread lowered what.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const Zir = std.zig.Zir;
const AstGen = std.zig.AstGen;
const assert = std.debug.assert;

const Frontend = @This();

gpa: Allocator,
io: Io,
/// Directory containing `std/std.zig` for the pinned Zig release.
zig_lib_dir: []const u8,
/// On-disk ZIR caches, indexed by `Module.cache`. Null entries (the default)
/// keep everything in memory.
caches: [2]?CacheDir = .{ null, null },
files: std.ArrayList(File) = .empty,
/// Maps `"<module index>:<sub_path>"` to its file.
file_map: std.StringHashMapUnmanaged(File.Index) = .empty,
modules: std.ArrayList(Module) = .empty,
/// What the last `loadAll` did, for `ZAP_FRONTEND_TIMING`.
stats: Stats = .{},

pub const Module = struct {
    /// Name used in `@import("name")`.
    name: []const u8,
    /// Directory that the module's root file and its relative imports live in.
    root_dir: []const u8,
    /// Root file path, relative to `root_dir`.
    root_file: []const u8,
    /// `root_dir` made absolute, for cache index keys. Set by `enableCache`.
    abs_root_dir: ?[:0]const u8 = null,
    /// Which of `caches` holds this module's ZIR: std's files are shared by
    /// every project through the global cache.
    cache: CacheKind,

    pub const Index = enum(u32) {
        root,
        std,
        _,
    };
};

pub const CacheKind = enum(u1) { local, global };

pub const File = struct {
    module: Module.Index,
    /// Path relative to the module's `root_dir`.
    sub_path: []const u8,
    /// Path shown in diagnostics.
    display_path: []const u8,
    zir: Zir,
    /// Hash of the source `zir` was lowered from.
    content_hash: Hash,
    /// Set when `zir` points into a mapped cache file rather than `gpa` memory.
    mapping: ?Io.File.MemoryMap,
    /// Source and syntax tree, loaded on first use by `Frontend.tree` and
    /// `Frontend.source`.
    syntax: ?Syntax,
    syntax_mutex: Io.Mutex = .init,

    pub const Index = enum(u32) { _ };
};

pub const Syntax = struct {
    source: [:0]const u8,
    tree: Ast,
};

pub const Hash = [16]u8;

pub const Stats = struct {
    files: u32 = 0,
    /// Stat matched the index; the source was not read.
    stat_hits: u32 = 0,
    /// Read and hashed, but ZIR for that content was already cached.
    content_hits: u32 = 0,
    /// Parsed and lowered.
    lowered: u32 = 0,
    /// Loaded as a guessed import of an edited file but not imported by it.
    guessed: u32 = 0,
    threads: u32 = 0,
    /// Wall time of `enableCache` (opening caches, reading their indexes),
    /// of `loadAll`, and of the part of `loadAll` after the work queue
    /// drained (numbering, error messages, index writes).
    open_ns: u64 = 0,
    load_ns: u64 = 0,
    finish_ns: u64 = 0,
};

pub fn init(gpa: Allocator, io: Io, zig_lib_dir: []const u8, root_src_path: []const u8) !Frontend {
    var fe: Frontend = .{ .gpa = gpa, .io = io, .zig_lib_dir = zig_lib_dir };
    errdefer fe.deinit();
    const root_dir = std.fs.path.dirname(root_src_path) orelse ".";
    try fe.modules.append(gpa, .{
        .name = "root",
        .root_dir = try gpa.dupe(u8, root_dir),
        .root_file = try gpa.dupe(u8, std.fs.path.basename(root_src_path)),
        .cache = .local,
    });
    try fe.modules.append(gpa, .{
        .name = "std",
        .root_dir = try std.fs.path.join(gpa, &.{ zig_lib_dir, "std" }),
        .root_file = try gpa.dupe(u8, "std.zig"),
        .cache = .global,
    });
    return fe;
}

pub fn deinit(fe: *Frontend) void {
    const gpa = fe.gpa;
    for (fe.files.items) |*f| freeFile(gpa, fe.io, f);
    fe.files.deinit(gpa);
    var it = fe.file_map.keyIterator();
    while (it.next()) |key| gpa.free(key.*);
    fe.file_map.deinit(gpa);
    for (fe.modules.items) |m| {
        gpa.free(m.root_dir);
        gpa.free(m.root_file);
        if (m.abs_root_dir) |p| gpa.free(p);
    }
    fe.modules.deinit(gpa);
    for (&fe.caches) |*c| if (c.*) |*cd| cd.deinit(gpa, fe.io);
}

fn freeFile(gpa: Allocator, io: Io, f: *File) void {
    if (f.mapping) |*m| m.destroy(io) else f.zir.deinit(gpa);
    if (f.syntax) |*s| {
        s.tree.deinit(gpa);
        gpa.free(s.source);
    }
    gpa.free(f.sub_path);
    gpa.free(f.display_path);
}

pub fn file(fe: *const Frontend, index: File.Index) *const File {
    return &fe.files.items[@backingInt(index)];
}

pub fn module(fe: *const Frontend, index: Module.Index) *const Module {
    return &fe.modules.items[@backingInt(index)];
}

/// The syntax tree of a file, read and parsed again on first use. For error
/// reporting; thread-safe.
pub fn tree(fe: *const Frontend, index: File.Index) Allocator.Error!*const Ast {
    return &(try fe.syntaxOf(index)).tree;
}

/// The source of a file, read again on first use. Thread-safe.
pub fn source(fe: *const Frontend, index: File.Index) Allocator.Error![:0]const u8 {
    return (try fe.syntaxOf(index)).source;
}

fn syntaxOf(fe: *const Frontend, index: File.Index) Allocator.Error!*const Syntax {
    const f = &fe.files.items[@backingInt(index)];
    f.syntax_mutex.lockUncancelable(fe.io);
    defer f.syntax_mutex.unlock(fe.io);
    if (f.syntax) |*s| return s;
    const src = Io.Dir.cwd().readFileAllocOptions(fe.io, f.display_path, fe.gpa, .unlimited, .of(u8), 0) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => fatalFile(f.display_path, err),
    };
    errdefer fe.gpa.free(src);
    // Spans into a different source than the ZIR came from would be wrong.
    if (!std.mem.eql(u8, &hashSource(src), &f.content_hash))
        std.process.fatal("'{s}' changed during compilation", .{f.display_path});
    f.syntax = .{ .source = src, .tree = try Ast.parse(fe.gpa, src, .{ .mode = .zig }) };
    return &f.syntax.?;
}

// ---------------------------------------------------------------------------
// Cache directories

/// The local and global cache directories of a compilation.
pub const CacheDirs = struct {
    local: []const u8,
    global: []const u8,
};

/// Resolves cache directories like `zig build-exe`: `--global-cache-dir`,
/// else `ZIG_GLOBAL_CACHE_DIR`, else `$XDG_CACHE_HOME/zig` or
/// `~/.cache/zig`; `--cache-dir`, else `ZIG_LOCAL_CACHE_DIR`, else the
/// `.zig-cache` next to the nearest `build.zig` above the working directory,
/// else (and always for `zig run`) the global cache. zap's files live in a
/// `zap/` subdirectory of each, apart from upstream's.
pub fn resolveCacheDirs(
    arena: Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    overrides: struct { local: ?[]const u8 = null, global: ?[]const u8 = null, local_is_global: bool = false },
) CacheDirs {
    const global = overrides.global orelse std.zig.resolveGlobalCacheDir(arena, environ_map) catch |err|
        std.process.fatal("unable to resolve zig cache directory: {t}", .{err});
    const local = overrides.local orelse std.zig.EnvVar.ZIG_LOCAL_CACHE_DIR.get(environ_map) orelse local: {
        if (overrides.local_is_global) break :local global;
        const cwd = std.zig.getResolvedCwd(io, arena) catch |err|
            std.process.fatal("unable to get the working directory: {t}", .{err});
        break :local std.zig.resolveSuitableLocalCacheDir(arena, io, cwd) catch |err|
            std.process.fatal("unable to resolve zig cache directory: {t}", .{err}) orelse global;
    };
    return .{ .local = local, .global = global };
}

/// Makes `loadAll` read and write ZIR in `dirs`. Call before `loadAll`.
pub fn enableCache(fe: *Frontend, dirs: CacheDirs) !void {
    const gpa = fe.gpa;
    const start = Io.Clock.awake.now(fe.io);
    defer fe.stats.open_ns = @intCast(start.durationTo(Io.Clock.awake.now(fe.io)).toNanoseconds());
    fe.caches[@backingInt(CacheKind.local)] = try .open(gpa, fe.io, dirs.local);
    if (!std.mem.eql(u8, dirs.local, dirs.global))
        fe.caches[@backingInt(CacheKind.global)] = try .open(gpa, fe.io, dirs.global);
    for (fe.modules.items) |*m| {
        m.abs_root_dir = Io.Dir.cwd().realPathFileAlloc(fe.io, m.root_dir, gpa) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // The root file's load will report it.
            else => try gpa.dupeSentinel(u8, m.root_dir, 0),
        };
    }
}

fn cacheFor(fe: *Frontend, mod: *const Module) ?*CacheDir {
    if (fe.caches[@backingInt(mod.cache)]) |*cd| return cd;
    if (fe.caches[@backingInt(CacheKind.local)]) |*cd| return cd;
    return null;
}

/// Cache layout, in `<cache dir>/zap/zir/`:
/// - `<32 hex digits>`: the ZIR of one source text, named by `hashSource`.
///   Written once to a temporary file and linked into place; never changed.
/// - `index`: `IndexHeader` then `IndexEntry`s sorted by `path_hash`.
///   Rewritten through a temporary file when a build learns new stats.
const CacheDir = struct {
    dir: Io.Dir,
    /// Entries loaded at `open`, sorted by `path_hash`; they point into
    /// `index_bytes`, the whole index file.
    index: []const IndexEntry,
    index_bytes: []align(@alignOf(IndexEntry)) u8,

    const sub_path = "zap" ++ std.fs.path.sep_str ++ "zir";

    fn open(gpa: Allocator, io: Io, path: []const u8) !CacheDir {
        const full = try std.fs.path.join(gpa, &.{ path, sub_path });
        defer gpa.free(full);
        const dir = Io.Dir.cwd().openDir(io, full, .{}) catch |err| switch (err) {
            error.FileNotFound => Io.Dir.cwd().createDirPathOpen(io, full, .{}) catch |e|
                std.process.fatal("unable to create cache directory '{s}': {t}", .{ full, e }),
            else => std.process.fatal("unable to open cache directory '{s}': {t}", .{ full, err }),
        };
        var cd: CacheDir = .{ .dir = dir, .index = &.{}, .index_bytes = &.{} };
        cd.loadIndex(gpa, io) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // Missing or unreadable: every file is rehashed and the index rewritten.
            else => {},
        };
        return cd;
    }

    fn deinit(cd: *CacheDir, gpa: Allocator, io: Io) void {
        gpa.free(cd.index_bytes);
        cd.dir.close(io);
    }

    fn loadIndex(cd: *CacheDir, gpa: Allocator, io: Io) !void {
        const bytes = try cd.dir.readFileAllocOptions(io, "index", gpa, .unlimited, .of(IndexEntry), null);
        errdefer gpa.free(bytes);
        if (bytes.len < @sizeOf(IndexHeader)) return error.CorruptCache;
        const header: *const IndexHeader = @ptrCast(bytes.ptr);
        if (!std.mem.eql(u8, &header.magic, &index_magic) or
            bytes.len != @sizeOf(IndexHeader) + header.len * @sizeOf(IndexEntry)) return error.CorruptCache;
        cd.index = @ptrCast(@alignCast(bytes[@sizeOf(IndexHeader)..]));
        cd.index_bytes = bytes;
    }

    fn lookup(cd: *const CacheDir, path_hash: u64) ?*const IndexEntry {
        const i = std.sort.binarySearch(IndexEntry, cd.index, path_hash, IndexEntry.order) orelse return null;
        return &cd.index[i];
    }

    /// Writes the index merged with `updates` (sorted by `path_hash`, no
    /// duplicates). Concurrent builds race benignly: the last rename wins and
    /// the loser's entries are relearned by hashing.
    fn writeIndex(cd: *const CacheDir, gpa: Allocator, io: Io, updates: []const IndexEntry) !void {
        var merged: std.ArrayList(IndexEntry) = try .initCapacity(gpa, cd.index.len + updates.len);
        defer merged.deinit(gpa);
        var i: usize = 0;
        var j: usize = 0;
        while (i < cd.index.len or j < updates.len) {
            if (j == updates.len or (i < cd.index.len and cd.index[i].path_hash < updates[j].path_hash)) {
                merged.appendAssumeCapacity(cd.index[i]);
                i += 1;
            } else {
                if (i < cd.index.len and cd.index[i].path_hash == updates[j].path_hash) i += 1;
                merged.appendAssumeCapacity(updates[j]);
                j += 1;
            }
        }
        const header: IndexHeader = .{ .len = merged.items.len };
        var af = try cd.dir.createFileAtomic(io, "index", .{ .replace = true });
        defer af.deinit(io);
        var w = af.file.writerStreaming(io, &.{});
        var vecs = [_][]const u8{ @ptrCast((&header)[0..1]), @ptrCast(merged.items) };
        w.interface.writeVecAll(&vecs) catch return w.err.?;
        w.interface.flush() catch return w.err.?;
        try af.replace(io);
    }

    /// Maps the cached ZIR for `hash`, or fails if there is none. The header
    /// and summary are read into `buf` rather than through the mapping, so
    /// the frontend faults in no page of it; the returned summary's names
    /// point into `buf`.
    fn loadZir(cd: *const CacheDir, gpa: Allocator, io: Io, hash: Hash, buf: *std.ArrayList(u8)) !struct { Zir, ?Io.File.MemoryMap, Summary } {
        const name = std.fmt.bytesToHex(hash, .lower);
        const f = try cd.dir.openFile(io, &name, .{});
        defer f.close(io);
        const header, const layout, const summary = try readSummary(f, gpa, io, buf);
        const len = try f.length(io);
        if (layout.total != len) return error.CorruptCache;
        var mm: Io.File.MemoryMap = try .create(io, f, .{
            .len = @intCast(len),
            .protection = .{ .read = true },
            .populate = false,
        });
        errdefer mm.destroy(io);
        const bytes = mm.memory;
        const n = header.instructions_len;
        const extra: []u32 = @ptrCast(@alignCast(bytes[layout.extra..layout.strings]));
        const string_bytes = bytes[layout.strings..layout.total];
        if (data_has_safety_tag) {
            // The in-memory `Data` union carries a safety tag the file omits.
            var insts: std.MultiArrayList(Zir.Inst) = .empty;
            try insts.resize(gpa, n);
            errdefer insts.deinit(gpa);
            const tags = insts.items(.tag);
            @memcpy(@as([]u8, @ptrCast(tags)), bytes[layout.tags..][0..n]);
            const raw: []const [8]u8 = @ptrCast(@alignCast(bytes[layout.data..layout.extra]));
            for (insts.items(.data), raw, tags) |*data, r, tag| {
                const hack: *HackDataLayout = @ptrCast(data);
                hack.* = .{ .data = r, .safety_tag = @backingInt(Zir.Inst.Tag.data_tags[@backingInt(tag)]) };
            }
            const extra_copy = try gpa.dupe(u32, extra);
            errdefer gpa.free(extra_copy);
            const strings_copy = try gpa.dupe(u8, string_bytes);
            mm.destroy(io);
            return .{ .{ .instructions = insts.toOwnedSlice(), .extra = extra_copy, .string_bytes = strings_copy }, null, summary };
        }
        var insts: std.MultiArrayList(Zir.Inst).Slice = .{ .ptrs = undefined, .len = n, .capacity = n };
        insts.ptrs[@backingInt(std.MultiArrayList(Zir.Inst).Field.tag)] = bytes.ptr + layout.tags;
        insts.ptrs[@backingInt(std.MultiArrayList(Zir.Inst).Field.data)] = bytes.ptr + layout.data;
        return .{ .{ .instructions = insts, .extra = extra, .string_bytes = string_bytes }, mm, summary };
    }

    /// The summary of the cached ZIR for `hash`, read into `buf`.
    fn loadSummary(cd: *const CacheDir, gpa: Allocator, io: Io, hash: Hash, buf: *std.ArrayList(u8)) !Summary {
        const name = std.fmt.bytesToHex(hash, .lower);
        const f = try cd.dir.openFile(io, &name, .{});
        defer f.close(io);
        _, _, const summary = try readSummary(f, gpa, io, buf);
        return summary;
    }

    fn readSummary(f: Io.File, gpa: Allocator, io: Io, buf: *std.ArrayList(u8)) !struct { BlobHeader, BlobLayout, Summary } {
        try buf.resize(gpa, @max(buf.capacity, 4096));
        buf.items.len = try f.readPositionalAll(io, buf.items, 0);
        if (buf.items.len < @sizeOf(BlobHeader)) return error.CorruptCache;
        const header = std.mem.bytesToValue(BlobHeader, buf.items[0..@sizeOf(BlobHeader)]);
        if (!std.mem.eql(u8, &header.magic, &blob_magic)) return error.CorruptCache;
        const layout = BlobLayout.of(header);
        if (buf.items.len < layout.tags) {
            const have = buf.items.len;
            try buf.resize(gpa, layout.tags);
            if (try f.readPositionalAll(io, buf.items[have..], have) != layout.tags - have) return error.CorruptCache;
        }
        return .{ header, layout, .{
            .has_errors = header.flags.has_errors,
            .names = buf.items[layout.summary..][0..header.summary_len],
        } };
    }

    fn saveZir(cd: *const CacheDir, gpa: Allocator, io: Io, hash: Hash, zir: *const Zir, summary: Summary) !void {
        const n = zir.instructions.len;
        const header: BlobHeader = .{
            .instructions_len = @intCast(n),
            .string_bytes_len = @intCast(zir.string_bytes.len),
            .extra_len = @intCast(zir.extra.len),
            .summary_len = @intCast(summary.names.len),
            .flags = .{ .has_errors = summary.has_errors },
        };
        const layout = BlobLayout.of(header);
        const data_bytes: []const u8 = if (data_has_safety_tag) data: {
            const raw = try gpa.alloc([8]u8, n);
            for (raw, zir.instructions.items(.data)) |*r, *data| r.* = @as(*const HackDataLayout, @ptrCast(data)).data;
            break :data @ptrCast(raw);
        } else @ptrCast(zir.instructions.items(.data));
        defer if (data_has_safety_tag) gpa.free(data_bytes);
        const padding: [8]u8 = @splat(0);

        const name = std.fmt.bytesToHex(hash, .lower);
        var af = try cd.dir.createFileAtomic(io, &name, .{});
        defer af.deinit(io);
        var w = af.file.writerStreaming(io, &.{});
        var vecs = [_][]const u8{
            @ptrCast((&header)[0..1]),
            summary.names,
            padding[0 .. layout.tags - layout.summary - summary.names.len],
            @ptrCast(zir.instructions.items(.tag)),
            padding[0 .. layout.data - layout.tags - n],
            data_bytes,
            @ptrCast(zir.extra),
            zir.string_bytes,
        };
        w.interface.writeVecAll(&vecs) catch return w.err.?;
        w.interface.flush() catch return w.err.?;
        af.link(io) catch |err| switch (err) {
            // Another build wrote the same content.
            error.PathAlreadyExists => {},
            else => |e| return e,
        };
    }
};

const index_magic = "ZAPZIX01".*;
const blob_magic = "ZAPZIR01".*;

const IndexHeader = extern struct {
    magic: [8]u8 = index_magic,
    len: u64,
};

const IndexEntry = extern struct {
    /// Wyhash of the absolute module root, "/", and the module-relative path.
    path_hash: u64,
    inode: u64,
    size: u64,
    /// Nanoseconds, or `racy_mtime` when the file was too new to trust.
    mtime: i64,
    content_hash: Hash,

    /// A file changed within the timestamp granularity of its last read
    /// could change again without changing its mtime, so its entry is
    /// stored with this mtime and is rehashed by the next build.
    const racy_mtime = std.math.minInt(i64);
    const racy_window_ns = 2 * std.time.ns_per_s;

    fn order(path_hash: u64, e: IndexEntry) std.math.Order {
        return std.math.order(path_hash, e.path_hash);
    }

    fn matches(e: IndexEntry, stat: Io.File.Stat) bool {
        return e.mtime != racy_mtime and e.inode == stat.inode and e.size == stat.size and
            e.mtime == stat.mtime.toNanoseconds();
    }
};

/// The ZIR file format: the header, the `Summary` names, padding to 8, then
/// `Zir.Inst.Tag`s, padding to 8, `Zir.Inst.Data` without its safety tag
/// (8 bytes each), `extra`, and `string_bytes`. Everything is at its natural
/// alignment so a mapped file is used in place.
const BlobHeader = extern struct {
    magic: [8]u8 = blob_magic,
    instructions_len: u32,
    string_bytes_len: u32,
    extra_len: u32,
    summary_len: u32,
    flags: packed struct(u32) { has_errors: bool, unused: u31 = 0 },
    unused: u32 = 0,
};

/// What `loadAll` needs from a file's ZIR: whether it has AstGen errors and
/// the names it imports, each followed by a 0 byte. Stored next to the
/// cached ZIR so a warm build reads it without touching the ZIR.
const Summary = struct {
    has_errors: bool,
    names: []const u8,

    fn of(arena: Allocator, zir: *const Zir) !Summary {
        const has_errors = zir.extra[@backingInt(Zir.ExtraIndex.compile_errors)] != 0;
        if (zir.loweringFailed()) return .{ .has_errors = has_errors, .names = "" };
        const imports_index = zir.extra[@backingInt(Zir.ExtraIndex.imports)];
        if (imports_index == 0) return .{ .has_errors = has_errors, .names = "" };
        const header = zir.extraData(Zir.Inst.Imports, imports_index);
        var names: std.ArrayList(u8) = .empty;
        var extra_index = header.end;
        for (0..header.data.imports_len) |_| {
            const item = zir.extraData(Zir.Inst.Imports.Item, extra_index);
            extra_index = item.end;
            try names.appendSlice(arena, zir.nullTerminatedString(item.data.name));
            try names.append(arena, 0);
        }
        return .{ .has_errors = has_errors, .names = names.items };
    }
};

const BlobLayout = struct {
    summary: usize,
    tags: usize,
    data: usize,
    extra: usize,
    strings: usize,
    total: usize,

    fn of(h: BlobHeader) BlobLayout {
        const summary = @sizeOf(BlobHeader);
        const tags = std.mem.alignForward(usize, summary + h.summary_len, 8);
        const data = std.mem.alignForward(usize, tags + h.instructions_len, 8);
        const extra = data + 8 * @as(usize, h.instructions_len);
        const strings = extra + 4 * @as(usize, h.extra_len);
        return .{ .summary = summary, .tags = tags, .data = data, .extra = extra, .strings = strings, .total = strings + h.string_bytes_len };
    }
};

// Copied from upstream `src/Zcu.zig` (Copyright (c) Zig contributors, MIT).
const data_has_safety_tag = @sizeOf(Zir.Inst.Data) != 8;
const HackDataLayout = extern struct {
    data: [8]u8 align(@alignOf(Zir.Inst.Data)),
    safety_tag: u8,
};
comptime {
    if (data_has_safety_tag) assert(@sizeOf(HackDataLayout) == @sizeOf(Zir.Inst.Data));
}

/// Names cached ZIR: two seeded Wyhash passes, salted with the Zig version
/// whose AstGen produced it. Not cryptographic; twice as fast as Blake3,
/// which took 5% of a cold build's CPU time.
fn hashSource(src: []const u8) Hash {
    const salt = comptime std.hash.Wyhash.hash(0, "zap zir " ++ builtin.zig_version_string);
    const lo = std.hash.Wyhash.hash(salt, src);
    const hi = std.hash.Wyhash.hash(salt ^ 0x9e3779b97f4a7c15, src);
    return @bitCast([2]u64{ lo, hi });
}

// ---------------------------------------------------------------------------
// Loading

/// One discovered file while `loadAll` runs.
const Job = struct {
    file: File,
    loaded: bool = false,
    how: enum { stat_hit, content_hit, lowered } = .lowered,
    has_errors: bool = false,
    /// Why the file could not be read. Only fatal if the file turns out to
    /// be reachable: speculative imports (see `Outcome`) may name files that
    /// no longer exist.
    missing: ?anyerror = null,
    /// From the probe, taken before the source is read: if the file changes
    /// in between, its index entry is stale and the next build rehashes it.
    stat: ?Io.File.Stat = null,
    /// The files it imports, in import order.
    imports: []*Job = &.{},
    /// New stat index entry for the file's cache directory.
    index_update: ?IndexEntry = null,
    index: ?File.Index = null,
};

/// The work queue of `loadAll`. A new file is first *probed* (stat, index
/// lookup, map cached ZIR), which takes a few syscalls; files whose probe
/// misses are *lowered* (read, hash, parse, AstGen). The main thread
/// probes, because mapping files from several threads contends on the
/// process's address-space lock and made a warm build 3x slower. Probes run
/// breadth-first, so a changed file near the root is found early. Helper
/// threads lower, largest file first, and start one at a time when a file
/// needs lowering and no helper is idle. They probe only while the main
/// thread is lowering a file itself.
const Loader = struct {
    fe: *Frontend,
    mutex: Io.Mutex = .init,
    main_cond: Io.Condition = .init,
    helper_cond: Io.Condition = .init,
    /// A FIFO: `probe.items[probe_head..]` are waiting.
    probe: std.ArrayList(*Job) = .empty,
    probe_head: usize = 0,
    lower: std.ArrayList(*Job) = .empty,
    /// Jobs taken off a queue and not finished yet.
    active: u32 = 0,
    helpers: u32 = 0,
    /// Helpers waiting for work that no signal has claimed yet.
    idle_helpers: u32 = 0,
    max_helpers: u32,
    /// The main thread is lowering a file, so helpers probe in its place.
    main_lowering: bool = false,
    /// Every job by `file_map` key. Owns the keys.
    jobs: std.StringHashMapUnmanaged(*Job) = .empty,
    failure: ?anyerror = null,
    /// Start of the build on the real clock, for `IndexEntry.racy_mtime`.
    start_ns: i96,
    group: Io.Group = .init,

    const Role = enum { main, helper };

    /// Frees the jobs and the files and keys that `loadAll` did not move
    /// into the frontend: all of them unless `moved`, else the unreachable ones.
    fn deinit(l: *Loader, moved: bool) void {
        const gpa = l.fe.gpa;
        var it = l.jobs.iterator();
        while (it.next()) |e| {
            const job = e.value_ptr.*;
            if (!moved or job.index == null) {
                if (job.loaded) freeFile(gpa, l.fe.io, &job.file) else {
                    gpa.free(job.file.sub_path);
                    gpa.free(job.file.display_path);
                }
                gpa.free(e.key_ptr.*);
            }
            gpa.free(job.imports);
            gpa.destroy(job);
        }
        l.jobs.deinit(gpa);
        l.probe.deinit(gpa);
        l.lower.deinit(gpa);
    }

    /// Returns the job for a file, creating and queueing it if it is new.
    /// Called with `mutex` held.
    fn getJob(l: *Loader, mod_index: Module.Index, sub_path: []const u8) !*Job {
        const fe = l.fe;
        const gpa = fe.gpa;
        const key = try std.fmt.allocPrint(gpa, "{d}:{s}", .{ @backingInt(mod_index), sub_path });
        const gop = l.jobs.getOrPut(gpa, key) catch |err| {
            gpa.free(key);
            return err;
        };
        if (gop.found_existing) {
            gpa.free(key);
            return gop.value_ptr.*;
        }
        errdefer {
            _ = l.jobs.remove(key);
            gpa.free(key);
        }
        const job = try gpa.create(Job);
        errdefer gpa.destroy(job);
        const owned_sub_path = try gpa.dupe(u8, sub_path);
        errdefer gpa.free(owned_sub_path);
        job.* = .{ .file = .{
            .module = mod_index,
            .sub_path = owned_sub_path,
            .display_path = try std.fs.path.join(gpa, &.{ fe.module(mod_index).root_dir, sub_path }),
            .zir = undefined,
            .content_hash = undefined,
            .mapping = null,
            .syntax = null,
        } };
        errdefer gpa.free(job.file.display_path);
        if (fe.cacheFor(fe.module(mod_index)) != null) {
            try l.probe.append(gpa, job);
            l.main_cond.signal(fe.io);
            if (l.main_lowering) _ = l.wakeHelper();
        } else try l.pushLower(job);
        gop.value_ptr.* = job;
        return job;
    }

    fn pushLower(l: *Loader, job: *Job) !void {
        try l.lower.append(l.fe.gpa, job);
        l.main_cond.signal(l.fe.io);
        if (!l.wakeHelper() and l.helpers < l.max_helpers) {
            l.group.concurrent(l.fe.io, work, .{ l, .helper }) catch return;
            l.helpers += 1;
        }
    }

    /// Wakes an idle helper, if there is one.
    fn wakeHelper(l: *Loader) bool {
        if (l.idle_helpers == 0) return false;
        l.idle_helpers -= 1;
        l.helper_cond.signal(l.fe.io);
        return true;
    }

    /// Called with `mutex` held.
    const Step = enum { probe, lower };

    fn take(l: *Loader, role: Role) ?struct { *Job, Step } {
        if (l.failure != null) return null;
        if ((role == .main or l.main_lowering) and l.probe_head < l.probe.items.len) {
            l.probe_head += 1;
            return .{ l.probe.items[l.probe_head - 1], .probe };
        }
        if (l.lower.items.len == 0) return null;
        var max: usize = 0;
        for (l.lower.items, 0..) |job, i| {
            if (size(job) > size(l.lower.items[max])) max = i;
        }
        return .{ l.lower.swapRemove(max), .lower };
    }

    fn work(l: *Loader, role: Role) void {
        const io = l.fe.io;
        // Parse trees and AstGen scratch reuse this memory from file to file.
        var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena.deinit();
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(l.fe.gpa);
        l.mutex.lockUncancelable(io);
        defer l.mutex.unlock(io);
        while (true) {
            if (l.take(role)) |taken| {
                const job, const step = taken;
                l.active += 1;
                if (role == .main and step == .lower) l.main_lowering = true;
                l.mutex.unlock(io);
                const result = l.run(job, step, &arena, &buf);
                _ = arena.reset(.retain_capacity);
                l.mutex.lockUncancelable(io);
                l.active -= 1;
                if (role == .main) l.main_lowering = false;
                l.finishJob(job, result) catch |err| {
                    if (l.failure == null) l.failure = err;
                };
                if (l.done()) {
                    l.main_cond.broadcast(io);
                    l.helper_cond.broadcast(io);
                }
                continue;
            }
            if (l.done()) return;
            switch (role) {
                .main => l.main_cond.waitUncancelable(io, &l.mutex),
                .helper => {
                    l.idle_helpers += 1;
                    l.helper_cond.waitUncancelable(io, &l.mutex);
                },
            }
        }
    }

    /// Returns the files `job` imports, or null if its probe missed.
    fn run(l: *Loader, job: *Job, step: Step, arena: *std.heap.ArenaAllocator, buf: *std.ArrayList(u8)) anyerror!Outcome {
        const summary = switch (step) {
            .probe => switch (try l.fe.probeFile(job, buf)) {
                .hit => |summary| summary,
                .miss => return .{ .imports = &.{}, .lower = true },
                .missing => return .{ .imports = &.{}, .lower = false },
                .changed => |old| return .{ .imports = try l.fe.collectImports(&job.file, old.names), .lower = true },
            },
            .lower => try l.fe.lowerFile(l, job, arena, buf),
        };
        job.has_errors = summary.has_errors;
        return .{ .imports = try l.fe.collectImports(&job.file, summary.names), .lower = false };
    }

    fn size(job: *const Job) u64 {
        return if (job.stat) |st| st.size else 0;
    }

    fn done(l: *const Loader) bool {
        return l.active == 0 and (l.failure != null or (l.probe_head == l.probe.items.len and l.lower.items.len == 0));
    }

    /// Queues the files `job` imports, or queues `job` for lowering if its
    /// probe missed. Called with `mutex` held.
    fn finishJob(l: *Loader, job: *Job, result: anyerror!Outcome) !void {
        const gpa = l.fe.gpa;
        const outcome = try result;
        const imports = outcome.imports;
        defer freeImports(gpa, imports);
        if (outcome.lower) {
            try l.pushLower(job);
            for (imports) |imp| _ = try l.getJob(imp.module, imp.sub_path);
            return;
        }
        job.imports = try gpa.alloc(*Job, imports.len);
        for (job.imports, imports) |*dst, imp| {
            dst.* = try l.getJob(imp.module, imp.sub_path);
        }
    }
};

const Import = struct { module: Module.Index, sub_path: []const u8 };

/// The result of one step of a job. When `lower` is set the job goes on to
/// be lowered, and `imports` are a guess: the imports of the file's
/// previous content, from its cached summary. Queueing them now lets their
/// probes overlap the lowering of an edited file. Guessed files that the
/// file does not import after all are dropped when files are numbered.
const Outcome = struct { imports: []Import, lower: bool };

fn freeImports(gpa: Allocator, imports: []const Import) void {
    for (imports) |imp| gpa.free(imp.sub_path);
    gpa.free(imports);
}

/// Loads, parses, and lowers the root file and every file reachable from it
/// through `@import`. Returns false and adds messages to `errors` if any file
/// failed to lower. Call once.
pub fn loadAll(fe: *Frontend, errors: *std.zig.ErrorBundle.Wip) !bool {
    const gpa = fe.gpa;
    const io = fe.io;
    const start = Io.Clock.awake.now(io);
    var l: Loader = .{
        .fe = fe,
        .start_ns = Io.Clock.real.now(io).toNanoseconds(),
        .max_helpers = @intCast(@max(std.Thread.getCpuCount() catch 1, 1) - 1),
    };
    var moved = false;
    defer l.deinit(moved);

    const root_job = try l.getJob(.root, fe.module(.root).root_file);
    l.work(.main);
    l.group.await(io) catch {};
    if (l.failure) |err| return err;
    const finish_start = Io.Clock.awake.now(io);

    // Number the files breadth-first in import order, as a serial load would.
    var stats = fe.stats;
    var order: std.ArrayList(*Job) = try .initCapacity(gpa, l.jobs.count());
    defer order.deinit(gpa);
    root_job.index = @fromBackingInt(0);
    order.appendAssumeCapacity(root_job);
    var i: usize = 0;
    while (i < order.items.len) : (i += 1) {
        const job = order.items[i];
        if (job.missing) |err| fatalFile(job.file.display_path, err);
        for (job.imports) |imp| {
            if (imp.index != null) continue;
            imp.index = @fromBackingInt(@intCast(order.items.len));
            order.appendAssumeCapacity(imp);
        }
    }
    stats.guessed = @intCast(l.jobs.count() - order.items.len);

    try fe.files.ensureTotalCapacityPrecise(gpa, order.items.len);
    try fe.file_map.ensureTotalCapacity(gpa, @intCast(order.items.len));
    stats.files = @intCast(order.items.len);
    stats.threads = l.helpers + 1;
    for (order.items) |job| {
        fe.files.appendAssumeCapacity(job.file);
        switch (job.how) {
            .stat_hit => stats.stat_hits += 1,
            .content_hit => stats.content_hits += 1,
            .lowered => stats.lowered += 1,
        }
    }
    var it = l.jobs.iterator();
    while (it.next()) |e| {
        const index = e.value_ptr.*.index orelse continue;
        fe.file_map.putAssumeCapacityNoClobber(e.key_ptr.*, index);
    }
    moved = true;

    var ok = true;
    for (fe.files.items, order.items, 0..) |*f, job, index| {
        // Not `f.zir.hasCompileErrors()`: that would fault in a page of every file.
        if (!job.has_errors) continue;
        const syntax = try fe.syntaxOf(@fromBackingInt(@intCast(index)));
        try errors.addZirErrorMessages(f.zir, syntax.tree, syntax.source, f.display_path);
        if (f.zir.loweringFailed()) ok = false;
    }

    // Record what this build learned about file stats.
    for (&fe.caches) |*slot| {
        const cd = if (slot.*) |*cd| cd else continue;
        var updates: std.ArrayList(IndexEntry) = .empty;
        defer updates.deinit(gpa);
        for (order.items) |job| {
            const update = job.index_update orelse continue;
            if (fe.cacheFor(fe.module(job.file.module)) == cd) try updates.append(gpa, update);
        }
        if (updates.items.len == 0) continue;
        std.mem.sortUnstable(IndexEntry, updates.items, {}, struct {
            fn lessThan(_: void, a: IndexEntry, b: IndexEntry) bool {
                return a.path_hash < b.path_hash;
            }
        }.lessThan);
        cd.writeIndex(gpa, io, updates.items) catch |err|
            std.log.warn("unable to write ZIR cache index: {t}", .{err});
    }

    const end = Io.Clock.awake.now(io);
    stats.load_ns = @intCast(start.durationTo(end).toNanoseconds());
    stats.finish_ns = @intCast(finish_start.durationTo(end).toNanoseconds());
    fe.stats = stats;
    return ok;
}

fn pathHash(mod: *const Module, sub_path: []const u8) u64 {
    var h: std.hash.Wyhash = .init(0);
    h.update(mod.abs_root_dir.?);
    h.update("/");
    h.update(sub_path);
    return h.final();
}

/// Maps a file's ZIR from the cache if the index says the file is unchanged.
/// Returns null if the file must be lowered.
fn probeFile(fe: *Frontend, job: *Job, buf: *std.ArrayList(u8)) !union(enum) {
    hit: Summary,
    miss,
    /// The file could not be stat'ed (`Job.missing`).
    missing,
    /// The file changed; this is the summary of its previous content.
    changed: Summary,
} {
    const f = &job.file;
    const mod = fe.module(f.module);
    const cd = fe.cacheFor(mod).?;
    const stat = Io.Dir.cwd().statFile(fe.io, f.display_path, .{}) catch |err| {
        job.missing = err;
        return .missing;
    };
    job.stat = stat;
    const entry = cd.lookup(pathHash(mod, f.sub_path)) orelse return .miss;
    if (!entry.matches(stat)) {
        return .{ .changed = cd.loadSummary(fe.gpa, fe.io, entry.content_hash, buf) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .miss,
        } };
    }
    f.zir, f.mapping, const summary = cd.loadZir(fe.gpa, fe.io, entry.content_hash, buf) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .miss,
    };
    f.content_hash = entry.content_hash;
    job.how = .stat_hit;
    job.loaded = true;
    return .{ .hit = summary };
}

/// Loads a file's ZIR by hashing its source and mapping the cached ZIR of
/// that content, or by lowering it. Temporaries live in `arena`, which the
/// caller resets.
fn lowerFile(fe: *Frontend, l: *Loader, job: *Job, arena_state: *std.heap.ArenaAllocator, buf: *std.ArrayList(u8)) !Summary {
    const gpa = fe.gpa;
    const io = fe.io;
    const arena = arena_state.allocator();
    const f = &job.file;
    const mod = fe.module(f.module);
    const cache = fe.cacheFor(mod);

    const src = Io.Dir.cwd().readFileAllocOptions(io, f.display_path, arena, .unlimited, .of(u8), 0) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            job.missing = err;
            return .{ .has_errors = false, .names = "" };
        },
    };
    f.content_hash = hashSource(src);
    if (cache) |cd| {
        const stat = job.stat.?;
        const mtime: i64 = @intCast(stat.mtime.toNanoseconds());
        job.index_update = .{
            .path_hash = pathHash(mod, f.sub_path),
            .inode = @intCast(stat.inode),
            .size = stat.size,
            .mtime = if (mtime >= l.start_ns - IndexEntry.racy_window_ns) IndexEntry.racy_mtime else mtime,
            .content_hash = f.content_hash,
        };
        if (cd.loadZir(gpa, io, f.content_hash, buf)) |loaded| {
            f.zir, f.mapping, const summary = loaded;
            job.how = .content_hit;
            job.loaded = true;
            return summary;
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        }
    }

    const ast = try Ast.parse(arena, src, .{ .mode = .zig });
    const zir = try AstGen.generate(arena, ast);
    const summary: Summary = try .of(arena, &zir);
    job.how = .lowered;
    if (cache) |cd| {
        if (cd.saveZir(gpa, io, f.content_hash, &zir, summary)) |_| {
            if (cd.loadZir(gpa, io, f.content_hash, buf)) |loaded| {
                f.zir, f.mapping, _ = loaded;
                job.loaded = true;
                return summary;
            } else |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {},
            }
        } else |err| std.log.warn("unable to cache ZIR of '{s}': {t}", .{ f.display_path, err });
    }
    // No cache to map it from: copy it out of the arena.
    var insts = try zir.instructions.toMultiArrayList().clone(gpa);
    errdefer insts.deinit(gpa);
    const extra = try gpa.dupe(u32, zir.extra);
    errdefer gpa.free(extra);
    f.zir = .{ .instructions = insts.toOwnedSlice(), .extra = extra, .string_bytes = try gpa.dupe(u8, zir.string_bytes) };
    f.mapping = null;
    job.loaded = true;
    return summary;
}

/// The files that `f`, which imports `names` (see `Summary`), makes the
/// frontend load: `.zig` paths, `std`, and `root`. `builtin` is generated
/// from the target by Sema's driver; unknown modules are reported by Sema
/// only if the import is actually analyzed, matching upstream.
fn collectImports(fe: *const Frontend, f: *const File, names: []const u8) ![]Import {
    const gpa = fe.gpa;
    var list: std.ArrayList(Import) = .empty;
    errdefer freeImports(gpa, list.items);
    var it = std.mem.tokenizeScalar(u8, names, 0);
    while (it.next()) |name| {
        try list.ensureUnusedCapacity(gpa, 1);
        const imp: Import = if (std.mem.endsWith(u8, name, ".zig")) .{
            .module = f.module,
            .sub_path = try std.fs.path.resolvePosix(gpa, &.{ std.fs.path.dirname(f.sub_path) orelse "", name }),
        } else if (std.mem.eql(u8, name, "std"))
            .{ .module = .std, .sub_path = try gpa.dupe(u8, fe.module(.std).root_file) }
        else if (std.mem.eql(u8, name, "root"))
            .{ .module = .root, .sub_path = try gpa.dupe(u8, fe.module(.root).root_file) }
        else
            // TODO: ZON imports go through ZonGen, not AstGen.
            continue;
        list.appendAssumeCapacity(imp);
    }
    return list.toOwnedSlice(gpa);
}

fn fatalFile(path: []const u8, err: anyerror) noreturn {
    std.process.fatal("unable to load '{s}': {t}", .{ path, err });
}

/// Prints `stats` to stderr (`ZAP_FRONTEND_TIMING=1`).
pub fn printStats(fe: *const Frontend) void {
    const s = fe.stats;
    const ms = struct {
        fn f(ns: u64) f64 {
            return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
        }
    }.f;
    std.debug.print("frontend: {d:.2} ms (open caches {d:.2}, load {d:.2}, of which finish {d:.2}), " ++
        "{d} files: {d} stat hits, {d} content hits, {d} lowered; {d} unused guesses; {d} threads\n", .{
        ms(s.open_ns + s.load_ns), ms(s.open_ns), ms(s.load_ns),  ms(s.finish_ns),
        s.files,                   s.stat_hits,   s.content_hits, s.lowered,
        s.guessed,                 s.threads,
    });
}

test "loads a file and its imports" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "const a = @import(\"a.zig\");\npub fn main() void { a.f(); }\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "pub fn f() void {}\n" });
    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/main.zig", .{tmp.sub_path});
    defer gpa.free(root);

    var fe: Frontend = try .init(gpa, io, "/nonexistent", root);
    defer fe.deinit();
    var errors: std.zig.ErrorBundle.Wip = try .init(gpa);
    defer errors.deinit();
    try std.testing.expect(try fe.loadAll(&errors));
    try std.testing.expectEqual(2, fe.files.items.len);
    try std.testing.expectEqualStrings("a.zig", fe.file(@fromBackingInt(@intCast(1))).sub_path);
}

test "reuses cached ZIR, drops stale guessed imports, and reports errors in cached files" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old: Io.File.SetTimestamp = .{ .new = .fromNanoseconds(1_000_000_000 * std.time.ns_per_s) };
    try tmp.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "const a = @import(\"a.zig\");\npub fn main() void { a.f(); }\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "const c = @import(\"c.zig\");\npub fn f() void {\n    c.g();\n}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "c.zig", .data = "pub fn g() void {}\n" });
    // Old enough that the index trusts their stats.
    try tmp.dir.setTimestamps(io, "main.zig", .{ .modify_timestamp = old });
    try tmp.dir.setTimestamps(io, "a.zig", .{ .modify_timestamp = old });
    try tmp.dir.setTimestamps(io, "c.zig", .{ .modify_timestamp = old });
    const base = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(base);
    const root = try std.fs.path.join(gpa, &.{ base, "main.zig" });
    defer gpa.free(root);
    const cache = try std.fs.path.join(gpa, &.{ base, "cache" });
    defer gpa.free(cache);

    const Run = struct {
        fe: Frontend,
        errors: std.zig.ErrorBundle.Wip,
        ok: bool,

        fn init(r: *@This(), root_path: []const u8, cache_path: []const u8) !void {
            r.fe = try .init(gpa, io, "/nonexistent", root_path);
            errdefer r.fe.deinit();
            try r.fe.enableCache(.{ .local = cache_path, .global = cache_path });
            r.errors = try .init(gpa);
            errdefer r.errors.deinit();
            r.ok = try r.fe.loadAll(&r.errors);
        }

        fn deinit(r: *@This()) void {
            r.errors.deinit();
            r.fe.deinit();
        }

        fn errorCount(r: *@This()) !u32 {
            var bundle = try r.errors.toOwnedBundle("");
            defer bundle.deinit(gpa);
            r.errors = try .init(gpa);
            return bundle.errorMessageCount();
        }
    };

    var cold: Run = undefined;
    try cold.init(root, cache);
    defer cold.deinit();
    try std.testing.expectEqual(3, cold.fe.stats.lowered);

    var warm: Run = undefined;
    try warm.init(root, cache);
    defer warm.deinit();
    try std.testing.expectEqual(3, warm.fe.stats.stat_hits);
    for (cold.fe.files.items, warm.fe.files.items) |c, w| {
        try std.testing.expectEqualStrings(c.sub_path, w.sub_path);
        try std.testing.expectEqualSlices(u8, @ptrCast(c.zir.instructions.items(.tag)), @ptrCast(w.zir.instructions.items(.tag)));
        try std.testing.expectEqualSlices(u32, c.zir.extra, w.zir.extra);
        try std.testing.expectEqualSlices(u8, c.zir.string_bytes, w.zir.string_bytes);
    }

    // An edit that drops an import and has an AstGen error is lowered and
    // reported. The import of its old content is guessed, but the deleted
    // file is neither loaded nor an error. The next build maps the edited
    // file's ZIR and still reports the error.
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "pub fn f() void {\n    var x = 1;\n}\n" });
    try tmp.dir.deleteFile(io, "c.zig");
    var edited: Run = undefined;
    try edited.init(root, cache);
    defer edited.deinit();
    try std.testing.expectEqual(1, edited.fe.stats.stat_hits);
    try std.testing.expectEqual(1, edited.fe.stats.lowered);
    try std.testing.expectEqual(1, edited.fe.stats.guessed);
    try std.testing.expectEqual(2, edited.fe.files.items.len);
    const edit_errors = try edited.errorCount();
    try std.testing.expect(edit_errors > 0);

    var again: Run = undefined;
    try again.init(root, cache);
    defer again.deinit();
    try std.testing.expectEqual(0, again.fe.stats.lowered);
    try std.testing.expectEqual(0, again.fe.stats.guessed);
    try std.testing.expectEqual(edit_errors, try again.errorCount());
}
