//! Source to ZIR. Loads the root file, parses it with `frontend.Ast`, lowers it
//! with `frontend.AstGen`, and follows its `@import`s until every reachable
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
const frontend = @import("frontend");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Ast = frontend.Ast;
const Zir = frontend.Zir;
const AstGen = frontend.AstGen;
const assert = std.debug.assert;
const LintConfig = @import("lint/Config.zig");
const Linter = @import("lint/Linter.zig");
const Language = @import("language.zig").Language;
const zirDir = @import("cache.zig").zirDir;

const Frontend = @This();

gpa: Allocator,
io: Io,
/// Directory containing `std/std.zig` for the pinned Zig release.
zig_lib_dir: []const u8,
/// On-disk ZIR caches, indexed by `Module.cache`, whose stat index each
/// holds a module's files' stats. Every file's ZIR, keyed by content, is
/// in the global one (`blobCache`). Null entries (the default) keep
/// everything in memory.
caches: [2]?CacheDir = .{ null, null },
/// Set at the first failure to write ZIR or an index to a cache, which
/// alone is reported.
zir_save_failed: std.atomic.Value(bool) = .init(false),
files: std.ArrayList(File) = .empty,
/// Maps `"<module index>:<sub_path>"` to its file.
file_map: std.StringHashMapUnmanaged(File.Index) = .empty,
modules: std.ArrayList(Module) = .empty,
/// The ZON files the loaded files import by path (`Job.zon_imports`), each
/// once: Sema reads only those it analyzes, but each must exist, so the
/// cache records them all as inputs (`Incremental`).
zon_imports: std.ArrayList(ZonImport) = .empty,
/// The module whose tests `bs test` runs; `root` outside of tests.
main_module: Module.Index = .root,
/// The project's lint config, unless lint is off: the files it covers
/// that this build lowers get their lint findings from the same syntax tree
/// (`lintFindings`).
lint: ?*const LintConfig = null,
/// `Options.root_name`: what `displayName` calls `main_module`.
root_name: []const u8 = "root",
/// See `Options.load_std`.
load_std: bool,
/// The Zig language of the compilation (`Options.language`), which keys
/// the caches.
language: Language,
/// The language sources are parsed and lowered in: `language`, but for
/// `Options.syntax_language`.
syntax_language: Language,
/// The root module of the fuzzer's family (`Options.fuzzer_builtin_dir`),
/// whose `=std@fuzzer` and `=builtin@fuzzer` follow it. Their names hold
/// an '=', which no `-M` name can, so no other module's keys are theirs.
fuzzer_root: ?Module.Index = null,
/// Whether any module has `error_tracing`, as upstream's
/// `Config.any_error_tracing`: only then do functions other than `.auto`
/// ones set up a trace for their `.auto` callees.
any_error_tracing: bool = true,
/// With `Options.c_runtimes`: the module of `<lib>/ubsan_rt.zig`, whose
/// `__ubsan_handle_*` exports `zig cc`'s Debug objects call. It shares
/// the main std and builtin. compiler_rt's `ssp_sub_path` is a root then
/// too, for `__stack_chk_fail` and `__stack_chk_guard`.
ubsan_rt: ?Module.Index = null,
/// With `Options.zigc`: the module of `<lib>/c.zig`, upstream's libc in
/// Zig, whose weak exports (`memcpy`, `malloc`, the math functions and
/// others) replace the musl sources that libc.a leaves out. It shares
/// the main std and builtin, as upstream's `zigc` module in the
/// compilation unit.
zigc: ?Module.Index = null,
/// What `loadAll` and `loadFile` did, for `BS_FRONTEND_TIMING`.
stats: Stats = .{},
/// AstGen errors in files `loadFile` loaded, for the caller to report
/// with its own.
late_errors: std.ArrayList(std.zig.ErrorBundle) = .empty,

pub const Module = struct {
    /// Name used in `@import("name")`.
    name: []const u8,
    /// Directory that the module's root file and its relative imports live in.
    root_dir: []const u8,
    /// Root file path, relative to `root_dir`.
    root_file: []const u8,
    /// `root_dir` made absolute, for cache index keys. Set by `enableCache`.
    abs_root_dir: ?[:0]const u8 = null,
    /// `@import` names this module resolves to other modules (`--dep`).
    deps: []const Dep = &.{},
    /// Which of `caches` indexes this module's files' stats: std's are
    /// shared by every project through the global cache, a project's are
    /// its own. Their ZIR is in the global cache either way (`blobCache`).
    cache: CacheKind,
    /// The modules `@import("std")`, `@import("root")`, and
    /// `@import("builtin")` name here: the main ones, except in the
    /// fuzzer's family (`fuzzer_root`), which has its own, as upstream's
    /// separate compilation of the fuzzer does.
    std_mod: Index = .std,
    root_mod: Index = .root,
    builtin_mod: Index = .builtin,
    /// `-ffuzz`: CodeGen instruments the module's functions.
    fuzz: bool = false,
    /// `-ferror-tracing` as resolved (`main.Options.error_tracing`): Sema
    /// saves, pushes and restores error return traces in the module's
    /// functions.
    error_tracing: bool = true,
    /// Whether Sema adds safety checks to the module's functions: not in
    /// ReleaseFast and ReleaseSmall (as resolved for it), nor in the
    /// fuzzer's family, which upstream builds ReleaseFast.
    safety: bool = true,
    /// `name` is `gpa`'s (an extra builtin's, `ModuleArg.builtin_dir`).
    owned_name: bool = false,
    /// Its C flags (`-I`, `-D`, ...), which Zig 0.16's `@cImport` passes
    /// to translate-c (`Zcu.c_import`). Not owned.
    cc_argv: []const []const u8 = &.{},

    pub const Index = enum(u32) {
        root,
        std,
        builtin,
        compiler_rt,
        _,
    };
};

fn safeMode(o: std.lang.Optimize) bool {
    return o == .debug or o == .safe;
}

pub const CacheKind = enum(u1) { local, global };

pub const Dep = struct { name: []const u8, module: Module.Index };

/// A module given on the command line (`--dep a --dep b=c -Mname=path`).
pub const ModuleArg = struct {
    name: []const u8,
    path: []const u8,
    /// `name` or `name=module`.
    deps: []const []const u8,
    /// Its C flags (`Module.cc_argv`).
    cc_argv: []const []const u8 = &.{},
    /// Its `-ffuzz` or `-fno-fuzz`, if any; after `main.parseOptions`, the
    /// flag it inherits otherwise.
    fuzz: ?bool = null,
    /// Its `-O`, `-ferror-tracing` and `-fvalgrind` (or their negations),
    /// as `fuzz`.
    optimize: ?std.lang.Optimize = null,
    error_tracing: ?bool = null,
    valgrind: ?bool = null,
    /// The directory of its own generated `builtin.zig`, when those
    /// differ from the root module's, as upstream gives each set of
    /// module options a builtin of its own.
    builtin_dir: ?[]const u8 = null,
};

