const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const build_options = @import("build_options");
const diag = @import("diag.zig");
const Frontend = @import("Frontend.zig");
const BuildWeb = @import("BuildWeb.zig");
const Zcu = @import("Zcu.zig");
const Ir = @import("Ir.zig");
const Emit = @import("Emit.zig");
const inline_ir = @import("codegen/inline.zig");
const Incremental = @import("Incremental.zig");
const Builtin = @import("Builtin.zig");
const Archive = @import("link/Archive.zig");
const ElfInput = @import("link/ElfInput.zig");
const ElfShared = @import("link/ElfShared.zig");
const Docs = @import("Docs.zig");
const Glibc = @import("link/Glibc.zig");
const CSource = @import("CSource.zig");

pub const zig_version = "0.17.1";

const usage =
    \\Usage: zap [command] [options]
    \\
    \\zap is a fast Debug-mode compiler for Zig 0.17.1.
    \\
    \\Commands:
    \\  build            Build project from build.zig
    \\  build-exe        Create executable from source
    \\  build-obj        Create object from source
    \\  build-lib        Create static library from source
    \\  run              Create executable and run immediately
    \\  test             Perform unit testing
    \\  translate-c      Convert C code to Zig code
    \\  fmt              Reformat Zig source into canonical form
    \\  ast-check        Look for simple compile errors in any set of files
    \\  env              Print lib path, std path, cache directory, and version
    \\  version          Print the Zig version zap compiles
    \\  help             Print this help and exit
    \\
;

pub const Command = enum { build_exe, build_obj, build_lib, run, @"test" };

/// Options shared by the compile commands. Spelled like `zig build-exe`.
pub const Options = struct {
    command: Command,
    root_src_path: []const u8,
    /// The root module's directory if not `root_src_path`'s (only for
    /// tools zap builds, `Frontend.Options.root_dir`); no flag sets it.
    root_dir: ?[]const u8 = null,
    name: ?[]const u8 = null,
    emit_bin: union(enum) { default, path: []const u8, none } = .default,
    /// `-femit-docs[=path]`: the autodocs directory (Docs.zig).
    emit_docs: union(enum) { default, path: []const u8, none } = .none,
    target: ?[]const u8 = null,
    zig_lib_dir: ?[]const u8 = null,
    /// `--cache-dir` and `--global-cache-dir`.
    cache_dir: ?[]const u8 = null,
    global_cache_dir: ?[]const u8 = null,
    /// `--build-root`: the project's directory, for the paths of the
    /// inputs a `--listen=-` build reports.
    build_root: ?[]const u8 = null,
    /// Arguments after `--` for `zap run`.
    run_args: []const []const u8 = &.{},
    /// `zap test` only: the test runner's root source file (`--test-runner`).
    test_runner: ?[]const u8 = null,
    /// `zap test` only: include only tests whose names contain one of these.
    test_filters: []const []const u8 = &.{},
    /// `zap test` only: build the test binary without running it.
    test_no_exec: bool = false,
    /// `--error-format`: how compile errors print to stderr.
    error_format: diag.Format = .text,
    /// Print the typed IR of every analyzed function to stdout
    /// (`--debug-dump-ir`, for zap's own tests and debugging).
    dump_ir: bool = false,
    /// `--stack`: the main thread's stack size in bytes, which std's start
    /// code sets from PT_GNU_STACK; upstream's default is 16 MiB.
    stack_size: u64 = 16 * 1024 * 1024,
    /// `-fsingle-threaded`.
    single_threaded: bool = false,
    /// `-ffuzz` on any module: instrument those modules for upstream's
    /// fuzzer and link it (docs/architecture.md, "Fuzzing").
    fuzz: bool = false,
    /// `-ffuzz` or `-fno-fuzz` on the root module, which std and the test
    /// runner inherit, and `builtin.fuzz` reports; other modules have
    /// theirs in `modules`.
    root_fuzz: bool = false,
    /// The root module's `-O` (Debug or ReleaseSafe), `-ferror-tracing`
    /// and `-fvalgrind`, resolved as upstream's: std and the test runner
    /// inherit them, other modules have theirs in `modules`.
    optimize: std.lang.Optimize = .debug,
    error_tracing: bool = true,
    valgrind: bool = true,
    /// `-funwind-tables`, `-fasync-unwind-tables`, `-fno-unwind-tables`:
    /// only what `builtin.unwind_tables` says (Builtin.Options).
    unwind_tables: std.lang.UnwindTables = .async,
    /// `-fPIC` on `build-obj` and `build-lib`, and `-fPIE` on `build-obj`
    /// (which sets both): position-independent code (see
    /// "Position-independent code" in docs/architecture.md). On executables
    /// both are accepted and ignored.
    pic: bool = false,
    pie: bool = false,
    /// `-dynamic` on `build-lib`: a shared object, position-independent.
    dynamic: bool = false,
    /// `-lc` (or another of glibc's libraries, `-lm`, `-lpthread`, ...):
    /// link glibc dynamically, with `glibc_version` resolved from the
    /// target (see "C interop" in docs/architecture.md).
    link_libc: bool = false,
    glibc_version: ?std.SemanticVersion = null,
    /// `-lc++` (or `-lstdc++`, `-lc++abi`, `-lsupc++`, as upstream): libc++'s
    /// headers for the C and C++ sources, and in an executable libc++,
    /// libc++abi and libunwind, built from the lib directory (CSource.zig).
    /// Implies `link_libc`.
    link_libcpp: bool = false,
    /// `-dynamic` on an executable, which only `-lc` makes one.
    exe_dynamic: bool = false,
    /// ELF objects (`.o`) and archives (`.a`) to link into the executable,
    /// in command-line order (docs/architecture.md, "Object, archive and
    /// shared-library inputs").
    link_inputs: []const []const u8 = &.{},
    /// Shared libraries (`.so`) the executable imports from, in
    /// command-line order, given by path or found by `-l`.
    shared_libs: []const []const u8 = &.{},
    /// DT_RUNPATH of a dynamically linked executable, as upstream's: the
    /// `-rpath` arguments, then for the native target the `-L`
    /// directories, without repeats, joined with ':'; null for none.
    runpath: ?[]const u8 = null,
    /// C source files, each with its module's C arguments and options,
    /// compiled by upstream's Clang (CSource.zig), and the settings they
    /// share.
    c_sources: []const CSource = &.{},
    /// A static library of C sources only (no Zig root module): its
    /// archive holds their objects, and zap analyzes no Zig.
    c_only: bool = false,
    /// An executable of C sources only, linking glibc: its root file is
    /// zap's (`Builtin.c_main`), and C defines `main`.
    c_exe: bool = false,
    c_global_cc_argv: []const []const u8 = &.{},
    /// `std.zig.system.NativePaths`' include directories, which upstream's
    /// C takes after libc's when a native build names system libraries
    /// (`native_system_include_paths`).
    c_native_includes: []const []const u8 = &.{},
    c_pie: bool = false,
    /// `-fllvm`: the backend upstream would use, which zap does not, but
    /// which gives the compilation's C a stack protector upstream.
    use_llvm: bool = false,
    function_sections: bool = false,
    data_sections: bool = false,
    /// `--verbose-cc`: print each Clang command line, as upstream.
    verbose_cc: bool = false,
    /// `-fsoname=<name>` and `-fno-soname`; by default the shared object's
    /// file name, as upstream's.
    soname: union(enum) { default, name: []const u8, none } = .default,
    /// `--listen=-`: serve std's compiler protocol on stdin and stdout
    /// (`zig build`'s compile steps) instead of compiling once.
    listen: bool = false,
    /// `-freference-trace[=n]`: the reference trace frames of each error
    /// under `--listen=-` (`diag.toBundle`); 0 for `-fno-reference-trace`.
    reference_trace: ?u32 = null,
    /// Why zap cannot build what the options ask for (a release mode, C
    /// sources, LLVM), as a diagnostic's message: the first such option.
    unsupported: ?[]const u8 = null,
    /// The name of the first `-M` module (the root module, or under `zap
    /// test` the module under test), which other modules' `--dep`s name.
    root_name: []const u8 = "root",
    root_deps: []const []const u8 = &.{},
    modules: []const Frontend.ModuleArg = &.{},
};

/// Commands of upstream's CLI that `zig build` runs and zap does not
/// implement, so that they fail with a diagnostic, over the compiler
/// protocol when asked to.
const unsupported_commands: std.StaticStringMap([]const u8) = .initComptime(.{
    .{ "test-obj", "zap does not build test objects yet ('test-obj'); build this step with upstream zig" },
    .{ "cc", "zap does not compile C ('cc'); build this step with upstream zig" },
    .{ "c++", "zap does not compile C++ ('c++'); build this step with upstream zig" },
    .{ "objcopy", "zap does not implement 'objcopy'; run this step with upstream zig" },
});

/// The general-purpose allocator of a ReleaseSafe zap: std's SafeAllocator,
/// as std.start would pick, but over SmpAllocator instead of the page
/// allocator. Over the page allocator it reuses no memory, so every freed
/// bucket and large block is unmapped, and with CodeGen workers each unmap
/// interrupts every other core to flush its TLB: std's tests took 14 s on
/// one thread and 17 s on four. It still catches double and mismatched
/// frees and corrupted allocation footers; a write after free no longer
/// faults, since the memory stays mapped.
///
/// A Debug zap's is std.start's choice, SafeAllocator over the page
/// allocator (a write after free faults), without the stack trace it
/// records per allocation, which made a Debug zap 3–4x slower and
/// `zig build test` with it (2026-11-04). `ZAP_ALLOC_TRACES=<frames>`
/// records them again, to find where a leaked or doubly freed block came
/// from.
var safe_gpa: std.heap.SafeAllocator = undefined;
const own_gpa = (builtin.mode == .safe or builtin.mode == .debug) and !builtin.link_libc;

pub fn main(init_std: std.process.Init) !void {
    var init = init_std;
    if (own_gpa) {
        safe_gpa = if (builtin.mode == .safe) .init(std.heap.smp_allocator, .{}) else .init(std.heap.page_allocator, .{
            .stack_trace_frames = if (init.environ_map.get("ZAP_ALLOC_TRACES")) |v| std.fmt.parseInt(usize, v, 10) catch 7 else 0,
        });
        init.gpa = safe_gpa.allocator();
    }
    // Reports leaks, as std.start does for the allocator it made.
    defer if (own_gpa) {
        _ = safe_gpa.deinit();
    };
    const arena = init.arena.allocator();
    const raw_args = try init.minimal.args.toSlice(arena);
    if (raw_args.len < 2) fatalUsage();
    const cmd = raw_args[1];
    if (std.mem.eql(u8, cmd, "build")) return @import("BuildRunner.zig").run(init, raw_args[2..]);
    if (std.mem.eql(u8, cmd, "translate-c")) return @import("TranslateC.zig").run(init, raw_args[2..]);
    const args = raw_args;
    const command: Command = if (std.mem.eql(u8, cmd, "build-exe"))
        .build_exe
    else if (std.mem.eql(u8, cmd, "build-obj"))
        .build_obj
    else if (std.mem.eql(u8, cmd, "build-lib"))
        .build_lib
    else if (std.mem.eql(u8, cmd, "run"))
        .run
    else if (std.mem.eql(u8, cmd, "test"))
        .@"test"
    else if (std.mem.eql(u8, cmd, "version")) {
        try Io.File.stdout().writeStreamingAll(init.io, zig_version ++ "\n");
        return;
    } else if (std.mem.eql(u8, cmd, "fmt")) {
        return @import("fmt.zig").run(init.gpa, arena, init.io, raw_args[2..]);
    } else if (std.mem.eql(u8, cmd, "ast-check")) {
        return @import("ast_check.zig").run(arena, init.io, raw_args[2..]);
    } else if (std.mem.eql(u8, cmd, "env")) {
        return printEnv(init);
    } else if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        try Io.File.stdout().writeStreamingAll(init.io, usage);
        return;
    } else if (unsupported_commands.get(cmd)) |msg| {
        const listen = for (args[2..]) |a| {
            if (std.mem.eql(u8, a, "--listen=-")) break true;
        } else false;
        const d: []const diag.Diagnostic = &.{.{ .code = .unsupported, .loc = null, .msg = msg }};
        if (listen) return serveFailure(init, d, .Exe);
        printDiagnostics(init.io, d, .text) catch {};
        std.process.exit(1);
    } else fatal("unknown command: {s}", .{cmd});

    const opts = try parseOptions(arena, init.io, init.environ_map, command, args[2..]);
    if (opts.listen) {
        if (BuildWeb.matches(&opts)) return BuildWeb.serve(init, &opts);
        return serve(init, args, opts);
    }
    if (opts.unsupported) |msg| {
        printDiagnostics(init.io, &.{.{ .code = .unsupported, .loc = null, .msg = msg }}, opts.error_format) catch {};
        std.process.exit(1);
    }

    const job = try Job.init(init, args, opts);
    // The command line that describes the compilation: `zap run`'s
    // arguments after `--` are the program's.
    const run_test = job.run_test;
    const out_path: ?[]const u8 = switch (opts.emit_bin) {
        .none => if (run_test) try testBinPath(arena, init.io, job.zapLocal(arena), job.stem) else if (command == .run) fatal("'zap run' needs a binary to run; remove -fno-emit-bin", .{}) else null,
        .path => |p| p,
        .default => if (run_test)
            try testBinPath(arena, init.io, job.zapLocal(arena), job.stem)
        else if (command == .run)
            try runBinPath(arena, init.io, job.zapLocal(arena), job.compile_args, job.zig_lib_dir, job.stem)
        else
            try outputName(arena, command, opts.dynamic, job.stem),
    };
    if (run_test or (command == .run and opts.emit_bin == .default)) try Io.Dir.cwd().createDirPath(init.io, std.fs.path.dirname(out_path.?).?);
    var inc = job.openCache(out_path);
    defer if (inc) |*i| i.close();
    switch (try compile(init, &job, if (inc) |*i| i else null, out_path, .none, null)) {
        .ok => {},
        .errors => |diags| {
            printDiagnostics(init.io, diags, opts.error_format) catch {};
            std.process.exit(1);
        },
        .failed => std.process.exit(1),
    }
    const docs_path: ?[]const u8 = switch (opts.emit_docs) {
        .none => null,
        .default => "docs",
        .path => |p| p,
    };
    if (docs_path) |p| try emitDocs(init, &job, p, false);
    if (run_test) try runTest(init, out_path.?, opts.emit_bin != .path);
    if (command == .run) {
        // Releases the cache's lock: the program inherits nothing of zap.
        if (inc) |*i| i.close();
        inc = null;
        runExe(init, out_path.?, opts.run_args);
    }
}