pub const File = struct {
    module: Module.Index,
    /// Path relative to the module's `root_dir`.
    sub_path: []const u8,
    /// Path shown in diagnostics.
    display_path: []const u8,
    /// Valid once `zir_ready` is set: a file whose stat matched the index
    /// is mapped on first use (`Frontend.file`).
    zir: Zir,
    /// Hash of the source `zir` was lowered from.
    content_hash: Hash,
    /// Set when `zir` points into a mapped cache file rather than `gpa` memory.
    mapping: ?Io.File.MemoryMap,
    zir_ready: std.atomic.Value(bool) = .init(true),
    zir_mutex: Io.Mutex = .init,
    /// Source and syntax tree, loaded on first use by `Frontend.tree` and
    /// `Frontend.source`.
    syntax: ?Syntax,
    syntax_mutex: Io.Mutex = .init,
    /// `Linter.encode`d findings, made while lowering a covered file.
    lint_facts: ?[]const u8 = null,

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

pub const Options = struct {
    /// Root source file of the root module (the test runner under `bs test`).
    root_src_path: []const u8,
    /// The Zig language of the compilation (`language.resolve`).
    language: Language = .newest,
    /// Parse and lower in this language instead, with `language`'s caches
    /// (test/language/keys.sh).
    syntax_language: ?Language = null,
    /// The root module's directory when it is not the root file's own:
    /// upstream roots translate-c, whose root file imports `../util.zig`,
    /// at `lib/compiler`. `root_src_path` starts with it and a '/'.
    root_dir: ?[]const u8 = null,
    /// Directory holding the generated `builtin.zig`.
    builtin_dir: []const u8,
    /// `bs test` only: root source file of the module under test.
    main_src_path: ?[]const u8 = null,
    /// `bs test` with `--test-runner`: as upstream's, the custom test
    /// runner imports the modules the module under test does.
    custom_test_runner: bool = false,
    /// Whether `loadAll` loads std, which upstream always analyzes. Off only
    /// in tests that have no lib directory.
    load_std: bool = true,
    /// The `-M` name of the root module, or under `bs test` of the module
    /// under test, which `--dep`s name it by; its `--dep`s; and the other
    /// modules.
    root_name: []const u8 = "root",
    root_deps: []const []const u8 = &.{},
    /// The C flags of the module `root_name` names (`Module.cc_argv`).
    root_cc_argv: []const []const u8 = &.{},
    modules: []const ModuleArg = &.{},
    /// `-ffuzz` on the main module, which std, builtin and the test runner
    /// inherit.
    fuzz: bool = false,
    /// `-ferror-tracing` on the main module, inherited as `fuzz`.
    error_tracing: bool = true,
    /// `-O` on the main module, inherited as `fuzz`.
    optimize: std.lang.Optimize = .debug,
    /// With `-ffuzz` on an executable: the directory of the fuzzer's
    /// generated `builtin.zig`. The fuzzer (`<lib>/fuzzer.zig`) then joins
    /// the compilation as a module family of its own (docs/slop/architecture.md,
    /// "Fuzzing").
    fuzzer_builtin_dir: ?[]const u8 = null,
    /// The executable links C objects: their runtimes join the
    /// compilation for their exports, as upstream links them for C code
    /// (`c_runtimes`).
    c_runtimes: bool = false,
    /// An executable or test linking musl statically (`zigc`), as
    /// upstream's `target_util.wantsZigC`.
    zigc: bool = false,
};

/// Whether testing `main_src_path` tests the std module itself: as
/// upstream, testing `<lib>/std/std.zig` makes std the module under test
/// rather than loading a second copy of it.
pub fn testsStd(gpa: Allocator, zig_lib_dir: []const u8, main_src_path: []const u8) !bool {
    const resolved = try Io.Dir.path.resolveAlloc(gpa, &.{main_src_path});
    defer gpa.free(resolved);
    const std_root = try Io.Dir.path.resolveAlloc(gpa, &.{ zig_lib_dir, "std", "std.zig" });
    defer gpa.free(std_root);
    return std.mem.eql(u8, resolved, std_root);
}

pub fn init(gpa: Allocator, io: Io, zig_lib_dir: []const u8, options: Options) !Frontend {
    var fe: Frontend = .{ .gpa = gpa, .io = io, .zig_lib_dir = zig_lib_dir, .load_std = options.load_std, .root_name = options.root_name, .language = options.language, .syntax_language = options.syntax_language orelse options.language };
    errdefer fe.deinit();
    // The root module and the module under test are named by their roles,
    // not their `-M` name (`root_name`): cache keys name modules
    // (`Zcu.fileKey`), and the root file of a `bs test` must not stand
    // for the root module of a `bs build-exe`, which `@import("root")`
    // finds. The names start with '=', which no `-M` name can hold, so no
    // other module's keys are theirs.
    if (options.root_dir) |dir| try fe.modules.append(gpa, .{
        .name = "=root",
        .root_dir = try gpa.dupe(u8, dir),
        .root_file = try gpa.dupe(u8, options.root_src_path[dir.len + 1 ..]),
        .cache = .local,
    }) else try fe.addModule("=root", options.root_src_path, .local);
    try fe.modules.append(gpa, .{
        .name = "std",
        .root_dir = try Io.Dir.path.join(gpa, &.{ zig_lib_dir, "std" }),
        .root_file = try gpa.dupe(u8, "std.zig"),
        .cache = .global,
    });
    // Content-addressed in the global cache, like std.
    try fe.modules.append(gpa, .{
        .name = "builtin",
        .root_dir = try gpa.dupe(u8, options.builtin_dir),
        .root_file = try gpa.dupe(u8, "builtin.zig"),
        .cache = .global,
    });
    // Its functions are analyzed only when CodeGen calls them.
    try fe.modules.append(gpa, .{
        .name = "compiler_rt",
        .root_dir = try gpa.dupe(u8, zig_lib_dir),
        .root_file = try gpa.dupe(u8, "compiler_rt.zig"),
        .cache = .global,
    });
    if (options.main_src_path) |path| {
        if (try testsStd(gpa, zig_lib_dir, path)) {
            fe.main_module = .std;
        } else {
            fe.main_module = @fromBackingInt(@intCast(fe.modules.items.len));
            try fe.addModule("=main", path, .local);
        }
    }
    const first_extra = fe.modules.items.len;
    for (options.modules) |m| try fe.addModule(m.name, m.path, .local);
    const resolve = struct {
        fn f(f_fe: *Frontend, root_name: []const u8, specs: []const []const u8) ![]const Dep {
            const deps = try f_fe.gpa.alloc(Dep, specs.len);
            for (deps, specs) |*d, spec| {
                const eq = std.mem.findScalar(u8, spec, '=');
                const name = if (eq) |e| spec[0..e] else spec;
                const target = if (eq) |e| spec[e + 1 ..] else spec;
                // By `-M` name: under `bs test` no `--dep` names the test
                // runner.
                const main: usize = @backingInt(f_fe.main_module);
                const idx = if (std.mem.eql(u8, target, root_name)) main else for (f_fe.modules.items, 0..) |m, k| {
                    if (k == 0 or (k == main and f_fe.main_module != .std)) continue;
                    if (std.mem.eql(u8, m.name, target)) break k;
                } else std.process.fatal("no module named '{s}' for --dep '{s}'", .{ target, spec });
                d.* = .{ .name = name, .module = @fromBackingInt(@intCast(idx)) };
            }
            return deps;
        }
    }.f;
    fe.modules.items[@backingInt(fe.main_module)].deps = try resolve(&fe, options.root_name, options.root_deps);
    if (options.custom_test_runner) fe.modules.items[@backingInt(Module.Index.root)].deps = try gpa.dupe(Dep, fe.modules.items[@backingInt(fe.main_module)].deps);
    for (options.modules, first_extra..) |m, k| fe.modules.items[k].deps = try resolve(&fe, options.root_name, m.deps);
    fe.modules.items[@backingInt(fe.main_module)].cc_argv = options.root_cc_argv;
    for (options.modules, first_extra..) |m, k| fe.modules.items[k].cc_argv = m.cc_argv;
    // `-ffuzz` per module: the main module's flag for it, std, builtin
    // and the test runner; each other module's resolved by `main`.
    for ([_]Module.Index{ .root, .std, .builtin, fe.main_module }) |m| fe.modules.items[@backingInt(m)].fuzz = options.fuzz;
    for (options.modules, first_extra..) |m, k| fe.modules.items[k].fuzz = m.fuzz orelse options.fuzz;
    // Error tracing likewise.
    for ([_]Module.Index{ .root, .std, .builtin, fe.main_module }) |m| fe.modules.items[@backingInt(m)].error_tracing = options.error_tracing;
    fe.any_error_tracing = options.error_tracing;
    for ([_]Module.Index{ .root, .std, .builtin, fe.main_module }) |m| fe.modules.items[@backingInt(m)].safety = safeMode(options.optimize);
    for (options.modules, first_extra..) |m, k| fe.modules.items[k].safety = safeMode(m.optimize orelse options.optimize);
    for (options.modules, first_extra..) |m, k| {
        const et = m.error_tracing orelse options.error_tracing;
        fe.modules.items[k].error_tracing = et;
        fe.any_error_tracing = fe.any_error_tracing or et;
    }
    // Modules with a builtin of their own (`ModuleArg.builtin_dir`): one
    // `=builtin@<n>` module per directory. Its name holds an '=', which no
    // `-M` name can, and follows from the directory, which the builtin's
    // content names, so equal builtins have equal keys in every build.
    for (options.modules, first_extra..) |m, k| {
        const dir = m.builtin_dir orelse continue;
        const existing = for (fe.modules.items[first_extra + options.modules.len ..], first_extra + options.modules.len..) |b, bk| {
            if (std.mem.eql(u8, b.root_dir, dir)) break bk;
        } else null;
        const b = existing orelse b: {
            const bk = fe.modules.items.len;
            try fe.modules.append(gpa, .{
                .name = try gpa.print("=builtin@{s}", .{Io.Dir.path.basename(dir)}),
                .root_dir = try gpa.dupe(u8, dir),
                .root_file = try gpa.dupe(u8, "builtin.zig"),
                .cache = .global,
                .owned_name = true,
            });
            break :b bk;
        };
        fe.modules.items[k].builtin_mod = @fromBackingInt(@intCast(b));
    }
    if (options.fuzzer_builtin_dir) |dir| {
        const root: Module.Index = @fromBackingInt(@intCast(fe.modules.items.len));
        const family: [3]Module.Index = .{ @fromBackingInt(@backingInt(root) + 1), root, @fromBackingInt(@backingInt(root) + 2) };
        try fe.modules.appendSlice(gpa, &.{
            .{ .name = "=root@fuzzer", .root_dir = try gpa.dupe(u8, zig_lib_dir), .root_file = try gpa.dupe(u8, "fuzzer.zig"), .cache = .global },
            .{ .name = "=std@fuzzer", .root_dir = try Io.Dir.path.join(gpa, &.{ zig_lib_dir, "std" }), .root_file = try gpa.dupe(u8, "std.zig"), .cache = .global },
            .{ .name = "=builtin@fuzzer", .root_dir = try gpa.dupe(u8, dir), .root_file = try gpa.dupe(u8, "builtin.zig"), .cache = .global },
        });
        for (fe.modules.items[@backingInt(root)..]) |*m| {
            m.std_mod, m.root_mod, m.builtin_mod = family;
            // ReleaseFast, as upstream builds it.
            m.error_tracing = false;
            m.safety = false;
        }
        fe.fuzzer_root = root;
    }
    if (options.c_runtimes) {
        fe.ubsan_rt = @fromBackingInt(@intCast(fe.modules.items.len));
        try fe.modules.append(gpa, .{ .name = "=ubsan_rt", .root_dir = try gpa.dupe(u8, zig_lib_dir), .root_file = try gpa.dupe(u8, "ubsan_rt.zig"), .cache = .global, .error_tracing = options.error_tracing });
    }
    if (options.zigc) {
        fe.zigc = @fromBackingInt(@intCast(fe.modules.items.len));
        try fe.modules.append(gpa, .{ .name = "=zigc", .root_dir = try gpa.dupe(u8, zig_lib_dir), .root_file = try gpa.dupe(u8, "c.zig"), .cache = .global, .error_tracing = options.error_tracing });
    }
    return fe;
}

/// The Zig 0.16 `@cImport` translations one compilation can hold: Sema
/// adds each one's module and file (`cImportFile`) in the room
/// `reserveCImports` made, as nothing that points into `files` and
/// `modules` (Sema's ZIR, CodeGen's reads) may move then.
pub const c_import_room = 64;

/// Makes `c_import_room` room in `files` and `modules` in a Zig 0.16
/// compilation. Call where nothing points into them.
pub fn reserveCImports(fe: *Frontend) !void {
    if (fe.syntax_language != .zig_0_16) return;
    try fe.files.ensureUnusedCapacity(fe.gpa, c_import_room);
    try fe.modules.ensureUnusedCapacity(fe.gpa, c_import_room);
}

/// Zig 0.16's `@cImport` in module `parent`: loads the translation's
/// `cimport.zig` in `dir`, which names the translation, as the root of a
/// module of its own, made once per directory. The module has `parent`'s
/// options, family and C flags, as upstream's, and no dependencies:
/// translate-c's output imports std alone, which is loaded. Returns
/// `error.NoRoom` past `c_import_room`; else as `loadFile`.
pub fn cImportFile(fe: *Frontend, parent: Module.Index, dir: []const u8) !?File.Index {
    const gpa = fe.gpa;
    var name_buf: [64]u8 = undefined;
    const name = std.mem.print(&name_buf, "=cimport@{s}", .{Io.Dir.path.basename(dir)}) catch return error.NameTooLong;
    const mod: Module.Index = for (fe.modules.items, 0..) |m, k| {
        if (std.mem.eql(u8, m.name, name)) break @fromBackingInt(@intCast(k));
    } else mod: {
        if (fe.modules.items.len == fe.modules.capacity or fe.files.items.len == fe.files.capacity) return error.NoRoom;
        const p = fe.module(parent);
        const abs = try Io.Dir.cwd().realPathFileAlloc(fe.io, dir, gpa);
        errdefer gpa.free(abs);
        const owned_name = try gpa.dupe(u8, name);
        errdefer gpa.free(owned_name);
        const root_dir = try gpa.dupe(u8, dir);
        errdefer gpa.free(root_dir);
        fe.modules.appendAssumeCapacity(.{
            .name = owned_name,
            .owned_name = true,
            .root_dir = root_dir,
            .root_file = try gpa.dupe(u8, "cimport.zig"),
            // As `enableCache` sets it for the modules there were then.
            .abs_root_dir = abs,
            .cache = .local,
            .std_mod = p.std_mod,
            .root_mod = p.root_mod,
            .builtin_mod = p.builtin_mod,
            .fuzz = p.fuzz,
            .error_tracing = p.error_tracing,
            .safety = p.safety,
            .cc_argv = p.cc_argv,
        });
        break :mod @fromBackingInt(@intCast(fe.modules.items.len - 1));
    };
    return fe.loadFile(mod, "cimport.zig");
}

/// compiler_rt's stack protector, a root with `ubsan_rt` (`c_runtimes`).
pub const ssp_sub_path = "compiler_rt/ssp.zig";

fn addModule(fe: *Frontend, name: []const u8, root_src_path: []const u8, cache: CacheKind) !void {
    try fe.modules.append(fe.gpa, .{
        .name = name,
        .root_dir = try fe.gpa.dupe(u8, Io.Dir.path.dirname(root_src_path) orelse "."),
        .root_file = try fe.gpa.dupe(u8, Io.Dir.path.basename(root_src_path)),
        .cache = cache,
    });
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
        if (m.owned_name) gpa.free(m.name);
        gpa.free(m.root_file);
        if (m.abs_root_dir) |p| gpa.free(p);
        gpa.free(m.deps);
    }
    fe.modules.deinit(gpa);
    for (fe.zon_imports.items) |z| gpa.free(z.sub_path);
    fe.zon_imports.deinit(gpa);
    for (&fe.caches) |*c| if (c.*) |*cd| cd.deinit(gpa, fe.io);
    for (fe.late_errors.items) |*b| b.deinit(gpa);
    fe.late_errors.deinit(gpa);
    fe.* = undefined;
}

fn freeFile(gpa: Allocator, io: Io, f: *File) void {
    if (f.zir_ready.load(.acquire)) {
        if (f.mapping) |*m| m.destroy(io) else f.zir.deinit(gpa);
    }
    if (f.syntax) |*s| {
        s.tree.deinit(gpa);
        gpa.free(s.source);
    }
    if (f.lint_facts) |b| gpa.free(b);
    gpa.free(f.sub_path);
    gpa.free(f.display_path);
}

/// File `index`, with its ZIR mapped. Thread-safe.
pub fn file(fe: *const Frontend, index: File.Index) *const File {
    const f = &fe.files.items[@backingInt(index)];
    if (!f.zir_ready.load(.acquire)) fe.ensureZir(f);
    return f;
}

/// Maps the cached ZIR of a file whose stat matched the index, which
/// `probeFile` left for its first use: most files a build reaches are
/// never analyzed, or replay from the cache without their ZIR. If the ZIR
/// is gone (the global cache's maintenance trims it), lowers the source
/// again, which must still have the content the index named.
fn ensureZir(fe: *const Frontend, f: *File) void {
    f.zir_mutex.lockUncancelable(fe.io);
    defer f.zir_mutex.unlock(fe.io);
    if (f.zir_ready.load(.acquire)) return;
    fe.mapOrLower(f) catch |err| switch (err) {
        error.OutOfMemory => std.process.fatal("out of memory", .{}),
    };
    f.zir_ready.store(true, .release);
}

fn mapOrLower(fe: *const Frontend, f: *File) Allocator.Error!void {
    const gpa = fe.gpa;
    const io = fe.io;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    if (fe.blobCache()) |blobs| {
        if (blobs.loadZir(gpa, io, f.content_hash, &buf, false)) |loaded| {
            f.zir, f.mapping, _ = loaded;
            return;
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        }
    }
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src = Io.Dir.cwd().readFileAllocOptions(io, f.display_path, arena, .unlimited, .of(u8), 0) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => fatalFile(f.display_path, err),
    };
    if (!std.mem.eql(u8, &hashSource(src), &f.content_hash))
        std.process.fatal("'{s}' changed during compilation", .{f.display_path});
    const ast = try Ast.parse(arena, src, .{ .mode = .zig, .language = fe.syntax_language });
    const zir = try AstGen.generate(arena, ast);
    if (fe.blobCache()) |blobs| blobs.saveZir(gpa, io, f.content_hash, &zir, try .of(arena, &zir)) catch {}; // ziglint-ignore: Z026 -- cache upkeep is best effort
    var insts = try zir.instructions.toMultiArrayList().clone(gpa);
    errdefer insts.deinit(gpa);
    const extra = try gpa.dupe(u32, zir.extra);
    errdefer gpa.free(extra);
    f.zir = .{ .instructions = insts.toOwnedSlice(), .extra = extra, .string_bytes = try gpa.dupe(u8, zir.string_bytes) };
    f.mapping = null;
}

/// A module's name as upstream shows it (in diagnostics and `@src()`):
/// its `-M` name, and "root" for the test runner.
pub fn displayName(fe: *const Frontend, index: Module.Index) []const u8 {
    if (index == fe.main_module) return fe.root_name;
    if (index == .root) return "root";
    const name = fe.module(index).name;
    // The fuzzer's family (`=std@fuzzer`), named as in upstream's
    // separate compilation of it.
    if (std.mem.startsWith(u8, name, "=")) return name[1..std.mem.findScalar(u8, name, '@').?];
    return name;
}

pub fn module(fe: *const Frontend, index: Module.Index) *const Module {
    return &fe.modules.items[@backingInt(index)];
}

/// The module that `@import(name)` in module `from` names through its
/// `--dep`s, if any.
pub fn depModule(fe: *const Frontend, from: Module.Index, name: []const u8) ?Module.Index {
    for (fe.module(from).deps) |d| if (std.mem.eql(u8, d.name, name)) return d.module;
    return null;
}

/// The module `@import(name)` names in module `from` when `name` is
/// `std`, `root`, or `builtin`: its family's.
pub fn familyModule(fe: *const Frontend, from: Module.Index, name: []const u8) ?Module.Index {
    const m = fe.module(from);
    if (std.mem.eql(u8, name, "std")) return m.std_mod;
    if (std.mem.eql(u8, name, "root")) return m.root_mod;
    if (std.mem.eql(u8, name, "builtin")) return m.builtin_mod;
    return null;
}

/// The absolute path of file `f`, as the lint config's paths are.
pub fn absPath(fe: *const Frontend, arena: Allocator, f: *const File) ![]const u8 {
    const mod = fe.module(f.module);
    return Io.Dir.path.join(arena, &.{ mod.abs_root_dir orelse mod.root_dir, f.sub_path });
}

/// Whether file `index` is one the lint config covers.
pub fn lintCovers(fe: *const Frontend, arena: Allocator, index: File.Index) !bool {
    const cfg = fe.lint orelse return false;
    return cfg.covers(try fe.absPath(arena, &fe.files.items[@backingInt(index)]));
}

/// The syntax pass's findings (`Linter.run`) in covered file `index`, in
/// `arena`: made while lowering it, else from the cache, which keeps them
/// by the file's content and name, else from its syntax tree, parsed
/// again. None for a file that does not parse, whose parse errors the
/// build reports.
pub fn lintFindings(fe: *const Frontend, arena: Allocator, index: File.Index) ![]const Linter.Diagnostic {
    const f = &fe.files.items[@backingInt(index)];
    if (f.lint_facts) |b| return (try Linter.decode(arena, b)).?;
    const name = lintFactsName(f);
    if (fe.blobCache()) |blobs| if (blobs.loadLintFacts(arena, fe.io, name)) |bytes| {
        if (try Linter.decode(arena, bytes)) |findings| return findings;
    };
    const syntax = try fe.syntaxOf(index);
    if (syntax.tree.errors.len != 0) return &.{};
    const findings = Linter.run(arena, syntax.source, syntax.tree, f.sub_path);
    if (fe.blobCache()) |blobs| blobs.saveLintFacts(fe.io, name, try Linter.encode(arena, findings));
    return findings;
}

/// File `index`'s deprecated declarations (`Linter.deprecations`), which
/// Z011 reads, in `arena`: from the cache, which keeps them by the
/// file's content, else from its syntax tree, parsed again. Any file, std
/// included, as Sema calls into it. Thread-safe.
pub fn deprecations(fe: *const Frontend, arena: Allocator, index: File.Index) ![]const Linter.Deprecation {
    const f = &fe.files.items[@backingInt(index)];
    if (try fe.cachedDeprecations(arena, f.content_hash)) |table| return table;
    const syntax = try fe.syntaxOf(index);
    const table = try Linter.deprecations(arena, &syntax.tree);
    if (fe.blobCache()) |blobs| blobs.saveLintFacts(fe.io, deprecationsName(f.content_hash), try Linter.encodeDeprecations(arena, table));
    return table;
}

/// The deprecation table of contents `content_hash`, if the cache has it.
pub fn cachedDeprecations(fe: *const Frontend, arena: Allocator, content_hash: Hash) !?[]const Linter.Deprecation {
    const blobs = fe.blobCache() orelse return null;
    const bytes = blobs.loadLintFacts(arena, fe.io, deprecationsName(content_hash)) orelse return null;
    return Linter.decodeDeprecations(arena, bytes);
}

fn deprecationsName(content_hash: Hash) [32]u8 {
    var h: std.crypto.hash.Blake3 = .init(.{});
    h.update(Linter.deprecations_magic);
    h.update(&content_hash);
    var key: Hash = undefined;
    h.final(&key);
    return std.fmt.bytesToHex(key, .lower);
}

/// What file `f`'s lint findings depend on: its contents, its base name
/// (Z009, Z012, Z021) and the rules (`Linter.version`).
pub fn lintKey(f: *const File) Hash {
    var h: std.crypto.hash.Blake3 = .init(.{});
    h.update(Linter.facts_magic);
    h.update(&std.mem.toBytes(Linter.version));
    h.update(&f.content_hash);
    h.update(Io.Dir.path.basename(f.sub_path));
    var out: Hash = undefined;
    h.final(&out);
    return out;
}

/// The cache file name of file `f`'s lint findings: 32 hex digits, so
/// that the store's maintenance trims it with the ZIR (`Store.maintain`).
fn lintFactsName(f: *const File) [32]u8 {
    return std.fmt.bytesToHex(lintKey(f), .lower);
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
    f.syntax = .{ .source = src, .tree = try Ast.parse(fe.gpa, src, .{ .mode = .zig, .language = fe.syntax_language }) };
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
/// else (and always for `zig run`) the global cache. bs's files live in a
/// `bs/` subdirectory of each, apart from upstream's.
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
/// Trims the ZIR caches (`CacheDir.trim`). Best effort; `Incremental`
/// runs it beside the link.
pub fn trimCaches(fe: *const Frontend) void {
    const blobs = fe.blobCache() orelse return;
    for (&fe.caches) |*c| if (c.*) |*cd| cd.trim(fe.gpa, fe.io, blobs) catch {}; // ziglint-ignore: Z026 -- cache upkeep is best effort
}

pub fn enableCache(fe: *Frontend, dirs: CacheDirs) !void {
    const gpa = fe.gpa;
    const start = Io.Clock.awake.now(fe.io);
    defer fe.stats.open_ns = @intCast(start.durationTo(Io.Clock.awake.now(fe.io)).toNanoseconds());
    const same = std.mem.eql(u8, dirs.local, dirs.global);
    fe.caches[@backingInt(CacheKind.local)] = try .openOrWarn(gpa, fe.io, dirs.local, fe.language, same);
    if (!same) fe.caches[@backingInt(CacheKind.global)] = try .openOrWarn(gpa, fe.io, dirs.global, fe.language, true);
    for (fe.modules.items) |*m| {
        m.abs_root_dir = Io.Dir.cwd().realPathFileAlloc(fe.io, m.root_dir, gpa) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // The root file's load will report it.
            else => try gpa.dupeSentinel(u8, m.root_dir, 0),
        };
    }
}

/// ZIR an earlier build lowered from file `index`'s source when it had
/// `content_hash`, from the cache of every file's ZIR (`blobCache`), for
/// comparing with the file's ZIR now (`seeds.zig`); null if the cache no
/// longer has it.
pub fn loadOldZir(fe: *const Frontend, index: File.Index, content_hash: Hash) Allocator.Error!?OldZir {
    _ = index;
    const cd = fe.blobCache() orelse return null;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(fe.gpa);
    const zir, const mapping, _ = cd.loadZir(fe.gpa, fe.io, content_hash, &buf, false) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    return .{ .zir = zir, .mapping = mapping };
}