/// The target as the cache keys it, salting the store seed and so the
/// compilation and donor keys. Instrumented atoms (`-ffuzz`) differ from
/// plain ones, and no node key holds a module's flag, so each set of
/// modules that fuzz gets store entries of its own: `+fuzz`, then each
/// module whose flag differs from the root module's, as `+name` or
/// `-name` (`-root` if the root module does not fuzz).
/// Error tracing off in the root module (`-fno-error-tracing`,
/// ReleaseSafe's default) likewise, as `=notrace`; safety checks off in
/// it (ReleaseFast and ReleaseSmall), as `=nosafety`; and each module whose
/// `-O`, `-ferror-tracing` or `-fvalgrind` differs from the root module's,
/// and so has a builtin of its own that no node key names, as
/// `=<name>:<mode>` with `t` or `n` for tracing and `v` or `n` for
/// Valgrind. ('=' is in no module's name.)
/// Atoms inlined other than by default (`inlining`) get entries of their
/// own too, as `+inline<budget>` and `s` for the safe variant, and
/// atoms with every check kept (`ZAP_PROVE=off`) as `+noprove`.
fn cacheTarget(arena: std.mem.Allocator, opts: *const Options, env: *const std.process.Environ.Map) ![]const u8 {
    const inl = inlining(env);
    const default_inl = inl.budget == inline_ir.budget and !inl.safe;
    const same_modes = for (opts.modules) |m| {
        if (m.optimize.? != opts.optimize or m.error_tracing.? != opts.error_tracing or m.valgrind.? != opts.valgrind) break false;
    } else true;
    const unsafe = opts.optimize == .fast or opts.optimize == .small;
    const prove_on = proving(env);
    if (!opts.fuzz and default_inl and opts.error_tracing and !unsafe and same_modes and prove_on) return "x86_64-linux";
    var s: std.ArrayList(u8) = .empty;
    try s.appendSlice(arena, "x86_64-linux");
    if (opts.fuzz) {
        try s.appendSlice(arena, "+fuzz");
        if (!opts.root_fuzz) try s.appendSlice(arena, "-root");
        for (opts.modules) |m| {
            if (m.fuzz.? != opts.root_fuzz) try s.print(arena, "{c}{s}", .{ @as(u8, if (m.fuzz.?) '+' else '-'), m.name });
        }
    }
    if (!opts.error_tracing) try s.appendSlice(arena, "=notrace");
    if (unsafe) try s.appendSlice(arena, "=nosafety");
    for (opts.modules) |m| {
        if (m.optimize.? == opts.optimize and m.error_tracing.? == opts.error_tracing and m.valgrind.? == opts.valgrind) continue;
        try s.print(arena, "={s}:{t}{c}{c}", .{ m.name, m.optimize.?, "nt"[@intFromBool(m.error_tracing.?)], "nv"[@intFromBool(m.valgrind.?)] });
    }
    if (!default_inl) try s.print(arena, "+inline{d}{s}", .{ inl.budget, if (inl.safe) "s" else "" });
    if (!prove_on) try s.appendSlice(arena, "+noprove");
    return s.items;
}

/// Whether checks that facts prove are removed (docs/architecture.md,
/// "Proving checks"): `ZAP_PROVE=off` keeps them all.
fn proving(env: *const std.process.Environ.Map) bool {
    const v = env.get("ZAP_PROVE") orelse return true;
    if (std.mem.eql(u8, v, "off")) return false;
    if (std.mem.eql(u8, v, "on")) return true;
    fatal("invalid ZAP_PROVE '{s}': expected 'on' or 'off'", .{v});
}

/// How calls are inlined (docs/architecture.md, "Inlining within a
/// budget"): `ZAP_INLINE=<budget>` sets the budget, 0 turns inlining off,
/// and `ZAP_INLINE_SAFE=1` inlines only callees that cannot panic.
fn inlining(env: *const std.process.Environ.Map) struct { budget: u32, safe: bool } {
    const budget = if (env.get("ZAP_INLINE")) |v| std.fmt.parseInt(u32, v, 10) catch fatal("invalid ZAP_INLINE '{s}': expected a number", .{v}) else inline_ir.budget;
    return .{ .budget = budget, .safe = env.get("ZAP_INLINE_SAFE") != null };
}

/// What one compilation needs besides its output path, resolved from the
/// options.
pub const Job = struct {
    opts: Options,
    zig_lib_dir: []const u8,
    cache_dirs: Frontend.CacheDirs,
    builtin_dir: []const u8,
    /// The fuzzer's `builtin` (`-ffuzz` on an executable), else null.
    fuzzer_builtin_dir: ?[]const u8,
    /// The target as the cache keys it (`cacheTarget`).
    cache_target: []const u8,
    /// The command line that keys the compilation in the cache.
    compile_args: []const []const u8,
    /// `opts.link_inputs`, absolute (`Incremental.link_objects`).
    link_objects: []const []const u8,
    /// `opts.shared_libs`, absolute (`Incremental.link_shared`).
    link_shared: []const []const u8,
    stem: []const u8,
    run_test: bool,
    environ_map: *std.process.Environ.Map,
    full_args: []const []const u8,
    io: Io,
    gpa: std.mem.Allocator,

    pub fn init(init_: std.process.Init, args: []const []const u8, opts: Options) !Job {
        const arena = init_.arena.allocator();
        const zig_lib_dir = opts.zig_lib_dir orelse init_.environ_map.get("ZIG_LIB_DIR") orelse build_options.zig_lib_dir;
        const command = opts.command;
        const cache_dirs = Frontend.resolveCacheDirs(arena, init_.io, init_.environ_map, .{
            .local = opts.cache_dir,
            .global = opts.global_cache_dir,
            .local_is_global = command == .run,
        });
        const is_test = command == .@"test";
        const builtin_opts: Builtin.Options = .{
            .output_mode = switch (command) {
                .build_obj => .Obj,
                .build_lib => .Lib,
                else => .Exe,
            },
            .is_test = is_test,
            .single_threaded = opts.single_threaded,
            .unwind_tables = opts.unwind_tables,
            .fuzz = opts.root_fuzz,
            .optimize = opts.optimize,
            .error_tracing = opts.error_tracing,
            .valgrind = opts.valgrind,
            .pic = opts.pic,
            .pie = opts.pie,
            .dynamic = opts.dynamic,
            .glibc = if (opts.link_libc) opts.glibc_version else null,
            .link_libcpp = opts.link_libcpp,
        };
        const builtin_dir = try Builtin.writeToCache(arena, init_.io, try std.fs.path.join(arena, &.{ cache_dirs.global, "zap" }), builtin_opts);
        // A module whose `-O`, `-ferror-tracing` or `-fvalgrind` differs
        // from the root module's gets a builtin of its own, as upstream's.
        const modules = try arena.dupe(Frontend.ModuleArg, opts.modules);
        for (modules) |*m| {
            if (m.optimize.? == opts.optimize and m.error_tracing.? == opts.error_tracing and m.valgrind.? == opts.valgrind) continue;
            var o = builtin_opts;
            o.optimize, o.error_tracing, o.valgrind = .{ m.optimize.?, m.error_tracing.?, m.valgrind.? };
            m.builtin_dir = try Builtin.writeToCache(arena, init_.io, try std.fs.path.join(arena, &.{ cache_dirs.global, "zap" }), o);
        }
        var job_opts = opts;
        job_opts.modules = modules;
        if (opts.c_exe) job_opts.root_src_path = try Builtin.writeCMain(arena, init_.io, try std.fs.path.join(arena, &.{ cache_dirs.global, "zap" }));
        // A test that fuzzes links the fuzzer, whose module family has a
        // builtin of its own, as upstream's separate compilation of it (a
        // static library) does. Only the test runner references the
        // fuzzer and provides the `runner_*` functions it calls back, so
        // a non-test executable links without it, as upstream's default
        // backend links one (its linker leaves libfuzzer.a out).
        const fuzzer_builtin_dir: ?[]const u8 = if (opts.fuzz and is_test)
            try Builtin.writeToCache(arena, init_.io, try std.fs.path.join(arena, &.{ cache_dirs.global, "zap" }), .{
                .output_mode = .Lib,
                .is_test = false,
                .single_threaded = opts.single_threaded,
                .unwind_tables = opts.unwind_tables,
                // Upstream builds it in ReleaseFast (`compilerRtOptMode`).
                .optimize = .fast,
                .error_tracing = false,
                .valgrind = false,
            })
        else
            null;
        // `--listen=-` does not change what is built, so it is not part
        // of the compilation's key (nor of its output's digest).
        var compile_args: std.ArrayList([]const u8) = .empty;
        for (args[1 .. args.len - opts.run_args.len]) |a| {
            if (!std.mem.eql(u8, a, "--listen=-")) try compile_args.append(arena, a);
        }
        // The glibc version a -lc build links, which the arguments do not
        // spell for the native target. Keys only: `full_args` stay as given.
        if (opts.link_libc) try compile_args.append(arena, try std.fmt.allocPrint(arena, "--zap-glibc={f}", .{opts.glibc_version.?}));
        // The files the object and library arguments name, which `-l`
        // finds in the `-L` directories: the cache's link-only inputs,
        // objects and archives, then shared libraries.
        const link_objects = try arena.alloc([]const u8, opts.link_inputs.len);
        const link_shared = try arena.alloc([]const u8, opts.shared_libs.len);
        if (link_objects.len + link_shared.len != 0) {
            const cwd = try std.process.currentPathAlloc(init_.io, arena);
            for ([_][]const []const u8{ opts.link_inputs, opts.shared_libs }, [_][][]const u8{ link_objects, link_shared }) |paths, absolute| {
                for (absolute, paths) |*abs, path| {
                    abs.* = try std.fs.path.resolve(arena, &.{ cwd, path });
                    try compile_args.append(arena, try std.fmt.allocPrint(arena, "--zap-link-input={s}", .{abs.*}));
                }
            }
        }
        return .{
            .opts = job_opts,
            .zig_lib_dir = zig_lib_dir,
            .cache_dirs = cache_dirs,
            .builtin_dir = builtin_dir,
            .fuzzer_builtin_dir = fuzzer_builtin_dir,
            .cache_target = try cacheTarget(arena, &opts, init_.environ_map),
            .compile_args = compile_args.items,
            .link_objects = link_objects,
            .link_shared = link_shared,
            .stem = opts.name orelse if (is_test) "test" else if (opts.c_only or opts.c_exe) std.fs.path.stem(opts.c_sources[0].path) else std.fs.path.stem(opts.root_src_path),
            .run_test = is_test and !opts.test_no_exec and !opts.listen,
            .environ_map = init_.environ_map,
            .full_args = args,
            .io = init_.io,
            .gpa = init_.gpa,
        };
    }

    fn zapLocal(job: *const Job, arena: std.mem.Allocator) []const u8 {
        return std.fs.path.join(arena, &.{ job.cache_dirs.local, "zap" }) catch fatal("out of memory", .{});
    }

    /// Opens the on-disk cache for a build into `out_path`: a build whose
    /// inputs did not change relinks the last build's Atoms and skips
    /// everything else.
    pub fn openCache(job: *const Job, out_path: ?[]const u8) ?Incremental {
        const env = job.environ_map;
        // The numbered link has no position-independent layout yet (`Elf`);
        // -fPIE and -dynamic imply -fPIC (and -lc on objects and
        // libraries). A library of C only has no Zig to cache; its
        // objects have their records.
        const use_cache = out_path != null and !job.opts.dump_ir and !job.opts.pic and !job.opts.c_only and
            !std.mem.eql(u8, env.get("ZAP_CACHE") orelse "", "off");
        if (!use_cache) return null;
        const tests_std = job.opts.command == .@"test" and
            (Frontend.testsStd(job.gpa, job.zig_lib_dir, job.opts.root_src_path) catch fatal("out of memory", .{}));
        // A cache that cannot be opened (a full disk, say) costs reuse, not the build.
        var i = Incremental.open(job.gpa, job.io, job.cache_dirs, job.compile_args, job.zig_lib_dir, job.opts.root_name, tests_std, job.cache_target, env.get("ZAP_CACHE_TIMING") != null) catch |err| {
            std.log.warn("unable to use the cache: {t}", .{err});
            return null;
        };
        i.check = env.get("ZAP_CACHE_CHECK") != null;
        i.donors = !std.mem.eql(u8, env.get("ZAP_CACHE_DONOR") orelse "", "off");
        i.stack_size = job.opts.stack_size;
        i.link_objects = job.link_objects;
        i.link_shared = job.link_shared;
        if (job.opts.link_libc and !job.opts.pic) {
            i.glibc_version = job.opts.glibc_version;
            i.glibc_lib_dir = job.zig_lib_dir;
            i.runpath = job.opts.runpath;
        }
        i.output = switch (job.opts.command) {
            .build_obj => .obj,
            .build_lib => .lib,
            else => .exe,
        };
        i.archive_stem = std.fs.path.stem(job.opts.root_src_path);
        // `zap run`'s program counts as used when it runs (`renew_output`);
        // other outputs keep the stat the last link left, so that the next
        // build can skip the link.
        i.renew_output = job.opts.command == .run;
        if (env.get("ZAP_CACHE_VERIFY")) |v| {
            i.verify = if (std.mem.eql(u8, v, "full")) .full else .replay;
            i.verify_argv = job.full_args;
            i.verify_environ = env;
        }
        if (env.get("ZAP_CACHE_MAX_SIZE")) |v| {
            i.max_bytes = @import("cache.zig").parseSize(v) orelse fatal("invalid ZAP_CACHE_MAX_SIZE '{s}': expected bytes, or a number and K, M, G, or T", .{v});
        }
        return i;
    }
};

pub const Outcome = union(enum) {
    /// `cache_hit`: the inputs had not changed and the output was relinked
    /// from the cache.
    ok: struct { cache_hit: bool },
    errors: []const diag.Diagnostic,
    /// Reported on stderr already (a failed link).
    failed,
};

/// Compiles `job` into `out_path` (nothing for null), with `inc` as the
/// cache. `inputs`, if given, gets every source file the build read, as
/// absolute paths separated by zero bytes.
pub fn compile(init: std.process.Init, job: *const Job, inc_opt: ?*Incremental, out_path: ?[]const u8, prog: std.Progress.Node, inputs: ?*std.ArrayList(u8)) !Outcome {
    const n_inputs = if (inputs) |list| list.items.len else 0;
    // A lazy edit build whose changes the cache cannot record builds again
    // eagerly (`Incremental.finishLazy`).
    var replay_mode = init.environ_map.get("ZAP_CACHE_REPLAY") orelse "";
    // A build whose analysis read a type name that then changed builds
    // again with the first attempt's final names (`Zcu.finalizeNames`).
    var pins: ?*const Zcu.NamePins = null;
    // C sources compile while the build analyzes, once for every attempt.
    const c_batch: ?*CSource.Batch = if (job.opts.c_sources.len != 0 or cxxRuntime(&job.opts) or libcNonshared(&job.opts)) try startC(init, job) else null;
    defer if (c_batch) |b| CSource.destroy(b);
    if (job.opts.c_only) return compileCOnly(init, job, c_batch.?, out_path, inputs);
    // The C objects are link-only inputs of the cache, after the object
    // and archive arguments, as `ElfInput` takes them.
    if (c_batch) |b| if (inc_opt) |i| {
        i.link_objects = try std.mem.concat(init.arena.allocator(), []const u8, &.{ job.link_objects, try CSource.objectPaths(b, init.arena.allocator()) });
    };
    while (true) return compileReplaying(init, job, inc_opt, out_path, prog, inputs, replay_mode, &pins, c_batch) catch |err| switch (err) {
        error.LazyFallback => {
            if (inputs) |list| list.shrinkRetainingCapacity(n_inputs);
            replay_mode = "eager";
            continue;
        },
        error.NamesRerun => {
            if (inputs) |list| list.shrinkRetainingCapacity(n_inputs);
            continue;
        },
        // An edit build that kept a unit which read a type's name that
        // changed (`Replay.contributeNames`).
        error.NamesFullBuild => {
            if (inputs) |list| list.shrinkRetainingCapacity(n_inputs);
            if (inc_opt) |i| i.endReplay();
            replay_mode = "off";
            continue;
        },
        else => |e| return e,
    };
}

/// A static library of C sources only: their objects in an archive. The
/// archive stays when no source compiled and neither it nor an object
/// changed since it was written (`CSource.archiveStamp`, kept under the
/// compilation's key), as upstream's cache hit: SDL3's is 70 MB.
fn compileCOnly(init: std.process.Init, job: *const Job, b: *CSource.Batch, out_path: ?[]const u8, inputs: ?*std.ArrayList(u8)) !Outcome {
    const arena = init.arena.allocator();
    const io = init.io;
    const stamp_path: ?[]const u8 = if (out_path != null) path: {
        _, const key = try Incremental.compilationKey(arena, io, job.compile_args, job.zig_lib_dir, "c archive");
        break :path try std.fs.path.join(arena, &.{ job.zapLocal(arena), "car", &std.fmt.bytesToHex(@as([16]u8, @bitCast(key)), .lower) });
    } else null;
    if (b.misses == 0) if (stamp_path) |sp| if (try CSource.archiveStamp(b, arena, out_path.?)) |stamp| {
        var buf: [16]u8 = undefined;
        const old = Io.Dir.cwd().readFile(io, sp, &buf) catch "";
        if (old.len == 16 and std.mem.readInt(u128, buf[0..16], .little) == stamp) {
            if (inputs) |list| try appendCInputs(arena, list, try CSource.hitInputs(b, arena));
            return .{ .ok = .{ .cache_hit = true } };
        }
    };
    const c = try b.wait();
    if (inputs) |list| try appendCInputs(arena, list, c.inputs);
    if (c.errors.len != 0) return .{ .errors = try dupeDiagnostics(arena, c.errors) };
    const bin_path = out_path orelse return .{ .ok = .{ .cache_hit = false } };
    const members = try arena.alloc(Archive.Input, c.objects.len);
    for (members, c.objects) |*m, o| m.* = .{ .name = o.member, .bytes = o.bytes };
    Archive.write(init.gpa, init.io, Io.Dir.cwd(), bin_path, members) catch |err| {
        std.log.err("unable to write the archive '{s}': {t}", .{ bin_path, err });
        return .failed;
    };
    // Best effort: without the stamp, the next build writes the archive.
    if (stamp_path) |sp| if (CSource.archiveStamp(b, arena, bin_path) catch null) |stamp| {
        var bytes: [16]u8 = undefined;
        std.mem.writeInt(u128, &bytes, stamp, .little);
        Io.Dir.cwd().writeFile(io, .{ .sub_path = sp, .data = &bytes, .flags = .{} }) catch |err| switch (err) {
            error.FileNotFound => if (Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(sp).?)) |_| {
                Io.Dir.cwd().writeFile(io, .{ .sub_path = sp, .data = &bytes, .flags = .{} }) catch {};
            } else |_| {},
            else => {},
        };
    };
    return .{ .ok = .{ .cache_hit = false } };
}

/// Appends the files the C sources read, each once: sources share most of
/// their headers.
fn appendCInputs(arena: std.mem.Allocator, list: *std.ArrayList(u8), c_inputs: []const u8) !void {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var it = std.mem.splitScalar(u8, c_inputs, 0);
    while (it.next()) |p| if (p.len != 0 and !(try seen.getOrPut(arena, p)).found_existing) try appendInput(arena, list, p);
}

/// Whether the build links the C++ runtime libraries: an executable with
/// `-lc++`, as upstream builds them for executables and shared libraries.
fn cxxRuntime(opts: *const Options) bool {
    return opts.link_libcpp and opts.command != .build_obj and opts.command != .build_lib;
}

/// Whether the build links glibc's libc_nonshared.a: an executable linking
/// glibc with C inputs, which may call its functions (`atexit`); Zig code
/// calls none of them.
fn libcNonshared(opts: *const Options) bool {
    return opts.link_libc and opts.glibc_version != null and opts.command != .build_obj and opts.command != .build_lib and
        (opts.link_inputs.len != 0 or opts.c_sources.len != 0 or opts.link_libcpp);
}

/// Starts compiling the job's C sources (CSource.zig).
fn startC(init: std.process.Init, job: *const Job) !*CSource.Batch {
    const opts = &job.opts;
    // The target's glibc names the ABI: without -lc too for the native
    // target, as upstream's.
    const glibc_version = opts.glibc_version orelse if (opts.target == null)
        if (std.zig.system.resolveTargetQuery(init.io, .{})) |native| (if (native.abi.isGnu()) native.os.version_range.linux.glibc else null) else |_| null
    else
        null;
    return CSource.start(init.gpa, init.io, init.environ_map, opts.c_sources, .{
        .zig_lib_dir = job.zig_lib_dir,
        .local_cache = job.cache_dirs.local,
        .glibc_version = glibc_version,
        .link_libc = opts.link_libc,
        .link_libcpp = opts.link_libcpp,
        .cxx_runtime = cxxRuntime(opts),
        .libc_nonshared = libcNonshared(opts),
        .global_cache = job.cache_dirs.global,
        .single_threaded = opts.single_threaded,
        .stack_protector = opts.c_only or opts.use_llvm,
        .pie = opts.c_pie,
        .function_sections = opts.function_sections,
        .data_sections = opts.data_sections,
        .unwind_tables = opts.unwind_tables,
        .global_cc_argv = opts.c_global_cc_argv,
        .native_includes = opts.c_native_includes,
        .verbose = opts.verbose_cc,
    });
}

fn compileReplaying(init: std.process.Init, job: *const Job, inc_opt: ?*Incremental, out_path: ?[]const u8, prog: std.Progress.Node, inputs: ?*std.ArrayList(u8), replay_mode: []const u8, pins: *?*const Zcu.NamePins, c_batch: ?*CSource.Batch) !Outcome {
    const arena = init.arena.allocator();
    const opts = job.opts;
    const env = init.environ_map;
    var stages: Stages = .{ .io = init.io, .last = .now(init.io, .awake) };
    stages.on = env.get("ZAP_TIMING") != null;
    // While Clang compiles a C source, its object is not yet what the
    // build links, so the build cannot be the last one.
    const c_compiling = if (c_batch) |b| b.misses != 0 else false;
    if (inc_opt) |i| i.link_objects_pending = c_compiling;
    if (inc_opt) |i| if (try i.relinkIfUnchanged(Io.Dir.cwd(), out_path.?)) {
        // The C objects come after the arguments' link inputs. They are
        // the records' outputs; the build reports the C sources and their
        // headers instead, as a full build does.
        var link_inputs: usize = 0;
        if (inputs) |list| if (i.prev) |*m| for (0..m.inputCount()) |n| {
            if (Incremental.isLinkInput(m.inputKey(@intCast(n)))) {
                link_inputs += 1;
                if (link_inputs > job.link_objects.len) continue;
            }
            _, const path = m.input(@intCast(n));
            try appendInput(arena, list, path);
        };
        if (inputs) |list| if (c_batch) |b| try appendCInputs(arena, list, (try b.wait()).inputs);
        return .{ .ok = .{ .cache_hit = true } };
    };

    const is_test = opts.command == .@"test";
    const test_runner = opts.test_runner orelse try std.fs.path.join(arena, &.{ job.zig_lib_dir, "compiler", "test_runner.zig" });
    const fe_node = prog.start("Load Sources", 0);
    var fe: Frontend = try .init(init.gpa, init.io, job.zig_lib_dir, .{
        .root_src_path = if (is_test) test_runner else opts.root_src_path,
        .root_dir = opts.root_dir,
        .builtin_dir = job.builtin_dir,
        .main_src_path = if (is_test) opts.root_src_path else null,
        .root_name = opts.root_name,
        .root_deps = opts.root_deps,
        .modules = opts.modules,
        .fuzz = opts.root_fuzz,
        .error_tracing = opts.error_tracing,
        .optimize = opts.optimize,
        .fuzzer_builtin_dir = job.fuzzer_builtin_dir,
        // Only executables link the C runtimes; a library's C objects
        // reach them when an executable links the library, as upstream's.
        .c_runtimes = opts.command != .build_obj and opts.command != .build_lib and (opts.link_inputs.len != 0 or opts.c_sources.len != 0 or opts.link_libcpp),
    });
    defer fe.deinit();
    try fe.enableCache(job.cache_dirs);
    var errors: std.zig.ErrorBundle.Wip = try .init(init.gpa);
    defer errors.deinit();
    stages.mark("setup and cache check");
    const ok = try fe.loadAll(&errors);
    stages.mark("frontend");
    fe_node.end();
    if (env.get("ZAP_FRONTEND_TIMING") != null) fe.printStats();
    var path_buf: std.ArrayList(u8) = .empty;
    if (inputs) |list| for (fe.files.items) |*f| {
        try Incremental.inputPath(arena, &path_buf, &fe, f.module, f.sub_path);
        try appendInput(arena, list, path_buf.items);
    };
    var bundle = try errors.toOwnedBundle("");
    defer bundle.deinit(init.gpa);
    const paths: diag.Paths = try .init(arena, init.io, job.zig_lib_dir);
    // As upstream, analysis goes on after AstGen's errors unless a file
    // could not be lowered, so one build reports AstGen's errors and
    // Sema's. Such a build emits nothing and records nothing.
    var astgen_errors: []const diag.Diagnostic = &.{};
    if (bundle.errorMessageCount() > 0) {
        var diags: std.ArrayList(diag.Diagnostic) = .empty;
        try diag.fromBundle(arena, paths, bundle, &diags);
        if (!ok) return .{ .errors = try dupeDiagnostics(arena, diags.items) };
        astgen_errors = diags.items;
    }

    var zcu: Zcu = try .init(init.gpa, init.io, &fe);
    defer zcu.deinit();
    defer if (inputs) |list| for (zcu.embed_files.values()) |f| {
        Incremental.inputPath(arena, &path_buf, &fe, f.module, f.sub_path) catch {};
        appendInput(arena, list, path_buf.items) catch {};
    };
    zcu.is_test = is_test;
    zcu.name_pins = pins.*;
    zcu.single_threaded = opts.single_threaded;
    zcu.link_libc = opts.link_libc;
    zcu.link_libcpp = opts.link_libcpp;
    zcu.test_filters = opts.test_filters;
    // `ZAP_COMPTIME_EVAL=n`: lower a function for the comptime evaluator
    // after n walker runs (0: never), for testing it.
    if (env.get("ZAP_COMPTIME_EVAL")) |v| zcu.comptime_eval_threshold = std.fmt.parseInt(u32, v, 10) catch 0;
    // `ZAP_UNIT_TIMING=n`: print the n units whose analysis took longest,
    // not counting the units each analyzed in turn.
    if (env.get("ZAP_UNIT_TIMING")) |v| zcu.unit_timing = .{ .top = std.fmt.parseInt(u32, v, 10) catch 20 };
    // A first build replays another compilation's graph, if one was published.
    if (inc_opt) |i| if (!std.mem.eql(u8, replay_mode, "off")) try i.useDonor(&fe);
    if (inc_opt) |i| try i.seedErrors(&zcu);
    if (opts.dump_ir) {
        var stdout_buf: [4096]u8 = undefined;
        var stdout = Io.File.stdout().writerStreaming(init.io, &stdout_buf);
        var sink: DumpSink = .{ .w = &stdout.interface };
        try zcu.analyzeAll(&sink);
        try stdout.interface.flush();
        if (zcu.failed() or astgen_errors.len != 0) {
            const sema_errors = if (zcu.failed()) try zcu.diagnostics(arena, paths) else &.{};
            return .{ .errors = try dupeDiagnostics(arena, try std.mem.concat(arena, diag.Diagnostic, &.{ astgen_errors, sema_errors })) };
        }
        return .{ .ok = .{ .cache_hit = false } };
    }
    var emit: Emit = .init(init.gpa, &zcu);
    defer emit.deinit();
    emit.obj = opts.command == .build_obj or opts.command == .build_lib;
    emit.pic = if (opts.pie) .pie else if (opts.pic) .pic else .none;
    emit.shared = opts.dynamic;
    if (opts.dynamic) emit.soname = switch (opts.soname) {
        .default => try outputName(arena, .build_lib, true, job.stem),
        .name => |n| n,
        .none => null,
    };
    emit.stack_size = opts.stack_size;
    emit.fuzz = opts.fuzz;
    emit.prove_on = proving(job.environ_map);
    // Only executables link glibc: an object or a static library with
    // -lc is an ordinary one, as upstream's.
    const links_glibc = opts.link_libc and opts.command != .build_obj and opts.command != .build_lib;
    var glibc: ?Glibc = if (links_glibc) try loadGlibc(init, job) else null;
    defer if (glibc) |*g| g.deinit();
    if (glibc) |*g| emit.glibc = g;
    if (glibc) |*g| if (inc_opt) |i| {
        i.glibc = g;
    };
    // `glibc` goes with this attempt (`compile` may try again).
    defer if (inc_opt) |i| {
        i.glibc = null;
    };
    if (glibc != null) emit.runpath = opts.runpath;
    const shared_libs = try arena.alloc(ElfShared, opts.shared_libs.len);
    for (shared_libs, opts.shared_libs) |*lib, path| {
        const bytes = Io.Dir.cwd().readFileAlloc(init.io, path, arena, .unlimited) catch |err|
            fatal("unable to read '{s}': {t}", .{ path, err });
        lib.* = ElfShared.parse(arena, path, bytes) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.InvalidShared => if (!std.mem.startsWith(u8, bytes, std.elf.MAGIC))
                fatal("zap does not read linker scripts ('{s}') yet", .{path})
            else
                fatal("'{s}' is not an x86_64 ELF shared library", .{path}),
        };
    }
    emit.shared_libs = shared_libs;
    if (inc_opt) |i| i.shared = shared_libs;
    var link_inputs: ElfInput = .{ .arena = arena };
    // An executable links the C objects and the C++ runtime libraries; a
    // static library holds the objects as members.
    if (c_batch) |b| if (!emit.obj) {
        emit.inputs = &link_inputs;
        emit.c_batch = b;
    };
    // `ZAP_BENCH_CODEGEN=n`: time the backend over this build's functions
    // n more times (`zig build bench-codegen`).
    const bench_runs: u32 = if (env.get("ZAP_BENCH_CODEGEN")) |v| std.fmt.parseInt(u32, v, 10) catch 0 else 0;
    if (bench_runs != 0) emit.bench_irs = .empty;
    const inl = inlining(job.environ_map);
    if (inl.budget != 0) emit.enableInlining(inl.budget, inl.safe);
    // `ZAP_THREADS=n`: analysis and CodeGen on n threads, Sema on one and
    // CodeGen on the others; 1 generates on the Sema thread. The output
    // is the same for every n.
    const threads: usize = if (env.get("ZAP_THREADS")) |v| std.fmt.parseInt(usize, v, 10) catch 1 else std.Thread.getCpuCount() catch 1;
    // `ZAP_SCHED_FUZZ=<seed>`: perturb the workers' timing (`Emit.Pool.fuzz`).
    const fuzz: ?u64 = if (env.get("ZAP_SCHED_FUZZ")) |v| std.fmt.parseInt(u64, v, 10) catch 1 else null;
    emit.has_inputs = !emit.obj and !emit.shared and (opts.link_inputs.len != 0 or c_batch != null);
    try emit.startPool(@max(threads, 1) - 1, fuzz);
    const sema_node = prog.start("Analyze and Generate Code", 0);
    if (inc_opt) |i| try i.beginReplay(&fe, &zcu, &emit, replay_mode);
    // A lazy edit build relinks from the manifest, which reads the
    // objects itself (`Incremental.linkFrom`).
    if (opts.link_inputs.len != 0 and !emit.obj and !(if (zcu.replay) |r| r.lazy else false)) {
        for (opts.link_inputs) |path| {
            const bytes = Io.Dir.cwd().readFileAlloc(init.io, path, arena, .unlimited) catch |err|
                fatal("unable to read '{s}': {t}", .{ path, err });
            const is_archive = std.mem.startsWith(u8, bytes, "!<arch>\n") or std.mem.startsWith(u8, bytes, "!<thin>\n");
            (if (is_archive) link_inputs.addArchive(path, bytes) else link_inputs.addObject(path, bytes)) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                error.InvalidObject => fatal("'{s}' is not an x86_64 ELF relocatable object", .{path}),
                error.InvalidArchive => fatal("'{s}' is not a valid archive", .{path}),
                error.ThinArchive => fatal("zap does not link thin archives ('{s}') yet", .{path}),
            };
        }
        emit.inputs = &link_inputs;
    }
    try zcu.analyzeAll(&emit);
    if (bench_runs != 0) try emit.benchCodegen(bench_runs);
    stages.markSplit("sema", "codegen", emit.codegen_ns);
    sema_node.end();
    zcu.printUnitTiming();
    if (try zcu.finalizeNames(arena)) |p| {
        pins.* = p;
        if (inc_opt) |i| i.endReplay();
        return error.NamesRerun;
    }
    // A lazy edit build leaves the test list as the last build linked it.
    if (is_test and !(if (zcu.replay) |r| r.lazy else false)) @import("Sema.zig").populateTestFunctions(&zcu) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
    if (c_batch) |b| {
        const c = try b.wait();
        if (inputs) |list| try appendCInputs(arena, list, c.inputs);
        if (c.errors.len != 0) {
            const zig_errors = if (zcu.failed()) try zcu.diagnostics(arena, paths) else &.{};
            return .{ .errors = try dupeDiagnostics(arena, try std.mem.concat(arena, diag.Diagnostic, &.{ astgen_errors, zig_errors, c.errors })) };
        }
    }
    if (astgen_errors.len != 0) {
        const sema_errors = if (zcu.failed()) try zcu.diagnostics(arena, paths) else &.{};
        return .{ .errors = try dupeDiagnostics(arena, try std.mem.concat(arena, diag.Diagnostic, &.{ astgen_errors, sema_errors })) };
    }
    if (zcu.failed()) return .{ .errors = try dupeDiagnostics(arena, try zcu.diagnostics(arena, paths)) };
    const bin_path = out_path orelse return .{ .ok = .{ .cache_hit = false } };
    const link_node = prog.start("Link", 0);
    defer link_node.end();
    const ready = try emit.finish();
    stages.mark("emit");
    if (zcu.failed()) return .{ .errors = try dupeDiagnostics(arena, try zcu.diagnostics(arena, paths)) };
    if (!ready) return .failed;
    // The cache records the build while it links, and keeps the record
    // only if the link succeeds.
    // A lazy edit build links from the manifest it appends to.
    const lazy_linked = if (inc_opt) |i| try i.finishLazy(&fe, &zcu, &emit, Io.Dir.cwd(), bin_path) else null;
    if (lazy_linked == null) if (inc_opt) |i| i.startRecord(&fe, &zcu, &emit);
    // A static library is its object in an archive (link/Archive.zig); a
    // lazy edit build writes the archive itself.
    const archive = opts.command == .build_lib and !opts.dynamic;
    const link_path = if (archive) try std.fmt.allocPrint(arena, "{s}.o.tmp", .{bin_path}) else bin_path;
    var linked = lazy_linked orelse try emit.link(init.io, Io.Dir.cwd(), link_path);
    if (linked and lazy_linked == null and archive) {
        defer Io.Dir.cwd().deleteFile(init.io, link_path) catch {};
        const obj = try Io.Dir.cwd().readFileAlloc(init.io, link_path, arena, .unlimited);
        var members: std.ArrayList(Archive.Input) = .empty;
        try members.append(arena, .{ .name = try std.fmt.allocPrint(arena, "{s}.o", .{std.fs.path.stem(opts.root_src_path)}), .bytes = obj });
        for (opts.link_inputs) |path| try members.append(arena, .{
            .name = std.fs.path.basename(path),
            .bytes = Io.Dir.cwd().readFileAlloc(init.io, path, arena, .unlimited) catch |err| fatal("unable to read '{s}': {t}", .{ path, err }),
        });
        if (c_batch) |b| for ((try b.wait()).objects) |o| try members.append(arena, .{ .name = o.member, .bytes = o.bytes });
        Archive.write(init.gpa, init.io, Io.Dir.cwd(), bin_path, members.items) catch |err| {
            std.log.err("unable to write the archive '{s}': {t}", .{ bin_path, err });
            linked = false;
        };
    }
    stages.mark("link");
    if (lazy_linked == null) if (inc_opt) |i| {
        i.finishRecord(linked);
        if (linked) i.noteOutput(Io.Dir.cwd(), bin_path);
    };
    stages.mark("cache record (after the link)");
    stages.print();
    if (stages.on) emit.codegen_stats.print("zap: codegen");
    if (!linked) return .failed;
    return .{ .ok = .{ .cache_hit = false } };
}