pub const OldZir = struct {
    zir: Zir,
    mapping: ?Io.File.MemoryMap,

    pub fn deinit(o: *OldZir, fe: *const Frontend) void {
        if (o.mapping) |*m| m.destroy(fe.io) else o.zir.deinit(fe.gpa);
        o.* = undefined;
    }
};

/// The cache whose index holds `mod`'s files' stats.
fn cacheFor(fe: *Frontend, mod: *const Module) ?*CacheDir {
    if (fe.caches[@backingInt(mod.cache)]) |*cd| return cd;
    if (fe.caches[@backingInt(CacheKind.local)]) |*cd| return cd;
    return null;
}

/// The cache that holds every file's ZIR: the global one, so that a
/// project's ZIR outlives its local cache and its worktrees share it.
/// The local one only if the global one cannot be opened.
fn blobCache(fe: *const Frontend) ?*const CacheDir {
    if (fe.caches[@backingInt(CacheKind.global)]) |*cd| return cd;
    if (fe.caches[@backingInt(CacheKind.local)]) |*cd| return cd;
    return null;
}

/// Cache layout, in `<cache dir>/bs/zir/` for 0.17 and in another
/// directory for each other language (`cache.zirDir`), so that nothing in
/// it is shared between languages: not the ZIR of the same source text,
/// nor a path's stats, imports or lint facts:
/// - `<32 hex digits>`: the ZIR of one source text, named by `hashSource`.
///   Written once to a temporary file and linked into place; never changed
///   but for its mtime, which a build that maps it renews once a day, so
///   that the store's maintenance can count and evict it in the global
///   cache (`Store.maintain`).
/// - `index`: `IndexHeader` then `IndexEntry`s sorted by `path_hash`.
///   Rewritten through a temporary file when a build learns new stats.
/// - `trim`: empty; its mtime is when `trim` last ran.
const CacheDir = struct {
    dir: Io.Dir,
    /// Entries loaded at `open`, sorted by `path_hash`; they point into
    /// `index_bytes`, the whole index file.
    index: []const IndexEntry,
    /// The entries' import names (`IndexEntry.names_off`).
    index_names: []const u8,
    index_bytes: []align(@alignOf(IndexEntry)) u8,
    /// The global cache's: its ZIR is every project's, which the store's
    /// maintenance counts and trims, not `trim`.
    global: bool,
    /// ZIR whose mtime is older than this (real clock, nanoseconds) has
    /// its mtime renewed when it is mapped.
    renew_before_ns: i96,

    /// Opens `lang`'s cache in `path`, or warns and returns null if it
    /// cannot (a full disk, for one): the build goes on without it.
    fn openOrWarn(gpa: Allocator, io: Io, path: []const u8, lang: Language, global: bool) Allocator.Error!?CacheDir {
        const full = try Io.Dir.path.join(gpa, &.{ path, "bs", zirDir(lang) });
        defer gpa.free(full);
        const dir = Io.Dir.cwd().openDir(io, full, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => Io.Dir.cwd().createDirPathOpen(io, full, .{ .open_options = .{ .iterate = true } }) catch |e| {
                std.log.warn("unable to create cache directory '{s}': {t}", .{ full, e });
                return null;
            },
            else => {
                std.log.warn("unable to open cache directory '{s}': {t}", .{ full, err });
                return null;
            },
        };
        var cd: CacheDir = .{
            .dir = dir,
            .index = &.{},
            .index_names = &.{},
            .index_bytes = &.{},
            .global = global,
            .renew_before_ns = Io.Clock.real.now(io).toNanoseconds() - std.time.ns_per_day,
        };
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
        cd.* = undefined;
    }

    /// Deletes the ZIR that the index on disk does not name and that is
    /// more than a day old, and other files left that long (temporary files
    /// of interrupted builds), at most once a day. That keeps the cache to
    /// the sources last seen at each path, plus a day of edits. A build
    /// whose index entry names deleted ZIR lowers the file again. In the
    /// global cache it deletes only the other files: the ZIR there is
    /// every project's, and goes with the store's packs (`Store.maintain`).
    fn trim(cd: *const CacheDir, gpa: Allocator, io: Io, blobs: *const CacheDir) !void {
        const now = Io.Clock.real.now(io);
        if (cd.dir.statFile(io, "trim", .{})) |stat| {
            if (stat.mtime.durationTo(now).toNanoseconds() < std.time.ns_per_day) return;
        } else |_| {}
        try cd.dir.writeFile(io, .{ .sub_path = "trim", .data = "" });
        var named: std.AutoHashMapUnmanaged(Hash, void) = .empty;
        defer named.deinit(gpa);
        {
            var index: CacheDir = .{ .dir = cd.dir, .index = &.{}, .index_names = &.{}, .index_bytes = &.{}, .global = false, .renew_before_ns = 0 };
            try index.loadIndex(gpa, io);
            defer gpa.free(index.index_bytes);
            cd.sweepSuperseded(gpa, io, blobs, index.index, &.{}, now) catch {}; // ziglint-ignore: Z026 -- cache upkeep is best effort
            if (!cd.global) {
                try named.ensureTotalCapacity(gpa, @intCast(index.index.len));
                for (index.index) |e| named.putAssumeCapacity(e.content_hash, {});
            }
        }
        var it = cd.dir.iterate();
        while (try it.next(io)) |e| {
            if (e.kind != .file or std.mem.eql(u8, e.name, "index") or std.mem.eql(u8, e.name, "trim") or
                std.mem.eql(u8, e.name, "superseded")) continue;
            var hash: Hash = undefined;
            if (e.name.len == 2 * hash.len) {
                if (std.fmt.hexToBytes(&hash, e.name)) |_| {
                    if (cd.global or named.contains(hash)) continue;
                } else |_| {}
            }
            const stat = cd.dir.statFile(io, e.name, .{}) catch continue;
            if (stat.mtime.durationTo(now).toNanoseconds() < std.time.ns_per_day) continue;
            cd.dir.deleteFile(io, e.name) catch {}; // ziglint-ignore: Z026 -- cache upkeep is best effort
        }
    }

    fn loadIndex(cd: *CacheDir, gpa: Allocator, io: Io) !void {
        const bytes = try cd.dir.readFileAllocOptions(io, "index", gpa, .unlimited, .of(IndexEntry), null);
        errdefer gpa.free(bytes);
        if (bytes.len < @sizeOf(IndexHeader)) return error.CorruptCache;
        const header: *const IndexHeader = @ptrCast(bytes.ptr);
        const entries_end = @sizeOf(IndexHeader) + header.len * @sizeOf(IndexEntry);
        if (!std.mem.eql(u8, &header.magic, &index_magic) or bytes.len != entries_end + header.names_len) return error.CorruptCache;
        const index: []const IndexEntry = @ptrCast(@alignCast(bytes[@sizeOf(IndexHeader)..entries_end]));
        for (index) |e| if (e.names_off > header.names_len or e.names_len > header.names_len - e.names_off) return error.CorruptCache;
        cd.index = index;
        cd.index_names = bytes[entries_end..];
        cd.index_bytes = bytes;
    }

    fn names(cd: *const CacheDir, e: *const IndexEntry) []const u8 {
        return cd.index_names[e.names_off..][0..e.names_len];
    }

    fn lookup(cd: *const CacheDir, path_hash: u64) ?*const IndexEntry {
        const i = std.sort.binarySearch(IndexEntry, cd.index, path_hash, IndexEntry.order) orelse return null;
        return &cd.index[i];
    }

    /// Deletes the ZIR of the sources that edits replaced, once no build
    /// uses it, so that a file edited all day does not keep a copy per
    /// edit in the global cache. `new` are the content hashes that this
    /// build's index updates replaced; `index` is the index now, whose
    /// sources stay. Each new one's ZIR file in `blobs` gets an mtime of
    /// two days before `now`, which every build that maps it afterwards
    /// renews (`loadZir`); it goes on the `superseded` list with `now`.
    /// An earlier entry's file whose mark is still there an hour later
    /// (`superseded_grace_ns`) is deleted. A worktree that still has that
    /// source and has not built since lowers it again, which costs time,
    /// not correctness. A renewed, missing or reindexed one leaves the list.
    fn sweepSuperseded(cd: *const CacheDir, gpa: Allocator, io: Io, blobs: *const CacheDir, index: []const IndexEntry, new: []const Hash, now: Io.Timestamp) !void {
        var named: std.AutoHashMapUnmanaged(Hash, void) = .empty;
        defer named.deinit(gpa);
        try named.ensureTotalCapacity(gpa, @intCast(index.len));
        for (index) |e| named.putAssumeCapacity(e.content_hash, {});
        const now_ns: i64 = @intCast(now.toNanoseconds());
        const old_bytes = cd.dir.readFileAllocOptions(io, "superseded", gpa, .limited(1 << 24), .of(Superseded), null) catch |err| switch (err) {
            error.FileNotFound => try gpa.alignedAlloc(u8, .of(Superseded), 0),
            error.OutOfMemory => return error.OutOfMemory,
            else => |e| return e,
        };
        defer gpa.free(old_bytes);
        const old: []const Superseded = @ptrCast(old_bytes[0 .. old_bytes.len / @sizeOf(Superseded) * @sizeOf(Superseded)]);
        var keep: std.ArrayList(Superseded) = .empty;
        defer keep.deinit(gpa);
        for (old) |e| {
            if (named.contains(e.content_hash)) continue;
            const name = std.fmt.bytesToHex(e.content_hash, .lower);
            const stat = blobs.dir.statFile(io, &name, .{}) catch continue;
            // Renewed since it was marked.
            if (stat.mtime.toNanoseconds() >= e.at_ns - std.time.ns_per_day) continue;
            if (now_ns - e.at_ns >= superseded_grace_ns) {
                blobs.dir.deleteFile(io, &name) catch {}; // ziglint-ignore: Z026 -- cache upkeep is best effort
                continue;
            }
            try keep.append(gpa, e);
        }
        for (new) |h| {
            if (named.contains(h)) continue;
            const name = std.fmt.bytesToHex(h, .lower);
            // Through a handle: another process may have deleted it, and
            // std's path-based setTimestamps takes ENOENT as unexpected.
            const f = blobs.dir.openFile(io, &name, .{}) catch continue;
            defer f.close(io);
            f.setTimestamps(io, .{ .modify_timestamp = .{ .new = now.addDuration(.fromNanoseconds(-2 * std.time.ns_per_day)) } }) catch continue;
            try keep.append(gpa, .{ .content_hash = h, .at_ns = now_ns });
        }
        if (keep.items.len == old.len and new.len == 0) return;
        if (keep.items.len == 0) {
            cd.dir.deleteFile(io, "superseded") catch {}; // ziglint-ignore: Z026 -- cache upkeep is best effort
            return;
        }
        var af = try cd.dir.createFileAtomic(io, "superseded", .{ .replace = true });
        defer af.deinit(io);
        var w = af.file.writerStreaming(io, &.{});
        w.interface.writeAll(@ptrCast(keep.items)) catch return w.err.?;
        w.interface.flush() catch return w.err.?;
        try af.replace(io);
    }

    /// Writes the index merged with `updates` (sorted by `path_hash`, no
    /// duplicates) into `merged`, and appends to `superseded` the content
    /// hashes that updates replaced with others. Concurrent builds race
    /// benignly: the last rename wins and the loser's entries are relearned
    /// by hashing.
    fn writeIndex(cd: *const CacheDir, gpa: Allocator, io: Io, updates: []const IndexUpdate, merged: *std.ArrayList(IndexEntry), superseded: *std.ArrayList(Hash)) !void {
        try merged.ensureTotalCapacity(gpa, cd.index.len + updates.len);
        var all_names: std.ArrayList(u8) = .empty;
        defer all_names.deinit(gpa);
        try all_names.ensureTotalCapacity(gpa, cd.index_names.len);
        var i: usize = 0;
        var j: usize = 0;
        while (i < cd.index.len or j < updates.len) {
            var e: IndexEntry, const entry_names: []const u8 = e: {
                if (j == updates.len or (i < cd.index.len and cd.index[i].path_hash < updates[j].entry.path_hash)) {
                    i += 1;
                    break :e .{ cd.index[i - 1], cd.names(&cd.index[i - 1]) };
                }
                if (i < cd.index.len and cd.index[i].path_hash == updates[j].entry.path_hash) {
                    if (!std.mem.eql(u8, &cd.index[i].content_hash, &updates[j].entry.content_hash)) try superseded.append(gpa, cd.index[i].content_hash);
                    i += 1;
                }
                j += 1;
                break :e .{ updates[j - 1].entry, updates[j - 1].names };
            };
            e.names_off = @intCast(all_names.items.len);
            e.names_len = @intCast(entry_names.len);
            try all_names.appendSlice(gpa, entry_names);
            merged.appendAssumeCapacity(e);
        }
        const header: IndexHeader = .{ .len = merged.items.len, .names_len = all_names.items.len };
        var af = try cd.dir.createFileAtomic(io, "index", .{ .replace = true });
        defer af.deinit(io);
        var w = af.file.writerStreaming(io, &.{});
        var vecs = [_][]const u8{ @ptrCast((&header)[0..1]), @ptrCast(merged.items), all_names.items };
        w.interface.writeVecAll(&vecs) catch return w.err.?;
        w.interface.flush() catch return w.err.?;
        try af.replace(io);
    }

    /// Maps the cached ZIR for `hash`, or fails if there is none. The header
    /// and summary are read into `buf` rather than through the mapping, so
    /// the frontend faults in no page of it; the returned summary's names
    /// point into `buf`.
    /// `renew`: renew the file's mtime if it is older than
    /// `renew_before_ns`, as for every use but comparing an edited file's
    /// old ZIR, which must not keep superseded ZIR alive (`sweepSuperseded`).
    fn loadZir(cd: *const CacheDir, gpa: Allocator, io: Io, hash: Hash, buf: *std.ArrayList(u8), renew: bool) !struct { Zir, ?Io.File.MemoryMap, Summary } {
        const name = std.fmt.bytesToHex(hash, .lower);
        const f = try cd.dir.openFile(io, &name, .{});
        defer f.close(io);
        const header, const layout, const summary = try readSummary(f, gpa, io, buf);
        const stat = try f.stat(io);
        const len = stat.size;
        if (layout.total != len) return error.CorruptCache;
        if (renew and stat.mtime.toNanoseconds() < cd.renew_before_ns) f.setTimestampsNow(io) catch {}; // ziglint-ignore: Z026 -- cache upkeep is best effort
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

    /// Lint findings saved by `saveLintFacts`, renewed as `loadZir`
    /// renews ZIR; null if there are none.
    fn loadLintFacts(cd: *const CacheDir, arena: Allocator, io: Io, name: [32]u8) ?[]const u8 {
        const f = cd.dir.openFile(io, &name, .{}) catch return null;
        defer f.close(io);
        const stat = f.stat(io) catch return null;
        if (stat.mtime.toNanoseconds() < cd.renew_before_ns) f.setTimestampsNow(io) catch {}; // ziglint-ignore: Z026 -- cache upkeep is best effort
        const bytes = arena.alloc(u8, stat.size) catch return null;
        if ((f.readPositionalAll(io, bytes, 0) catch return null) != bytes.len) return null;
        return bytes;
    }

    /// Best effort: without it, a later build parses the file again.
    fn saveLintFacts(cd: *const CacheDir, io: Io, name: [32]u8, bytes: []const u8) void {
        var af = cd.dir.createFileAtomic(io, &name, .{}) catch return;
        defer af.deinit(io);
        af.file.writePositionalAll(io, bytes, 0) catch return;
        af.link(io) catch {}; // ziglint-ignore: Z026 -- another build wrote the same findings, or it is best effort
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

const index_magic = "ZAPZIX02".*;
const blob_magic = "ZAPZIR01".*;

/// A `superseded` list record (`CacheDir.sweepSuperseded`).
const Superseded = extern struct {
    content_hash: Hash,
    /// When it was superseded, in real-clock nanoseconds.
    at_ns: i64,
    unused: u64 = 0,
};

/// How long superseded ZIR that no build mapped since stays.
const superseded_grace_ns = 60 * std.time.ns_per_min;

const IndexHeader = extern struct {
    magic: [8]u8 = index_magic,
    len: u64,
    names_len: u64,
};

/// A new index entry, with its summary's import names (gpa memory).
const IndexUpdate = struct {
    entry: IndexEntry,
    names: []const u8,
};

const IndexEntry = extern struct {
    /// Wyhash of the absolute module root, "/", and the module-relative path.
    path_hash: u64,
    inode: u64,
    size: u64,
    /// Nanoseconds, or `racy_mtime` when the file was too new to trust.
    mtime: i64,
    content_hash: Hash,
    /// The file's `Summary`: its import names at `names_off` in the
    /// index's names, so that a stat hit learns its imports without
    /// opening its ZIR.
    names_off: u32 = 0,
    names_len: u32 = 0,
    has_errors: u32 = 0,
    unused: u32 = 0,
    /// When the ZIR's mtime was last renewed (real clock, nanoseconds), so
    /// that ZIR that stat hits never map stays in the global cache.
    renewed_ns: i64 = 0,

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

/// The seed of the hashes that name cached ZIR and index it by path: the
/// sources of the AstGen that produced it, and the Zig that built them.
const zir_salt = std.hash.Wyhash.hash(frontend.source_hash, "bs zir " ++ builtin.zig_version_string);

/// Names cached ZIR: two seeded Wyhash passes, salted with `zir_salt`. Not
/// cryptographic; twice as fast as Blake3, which took 5% of a cold build's
/// CPU time. Also the content hash of the cache manifest's source inputs
/// (`File.content_hash`).
pub fn hashSource(src: []const u8) Hash {
    const lo = std.hash.Wyhash.hash(zir_salt, src);
    const hi = std.hash.Wyhash.hash(zir_salt ^ 0x9e3779b97f4a7c15, src);
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
    /// The ZON files it imports by path, relative to its module's root
    /// directory: Sema reads them, but as upstream, one that cannot be
    /// read is an error even if the import is never analyzed.
    zon_imports: [][]const u8 = &.{},
    /// The job that imports it first, breadth-first, set when files are
    /// numbered: upstream's reference for the notes of a file-level error.
    importer: ?*Job = null,
    /// New stat index entry for the file's cache directory.
    index_update: ?IndexUpdate = null,
    index: ?File.Index = null,
    /// Loaded by an earlier `loadAll` or `loadFile`: `index` is set and
    /// `file` is not used.
    existing: bool = false,
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
            if (job.existing) {
                gpa.free(e.key_ptr.*);
            } else if (!moved or job.index == null) {
                if (job.loaded) freeFile(gpa, l.fe.io, &job.file) else {
                    gpa.free(job.file.sub_path);
                    gpa.free(job.file.display_path);
                }
                gpa.free(e.key_ptr.*);
            }
            gpa.free(job.imports);
            freeZonImports(gpa, job.zon_imports);
            if (job.index_update) |u| gpa.free(u.names);
            gpa.destroy(job);
        }
        l.jobs.deinit(gpa);
        l.probe.deinit(gpa);
        l.lower.deinit(gpa);
        l.* = undefined;
    }

    /// Returns the job for a file, creating and queueing it if it is new.
    /// Called with `mutex` held.
    fn getJob(l: *Loader, mod_index: Module.Index, sub_path: []const u8) !*Job {
        const fe = l.fe;
        const gpa = fe.gpa;
        const key = try gpa.print("{d}:{s}", .{ @backingInt(mod_index), sub_path });
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
        if (fe.file_map.get(key)) |index| {
            job.* = .{ .file = undefined, .index = index, .existing = true };
            gop.value_ptr.* = job;
            return job;
        }
        const owned_sub_path = try gpa.dupe(u8, sub_path);
        errdefer gpa.free(owned_sub_path);
        job.* = .{ .file = .{
            .module = mod_index,
            .sub_path = owned_sub_path,
            .display_path = try Io.Dir.path.join(gpa, &.{ fe.module(mod_index).root_dir, sub_path }),
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
            .probe => switch (try l.fe.probeFile(job, buf, l.start_ns)) {
                .hit => |summary| summary,
                .miss => return .{ .imports = &.{}, .lower = true },
                .missing => return .{ .imports = &.{}, .lower = false },
                .changed => |old| return .{ .imports = try l.fe.collectImports(&job.file, old.names), .lower = true },
            },
            .lower => try l.fe.lowerFile(l, job, arena, buf),
        };
        job.has_errors = summary.has_errors;
        if (step == .lower) if (job.index_update) |*u| {
            u.names = try l.fe.gpa.dupe(u8, summary.names);
            u.entry.has_errors = @intFromBool(summary.has_errors);
        };
        const zon = try l.fe.collectZonImports(&job.file, summary.names);
        errdefer freeZonImports(l.fe.gpa, zon);
        return .{ .imports = try l.fe.collectImports(&job.file, summary.names), .lower = false, .zon = zon };
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
        job.zon_imports = outcome.zon;
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
const Outcome = struct { imports: []Import, lower: bool, zon: [][]const u8 = &.{} };

fn freeZonImports(gpa: Allocator, paths: []const []const u8) void {
    for (paths) |p| gpa.free(p);
    gpa.free(paths);
}

fn freeImports(gpa: Allocator, imports: []const Import) void {
    for (imports) |imp| gpa.free(imp.sub_path);
    gpa.free(imports);
}

/// Loads, parses, and lowers the root file and every file reachable from it
/// through `@import`. Returns false and adds messages to `errors` if any file
/// failed to lower. Call once.
pub fn loadAll(fe: *Frontend, errors: *std.zig.ErrorBundle.Wip) !bool {
    var roots: [8]Root = undefined;
    var n: usize = 0;
    roots[n] = .{ .module = .root, .sub_path = fe.module(.root).root_file };
    n += 1;
    // As upstream, std is always analyzed: std.start and the panic
    // handlers in `std.lang.panic` come from it.
    if (fe.load_std) {
        roots[n] = .{ .module = .std, .sub_path = fe.module(.std).root_file };
        n += 1;
    }
    // `bs test` also analyzes the module under test.
    if (fe.main_module != .root) {
        roots[n] = .{ .module = fe.main_module, .sub_path = fe.module(fe.main_module).root_file };
        n += 1;
    }
    // The fuzzer's family: its root (whose exports the program's externs
    // name) and its std, which is always analyzed, as the main one.
    if (fe.fuzzer_root) |r| {
        roots[n] = .{ .module = r, .sub_path = fe.module(r).root_file };
        roots[n + 1] = .{ .module = fe.module(r).std_mod, .sub_path = fe.module(fe.module(r).std_mod).root_file };
        n += 2;
    }
    if (fe.ubsan_rt) |u| {
        roots[n] = .{ .module = u, .sub_path = fe.module(u).root_file };
        roots[n + 1] = .{ .module = .compiler_rt, .sub_path = ssp_sub_path };
        n += 2;
    }
    if (fe.zigc) |z| {
        roots[n] = .{ .module = z, .sub_path = fe.module(z).root_file };
        n += 1;
    }
    var indices: [8]?File.Index = undefined;
    return fe.load(roots[0..n], indices[0..n], errors);
}

/// Loads `sub_path` of module `mod` and the files it reaches that are not
/// loaded yet, after `loadAll`, for code analyzed on demand (compiler_rt).
/// Returns its index, or null if it does not exist. If a newly loaded file
/// has AstGen errors, their messages go to `late_errors` and this returns
/// `error.AstGenFailed`. Grows `files`, so pointers to `File`s and their ZIR
/// are invalid afterwards.
pub fn loadFile(fe: *Frontend, mod: Module.Index, sub_path: []const u8) !?File.Index {
    var buf: [std.fs.max_path_bytes + 16]u8 = undefined;
    const key = std.mem.print(&buf, "{d}:{s}", .{ @backingInt(mod), sub_path }) catch return error.NameTooLong;
    if (fe.file_map.get(key)) |index| return index;
    var errors: std.zig.ErrorBundle.Wip = try .init(fe.gpa);
    defer errors.deinit();
    var index: [1]?File.Index = undefined;
    const ok = try fe.load(&.{.{ .module = mod, .sub_path = sub_path, .optional = true }}, &index, &errors);
    if (errors.root_list.items.len > 0) {
        try fe.late_errors.ensureUnusedCapacity(fe.gpa, 1);
        fe.late_errors.appendAssumeCapacity(try errors.toOwnedBundle(""));
        return error.AstGenFailed;
    }
    assert(ok);
    return index[0];
}

const Root = struct {
    module: Module.Index,
    sub_path: []const u8,
    /// A missing file is not an error: its index is null.
    optional: bool = false,
};

pub const ZonImport = struct { module: Module.Index, sub_path: []const u8 };

/// Loads `roots` and every file they reach that is not loaded yet, and
/// numbers the new files breadth-first after the loaded ones. Stores each
/// root's index in `indices`.
fn load(fe: *Frontend, roots: []const Root, indices: []?File.Index, errors: *std.zig.ErrorBundle.Wip) !bool {
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

    var root_jobs: [5]*Job = undefined;
    for (roots, root_jobs[0..roots.len]) |r, *j| j.* = try l.getJob(r.module, r.sub_path);
    l.work(.main);
    l.group.await(io) catch {}; // ziglint-ignore: Z026 -- bs never cancels this group
    if (l.failure) |err| return err;
    const finish_start = Io.Clock.awake.now(io);

    // Number the new files breadth-first in import order, as a serial load
    // would.
    var stats = fe.stats;
    const base = fe.files.items.len;
    var order: std.ArrayList(*Job) = try .initCapacity(gpa, l.jobs.count());
    defer order.deinit(gpa);
    var skipped: u32 = 0;
    for (roots, root_jobs[0..roots.len], indices) |r, job, *index| {
        if (job.missing != null and r.optional) {
            index.* = null;
            skipped += 1;
            continue;
        }
        if (job.index == null) {
            job.index = @fromBackingInt(@intCast(base + order.items.len));
            order.appendAssumeCapacity(job);
        }
        index.* = job.index;
    }
    var i: usize = 0;
    var any_missing = false;
    while (i < order.items.len) : (i += 1) {
        const job = order.items[i];
        if (job.missing) |err| {
            // As upstream, an imported file that cannot be read is an
            // error at that file, with a note at the import.
            const importer = for (order.items[0..i]) |o| {
                if (std.mem.findScalar(*Job, o.imports, job) != null) break o;
            } else fatalFile(job.file.display_path, err);
            try fe.addMissingFile(errors, importer, job, err);
            any_missing = true;
            continue;
        }
        for (job.zon_imports) |sub_path| {
            const path = try Io.Dir.path.join(gpa, &.{ fe.module(job.file.module).root_dir, sub_path });
            defer gpa.free(path);
            _ = Io.Dir.cwd().statFile(io, path, .{}) catch |err| {
                try fe.addMissingZon(errors, job, sub_path, err);
                any_missing = true;
                continue;
            };
            for (fe.zon_imports.items) |z| {
                if (z.module == job.file.module and std.mem.eql(u8, z.sub_path, sub_path)) break;
            } else try fe.zon_imports.append(gpa, .{ .module = job.file.module, .sub_path = try gpa.dupe(u8, sub_path) });
        }
        for (job.imports) |imp| {
            if (imp.index != null) continue;
            imp.index = @fromBackingInt(@intCast(base + order.items.len));
            imp.importer = job;
            order.appendAssumeCapacity(imp);
        }
    }
    if (try fe.checkModuleOverlap(errors, root_jobs[0..roots.len], order.items)) return false;
    if (any_missing) return false;
    var existing: u32 = 0;
    var jit = l.jobs.valueIterator();
    while (jit.next()) |job| existing += @intFromBool(job.*.existing);
    stats.guessed += @intCast(l.jobs.count() - order.items.len - existing - skipped);

    try fe.files.ensureUnusedCapacity(gpa, order.items.len);
    try fe.file_map.ensureUnusedCapacity(gpa, @intCast(order.items.len));
    stats.files += @intCast(order.items.len);
    stats.threads = @max(stats.threads, l.helpers + 1);
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
        if (e.value_ptr.*.existing) continue;
        const index = e.value_ptr.*.index orelse continue;
        fe.file_map.putAssumeCapacityNoClobber(e.key_ptr.*, index);
    }
    moved = true;

    var ok = true;
    for (fe.files.items[base..], order.items, base..) |*f, job, index| {
        // Not `f.zir.hasCompileErrors()`: that would fault in a page of every file.
        if (!job.has_errors) continue;
        const syntax = try fe.syntaxOf(@fromBackingInt(@intCast(index)));
        try frontend.errors.addZirErrorMessages(errors, f.zir, syntax.tree, syntax.source, f.display_path);
        if (f.zir.loweringFailed()) ok = false;
    }

    // Record what this build learned about file stats.
    for (&fe.caches) |*slot| {
        const cd = if (slot.*) |*cd| cd else continue;
        var updates: std.ArrayList(IndexUpdate) = .empty;
        defer updates.deinit(gpa);
        for (order.items) |job| {
            const update = job.index_update orelse continue;
            if (fe.cacheFor(fe.module(job.file.module)) == cd) try updates.append(gpa, update);
        }
        if (updates.items.len == 0) continue;
        std.mem.sortUnstable(IndexUpdate, updates.items, {}, struct {
            fn lessThan(_: void, a: IndexUpdate, b: IndexUpdate) bool {
                return a.entry.path_hash < b.entry.path_hash;
            }
        }.lessThan);
        var merged: std.ArrayList(IndexEntry) = .empty;
        defer merged.deinit(gpa);
        var superseded: std.ArrayList(Hash) = .empty;
        defer superseded.deinit(gpa);
        cd.writeIndex(gpa, io, updates.items, &merged, &superseded) catch |err| {
            if (!fe.zir_save_failed.swap(true, .monotonic))
                std.log.warn("unable to write ZIR cache index: {t}; not reporting further failures", .{err});
            continue;
        };
        // Best effort: what it misses goes with the store's packs.
        if (superseded.items.len != 0) cd.sweepSuperseded(gpa, io, fe.blobCache().?, merged.items, superseded.items, Io.Clock.real.now(io)) catch {}; // ziglint-ignore: Z026 -- cache upkeep is best effort
    }

    const end = Io.Clock.awake.now(io);
    stats.load_ns += @intCast(start.durationTo(end).toNanoseconds());
    stats.finish_ns += @intCast(finish_start.durationTo(end).toNanoseconds());
    fe.stats = stats;
    return ok;
}

/// A file's key in the stat index, salted with `zir_salt`: a bs with
/// another AstGen keeps its own entries rather than taking this one's
/// content hash for a file it hashes differently.
fn pathHash(mod: *const Module, sub_path: []const u8) u64 {
    var h: std.hash.Wyhash = .init(zir_salt);
    h.update(mod.abs_root_dir.?);
    h.update("/");
    h.update(sub_path);
    return h.final();
}

/// Maps a file's ZIR from the cache if the index says the file is unchanged.
/// Returns null if the file must be lowered.
fn probeFile(fe: *Frontend, job: *Job, buf: *std.ArrayList(u8), loader_start_ns: i96) !union(enum) {
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
    const blobs = fe.blobCache().?;
    const summary: Summary = .{ .has_errors = entry.has_errors != 0, .names = cd.names(entry) };
    if (!entry.matches(stat)) return .{ .changed = summary };
    f.content_hash = entry.content_hash;
    job.how = .stat_hit;
    job.loaded = true;
    // The ZIR is mapped on first use (`file`), except a file with errors,
    // whose messages the build reports now.
    if (summary.has_errors) {
        f.zir, f.mapping, _ = blobs.loadZir(fe.gpa, fe.io, entry.content_hash, buf, true) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                job.loaded = false;
                return .miss;
            },
        };
        return .{ .hit = summary };
    }
    f.zir_ready = .init(false);
    // Renewed once a day, as mapping it would: the global cache's
    // maintenance trims ZIR by mtime. ZIR that is gone is lowered again now.
    if (entry.renewed_ns < loader_start_ns - std.time.ns_per_day) {
        const name = std.fmt.bytesToHex(entry.content_hash, .lower);
        const zf = blobs.dir.openFile(fe.io, &name, .{}) catch {
            f.zir_ready = .init(true);
            job.loaded = false;
            return .miss;
        };
        defer zf.close(fe.io);
        zf.setTimestampsNow(fe.io) catch {}; // ziglint-ignore: Z026 -- cache upkeep is best effort
        var e = entry.*;
        e.renewed_ns = @intCast(loader_start_ns);
        job.index_update = .{ .entry = e, .names = try fe.gpa.dupe(u8, summary.names) };
    }
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
    if (cache != null) {
        const stat = job.stat.?;
        const mtime: i64 = @intCast(stat.mtime.toNanoseconds());
        job.index_update = .{ .entry = .{
            .path_hash = pathHash(mod, f.sub_path),
            .inode = @intCast(stat.inode),
            .size = stat.size,
            .mtime = if (mtime >= l.start_ns - IndexEntry.racy_window_ns) IndexEntry.racy_mtime else mtime,
            .content_hash = f.content_hash,
            .renewed_ns = @intCast(l.start_ns),
        }, .names = "" };
        if (fe.blobCache().?.loadZir(gpa, io, f.content_hash, buf, true)) |loaded| {
            f.zir, f.mapping, const summary = loaded;
            job.how = .content_hit;
            job.loaded = true;
            return summary;
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        }
    }

    const ast = try Ast.parse(arena, src, .{ .mode = .zig, .language = fe.syntax_language });
    const zir = try AstGen.generate(arena, ast);
    const summary: Summary = try .of(arena, &zir);
    job.how = .lowered;
    if (fe.lint) |cfg| if (ast.errors.len == 0 and cfg.covers(try fe.absPath(arena, f))) {
        f.lint_facts = try Linter.encode(gpa, Linter.run(arena, src, ast, f.sub_path));
        if (cache != null) fe.blobCache().?.saveLintFacts(io, lintFactsName(f), f.lint_facts.?);
    };
    if (cache != null) {
        const blobs = fe.blobCache().?;
        if (blobs.saveZir(gpa, io, f.content_hash, &zir, summary)) |_| {
            if (blobs.loadZir(gpa, io, f.content_hash, buf, true)) |loaded| {
                f.zir, f.mapping, _ = loaded;
                job.loaded = true;
                return summary;
            } else |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {},
            }
        } else |err| if (!fe.zir_save_failed.swap(true, .monotonic))
            std.log.warn("unable to cache ZIR of '{s}': {t}; not reporting further failures", .{ f.display_path, err });
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
/// frontend load: `.zig` paths, `std`, `root`, and `builtin`. Unknown
/// modules are reported by Sema only if the import is actually analyzed,
/// matching upstream.
fn collectImports(fe: *const Frontend, f: *const File, names: []const u8) ![]Import {
    const gpa = fe.gpa;
    var list: std.ArrayList(Import) = .empty;
    errdefer freeImports(gpa, list.items);
    var it = std.mem.tokenizeScalar(u8, names, 0);
    while (it.next()) |name| {
        try list.ensureUnusedCapacity(gpa, 1);
        list.appendAssumeCapacity((try fe.resolveImport(f, name)) orelse continue);
    }
    return list.toOwnedSlice(gpa);
}

/// The ZON files that `f` imports by path (`Job.zon_imports`), each
/// allocated with `gpa`.
fn collectZonImports(fe: *const Frontend, f: *const File, names: []const u8) ![][]const u8 {
    const gpa = fe.gpa;
    var list: std.ArrayList([]const u8) = .empty;
    errdefer freeZonImports(gpa, list.items);
    var it = std.mem.tokenizeScalar(u8, names, 0);
    while (it.next()) |name| {
        try list.ensureUnusedCapacity(gpa, 1);
        list.appendAssumeCapacity((try fe.resolveZonImport(f, name)) orelse continue);
    }
    return list.toOwnedSlice(gpa);
}

/// The path of the ZON file `@import(name)` in `f` reads, relative to its
/// module's root directory, allocated with `gpa`; null if `name` is not a
/// ZON file inside the module (a path outside it is Sema's error).
fn resolveZonImport(fe: *const Frontend, f: *const File, name: []const u8) !?[]const u8 {
    if (!std.mem.endsWith(u8, name, ".zon") or fe.depModule(f.module, name) != null) return null;
    const sub_path = try Io.Dir.path.resolveAllocPosix(fe.gpa, &.{ Io.Dir.path.dirname(f.sub_path) orelse "", name });
    if (std.mem.eql(u8, sub_path, "..") or std.mem.startsWith(u8, sub_path, "../")) {
        fe.gpa.free(sub_path);
        return null;
    }
    return sub_path;
}

/// The file `@import(name)` in `f` loads, or null if the frontend leaves
/// the import to Sema. `sub_path` is allocated with `gpa`.
fn resolveImport(fe: *const Frontend, f: *const File, name: []const u8) !?Import {
    const gpa = fe.gpa;
    if (fe.depModule(f.module, name)) |m| {
        // A ZON module is Sema's to read, like a ZON file.
        if (std.mem.endsWith(u8, fe.module(m).root_file, ".zon")) return null;
        return .{ .module = m, .sub_path = try gpa.dupe(u8, fe.module(m).root_file) };
    }
    if (std.mem.endsWith(u8, name, ".zig")) {
        const sub_path = try Io.Dir.path.resolveAllocPosix(gpa, &.{ Io.Dir.path.dirname(f.sub_path) orelse "", name });
        // A path outside the module is Sema's error, at the import.
        if (std.mem.eql(u8, sub_path, "..") or std.mem.startsWith(u8, sub_path, "../")) {
            gpa.free(sub_path);
            return null;
        }
        return .{ .module = f.module, .sub_path = sub_path };
    }
    if (fe.familyModule(f.module, name)) |m| return .{ .module = m, .sub_path = try gpa.dupe(u8, fe.module(m).root_file) };
    // ZON files are Sema's to read (`collectZonImports`).
    return null;
}

/// As upstream, a file belongs to one module: if two modules reach the same
/// file (`order` is breadth-first, as upstream's traversal), reports the
/// first such file, with notes on how each module reaches it, and returns
/// true. Only the main family's modules count: the fuzzer's is upstream's
/// separate compilation.
fn checkModuleOverlap(fe: *Frontend, errors: *std.zig.ErrorBundle.Wip, root_jobs: []const *Job, order: []const *Job) !bool {
    var arena_state: std.heap.ArenaAllocator = .init(fe.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var seen: std.StringHashMapUnmanaged(*Job) = .empty;
    const job = for (order) |job| {
        if (job.missing != null) continue;
        const m = fe.module(job.file.module);
        if (m.std_mod != .std) continue;
        const path = try Io.Dir.path.resolveAlloc(arena, &.{ m.abs_root_dir orelse m.root_dir, job.file.sub_path });
        const gop = try seen.getOrPut(arena, path);
        if (!gop.found_existing) {
            gop.value_ptr.* = job;
            continue;
        }
        break [2]*Job{ gop.value_ptr.*, job };
    } else return false;
    var notes: std.ArrayList(std.zig.ErrorBundle.MessageIndex) = .empty;
    try notes.append(arena, try errors.addErrorMessage(.{
        .msg = try errors.addString("files must belong to only one module"),
        .src_loc = try wholeFileLoc(errors, job[0].file.display_path),
    }));
    for (job) |j| {
        // Upstream's `explainWhyFileIsInModule`: up the importers to the
        // root of the module.
        if (fe.isModuleRoot(j, root_jobs)) {
            try notes.append(arena, try errors.addErrorMessage(.{
                .msg = try errors.printString("file is the root of module '{s}'", .{fe.overlapName(j.file.module)}),
                .src_loc = try wholeFileLoc(errors, j.file.display_path),
            }));
            continue;
        }
        var cur = j;
        var thing: []const u8 = "file";
        while (cur.importer) |imp| : (thing = "which") {
            const loc = try fe.tokenLoc(errors, imp, try fe.importToken(imp, cur.file.module, cur.file.sub_path, false));
            if (fe.isModuleRoot(imp, root_jobs)) {
                try notes.append(arena, try errors.addErrorMessage(.{
                    .msg = try errors.printString("{s} is imported here by the root of module '{s}'", .{ thing, fe.overlapName(imp.file.module) }),
                    .src_loc = loc,
                }));
                break;
            }
            try notes.append(arena, try errors.addErrorMessage(.{
                .msg = try errors.printString("{s} is imported here", .{thing}),
                .src_loc = loc,
            }));
            cur = imp;
        }
    }
    try errors.addRootErrorMessage(.{
        .msg = try errors.printString("file exists in modules '{s}' and '{s}'", .{ fe.overlapName(job[0].file.module), fe.overlapName(job[1].file.module) }),
        .src_loc = try wholeFileLoc(errors, job[0].file.display_path),
        .notes_len = @intCast(notes.items.len),
    });
    const notes_start = try errors.reserveNotes(@intCast(notes.items.len));
    @memcpy(errors.extra.items[notes_start..][0..notes.items.len], @as([]const u32, @ptrCast(notes.items)));
    return true;
}

/// Whether `job` is the root file of its module, or one of the files a
/// load starts from.
fn isModuleRoot(fe: *const Frontend, job: *const Job, root_jobs: []const *Job) bool {
    return std.mem.findScalar(*const Job, root_jobs, job) != null or
        std.mem.eql(u8, job.file.sub_path, fe.module(job.file.module).root_file);
}

/// A module's name in `checkModuleOverlap`'s error: upstream's fully
/// qualified name, `root` for the root module.
fn overlapName(fe: *const Frontend, m: Module.Index) []const u8 {
    return if (m == .root) "root" else fe.displayName(m);
}

/// Reports `job`, which `importer` imports, as a file that could not be
/// read: upstream's error at the file, with a note at the import.
fn addMissingFile(fe: *Frontend, errors: *std.zig.ErrorBundle.Wip, importer: *const Job, job: *const Job, err: anyerror) !void {
    const token = try fe.importToken(importer, job.file.module, job.file.sub_path, false);
    try fe.addUnreadable(errors, importer, token, job.file.display_path, err);
}

/// Reports the ZON file `sub_path` that `importer` imports as a file that
/// could not be read, as `addMissingFile`.
fn addMissingZon(fe: *Frontend, errors: *std.zig.ErrorBundle.Wip, importer: *const Job, sub_path: []const u8, err: anyerror) !void {
    const token = try fe.importToken(importer, importer.file.module, sub_path, true);
    const path = try Io.Dir.path.join(fe.gpa, &.{ fe.module(importer.file.module).root_dir, sub_path });
    defer fe.gpa.free(path);
    try fe.addUnreadable(errors, importer, token, path, err);
}

fn addUnreadable(fe: *Frontend, errors: *std.zig.ErrorBundle.Wip, importer: *const Job, token: ?Ast.TokenIndex, path: []const u8, err: anyerror) !void {
    const note_loc = try fe.tokenLoc(errors, importer, token);
    try errors.addRootErrorMessage(.{
        // As upstream, the file by its base name; its path is the location.
        .msg = try errors.printString("unable to load \"{s}\": {t}", .{ Io.Dir.path.basename(path), err }),
        .src_loc = try wholeFileLoc(errors, path),
        .notes_len = 1,
    });
    const notes_start = try errors.reserveNotes(1);
    // Not one statement: adding the message can move `extra`.
    const note = try errors.addErrorMessage(.{ .msg = try errors.addString("file imported here"), .src_loc = note_loc });
    errors.extra.items[notes_start] = @backingInt(note);
}

/// The token of the `@import` in `importer` that names `sub_path` of
/// module `mod` (a ZON file's if `zon`), if there is one.
fn importToken(fe: *Frontend, importer: *const Job, mod: Module.Index, sub_path: []const u8, zon: bool) !?Ast.TokenIndex {
    const gpa = fe.gpa;
    const f = &importer.file;
    if (!f.zir_ready.load(.acquire)) fe.ensureZir(@constCast(f));
    const imports_index = f.zir.extra[@backingInt(Zir.ExtraIndex.imports)];
    if (imports_index == 0) return null;
    const imports = f.zir.extraData(Zir.Inst.Imports, imports_index);
    var extra_index = imports.end;
    for (0..imports.data.imports_len) |_| {
        const item = f.zir.extraData(Zir.Inst.Imports.Item, extra_index);
        extra_index = item.end;
        const item_name = f.zir.nullTerminatedString(item.data.name);
        if (zon) {
            const p = (try fe.resolveZonImport(f, item_name)) orelse continue;
            defer gpa.free(p);
            if (std.mem.eql(u8, p, sub_path)) return item.data.token;
        } else {
            const imp = (try fe.resolveImport(f, item_name)) orelse continue;
            defer gpa.free(imp.sub_path);
            if (imp.module == mod and std.mem.eql(u8, imp.sub_path, sub_path)) return item.data.token;
        }
    }
    return null;
}

/// Token `token` of `job`'s file as an error location, read from the
/// file's source; none if `token` is null or the file cannot be read.
fn tokenLoc(fe: *Frontend, errors: *std.zig.ErrorBundle.Wip, job: *const Job, token: ?Ast.TokenIndex) !std.zig.ErrorBundle.SourceLocationIndex {
    const gpa = fe.gpa;
    const t = token orelse return .none;
    const path = job.file.display_path;
    const src = Io.Dir.cwd().readFileAllocOptions(fe.io, path, gpa, .unlimited, .of(u8), 0) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .none,
    };
    defer gpa.free(src);
    var tokenizer: frontend.Tokenizer = .init(src);
    var tok = tokenizer.next();
    for (0..t) |_| tok = tokenizer.next();
    const lc = std.zig.findLineColumn(src, tok.loc.start);
    return errors.addSourceLocation(.{
        .src_path = try errors.addString(path),
        .line = @intCast(lc.line),
        .column = @intCast(lc.column),
        .span_start = @intCast(tok.loc.start),
        .span_main = @intCast(tok.loc.start),
        .span_end = @intCast(tok.loc.end),
        .source_line = try errors.addString(lc.source_line),
    });
}

/// A whole file as an error location, as upstream's (line 1, column 1).
fn wholeFileLoc(errors: *std.zig.ErrorBundle.Wip, path: []const u8) !std.zig.ErrorBundle.SourceLocationIndex {
    return errors.addSourceLocation(.{ .src_path = try errors.addString(path), .line = 0, .column = 0, .span_start = 0, .span_main = 0, .span_end = 0 });
}

fn fatalFile(path: []const u8, err: anyerror) noreturn {
    std.process.fatal("unable to load '{s}': {t}", .{ path, err });
}

/// Prints `stats` to stderr (`BS_FRONTEND_TIMING=1`).
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
    const root = try gpa.print(".zig-cache/tmp/{s}/main.zig", .{tmp.sub_path});
    defer gpa.free(root);

    var fe: Frontend = try .init(gpa, io, "/nonexistent", .{ .root_src_path = root, .builtin_dir = "/nonexistent", .load_std = false });
    defer fe.deinit();
    var errors: std.zig.ErrorBundle.Wip = try .init(gpa);
    defer errors.deinit();
    try std.testing.expect(try fe.loadAll(&errors));
    try std.testing.expectEqual(2, fe.files.items.len);
    try std.testing.expectEqualStrings("a.zig", fe.file(@fromBackingInt(@intCast(1))).sub_path);

    // On demand: b.zig and c.zig are new, a.zig is reused.
    try tmp.dir.writeFile(io, .{ .sub_path = "b.zig", .data = "const a = @import(\"a.zig\");\nconst c = @import(\"c.zig\");\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "c.zig", .data = "pub const x = 1;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "d.zig", .data = "fn f() void { var x: u32 = 1; }\n" });
    const b = (try fe.loadFile(.root, "b.zig")).?;
    try std.testing.expectEqual(2, @backingInt(b));
    try std.testing.expectEqual(4, fe.files.items.len);
    try std.testing.expectEqualStrings("c.zig", fe.file(@fromBackingInt(@intCast(3))).sub_path);
    try std.testing.expectEqual(b, (try fe.loadFile(.root, "b.zig")).?);
    try std.testing.expectEqual(null, try fe.loadFile(.root, "missing.zig"));
    try std.testing.expectEqual(4, fe.files.items.len);
    try std.testing.expectError(error.AstGenFailed, fe.loadFile(.root, "d.zig"));
    try std.testing.expectEqual(1, fe.late_errors.items.len);
    try std.testing.expectEqual(1, fe.late_errors.items[0].errorMessageCount());
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
    const base = try gpa.print(".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(base);
    const root = try Io.Dir.path.join(gpa, &.{ base, "main.zig" });
    defer gpa.free(root);
    const cache = try Io.Dir.path.join(gpa, &.{ base, "cache" });
    defer gpa.free(cache);

    const Run = struct {
        fe: Frontend,
        errors: std.zig.ErrorBundle.Wip,
        ok: bool,

        const Self = @This();
        fn init(r: *Self, root_path: []const u8, cache_path: []const u8) !void {
            r.fe = try .init(gpa, io, "/nonexistent", .{ .root_src_path = root_path, .builtin_dir = "/nonexistent", .load_std = false });
            errdefer r.fe.deinit();
            try r.fe.enableCache(.{ .local = cache_path, .global = cache_path });
            r.errors = try .init(gpa);
            errdefer r.errors.deinit();
            r.ok = try r.fe.loadAll(&r.errors);
        }

        fn deinit(r: *Self) void {
            r.errors.deinit();
            r.fe.deinit();
            r.* = undefined;
        }

        fn errorCount(r: *Self) !u32 {
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
    for (0..cold.fe.files.items.len) |fi| {
        const c = cold.fe.file(@fromBackingInt(@intCast(fi)));
        // A stat hit maps its ZIR on first use.
        try std.testing.expect(!warm.fe.files.items[fi].zir_ready.load(.monotonic));
        const w = warm.fe.file(@fromBackingInt(@intCast(fi)));
        try std.testing.expectEqualStrings(c.sub_path, w.sub_path);
        try std.testing.expectEqualSlices(u8, @ptrCast(c.zir.instructions.items(.tag)), @ptrCast(w.zir.instructions.items(.tag)));
        try std.testing.expectEqualSlices(u32, c.zir.extra, w.zir.extra);
        try std.testing.expectEqualSlices(u8, c.zir.string_bytes, w.zir.string_bytes);
    }

    // ZIR that the cache's maintenance deleted after the frontend found its
    // stat unchanged is lowered again on first use, and cached again.
    {
        var gone: Run = undefined;
        try gone.init(root, cache);
        defer gone.deinit();
        try std.testing.expectEqual(3, gone.fe.stats.stat_hits);
        const g = &gone.fe.files.items[1];
        var name_buf: [128]u8 = undefined;
        const blob = try std.mem.print(&name_buf, "{s}/bs/zir/{s}", .{ cache, &std.fmt.bytesToHex(g.content_hash, .lower) });
        try Io.Dir.cwd().deleteFile(io, blob);
        const c = cold.fe.file(@fromBackingInt(1));
        const w = gone.fe.file(@fromBackingInt(1));
        try std.testing.expect(w.mapping == null);
        try std.testing.expectEqualSlices(u32, c.zir.extra, w.zir.extra);
        try std.testing.expectEqualSlices(u8, c.zir.string_bytes, w.zir.string_bytes);
        _ = try Io.Dir.cwd().statFile(io, blob, .{});
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

test "drops the ZIR of edited sources once no build maps it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const t = std.testing;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old: Io.File.SetTimestamp = .{ .new = .fromNanoseconds(1_000_000_000 * std.time.ns_per_s) };
    const sources = [_][]const u8{ "pub const x = 1;\n", "pub const x = 2;\n", "pub const x = 3;\n" };
    try tmp.dir.createDirPath(io, "a");
    try tmp.dir.createDirPath(io, "b");
    try tmp.dir.writeFile(io, .{ .sub_path = "b/main.zig", .data = sources[1] });
    try tmp.dir.setTimestamps(io, "b/main.zig", .{ .modify_timestamp = old });
    const base = try gpa.print(".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(base);
    const global = try Io.Dir.path.join(gpa, &.{ base, "global" });
    defer gpa.free(global);

    // `a/main.zig` at `sources[i]`, built with its own local cache.
    const build = struct {
        fn build(dir: Io.Dir, b: []const u8, g: []const u8, sub: []const u8, src: ?[]const u8) !Frontend {
            const path = try gpa.print("{s}/main.zig", .{sub});
            defer gpa.free(path);
            if (src) |s| {
                try dir.writeFile(io, .{ .sub_path = path, .data = s });
                // Old enough that the index trusts it, and another stat per source.
                try dir.setTimestamps(io, path, .{ .modify_timestamp = .{ .new = .fromNanoseconds((1_000_000_000 + @as(i96, s[14])) * std.time.ns_per_s) } });
            }
            const root = try Io.Dir.path.join(gpa, &.{ b, path });
            defer gpa.free(root);
            const local = try Io.Dir.path.join(gpa, &.{ b, sub, "local" });
            defer gpa.free(local);
            var fe: Frontend = try .init(gpa, io, "/nonexistent", .{ .root_src_path = root, .builtin_dir = "/nonexistent", .load_std = false });
            errdefer fe.deinit();
            try fe.enableCache(.{ .local = local, .global = g });
            var errors: std.zig.ErrorBundle.Wip = try .init(gpa);
            defer errors.deinit();
            try t.expect(try fe.loadAll(&errors));
            return fe;
        }
    }.build;
    var hashes: [3]Hash = undefined;
    for (&hashes, sources) |*h, s| h.* = hashSource(s);
    var fe0 = try build(tmp.dir, base, global, "a", sources[0]);
    fe0.deinit();
    var zir = try tmp.dir.openDir(io, "global/bs/zir", .{});
    defer zir.close(io);
    // The edit marks the old ZIR as unused for two days.
    var fe1 = try build(tmp.dir, base, global, "a", sources[1]);
    defer fe1.deinit();
    const now = Io.Clock.real.now(io);
    const marked = try zir.statFile(io, &std.fmt.bytesToHex(hashes[0], .lower), .{});
    try t.expect(marked.mtime.durationTo(now).toNanoseconds() > std.time.ns_per_day);
    // A worktree with the next source maps its ZIR, then the source is
    // superseded too: that renews it, so it stays; the first goes an hour
    // after it was superseded.
    var fe2 = try build(tmp.dir, base, global, "a", sources[2]);
    defer fe2.deinit();
    var other = try build(tmp.dir, base, global, "b", null);
    defer other.deinit();
    try t.expectEqual(1, other.stats.content_hits);
    const cd = &fe2.caches[@backingInt(CacheKind.local)].?;
    var index: CacheDir = .{ .dir = cd.dir, .index = &.{}, .index_names = &.{}, .index_bytes = &.{}, .global = false, .renew_before_ns = 0 };
    try index.loadIndex(gpa, io);
    defer gpa.free(index.index_bytes);
    try cd.sweepSuperseded(gpa, io, fe2.blobCache().?, index.index, &.{}, now.addDuration(.fromNanoseconds(2 * std.time.ns_per_hour)));
    try t.expectError(error.FileNotFound, zir.statFile(io, &std.fmt.bytesToHex(hashes[0], .lower), .{}));
    _ = try zir.statFile(io, &std.fmt.bytesToHex(hashes[1], .lower), .{});
    _ = try zir.statFile(io, &std.fmt.bytesToHex(hashes[2], .lower), .{});
    // Both left the list: one deleted, one renewed.
    try t.expectError(error.FileNotFound, cd.dir.statFile(io, "superseded", .{}));
}