/// Writes the docs directory (`-femit-docs`) at `path`; after a build that
/// compiled nothing, only if it is missing.
fn emitDocs(init: std.process.Init, job: *const Job, path: []const u8, cache_hit: bool) !void {
    const io = init.io;
    if (cache_hit) {
        const tar = try std.fs.path.join(init.arena.allocator(), &.{ path, "sources.tar" });
        if (Io.Dir.cwd().access(io, tar, .{})) |_| return else |_| {}
    }
    Docs.emit(init.gpa, io, job.zig_lib_dir, path, job.stem, &job.opts) catch |err|
        fatal("unable to emit docs to '{s}': {t}", .{ path, err });
}

/// `zap env`, in upstream's form (src/print_env.zig): tools ask the
/// compiler for its lib directory this way (zls's tests run `<zig> env`
/// with the zig that runs the build). Copyright (c) Zig contributors, MIT
/// licensed (see upstream/LICENSE).
fn printEnv(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const env = init.environ_map;
    const cwd = try std.process.currentPathAlloc(io, arena);
    const lib_dir = try std.fs.path.resolve(arena, &.{ cwd, env.get("ZIG_LIB_DIR") orelse build_options.zig_lib_dir });
    const dirs = Frontend.resolveCacheDirs(arena, io, env, .{ .local_is_global = true });
    var buf: [4096]u8 = undefined;
    var out = Io.File.stdout().writerStreaming(io, &buf);
    var serializer: std.zon.Serializer = .{ .writer = &out.interface };
    var root = try serializer.beginStruct(.{});
    try root.field("zig_exe", try std.process.executablePathAlloc(io, arena), .{});
    try root.field("lib_dir", lib_dir, .{});
    try root.field("std_dir", try std.fs.path.join(arena, &.{ lib_dir, "std" }), .{});
    try root.field("global_cache_dir", try std.fs.path.resolve(arena, &.{ cwd, dirs.global }), .{});
    try root.field("version", zig_version, .{});
    try root.field("target", "x86_64-linux-none", .{});
    var env_struct = try root.beginStructField("env", .{});
    inline for (@typeInfo(std.zig.EnvVar).@"enum".field_names) |field_name| {
        try env_struct.field(field_name, @field(std.zig.EnvVar, field_name).get(env), .{});
    }
    try env_struct.end();
    try root.end();
    try out.interface.writeByte('\n');
    try out.interface.flush();
}

/// The output's file name in its directory, as upstream names it.
fn outputName(arena: std.mem.Allocator, command: Command, dynamic: bool, stem: []const u8) ![]const u8 {
    return switch (command) {
        .build_obj => std.fmt.allocPrint(arena, "{s}.o", .{stem}),
        .build_lib => std.fmt.allocPrint(arena, "lib{s}.{s}", .{ stem, if (dynamic) "so" else "a" }),
        else => stem,
    };
}

/// `diags` with their strings copied to `arena`: they point into the Zcu
/// and the Frontend's sources, which `compile` frees before it returns.
fn dupeDiagnostics(arena: std.mem.Allocator, diags: []const diag.Diagnostic) ![]const diag.Diagnostic {
    const S = struct {
        fn loc(a: std.mem.Allocator, l: ?diag.Loc) !?diag.Loc {
            var c = l orelse return null;
            c.path = try a.dupe(u8, c.path);
            c.source_line = try a.dupe(u8, c.source_line);
            return c;
        }
    };
    const out = try arena.dupe(diag.Diagnostic, diags);
    for (out) |*d| {
        d.msg = try arena.dupe(u8, d.msg);
        d.loc = try S.loc(arena, d.loc);
        const notes = try arena.dupe(diag.Note, d.notes);
        for (notes) |*n| {
            n.msg = try arena.dupe(u8, n.msg);
            n.loc = try S.loc(arena, n.loc);
        }
        d.notes = notes;
        const refs = try arena.dupe(diag.Ref, d.refs);
        for (refs) |*r| {
            r.name = try arena.dupe(u8, r.name);
            r.loc = try S.loc(arena, r.loc);
        }
        d.refs = refs;
        const candidates = try arena.dupe([]const u8, d.candidates);
        for (candidates) |*c| c.* = try arena.dupe(u8, c.*);
        d.candidates = candidates;
        if (d.hint) |h| d.hint = try arena.dupe(u8, h);
        const fixes = try arena.dupe(diag.Fix, d.fixes);
        for (fixes) |*f| {
            const edits = try arena.dupe(diag.Edit, f.edits);
            for (edits) |*e| {
                e.path = try arena.dupe(u8, e.path);
                e.text = try arena.dupe(u8, e.text);
            }
            f.edits = edits;
        }
        d.fixes = fixes;
        const log = try arena.dupe([]const u8, d.log);
        for (log) |*l| l.* = try arena.dupe(u8, l.*);
        d.log = log;
    }
    return out;
}

fn appendInput(arena: std.mem.Allocator, list: *std.ArrayList(u8), path: []const u8) !void {
    if (list.items.len != 0) try list.append(arena, 0);
    try list.appendSlice(arena, path);
}

// ---------------------------------------------------------------------------
// The compiler protocol (`--listen=-`)

/// Serves std's compiler protocol (std/zig/Server.zig) on stdin and stdout,
/// as upstream's `--listen=-`: `zig build`'s compile steps send `update`
/// and then `exit`. Each update builds into `<local cache>/o/<digest>/`
/// and answers with the inputs it read, then either the errors or the
/// digest; errors travel as an ErrorBundle (`diag.toBundle`).
fn serve(init: std.process.Init, args: []const []const u8, opts: Options) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    var in_buf: [256]u8 = undefined;
    var out_buf: [4096]u8 = undefined;
    var in = Io.File.stdin().readerStreaming(io, &in_buf);
    var out = Io.File.stdout().writerStreaming(io, &out_buf);
    var server: std.zig.Server = .{ .in = &in.interface, .out = &out.interface };
    try server.serveStringMessage(.zig_version, zig_version);
    try server.serveConfig(.{ .flags = .{
        .output_mode = switch (opts.command) {
            .build_obj => .Obj,
            .build_lib => .Lib,
            else => .Exe,
        },
        .link_mode = if (opts.dynamic or (opts.link_libc and opts.command != .build_obj and opts.command != .build_lib)) .dynamic else .static,
        .link_libc = opts.link_libc,
        .link_libcpp = opts.link_libcpp,
        .link_libunwind = opts.link_libcpp,
        .pie = false,
    } });

    const job: ?Job = if (opts.unsupported == null) try .init(init, args, opts) else null;
    // The output goes where the build runner looks for it:
    // `<local cache>/o/<hex digest>/<binary name>`.
    var digest: [16]u8 = undefined;
    var out_path: ?[]const u8 = null;
    var docs_path: ?[]const u8 = null;
    if (job) |*j| {
        _, const key = try Incremental.compilationKey(arena, io, j.compile_args, j.zig_lib_dir, j.cache_target);
        digest = Incremental.outputDigest(key);
        const name = try outputName(arena, opts.command, opts.dynamic, j.stem);
        out_path = switch (opts.emit_bin) {
            .none => null,
            .path => |p| p,
            .default => try std.fs.path.join(arena, &.{ j.cache_dirs.local, "o", &std.fmt.bytesToHex(digest, .lower), name }),
        };
        if (opts.emit_bin == .default) try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(out_path.?).?);
        docs_path = switch (opts.emit_docs) {
            .none => null,
            .path => |p| p,
            .default => try std.fmt.allocPrint(arena, "{s}/o/{s}/{s}-docs", .{ j.cache_dirs.local, &std.fmt.bytesToHex(digest, .lower), j.stem }),
        };
        // Upstream's compiler creates the local cache's `tmp`, where the
        // build runner then writes the configuration without creating it.
        try Io.Dir.cwd().createDirPath(io, try std.fs.path.join(arena, &.{ j.cache_dirs.local, "tmp" }));
    }
    const root_node = std.Progress.start(io, .{});
    defer root_node.end();

    while (true) {
        const hdr = server.receiveMessage() catch |err| switch (err) {
            error.EndOfStream => return cleanExit(io),
            else => |e| return e,
        };
        switch (hdr.tag) {
            .exit => return cleanExit(io),
            .update => {
                try server.in.discardAll(hdr.bytes_len);
                const j = if (job) |*j| j else {
                    try serveUnsupported(&server, init.gpa, opts.unsupported.?);
                    continue;
                };
                var inputs: std.ArrayList(u8) = .empty;
                var inc = j.openCache(out_path);
                defer if (inc) |*i| i.close();
                const outcome = try compile(init, j, if (inc) |*i| i else null, out_path, root_node, &inputs);
                const prefixed = try prefixInputs(arena, io, inputs.items, .{ .zig_lib_dir = j.zig_lib_dir, .cache_dirs = j.cache_dirs, .build_root = j.opts.build_root });
                if (prefixed.len != 0) try server.serveStringMessage(.file_system_inputs, prefixed);
                switch (outcome) {
                    .ok => |r| {
                        if (docs_path) |p| try emitDocs(init, j, p, r.cache_hit);
                        if (out_path != null or docs_path != null) try server.serveEmitDigest(&digest, .{ .flags = .{ .cache_hit = r.cache_hit } });
                        try server.serveErrorBundle(.error_bundle, .empty);
                    },
                    .errors => |diags| try serveErrors(&server, init.gpa, diags, opts.reference_trace),
                    .failed => try serveErrors(&server, init.gpa, &.{.{ .loc = null, .msg = "the link failed; its error is on zap's stderr" }}, null),
                }
            },
            else => fatal("unrecognized message from client: 0x{x}", .{@backingInt(hdr.tag)}),
        }
    }
}

/// Answers every update with `diags`, for a command zap does not
/// implement.
fn serveFailure(init: std.process.Init, diags: []const diag.Diagnostic, output_mode: std.lang.OutputMode) !void {
    const io = init.io;
    var in_buf: [256]u8 = undefined;
    var out_buf: [4096]u8 = undefined;
    var in = Io.File.stdin().readerStreaming(io, &in_buf);
    var out = Io.File.stdout().writerStreaming(io, &out_buf);
    var server: std.zig.Server = .{ .in = &in.interface, .out = &out.interface };
    try server.serveStringMessage(.zig_version, zig_version);
    try server.serveConfig(.{ .flags = .{ .output_mode = output_mode, .link_mode = .static, .link_libc = false, .link_libcpp = false, .link_libunwind = false, .pie = false } });
    while (true) {
        const hdr = server.receiveMessage() catch |err| switch (err) {
            error.EndOfStream => return cleanExit(io),
            else => |e| return e,
        };
        switch (hdr.tag) {
            .exit => return cleanExit(io),
            .update => {
                try server.in.discardAll(hdr.bytes_len);
                try serveErrors(&server, init.gpa, diags, null);
            },
            else => fatal("unrecognized message from client: 0x{x}", .{@backingInt(hdr.tag)}),
        }
    }
}

pub fn serveUnsupported(server: *std.zig.Server, gpa: std.mem.Allocator, msg: []const u8) !void {
    try serveErrors(server, gpa, &.{.{ .code = .unsupported, .loc = null, .msg = msg }}, null);
}

fn serveErrors(server: *std.zig.Server, gpa: std.mem.Allocator, diags: []const diag.Diagnostic, ref_limit: ?u32) !void {
    var wip: std.zig.ErrorBundle.Wip = try .init(gpa);
    defer wip.deinit();
    try diag.toBundle(&wip, diags, ref_limit);
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(gpa);
    for (diags) |d| for (d.log) |l| {
        try log.appendSlice(gpa, l);
        try log.append(gpa, '\n');
    };
    var bundle = try wip.toOwnedBundle(log.items);
    defer bundle.deinit(gpa);
    try server.serveErrorBundle(.error_bundle, bundle);
}

/// The `file_system_inputs` message body: each absolute path relative to
/// the first of the build runner's cache prefixes that contains it (zig
/// lib, local cache, global cache, build root; else the working
/// directory), as one prefix byte (`PathPrefix` + 1) and the sub path,
/// separated by zero bytes; empty when there is nothing to report, which
/// is then not sent (the runner cannot parse an empty list).
///
/// Files of zap's own zig lib directory (the pinned release's, which
/// nobody edits; see `BuildRunner`) are left out, about 700 of a
/// configure script's 720: the runner would otherwise stat them for every
/// configuration cache check, hash them all whenever its build script
/// cannot be cached, and record each as a `--watch` input. With another
/// lib directory (`--zig-lib-dir`, ZIG_LIB_DIR), every file is reported.
pub fn prefixInputs(arena: std.mem.Allocator, io: Io, inputs: []const u8, job: struct { zig_lib_dir: []const u8, cache_dirs: Frontend.CacheDirs, build_root: ?[]const u8 }) ![]const u8 {
    if (inputs.len == 0) return "";
    const cwd = try std.process.currentPathAlloc(io, arena);
    const Prefix = std.zig.Server.Message.PathPrefix;
    const Root = struct { prefix: Prefix, path: []const u8 };
    var roots: std.ArrayList(Root) = .empty;
    try roots.append(arena, .{ .prefix = .zig_lib, .path = try std.fs.path.resolve(arena, &.{ cwd, job.zig_lib_dir }) });
    try roots.append(arena, .{ .prefix = .local_cache, .path = try std.fs.path.resolve(arena, &.{ cwd, job.cache_dirs.local }) });
    try roots.append(arena, .{ .prefix = .global_cache, .path = try std.fs.path.resolve(arena, &.{ cwd, job.cache_dirs.global }) });
    if (job.build_root) |br| try roots.append(arena, .{ .prefix = .build_root, .path = try std.fs.path.resolve(arena, &.{ cwd, br }) });
    try roots.append(arena, .{ .prefix = .cwd, .path = cwd });
    const trusted_lib = std.mem.eql(u8, roots.items[0].path, try std.fs.path.resolve(arena, &.{ cwd, build_options.zig_lib_dir }));
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, inputs, 0);
    while (it.next()) |raw| {
        const abs = try std.fs.path.resolve(arena, &.{ cwd, raw });
        for (roots.items) |r| {
            if (abs.len > r.path.len and std.mem.startsWith(u8, abs, r.path) and abs[r.path.len] == '/') {
                if (r.prefix == .zig_lib and trusted_lib) break;
                if (out.items.len != 0) try out.append(arena, 0);
                try out.append(arena, @backingInt(r.prefix) + 1);
                try out.appendSlice(arena, abs[r.path.len + 1 ..]);
                break;
            }
        } else {
            if (out.items.len != 0) try out.append(arena, 0);
            try out.append(arena, @backingInt(Prefix.cwd) + 1);
            try out.appendSlice(arena, abs);
        }
    }
    return out.items;
}

test prefixInputs {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const lib = try std.fs.path.resolve(arena, &.{build_options.zig_lib_dir});
    const dirs: Frontend.CacheDirs = .{ .local = "/p/.zig-cache", .global = "/g" };
    const inputs = try std.mem.join(arena, "\x00", &.{ try std.fs.path.join(arena, &.{ lib, "std/std.zig" }), "/p/build.zig", "/g/p/dep/build.zig" });
    // zap's own lib directory: its files are left out.
    try std.testing.expectEqualStrings("\x05build.zig\x00\x04p/dep/build.zig", try prefixInputs(arena, io, inputs, .{ .zig_lib_dir = lib, .cache_dirs = dirs, .build_root = "/p" }));
    // Nothing else to report: nothing to send.
    try std.testing.expectEqualStrings("", try prefixInputs(arena, io, inputs[0..std.mem.indexOfScalar(u8, inputs, 0).?], .{ .zig_lib_dir = lib, .cache_dirs = dirs, .build_root = "/p" }));
    // Another lib directory: every file.
    try std.testing.expectEqualStrings("\x02std/std.zig\x00\x05build.zig", try prefixInputs(arena, io, "/l/std/std.zig\x00/p/build.zig", .{ .zig_lib_dir = "/l", .cache_dirs = dirs, .build_root = "/p" }));
}

fn cleanExit(io: Io) void {
    _ = io;
    std.process.exit(0);
}

/// The arguments a response file lists (`@file`, as upstream reads the
/// ones `zig build` writes for long command lines): whitespace-separated,
/// double-quoted with `\` escapes.
fn readResponseFile(arena: std.mem.Allocator, io: Io, path: []const u8) ![]const []const u8 {
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 30)) catch |err| fatal("unable to read response file '{s}': {t}", .{ path, err });
    var out: std.ArrayList([]const u8) = .empty;
    var k: usize = 0;
    while (true) {
        while (k < text.len and std.ascii.isWhitespace(text[k])) k += 1;
        if (k == text.len) break;
        var arg: std.ArrayList(u8) = .empty;
        var quoted = false;
        while (k < text.len and (quoted or !std.ascii.isWhitespace(text[k]))) : (k += 1) {
            switch (text[k]) {
                '"' => quoted = !quoted,
                '\\' => if (k + 1 < text.len) {
                    k += 1;
                    try arg.append(arena, text[k]);
                },
                else => |c| try arg.append(arena, c),
            }
        }
        try out.append(arena, arg.items);
    }
    return out.items;
}

/// Replaces zap with the program at `path`, as upstream's `zig run` does,
/// so that its exit status and signals are the program's own.
fn runExe(init: std.process.Init, path: []const u8, run_args: []const []const u8) noreturn {
    const arena = init.arena.allocator();
    const argv = arena.alloc([]const u8, 1 + run_args.len) catch fatal("out of memory", .{});
    // A path without a slash would be looked up in PATH.
    argv[0] = if (std.mem.indexOfScalar(u8, path, '/') == null) std.fs.path.join(arena, &.{ ".", path }) catch fatal("out of memory", .{}) else path;
    @memcpy(argv[1..], run_args);
    // Upstream sets ZIG_EXE for the program.
    if (std.process.executablePathAlloc(init.io, arena)) |self| {
        init.environ_map.put("ZIG_EXE", self) catch {};
    } else |_| {}
    const err = std.process.replace(init.io, .{ .argv = argv, .environ_map = init.environ_map });
    fatal("the following command failed to execve with '{t}':\n{s}", .{ err, std.mem.join(arena, " ", argv) catch path });
}

/// Where `zap run` puts the program: a directory of the cache per
/// compilation, so that running it again relinks in place.
fn runBinPath(arena: std.mem.Allocator, io: Io, cache_dir: []const u8, compile_args: []const []const u8, zig_lib_dir: []const u8, stem: []const u8) ![]const u8 {
    var h: std.hash.Wyhash = .init(0);
    const cwd = try std.process.currentPathAlloc(io, arena);
    h.update(cwd);
    h.update(&.{0});
    h.update(zig_lib_dir);
    for (compile_args) |a| {
        h.update(&.{0});
        h.update(a);
    }
    return std.fmt.allocPrint(arena, "{s}/o/{x:0>16}/{s}", .{ cache_dir, h.final(), stem });
}

/// Runs a test binary, then deletes it if it is `temporary`: named by
/// `testBinPath` for this build alone.
fn runTest(init: std.process.Init, path: []const u8, temporary: bool) !void {
    var child = try std.process.spawn(init.io, .{ .argv = &.{path} });
    const term = try child.wait(init.io);
    if (temporary) Io.Dir.cwd().deleteFile(init.io, path) catch {};
    switch (term) {
        .exited => |code| if (code != 0) std.process.exit(code),
        else => fatal("the test binary terminated unexpectedly: {any}", .{term}),
    }
}

fn testBinPath(arena: std.mem.Allocator, io: Io, cache_dir: []const u8, stem: []const u8) ![]const u8 {
    var r: [8]u8 = undefined;
    io.random(&r);
    return std.fmt.allocPrint(arena, "{s}/tmp/{s}-{x}", .{ cache_dir, stem, &r });
}

/// `ZAP_TIMING`: wall time per stage of a build.
const Stages = struct {
    io: Io,
    on: bool = false,
    last: Io.Timestamp,
    buf: [512]u8 = undefined,
    len: usize = 0,
    total_ns: u64 = 0,

    fn mark(s: *Stages, name: []const u8) void {
        s.markSplit(name, "", 0);
    }

    /// Ends a stage, of which `part_ns` went to `part`.
    fn markSplit(s: *Stages, name: []const u8, part: []const u8, part_ns: u64) void {
        const t = Io.Timestamp.now(s.io, .awake);
        const ns: u64 = @intCast(s.last.durationTo(t).nanoseconds);
        s.last = t;
        s.total_ns += ns;
        if (!s.on) return;
        const ms = struct {
            fn f(x: u64) f64 {
                return @as(f64, @floatFromInt(x)) / 1e6;
            }
        }.f;
        const out = if (part.len == 0)
            std.fmt.bufPrint(s.buf[s.len..], "{s}{s} {d:.1}", .{ if (s.len == 0) "" else ", ", name, ms(ns) })
        else
            std.fmt.bufPrint(s.buf[s.len..], "{s}{s} {d:.1}, {s} {d:.1}", .{ if (s.len == 0) "" else ", ", name, ms(ns -| part_ns), part, ms(part_ns) });
        s.len += (out catch return).len;
    }

    fn print(s: *Stages) void {
        if (s.on) std.debug.print("zap: {d:.1} ms in main: {s}\n", .{ @as(f64, @floatFromInt(s.total_ns)) / 1e6, s.buf[0..s.len] });
    }
};

pub fn printDiagnostics(io: Io, diags: []const diag.Diagnostic, format: diag.Format) !void {
    var buf: [4096]u8 = undefined;
    var w = Io.File.stderr().writerStreaming(io, &buf);
    try diag.render(&w.interface, diags, format);
    try w.interface.flush();
}

const DumpSink = struct {
    w: *Io.Writer,

    pub fn function(s: *DumpSink, zcu: *Zcu, ir: *const Ir) !void {
        try @import("Ir/print.zig").dump(ir, &zcu.ip, s.w);
    }
};

/// Options that upstream accepts and that change nothing zap does: link
/// layout, C-only settings, and settings zap already has.
const ignored_flags: std.StaticStringMap(void) = .initComptime(.{
    // zap builds only Debug, where the backend is a preference that
    // changes nothing a program means: zap uses its own backend and
    // linker, and `builtin.zig_backend` stays upstream's Debug default for
    // the target (docs/architecture.md, "The command line and `zap
    // build`").
    .{"-fllvm"},                           .{"-flld"},
    .{"-fno-llvm"},                        .{"-fno-lld"},                  .{"-fnew-linker"},          .{"-fno-new-linker"},
    .{"-fallow-so-scripts"},               .{"-fno-allow-so-scripts"},     .{"-fentry"},               .{"-fno-strip"},
    .{"-fstack-check"},                    .{"-fno-stack-check"},          .{"-fstack-protector"},     .{"-fno-stack-protector"},
    .{"-fno-omit-frame-pointer"},          .{"-fno-sanitize-thread"},
    .{"-fno-PIC"},                  .{"-fno-PIE"},              .{"-fbuiltin"},
    .{"-fno-builtin"},                     .{"-mred-zone"},                .{"-mno-red-zone"},         .{"-fno-sanitize-c"},
    .{"-fsanitize-c=trap"},                .{"-fsanitize-c=full"},         .{"-fsanitize-c"},          .{"-gdwarf32"},
    .{"-gdwarf64"},
    .{"--no-dynamic-linker"},              .{"--debug-compile-errors"},    .{"--debug-incremental"},
    .{"--verbose-air"},                    .{"--verbose-llvm-ir"},         .{"--verbose-link"},
    .{"--verbose-llvm-cpu-features"},      .{"--time-report"},             .{"-fformatted-panics"},    .{"-fno-formatted-panics"},
    .{"--eh-frame-hdr"},                   .{"--emit-relocs"},
    .{"--gc-sections"},                    .{"--no-gc-sections"},          .{"--no-dynamicbase"},      .{"-fallow-shlib-undefined"},
    .{"-fno-allow-shlib-undefined"},       .{"-headerpad_max_install_names"}, .{"-dead_strip_dylibs"}, .{"-ObjC"},
    .{"--discard-all"},                    .{"-fcompiler-rt"},             .{"-fno-compiler-rt"},      .{"-fubsan-rt"},
    .{"-fno-ubsan-rt"},                    .{"-fdll-export-fns"},          .{"-fno-dll-export-fns"},   .{"-rdynamic"},
    .{"--undefined-version"},              .{"--no-undefined-version"},    .{"--enable-new-dtags"},    .{"--disable-new-dtags"},
    .{"-feach-lib-rpath"},                 .{"-fno-each-lib-rpath"},       .{"-fno-lto"},              .{"-fno-sanitize-coverage-trace-pc-guard"},
    .{"-fincremental"},                    .{"-fno-incremental"},          .{"--debug-rt"},            .{"-femit-bin"},
    .{"--compress-debug-sections=none"},
});

/// Ignored options that take a parameter.
const ignored_flags_with_arg: std.StaticStringMap(void) = .initComptime(.{
    .{"-iquote"},   .{"-iframework"},   .{"-iframeworkwithsysroot"},
    .{"-rpath"},    .{"--libc"},   .{"--sysroot"},    .{"--error-limit"}, .{"--debug-log"},
    .{"--dynamic-linker"}, .{"-z"},     .{"--image-base"},
});

/// Include directory options of C, with their group's bit (upstream's
/// `ClangSearchSanitizer`, which drops a directory given twice in a group).
const cc_include_flags: std.StaticStringMap(u8) = .initComptime(.{
    .{ "-I", 1 }, .{ "-isystem", 1 << 1 }, .{ "-iwithsysroot", 1 << 2 }, .{ "-idirafter", 1 << 3 },
});

fn addInclude(arena: std.mem.Allocator, argv: *std.ArrayList([]const u8), seen: *std.StringHashMapUnmanaged(u8), group: u8, arg: []const u8, dir: []const u8, joined: bool) !void {
    const gop = try seen.getOrPut(arena, dir);
    if (!gop.found_existing) gop.value_ptr.* = 0;
    if (gop.value_ptr.* & group != 0) return;
    gop.value_ptr.* |= group;
    try argv.append(arena, arg);
    if (!joined) try argv.append(arena, dir);
}

/// Options that ask for something zap does not do, as the diagnostic's
/// message.
const unsupported_flags: std.StaticStringMap([]const u8) = .initComptime(.{
    .{ "-fno-entry", "zap does not build executables without an entry point yet ('-fno-entry')" },
    .{ "-fstrip", "zap does not strip debug info yet ('-fstrip'); remove '.strip = true'" },
    .{ "-fomit-frame-pointer", "zap always keeps frame pointers ('-fomit-frame-pointer'); remove '.omit_frame_pointer = true'" },
    .{ "-fsanitize-thread", "zap has no ThreadSanitizer ('-fsanitize-thread'); build this step with upstream zig" },
    .{ "-femit-asm", "zap does not emit assembly ('-femit-asm')" },
    .{ "-femit-implib", "zap does not emit import libraries ('-femit-implib')" },
    .{ "-femit-llvm-bc", "zap has no LLVM backend ('-femit-llvm-bc')" },
    .{ "-femit-llvm-ir", "zap has no LLVM backend ('-femit-llvm-ir')" },
    .{ "-femit-h", "zap does not emit C headers ('-femit-h')" },
    .{ "-fsanitize-coverage-trace-pc-guard", "zap does not instrument coverage ('-fsanitize-coverage-trace-pc-guard')" },
    .{ "-rcflags", "zap does not compile Windows resources ('-rcflags')" },
    .{ "-x", "zap does not compile C sources ('-x'); build this step with upstream zig" },
    .{ "--force_undefined", "zap does not support '--force_undefined' yet" },
    .{ "-mcmodel", "zap only supports the default code model ('-mcmodel')" },
    .{ "--script", "zap does not support linker scripts ('--script'); build this step with upstream zig" },
    .{ "--version-script", "zap does not support version scripts ('--version-script')" },
    .{ "--version", "zap does not build shared libraries ('--version')" },
    .{ "-framework", "zap does not link frameworks yet ('-framework')" },
    .{ "-needed_framework", "zap does not link frameworks yet ('-needed_framework')" },
    .{ "-weak_framework", "zap does not link frameworks yet ('-weak_framework')" },
    .{ "--subsystem", "zap does not target Windows ('--subsystem')" },
    .{ "-municode", "zap does not target Windows ('-municode')" },
});

pub fn setUnsupported(opts: *Options, arena: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    if (opts.unsupported == null) opts.unsupported = std.fmt.allocPrint(arena, fmt, args) catch fatal("out of memory", .{});
}

pub fn parseOptions(arena: std.mem.Allocator, io: Io, environ_map: *const std.process.Environ.Map, command: Command, args_in: []const []const u8) !Options {
    var args = args_in;
    var root: ?[]const u8 = null;
    var positional_root = false;
    // A ReleaseFast or ReleaseSmall `-O`, which only `zap build` steps may use.
    var unsafe_mode: ?[]const u8 = null;
    var opts: Options = .{ .command = command, .root_src_path = undefined };
    var test_filters: std.ArrayList([]const u8) = .empty;
    var link_inputs: std.ArrayList([]const u8) = .empty;
    // `-l` names, resolved against `lib_dirs` once all arguments are read.
    var libs: std.ArrayList(LibQuery) = .empty;
    var lib_dirs: std.ArrayList([]const u8) = .empty;
    var lib_search: LibQuery.Search = .{};
    var rpaths: std.ArrayList([]const u8) = .empty;
    var sysroot = false;
    var deps: std.ArrayList([]const u8) = .empty;
    var modules: std.ArrayList(Frontend.ModuleArg) = .empty;
    // `-ffuzz` and `-fno-fuzz` are per module, as upstream's: each `-M`
    // takes the last one before it; a root file given by position takes
    // the last one left.
    var fuzz: ?bool = null;
    var root_fuzz: ?bool = null;
    // So are `-O`, `-ferror-tracing` and `-fvalgrind`.
    var mode: Mode = .{};
    var root_mode: Mode = .{};
    // C, as upstream's: `-I`, `-D` and the like collect in `cc_argv`, which
    // the next `-M` takes, with the C files given since the last one and
    // the module's C options; what is left after the last `-M` applies to
    // every module (`global_cc_argv`). `-cflags ... --` applies to the C
    // files after it.
    var cc_argv: std.ArrayList([]const u8) = .empty;
    var cc_seen: std.StringHashMapUnmanaged(u8) = .empty;
    var extra_cflags: []const []const u8 = &.{};
    var c_files: std.ArrayList(CSource) = .empty;
    var c_owned: usize = 0;
    var c_flags: CSource.Flags = .{};
    var root_c_flags: ?CSource.Flags = null;
    // The root module, or other modules, given without a root source file
    // (`-M<name>`): C sources only.
    var rootless_root = false;
    var rootless: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i +%= 1) {
        const arg = args[i];
        if (c_flags.parse(arg)) {
            // A module's C option; -fPIC and -fno-PIC mean more below.
            if (!std.mem.endsWith(u8, arg, "PIC")) continue;
        }
        if (arg.len > 1 and arg[0] == '@') {
            // Its arguments take its place.
            args = try std.mem.concat(arena, []const u8, &.{ try readResponseFile(arena, io, arg[1..]), args[i + 1 ..] });
            i = std.math.maxInt(usize);
            continue;
        } else if (std.mem.eql(u8, arg, "--")) {
            if (command != .run) fatal("unexpected '--' outside of 'zap run'", .{});
            opts.run_args = args[i + 1 ..];
            break;
        } else if (std.mem.startsWith(u8, arg, "-femit-bin=")) {
            opts.emit_bin = .{ .path = arg["-femit-bin=".len..] };
        } else if (std.mem.eql(u8, arg, "-fno-emit-bin")) {
            opts.emit_bin = .none;
        } else if (std.mem.eql(u8, arg, "-femit-docs")) {
            opts.emit_docs = .default;
        } else if (std.mem.startsWith(u8, arg, "-femit-docs=")) {
            opts.emit_docs = .{ .path = arg["-femit-docs=".len..] };
        } else if (std.mem.eql(u8, arg, "-fno-emit-docs")) {
            opts.emit_docs = .none;
        } else if (std.mem.eql(u8, arg, "-fPIC") or std.mem.eql(u8, arg, "-fPIE")) {
            if (std.mem.eql(u8, arg, "-fPIE")) opts.c_pie = true;
            // On an executable, a preference that changes nothing a program
            // means, as with -fllvm: zap links it static and non-PIE, and
            // `builtin.position_independent_*` stay false. Objects and
            // libraries get position-independent code, as upstream's.
            if (command == .build_obj or command == .build_lib) {
                opts.pic = true;
                if (std.mem.eql(u8, arg, "-fPIE") and command == .build_obj) opts.pie = true;
            }
        } else if (std.mem.eql(u8, arg, "-dynamic")) {
            lib_search = .{ .strategy = .mode_first, .static = false };
            // Shared objects, which are position-independent; executables
            // stay static.
            if (command == .build_lib) {
                opts.dynamic = true;
                opts.pic = true;
            } else opts.exe_dynamic = true;
        } else if (std.mem.startsWith(u8, arg, "-fsoname=")) {
            opts.soname = .{ .name = arg["-fsoname=".len..] };
        } else if (std.mem.eql(u8, arg, "-fsoname")) {
            opts.soname = .default;
        } else if (std.mem.eql(u8, arg, "-fno-soname")) {
            opts.soname = .none;
        } else if (std.mem.eql(u8, arg, "-fno-PIC") or std.mem.eql(u8, arg, "-fno-PIE")) {
            // As upstream: -fno-PIE leaves -fPIC alone.
            if (std.mem.eql(u8, arg, "-fno-PIC")) opts.pic = false;
            opts.pie = false;
            if (std.mem.eql(u8, arg, "-fno-PIE")) opts.c_pie = false;
        } else if (std.mem.eql(u8, arg, "--name")) {
            opts.name = nextArg(args, &i, arg);
        } else if (std.mem.eql(u8, arg, "-target")) {
            opts.target = nextArg(args, &i, arg);
        } else if (std.mem.eql(u8, arg, "-mcpu")) {
            const cpu = nextArg(args, &i, arg);
            // zap generates code for the baseline x86_64 CPU, for native too.
            if (!std.mem.eql(u8, cpu, "baseline") and !std.mem.eql(u8, cpu, "native") and !std.mem.eql(u8, cpu, "x86_64"))
                setUnsupported(&opts, arena, "zap generates code for the baseline CPU only ('-mcpu {s}')", .{cpu});
        } else if (std.mem.eql(u8, arg, "--zig-lib-dir")) {
            opts.zig_lib_dir = nextArg(args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--cache-dir")) {
            opts.cache_dir = nextArg(args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--global-cache-dir")) {
            opts.global_cache_dir = nextArg(args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--build-root")) {
            opts.build_root = nextArg(args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--listen=-")) {
            opts.listen = true;
        } else if (std.mem.startsWith(u8, arg, "--listen")) {
            fatal("zap only listens on stdin and stdout ('--listen=-'), found '{s}'", .{arg});
        } else if (std.mem.eql(u8, arg, "-fsingle-threaded")) {
            opts.single_threaded = true;
        } else if (std.mem.eql(u8, arg, "-fno-single-threaded")) {
            opts.single_threaded = false;
        } else if (std.mem.eql(u8, arg, "-ffuzz")) {
            // Objects would need the coverage sections and their symbols.
            if (command == .build_obj or command == .build_lib)
                setUnsupported(&opts, arena, "zap does not instrument objects or libraries for fuzzing yet ('-ffuzz'); fuzz an executable or a test", .{});
            fuzz = true;
        } else if (std.mem.eql(u8, arg, "-fno-fuzz")) {
            fuzz = false;
        } else if (std.mem.eql(u8, arg, "-ferror-tracing") or std.mem.eql(u8, arg, "-fno-error-tracing")) {
            mode.error_tracing = arg[2] == 'e';
        } else if (std.mem.eql(u8, arg, "-fvalgrind") or std.mem.eql(u8, arg, "-fno-valgrind")) {
            mode.valgrind = arg[2] == 'v';
        } else if (std.mem.eql(u8, arg, "-O") or (std.mem.startsWith(u8, arg, "-O") and !std.mem.eql(u8, arg, "-ObjC"))) {
            const v = if (arg.len == 2) nextArg(args, &i, arg) else arg[2..];
            const o = std.lang.Optimize.fromString(v) orelse fatal("unrecognized optimization mode: '{s}'", .{v});
            // zap compiles every mode with its one code generation, with
            // upstream's builtin and defaults for the mode. ReleaseFast and
            // ReleaseSmall (no safety checks) only for `zap build`'s steps,
            // which a project's build script may ask for.
            if (o == .fast or o == .small) unsafe_mode = arg;
            mode.optimize = o;
        } else if (std.mem.eql(u8, arg, "-funwind-tables")) {
            opts.unwind_tables = .sync;
        } else if (std.mem.eql(u8, arg, "-fasync-unwind-tables")) {
            opts.unwind_tables = .async;
        } else if (std.mem.eql(u8, arg, "-fno-unwind-tables")) {
            opts.unwind_tables = .none;
        } else if (std.mem.eql(u8, arg, "-freference-trace")) {
            opts.reference_trace = 256;
        } else if (std.mem.startsWith(u8, arg, "-freference-trace=")) {
            const v = arg["-freference-trace=".len..];
            opts.reference_trace = std.fmt.parseUnsigned(u32, v, 10) catch fatal("unable to parse reference_trace count '{s}'", .{v});
        } else if (std.mem.eql(u8, arg, "-fno-reference-trace")) {
            opts.reference_trace = 0;
        } else if (std.mem.eql(u8, arg, "--test-runner")) {
            opts.test_runner = nextTestArg(command, args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--test-filter")) {
            try test_filters.append(arena, nextTestArg(command, args, &i, arg));
        } else if (std.mem.eql(u8, arg, "--test-no-exec")) {
            if (command != .@"test") fatal("{s} is only valid for 'zap test'", .{arg});
            opts.test_no_exec = true;
        } else if (std.mem.eql(u8, arg, "--dep")) {
            try deps.append(arena, nextArg(args, &i, arg));
        } else if (std.mem.startsWith(u8, arg, "-M")) {
            const spec = arg[2..];
            c_flags.optimize = mode.optimize;
            // A module without a root source file holds C sources: no Zig
            // module, and `--dep`s on it name nothing.
            const eq = std.mem.indexOfScalar(u8, spec, '=');
            if (eq == null) {
                if (root == null and !rootless_root) {
                    rootless_root = true;
                    opts.root_name = spec;
                    root_c_flags = c_flags;
                } else try rootless.append(arena, spec);
                deps.clearRetainingCapacity();
                fuzz = null;
                mode = .{};
            } else if (root == null and !rootless_root) {
                root = spec[eq.? + 1 ..];
                opts.root_name = spec[0..eq.?];
                opts.root_deps = try deps.toOwnedSlice(arena);
                root_fuzz = fuzz;
                root_mode = mode;
                root_c_flags = c_flags;
            } else try modules.append(arena, .{
                .name = spec[0..eq.?],
                .path = spec[eq.? + 1 ..],
                .deps = try deps.toOwnedSlice(arena),
                .fuzz = fuzz,
                .optimize = mode.optimize,
                .error_tracing = mode.error_tracing,
                .valgrind = mode.valgrind,
            });
            fuzz = null;
            mode = .{};
            // The module's C files, arguments and options.
            const module_cc = try cc_argv.toOwnedSlice(arena);
            for (c_files.items[c_owned..]) |*f| {
                f.cc_argv = module_cc;
                f.flags = c_flags;
            }
            c_owned = c_files.items.len;
            cc_seen.clearRetainingCapacity();
            c_flags = .{};
        } else if (std.mem.startsWith(u8, arg, "--error-format=")) {
            const v = arg["--error-format=".len..];
            opts.error_format = std.meta.stringToEnum(diag.Format, v) orelse fatal("invalid --error-format '{s}': expected 'text' or 'json'", .{v});
        } else if (std.mem.eql(u8, arg, "--debug-dump-ir")) {
            opts.dump_ir = true;
        } else if (std.mem.eql(u8, arg, "--stack")) {
            const v = nextArg(args, &i, arg);
            opts.stack_size = std.fmt.parseUnsigned(u64, v, 0) catch fatal("invalid stack size: '{s}'", .{v});
        } else if (LibQuery.searches.get(arg)) |search| {
            lib_search = search;
        } else if (std.mem.eql(u8, arg, "-L")) {
            try lib_dirs.append(arena, nextArg(args, &i, arg));
        } else if (std.mem.startsWith(u8, arg, "-L")) {
            try lib_dirs.append(arena, arg[2..]);
        } else if (std.mem.eql(u8, arg, "-rpath")) {
            try rpaths.append(arena, nextArg(args, &i, arg));
        } else if (std.mem.eql(u8, arg, "--sysroot")) {
            // Only its effect on library search: upstream searches no
            // native directories with one.
            _ = nextArg(args, &i, arg);
            sysroot = true;
        } else if (std.mem.eql(u8, arg, "-fllvm") or std.mem.eql(u8, arg, "-fno-llvm")) {
            // zap uses its own backend either way (see `ignored_flags`).
            opts.use_llvm = arg[2] == 'l';
        } else if (ignored_flags.has(arg)) {
            // Changes nothing zap does.
        } else if (ignored_flags_with_arg.has(arg)) {
            _ = nextArg(args, &i, arg);
        } else if (std.mem.startsWith(u8, arg, "--build-id")) {
            // The build ID of a linked binary.
        } else if (std.mem.eql(u8, arg, "-D")) {
            try cc_argv.appendSlice(arena, &.{ arg, nextArg(args, &i, arg) });
        } else if (std.mem.startsWith(u8, arg, "-D")) {
            try cc_argv.append(arena, arg);
        } else if (cc_include_flags.get(arg)) |group| {
            try addInclude(arena, &cc_argv, &cc_seen, group, arg, nextArg(args, &i, arg), false);
        } else if (std.mem.startsWith(u8, arg, "-I")) {
            try addInclude(arena, &cc_argv, &cc_seen, 1, arg, arg[2..], true);
        } else if (std.mem.startsWith(u8, arg, "--embed-dir=")) {
            try addInclude(arena, &cc_argv, &cc_seen, 1 << 5, arg, arg["--embed-dir=".len..], true);
        } else if (std.mem.eql(u8, arg, "-cflags")) {
            var flags: std.ArrayList([]const u8) = .empty;
            while (true) {
                i += 1;
                if (i >= args.len) fatal("expected -- after -cflags", .{});
                if (std.mem.eql(u8, args[i], "--")) break;
                try flags.append(arena, args[i]);
            }
            extra_cflags = flags.items;
        } else if (std.mem.eql(u8, arg, "--verbose-cc")) {
            opts.verbose_cc = true;
        } else if (std.mem.eql(u8, arg, "-ffunction-sections")) {
            opts.function_sections = true;
        } else if (std.mem.eql(u8, arg, "-fdata-sections")) {
            opts.data_sections = true;
        } else if (std.mem.startsWith(u8, arg, "-ofmt=")) {
            if (!std.mem.eql(u8, arg, "-ofmt=elf")) setUnsupported(&opts, arena, "zap emits ELF on Linux only ('{s}')", .{arg});
        } else if (std.mem.startsWith(u8, arg, "-l") and glibc_libs.has(arg[2..])) {
            opts.link_libc = true;
        } else if (std.mem.startsWith(u8, arg, "-l") and libcpp_names.has(arg[2..])) {
            opts.link_libcpp = true;
            opts.link_libc = true;
        } else if (std.mem.startsWith(u8, arg, "-l") or std.mem.eql(u8, arg, "--library")) {
            const name = if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--library")) nextArg(args, &i, arg) else arg[2..];
            if (glibc_libs.has(name)) {
                opts.link_libc = true;
            } else if (libcpp_names.has(name)) {
                opts.link_libcpp = true;
                opts.link_libc = true;
            } else if (command == .build_obj or command == .build_lib) {
                setUnsupported(&opts, arena, "zap does not link libraries into objects or libraries yet ('-l{s}'); build this step with upstream zig", .{name});
            } else {
                try libs.append(arena, .{ .name = name, .at = link_inputs.items.len, .search = lib_search });
                try link_inputs.append(arena, "");
            }
        } else if (std.mem.startsWith(u8, arg, "-needed-l") or std.mem.startsWith(u8, arg, "-weak-l")) {
            setUnsupported(&opts, arena, "zap does not link libc or system libraries ('{s}'); build this step with upstream zig", .{arg});
        } else if (unsupported_flags.get(arg)) |msg| {
            setUnsupported(&opts, arena, "{s}", .{msg});
            // Their parameters: the C flags up to `--`, the language.
            if (std.mem.eql(u8, arg, "-rcflags")) {
                while (i + 1 < args.len and !std.mem.eql(u8, args[i + 1], "--")) i += 1;
                i += 1;
            } else if (std.mem.eql(u8, arg, "-x")) _ = nextArg(args, &i, arg);
        } else if (std.mem.startsWith(u8, arg, "-flto") or std.mem.startsWith(u8, arg, "-fentry=") or
            std.mem.startsWith(u8, arg, "--export=") or std.mem.startsWith(u8, arg, "-fpatchable-function-entry=") or
            std.mem.startsWith(u8, arg, "--compress-debug-sections="))
        {
            setUnsupported(&opts, arena, "zap does not support '{s}' yet", .{arg});
        } else if (std.mem.startsWith(u8, arg, "-")) {
            setUnsupported(&opts, arena, "zap does not support the option '{s}'", .{arg});
        } else if (!std.mem.endsWith(u8, arg, ".zig")) {
            const ext = std.fs.path.extension(arg);
            if (CSource.Lang.ofPath(arg)) |lang| {
                try c_files.append(arena, .{ .path = arg, .extra_flags = extra_cflags, .cc_argv = &.{}, .flags = .{}, .lang = lang });
            } else if (std.mem.eql(u8, ext, ".o") or std.mem.eql(u8, ext, ".a") or (isSharedLib(arg) and command != .build_obj and command != .build_lib)) {
                try link_inputs.append(arena, arg);
            } else if (std.mem.eql(u8, ext, ".o") or std.mem.eql(u8, ext, ".a") or std.mem.eql(u8, ext, ".so") or std.mem.indexOf(u8, arg, ".so.") != null or std.mem.eql(u8, ext, ".obj") or std.mem.eql(u8, ext, ".lib"))
                setUnsupported(&opts, arena, "zap does not link object files or libraries ('{s}'); build this step with upstream zig", .{arg})
            else
                setUnsupported(&opts, arena, "zap does not compile C, C++, or assembly sources ('{s}'); build this step with upstream zig", .{arg});
        } else if (root == null) {
            root = arg;
            positional_root = true;
            opts.root_deps = try deps.toOwnedSlice(arena);
        } else {
            fatal("unexpected extra parameter: {s}", .{arg});
        }
    }
    if (opts.target) |target| checkTarget(&opts, arena, target) else if (!(builtin.cpu.arch == .x86_64 and builtin.os.tag == .linux))
        setUnsupported(&opts, arena, "zap does not implement aarch64-macos code generation yet ('native'); pass -target x86_64-linux", .{});
    if (opts.exe_dynamic and !opts.link_libc and command != .build_lib)
        setUnsupported(&opts, arena, "zap links executables statically unless they link libc ('-dynamic'); add -lc or build this step with upstream zig", .{});
    // As upstream (`requiresPIC`): glibc makes objects and libraries
    // position-independent, as their builtin says. zap links executables
    // itself, non-PIE.
    if (opts.link_libc and (command == .build_obj or command == .build_lib)) opts.pic = true;
    if (opts.link_libc and opts.dynamic and command == .build_lib)
        setUnsupported(&opts, arena, "zap does not link shared libraries against glibc yet ('-dynamic' with '-lc'); build this step with upstream zig", .{});
    if (opts.link_libc and opts.unsupported == null) resolveGlibc(&opts, arena, io);
    // A static library holds the C objects as members; an object or a
    // shared library would need them linked into it.
    if (c_files.items.len != 0 and (command == .build_obj or (command == .build_lib and opts.dynamic)))
        setUnsupported(&opts, arena, "zap does not compile C sources into objects or shared libraries yet ('{s}'); build this step with upstream zig", .{c_files.items[0].path});
    // C sources without any module: a library or executable of C only, as
    // upstream's.
    if (root == null and !rootless_root and c_files.items.len != 0 and command != .build_obj and command != .@"test") rootless_root = true;
    if (root == null and rootless_root) {
        // An executable whose main is C's, as upstream's; zap needs glibc
        // for its start code (`Builtin.glibc_start`).
        if ((command == .build_exe or command == .run) and opts.link_libc and c_files.items.len != 0)
            opts.c_exe = true
        else if (command != .build_lib or opts.dynamic)
            setUnsupported(&opts, arena, "zap builds modules without a Zig root source file only into static libraries of C and executables of C that link glibc ('-M{s}'); build this step with upstream zig", .{opts.root_name})
        else if (c_files.items.len == 0)
            setUnsupported(&opts, arena, "zap builds a library without a Zig root source file only from C sources ('-M{s}')", .{opts.root_name})
        else
            opts.c_only = true;
    }
    opts.root_src_path = root orelse if (opts.unsupported != null or opts.c_only or opts.c_exe) "" else fatal("expected a root source file", .{});
    opts.test_filters = test_filters.items;
    // As upstream: `-L` directories that do not exist are left out, and
    // `-l` names also search the native library directories, after them.
    var search_dirs: std.ArrayList([]const u8) = .empty;
    for (lib_dirs.items) |dir| if (Io.Dir.cwd().access(io, dir, .{})) |_| try search_dirs.append(arena, dir) else |_| {};
    const native = opts.target == null or std.mem.eql(u8, opts.target.?, "native");
    const n_explicit_dirs = search_dirs.items.len;
    if (libs.items.len != 0 and native and !sysroot) {
        if (std.zig.system.resolveTargetQuery(io, .{})) |target| {
            if (std.zig.system.NativePaths.detect(arena, io, &target, environ_map)) |paths| {
                for (paths.lib_dirs.items) |dir| if (Io.Dir.cwd().access(io, dir, .{})) |_| try search_dirs.append(arena, dir) else |_| {};
                opts.c_native_includes = paths.include_dirs.items;
            } else |_| {}
        } else |_| {}
    }
    for (libs.items) |q| {
        link_inputs.items[q.at] = try q.find(arena, io, search_dirs.items) orelse
            fatal("unable to find library '-l{s}'; searched paths: {s}", .{ q.name, try std.mem.join(arena, " ", search_dirs.items) });
    }
    // As upstream, an object or a static library links nothing: it leaves
    // archive inputs out, and a static library holds object inputs as
    // members after its own object. Merging objects into an object (or a
    // shared library) is a relocatable link zap does not do yet.
    if (command == .build_obj or command == .build_lib) {
        var kept: usize = 0;
        for (link_inputs.items) |path| {
            if (std.mem.eql(u8, std.fs.path.extension(path), ".a")) {
                Io.Dir.cwd().access(io, path, .{}) catch fatal("{s}: file not found", .{path});
                continue;
            }
            if (command == .build_obj or opts.dynamic)
                setUnsupported(&opts, arena, "zap does not link object files into objects or shared libraries yet ('{s}'); build this step with upstream zig", .{path});
            link_inputs.items[kept] = path;
            kept += 1;
        }
        link_inputs.shrinkRetainingCapacity(kept);
    }
    // Shared libraries are imported from, not linked in.
    var objects: std.ArrayList([]const u8) = .empty;
    var shared: std.ArrayList([]const u8) = .empty;
    for (link_inputs.items) |path| try (if (isSharedLib(path)) &shared else &objects).append(arena, path);
    opts.link_inputs = objects.items;
    opts.shared_libs = shared.items;
    if (shared.items.len != 0 and !opts.link_libc)
        setUnsupported(&opts, arena, "zap links shared libraries only into executables that link libc ('{s}'); add -lc or build this step with upstream zig", .{shared.items[0]});
    // DT_RUNPATH: as upstream's `rpath_list`, deduplicated.
    if (native) try rpaths.appendSlice(arena, search_dirs.items[0..n_explicit_dirs]);
    var unique_rpaths: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (rpaths.items) |r| try unique_rpaths.put(arena, r, {});
    if (unique_rpaths.count() != 0) opts.runpath = try std.mem.join(arena, ":", unique_rpaths.keys());
    opts.modules = modules.items;
    // A root file given by position owns what no -M took, as upstream's;
    // so does a library or executable of C only.
    if (positional_root or ((opts.c_only or opts.c_exe) and c_owned == 0)) {
        c_flags.optimize = mode.optimize;
        root_c_flags = c_flags;
        const module_cc = try cc_argv.toOwnedSlice(arena);
        for (c_files.items[c_owned..]) |*f| {
            f.cc_argv = module_cc;
            f.flags = c_flags;
        }
        c_owned = c_files.items.len;
    }
    if (c_owned != c_files.items.len and opts.unsupported == null) fatal("C source file '{s}' has no parent module", .{c_files.items[c_owned].path});
    for (c_files.items) |*f| f.flags = f.flags.inherit(root_c_flags orelse .{});
    opts.c_sources = c_files.items;
    opts.c_global_cc_argv = cc_argv.items;
    // As upstream, a root file given without `-M` names its module "test"
    // under `zap test`, else after the file (not `--name`).
    if (positional_root) opts.root_name = if (command == .@"test") "test" else std.fs.path.stem(opts.root_src_path);
    // As upstream: a `--dep` names one module.
    for (modules.items, 0..) |m, k| {
        const prev = if (std.mem.eql(u8, m.name, opts.root_name)) opts.root_src_path else for (modules.items[0..k]) |p| {
            if (std.mem.eql(u8, p.name, m.name)) break p.path;
        } else continue;
        fatal("unable to add module \"{s}\": already exists as '{s}'", .{ m.name, prev });
    }
    // `--dep`s on modules of C only name nothing.
    if (rootless.items.len != 0) {
        opts.root_deps = try dropDeps(arena, opts.root_deps, rootless.items);
        for (modules.items) |*m| m.deps = try dropDeps(arena, m.deps, rootless.items);
    }
    // Per-module flags after the last `-M` belong to no module, unless the
    // root file is given by position.
    if (positional_root) {
        root_fuzz = fuzz;
        root_mode = mode;
    }
    opts.root_fuzz = root_fuzz orelse false;
    if (unsafe_mode) |a| if (!opts.listen)
        setUnsupported(&opts, arena, "zap builds only Debug and ReleaseSafe on the command line ('{s}'); use -OReleaseSafe, or upstream zig for an optimized build", .{a});
    // As upstream's `Config.resolve` and `Module.create`: error tracing and
    // Valgrind client requests are on in Debug and off in ReleaseSafe
    // unless asked for.
    opts.optimize = root_mode.optimize orelse .debug;
    opts.error_tracing = root_mode.error_tracing orelse (opts.optimize == .debug);
    opts.valgrind = root_mode.valgrind orelse (opts.optimize == .debug);
    const seen = try arena.alloc(bool, modules.items.len);
    @memset(seen, false);
    const root_flags: Inherited = .{ .fuzz = opts.root_fuzz, .optimize = opts.optimize, .error_tracing = opts.error_tracing, .valgrind = opts.valgrind };
    inheritFlags(modules.items, seen, opts.root_deps, root_flags);
    for (modules.items) |*m| inherit(m, root_flags); // no module depends on it
    opts.fuzz = opts.root_fuzz or for (modules.items) |m| {
        if (m.fuzz.?) break true;
    } else false;
    return opts;
}

/// `deps` without those that name one of `names` (`[alias=]name`).
fn dropDeps(arena: std.mem.Allocator, deps: []const []const u8, names: []const []const u8) ![]const []const u8 {
    var kept: std.ArrayList([]const u8) = .empty;
    for (deps) |spec| {
        const name = if (std.mem.indexOfScalar(u8, spec, '=')) |e| spec[e + 1 ..] else spec;
        for (names) |n| {
            if (std.mem.eql(u8, n, name)) break;
        } else try kept.append(arena, spec);
    }
    return kept.items;
}

/// A module's `-O`, `-ferror-tracing` and `-fvalgrind`, as given.
const Mode = struct {
    optimize: ?std.lang.Optimize = null,
    error_tracing: ?bool = null,
    valgrind: ?bool = null,
};

/// The per-module flags a module passes to those that depend on it.
const Inherited = struct { fuzz: bool, optimize: std.lang.Optimize, error_tracing: bool, valgrind: bool };

fn inherit(m: *Frontend.ModuleArg, parent: Inherited) void {
    m.fuzz = m.fuzz orelse parent.fuzz;
    m.optimize = m.optimize orelse parent.optimize;
    m.error_tracing = m.error_tracing orelse parent.error_tracing;
    m.valgrind = m.valgrind orelse parent.valgrind;
}

/// Per-module flags (`-ffuzz`, `-O`, ...), as upstream's `Module.create`:
/// a module without its own flag takes that of the module that first
/// depends on it, depth first from the root module, whose `deps` and
/// flags are given. `seen` has a slot per module.
fn inheritFlags(modules: []Frontend.ModuleArg, seen: []bool, deps: []const []const u8, parent: Inherited) void {
    for (deps) |spec| {
        const name = if (std.mem.indexOfScalar(u8, spec, '=')) |e| spec[e + 1 ..] else spec;
        for (modules, seen) |*m, *s| {
            if (!std.mem.eql(u8, m.name, name)) continue;
            if (s.*) break;
            s.* = true;
            inherit(m, parent);
            inheritFlags(modules, seen, m.deps, .{ .fuzz = m.fuzz.?, .optimize = m.optimize.?, .error_tracing = m.error_tracing.?, .valgrind = m.valgrind.? });
            break;
        }
    }
}

/// Only the x86_64-linux backend exists so far; refuses aarch64-macos
/// rather than silently writing an x86_64 ELF.
pub fn checkTarget(opts: *Options, arena: std.mem.Allocator, target: []const u8) void {
    const native_ok = builtin.cpu.arch == .x86_64 and builtin.os.tag == .linux;
    if (std.mem.eql(u8, target, "x86_64-linux") or std.mem.eql(u8, target, "x86_64-linux-none") or
        (std.mem.eql(u8, target, "native") and native_ok))
    {} else if (std.mem.startsWith(u8, target, "x86_64-linux-gnu")) {
        // `x86_64-linux-gnu[.version]`: glibc, of that version or upstream's
        // default for the target.
        const rest = target["x86_64-linux-gnu".len..];
        if (rest.len == 0) {
            opts.glibc_version = default_glibc;
        } else if (rest[0] == '.') {
            opts.glibc_version = std.SemanticVersion.parse(rest[1..]) catch parse: {
                const v = std.SemanticVersion.parse(std.fmt.allocPrint(arena, "{s}.0", .{rest[1..]}) catch fatal("out of memory", .{})) catch {
                    setUnsupported(opts, arena, "invalid glibc version in target '{s}'", .{target});
                    return;
                };
                break :parse v;
            };
        } else setUnsupported(opts, arena, "zap does not support the target '{s}'; it supports x86_64-linux and aarch64-macos", .{target});
        if (opts.glibc_version != null and !opts.link_libc)
            setUnsupported(opts, arena, "zap supports '{s}' only with -lc; drop the ABI or add -lc", .{target});
    } else if (std.mem.eql(u8, target, "aarch64-macos") or std.mem.eql(u8, target, "aarch64-macos-none") or
        std.mem.eql(u8, target, "native"))
    {
        setUnsupported(opts, arena, "zap does not implement aarch64-macos code generation yet ('{s}'); pass -target x86_64-linux", .{target});
    } else setUnsupported(opts, arena, "zap does not support the target '{s}'; it supports x86_64-linux and aarch64-macos", .{target});
}

/// glibc's symbols at the build's version, from the zig lib directory.
fn loadGlibc(init: std.process.Init, job: *const Job) !Glibc {
    const path = try std.fs.path.join(init.gpa, &.{ job.zig_lib_dir, Glibc.abilists_path });
    defer init.gpa.free(path);
    const contents = Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(1 << 20)) catch |err|
        fatal("unable to read glibc's symbols from '{s}': {t}", .{ path, err });
    defer init.gpa.free(contents);
    const want = job.opts.glibc_version.?;
    const g = Glibc.load(init.gpa, contents, want) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.UnsupportedVersion => fatal("zap cannot link glibc {f}: '{s}' does not list it", .{ want, path }),
        error.InvalidAbilists => fatal("unable to read glibc's symbols from '{s}': the file is damaged", .{path}),
    };
    // As upstream's warning.
    if (g.newest().order(want) == .lt) std.log.warn("zap cannot link new glibc version {f}; providing instead {f}", .{ want, g.newest() });
    return g;
}

/// Whether `path` names a shared library: `.so`, or a versioned `.so.1`.
fn isSharedLib(path: []const u8) bool {
    const base = std.fs.path.basename(path);
    return std.mem.endsWith(u8, base, ".so") or std.mem.indexOf(u8, base, ".so.") != null;
}

/// A `-l` library, found as upstream's `link.resolveLibInput` finds one
/// by its search strategy and preferred mode.
const LibQuery = struct {
    name: []const u8,
    /// Its place in `Options.link_inputs`.
    at: usize,
    search: Search,

    const Search = struct {
        strategy: enum { paths_first, mode_first, no_fallback } = .paths_first,
        static: bool = false,
    };

    /// The options that set the search for the `-l` after them.
    const searches: std.StaticStringMap(Search) = .initComptime(.{
        .{ "-search_paths_first", Search{} },
        .{ "-search_paths_first_static", Search{ .static = true } },
        .{ "-search_dylibs_first", Search{ .strategy = .mode_first } },
        .{ "-search_static_first", Search{ .strategy = .mode_first, .static = true } },
        .{ "-search_dylibs_only", Search{ .strategy = .no_fallback } },
        .{ "-search_static_only", Search{ .strategy = .no_fallback, .static = true } },
        .{ "-static", Search{ .strategy = .no_fallback, .static = true } },
    });

    /// The library's path, `lib<name>.so` or `lib<name>.a` in one of
    /// `dirs`, or null if there is none.
    fn find(q: LibQuery, arena: std.mem.Allocator, io: Io, dirs: []const []const u8) !?[]const u8 {
        const preferred: []const u8 = if (q.search.static) ".a" else ".so";
        const other: []const u8 = if (q.search.static) ".so" else ".a";
        switch (q.search.strategy) {
            .paths_first => for (dirs) |dir| {
                if (try exists(arena, io, dir, q.name, preferred)) |p| return p;
                if (try exists(arena, io, dir, q.name, other)) |p| return p;
            },
            .mode_first, .no_fallback => {
                for (dirs) |dir| if (try exists(arena, io, dir, q.name, preferred)) |p| return p;
                if (q.search.strategy == .mode_first) {
                    for (dirs) |dir| if (try exists(arena, io, dir, q.name, other)) |p| return p;
                }
            },
        }
        return null;
    }

    fn exists(arena: std.mem.Allocator, io: Io, dir: []const u8, name: []const u8, ext: []const u8) !?[]const u8 {
        const path = try std.fmt.allocPrint(arena, "{s}{s}lib{s}{s}", .{ dir, if (dir.len == 0 or dir[dir.len - 1] == '/') "" else "/", name, ext });
        return if (Io.Dir.cwd().access(io, path, .{})) |_| path else |_| null;
    }
};

/// glibc's libraries, which `-l` links as part of libc (upstream's
/// `std.zig.target.isLibCLibName` for glibc).
const glibc_libs: std.StaticStringMap(void) = .initComptime(.{ .{"c"}, .{"m"}, .{"rt"}, .{"pthread"}, .{"util"}, .{"resolv"}, .{"dl"} });
/// The names `-l` takes for libc++ (upstream's `target_util.is_libcpp_lib_name`).
const libcpp_names: std.StaticStringMap(void) = .initComptime(.{ .{"c++"}, .{"stdc++"}, .{"c++abi"}, .{"supc++"} });

pub fn isLibcppLib(name: []const u8) bool {
    return libcpp_names.has(name);
}

pub fn isGlibcLib(name: []const u8) bool {
    return glibc_libs.has(name);
}

/// Upstream's glibc version for `x86_64-linux-gnu` without one.
const default_glibc: std.SemanticVersion = .{ .major = 2, .minor = 31, .patch = 0 };

/// Settles the glibc a `-lc` build links: the target's version, or for the
/// native target the system's, which upstream detects the same way. Other
/// libcs are not supported.
pub fn resolveGlibc(opts: *Options, arena: std.mem.Allocator, io: Io) void {
    if (opts.glibc_version != null) return;
    const target = opts.target orelse "native";
    if (!std.mem.eql(u8, target, "native")) {
        setUnsupported(opts, arena, "zap links only glibc ('-lc' with target '{s}', whose libc is musl or none); pass -target x86_64-linux-gnu or no target", .{target});
        return;
    }
    const native = std.zig.system.resolveTargetQuery(io, .{}) catch |err| {
        setUnsupported(opts, arena, "unable to detect the native libc for -lc: {t}", .{err});
        return;
    };
    if (native.os.tag != .linux or !native.abi.isGnu()) {
        setUnsupported(opts, arena, "zap links only glibc ('-lc'), and this system's libc is not glibc ({t}); pass -target x86_64-linux-gnu", .{native.abi});
        return;
    }
    opts.glibc_version = native.os.version_range.linux.glibc;
}

fn nextTestArg(command: Command, args: []const []const u8, i: *usize, flag: []const u8) []const u8 {
    if (command != .@"test") fatal("{s} is only valid for 'zap test'", .{flag});
    return nextArg(args, i, flag);
}

fn nextArg(args: []const []const u8, i: *usize, flag: []const u8) []const u8 {
    i.* += 1;
    if (i.* >= args.len) fatal("expected parameter after {s}", .{flag});
    return args[i.*];
}

fn fatalUsage() noreturn {
    std.debug.print("{s}", .{usage});
    std.process.exit(1);
}

pub fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ format ++ "\n", args);
    std.process.exit(1);
}

test {
    _ = Frontend;
    _ = @import("cache.zig");
    _ = @import("link/Atom.zig");
    _ = @import("link/Elf.zig");
    _ = @import("link/ElfObject.zig");
    _ = @import("link/Glibc.zig");
    _ = @import("link/ElfInput.zig");
    _ = @import("link/Archive.zig");
    _ = @import("codegen/x86_64/Encoder.zig");
    _ = @import("link/MachO.zig");
    _ = @import("codegen/aarch64/Encoder.zig");
    _ = @import("codegen/Ssa.zig");
    _ = @import("codegen/rewrite.zig");
    _ = @import("codegen/prove.zig");
    _ = @import("InternPool.zig");
    _ = Zcu;
    _ = @import("Sema.zig");
    _ = @import("diag.zig");
    _ = Ir;
    _ = Emit;
}
