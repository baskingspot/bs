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
const Incremental = @import("Incremental.zig");
const Builtin = @import("Builtin.zig");
const Archive = @import("link/Archive.zig");
const Docs = @import("Docs.zig");

pub const zig_version = "0.17.0";

const usage =
    \\Usage: zap [command] [options]
    \\
    \\zap is a fast Debug-mode compiler for Zig 0.17.0.
    \\
    \\Commands:
    \\  build            Build project from build.zig
    \\  build-exe        Create executable from source
    \\  build-obj        Create object from source
    \\  build-lib        Create static library from source
    \\  run              Create executable and run immediately
    \\  test             Perform unit testing
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
    .{ "translate-c", "zap does not translate C ('translate-c', '@cImport'); build this step with upstream zig" },
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
var safe_gpa: std.heap.SafeAllocator = .init(std.heap.smp_allocator, .{});

pub fn main(init_std: std.process.Init) !void {
    var init = init_std;
    if (builtin.mode == .safe and !builtin.link_libc) init.gpa = safe_gpa.allocator();
    // Reports leaks, as std.start does for the allocator it made.
    defer if (builtin.mode == .safe and !builtin.link_libc) {
        _ = safe_gpa.deinit();
    };
    const arena = init.arena.allocator();
    const raw_args = try init.minimal.args.toSlice(arena);
    if (raw_args.len < 2) fatalUsage();
    const cmd = raw_args[1];
    if (std.mem.eql(u8, cmd, "build")) return @import("BuildRunner.zig").run(init, raw_args[2..]);
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

    const opts = try parseOptions(arena, init.io, command, args[2..]);
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
fn cacheTarget(arena: std.mem.Allocator, opts: *const Options) ![]const u8 {
    if (!opts.fuzz) return "x86_64-linux";
    var s: std.ArrayList(u8) = .empty;
    try s.appendSlice(arena, "x86_64-linux+fuzz");
    if (!opts.root_fuzz) try s.appendSlice(arena, "-root");
    for (opts.modules) |m| {
        if (m.fuzz.? != opts.root_fuzz) try s.print(arena, "{c}{s}", .{ @as(u8, if (m.fuzz.?) '+' else '-'), m.name });
    }
    return s.items;
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
        const builtin_dir = try Builtin.writeToCache(arena, init_.io, try std.fs.path.join(arena, &.{ cache_dirs.global, "zap" }), .{
            .output_mode = switch (command) {
                .build_obj => .Obj,
                .build_lib => .Lib,
                else => .Exe,
            },
            .is_test = is_test,
            .single_threaded = opts.single_threaded,
            .unwind_tables = opts.unwind_tables,
            .fuzz = opts.root_fuzz,
            .pic = opts.pic,
            .pie = opts.pie,
            .dynamic = opts.dynamic,
        });
        // An executable that fuzzes links the fuzzer, whose module family
        // has a builtin of its own, as upstream's separate compilation of
        // it (a static library) does. As upstream's, a non-test executable
        // fails to link: only the test runner provides the `runner_*`
        // functions the fuzzer calls back.
        const fuzzer_builtin_dir: ?[]const u8 = if (opts.fuzz and command != .build_obj and command != .build_lib)
            try Builtin.writeToCache(arena, init_.io, try std.fs.path.join(arena, &.{ cache_dirs.global, "zap" }), .{
                .output_mode = .Lib,
                .is_test = false,
                .single_threaded = opts.single_threaded,
                .unwind_tables = opts.unwind_tables,
            })
        else
            null;
        // `--listen=-` does not change what is built, so it is not part
        // of the compilation's key (nor of its output's digest).
        var compile_args: std.ArrayList([]const u8) = .empty;
        for (args[1 .. args.len - opts.run_args.len]) |a| {
            if (!std.mem.eql(u8, a, "--listen=-")) try compile_args.append(arena, a);
        }
        return .{
            .opts = opts,
            .zig_lib_dir = zig_lib_dir,
            .cache_dirs = cache_dirs,
            .builtin_dir = builtin_dir,
            .fuzzer_builtin_dir = fuzzer_builtin_dir,
            .cache_target = try cacheTarget(arena, &opts),
            .compile_args = compile_args.items,
            .stem = opts.name orelse if (is_test) "test" else std.fs.path.stem(opts.root_src_path),
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
        // -fPIE and -dynamic imply -fPIC.
        const use_cache = out_path != null and !job.opts.dump_ir and !job.opts.pic and
            !std.mem.eql(u8, env.get("ZAP_CACHE") orelse "", "off");
        if (!use_cache) return null;
        // A cache that cannot be opened (a full disk, say) costs reuse, not the build.
        var i = Incremental.open(job.gpa, job.io, job.cache_dirs, job.compile_args, job.zig_lib_dir, job.opts.root_name, job.cache_target, env.get("ZAP_CACHE_TIMING") != null) catch |err| {
            std.log.warn("unable to use the cache: {t}", .{err});
            return null;
        };
        i.check = env.get("ZAP_CACHE_CHECK") != null;
        i.donors = !std.mem.eql(u8, env.get("ZAP_CACHE_DONOR") orelse "", "off");
        i.stack_size = job.opts.stack_size;
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
    while (true) return compileReplaying(init, job, inc_opt, out_path, prog, inputs, replay_mode, &pins) catch |err| switch (err) {
        error.LazyFallback => {
            if (inputs) |list| list.shrinkRetainingCapacity(n_inputs);
            replay_mode = "eager";
            continue;
        },
        error.NamesRerun => {
            if (inputs) |list| list.shrinkRetainingCapacity(n_inputs);
            continue;
        },
        else => |e| return e,
    };
}

fn compileReplaying(init: std.process.Init, job: *const Job, inc_opt: ?*Incremental, out_path: ?[]const u8, prog: std.Progress.Node, inputs: ?*std.ArrayList(u8), replay_mode: []const u8, pins: *?*const Zcu.NamePins) !Outcome {
    const arena = init.arena.allocator();
    const opts = job.opts;
    const env = init.environ_map;
    var stages: Stages = .{ .io = init.io, .last = .now(init.io, .awake) };
    stages.on = env.get("ZAP_TIMING") != null;
    if (inc_opt) |i| if (try i.relinkIfUnchanged(Io.Dir.cwd(), out_path.?)) {
        if (inputs) |list| if (i.prev) |*m| for (0..m.inputCount()) |n| {
            _, const path = m.input(@intCast(n));
            try appendInput(arena, list, path);
        };
        return .{ .ok = .{ .cache_hit = true } };
    };

    const is_test = opts.command == .@"test";
    const test_runner = opts.test_runner orelse try std.fs.path.join(arena, &.{ job.zig_lib_dir, "compiler", "test_runner.zig" });
    const fe_node = prog.start("Load Sources", 0);
    var fe: Frontend = try .init(init.gpa, init.io, job.zig_lib_dir, .{
        .root_src_path = if (is_test) test_runner else opts.root_src_path,
        .builtin_dir = job.builtin_dir,
        .main_src_path = if (is_test) opts.root_src_path else null,
        .root_name = opts.root_name,
        .root_deps = opts.root_deps,
        .modules = opts.modules,
        .fuzz = opts.root_fuzz,
        .fuzzer_builtin_dir = job.fuzzer_builtin_dir,
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
    if (bundle.errorMessageCount() > 0) {
        var diags: std.ArrayList(diag.Diagnostic) = .empty;
        try diag.fromBundle(arena, paths, bundle, &diags);
        return .{ .errors = try dupeDiagnostics(arena, diags.items) };
    }
    std.debug.assert(ok);

    var zcu: Zcu = try .init(init.gpa, init.io, &fe);
    defer zcu.deinit();
    defer if (inputs) |list| for (zcu.embed_files.values()) |f| {
        Incremental.inputPath(arena, &path_buf, &fe, f.module, f.sub_path) catch {};
        appendInput(arena, list, path_buf.items) catch {};
    };
    zcu.is_test = is_test;
    zcu.name_pins = pins.*;
    zcu.single_threaded = opts.single_threaded;
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
        if (zcu.errors.items.len != 0) return .{ .errors = try dupeDiagnostics(arena, try zcu.diagnostics(arena, paths)) };
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
    // `ZAP_BENCH_CODEGEN=n`: time the backend over this build's functions
    // n more times (`zig build bench-codegen`).
    const bench_runs: u32 = if (env.get("ZAP_BENCH_CODEGEN")) |v| std.fmt.parseInt(u32, v, 10) catch 0 else 0;
    if (bench_runs != 0) emit.bench_irs = .empty;
    // `ZAP_THREADS=n`: analysis and CodeGen on n threads, Sema on one and
    // CodeGen on the others; 1 generates on the Sema thread. The output
    // is the same for every n.
    const threads: usize = if (env.get("ZAP_THREADS")) |v| std.fmt.parseInt(usize, v, 10) catch 1 else std.Thread.getCpuCount() catch 1;
    // `ZAP_SCHED_FUZZ=<seed>`: perturb the workers' timing (`Emit.Pool.fuzz`).
    const fuzz: ?u64 = if (env.get("ZAP_SCHED_FUZZ")) |v| std.fmt.parseInt(u64, v, 10) catch 1 else null;
    try emit.startPool(@max(threads, 1) - 1, fuzz);
    const sema_node = prog.start("Analyze and Generate Code", 0);
    if (inc_opt) |i| try i.beginReplay(&fe, &zcu, &emit, replay_mode);
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
    if (zcu.errors.items.len != 0) return .{ .errors = try dupeDiagnostics(arena, try zcu.diagnostics(arena, paths)) };
    const bin_path = out_path orelse return .{ .ok = .{ .cache_hit = false } };
    const link_node = prog.start("Link", 0);
    defer link_node.end();
    const ready = try emit.finish();
    stages.mark("emit");
    if (zcu.errors.items.len != 0) return .{ .errors = try dupeDiagnostics(arena, try zcu.diagnostics(arena, paths)) };
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
        const member = try std.fmt.allocPrint(arena, "{s}.o", .{std.fs.path.stem(opts.root_src_path)});
        Archive.write(init.gpa, init.io, Io.Dir.cwd(), bin_path, member, obj) catch |err| {
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
        .link_mode = .static,
        .link_libc = false,
        .link_libcpp = false,
        .link_libunwind = false,
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
                    try serveErrors(&server, init.gpa, &.{.{ .code = .unsupported, .loc = null, .msg = opts.unsupported.? }}, null);
                    continue;
                };
                var inputs: std.ArrayList(u8) = .empty;
                var inc = j.openCache(out_path);
                defer if (inc) |*i| i.close();
                const outcome = try compile(init, j, if (inc) |*i| i else null, out_path, root_node, &inputs);
                if (inputs.items.len != 0) {
                    const prefixed = try prefixInputs(arena, io, inputs.items, j);
                    try server.serveStringMessage(.file_system_inputs, prefixed);
                }
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

fn serveErrors(server: *std.zig.Server, gpa: std.mem.Allocator, diags: []const diag.Diagnostic, ref_limit: ?u32) !void {
    var wip: std.zig.ErrorBundle.Wip = try .init(gpa);
    defer wip.deinit();
    try diag.toBundle(&wip, diags, ref_limit);
    var bundle = try wip.toOwnedBundle("");
    defer bundle.deinit(gpa);
    try server.serveErrorBundle(.error_bundle, bundle);
}

/// The `file_system_inputs` message body: each absolute path relative to
/// the first of the build runner's cache prefixes that contains it (zig
/// lib, local cache, global cache, build root; else the working
/// directory), as one prefix byte (`PathPrefix` + 1) and the sub path,
/// separated by zero bytes.
fn prefixInputs(arena: std.mem.Allocator, io: Io, inputs: []const u8, job: *const Job) ![]const u8 {
    const cwd = try std.process.currentPathAlloc(io, arena);
    const Prefix = std.zig.Server.Message.PathPrefix;
    const Root = struct { prefix: Prefix, path: []const u8 };
    var roots: std.ArrayList(Root) = .empty;
    try roots.append(arena, .{ .prefix = .zig_lib, .path = try std.fs.path.resolve(arena, &.{ cwd, job.zig_lib_dir }) });
    try roots.append(arena, .{ .prefix = .local_cache, .path = try std.fs.path.resolve(arena, &.{ cwd, job.cache_dirs.local }) });
    try roots.append(arena, .{ .prefix = .global_cache, .path = try std.fs.path.resolve(arena, &.{ cwd, job.cache_dirs.global }) });
    if (job.opts.build_root) |br| try roots.append(arena, .{ .prefix = .build_root, .path = try std.fs.path.resolve(arena, &.{ cwd, br }) });
    try roots.append(arena, .{ .prefix = .cwd, .path = cwd });
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, inputs, 0);
    while (it.next()) |raw| {
        const abs = try std.fs.path.resolve(arena, &.{ cwd, raw });
        if (out.items.len != 0) try out.append(arena, 0);
        for (roots.items) |r| {
            if (abs.len > r.path.len and std.mem.startsWith(u8, abs, r.path) and abs[r.path.len] == '/') {
                try out.append(arena, @backingInt(r.prefix) + 1);
                try out.appendSlice(arena, abs[r.path.len + 1 ..]);
                break;
            }
        } else {
            try out.append(arena, @backingInt(Prefix.cwd) + 1);
            try out.appendSlice(arena, abs);
        }
    }
    return out.items;
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
    .{"-fno-omit-frame-pointer"},          .{"-ferror-tracing"},           .{"-fno-sanitize-thread"},
    .{"-fvalgrind"},                       .{"-fno-PIC"},                  .{"-fno-PIE"},              .{"-fbuiltin"},
    .{"-fno-builtin"},                     .{"-mred-zone"},                .{"-mno-red-zone"},         .{"-fno-sanitize-c"},
    .{"-fsanitize-c=trap"},                .{"-fsanitize-c=full"},         .{"-fsanitize-c"},          .{"-gdwarf32"},
    .{"-gdwarf64"},                        .{"-ODebug"},                   .{"-Odebug"},
    .{"-static"},                          .{"--no-dynamic-linker"},       .{"--debug-compile-errors"}, .{"--debug-incremental"},
    .{"--verbose-air"},                    .{"--verbose-llvm-ir"},         .{"--verbose-link"},        .{"--verbose-cc"},
    .{"--verbose-llvm-cpu-features"},      .{"--time-report"},             .{"-fformatted-panics"},    .{"-fno-formatted-panics"},
    .{"--eh-frame-hdr"},                   .{"--emit-relocs"},             .{"-ffunction-sections"},   .{"-fdata-sections"},
    .{"--gc-sections"},                    .{"--no-gc-sections"},          .{"--no-dynamicbase"},      .{"-fallow-shlib-undefined"},
    .{"-fno-allow-shlib-undefined"},       .{"-headerpad_max_install_names"}, .{"-dead_strip_dylibs"}, .{"-ObjC"},
    .{"--discard-all"},                    .{"-fcompiler-rt"},             .{"-fno-compiler-rt"},      .{"-fubsan-rt"},
    .{"-fno-ubsan-rt"},                    .{"-fdll-export-fns"},          .{"-fno-dll-export-fns"},   .{"-rdynamic"},
    .{"--undefined-version"},              .{"--no-undefined-version"},    .{"--enable-new-dtags"},    .{"--disable-new-dtags"},
    .{"-feach-lib-rpath"},                 .{"-fno-each-lib-rpath"},       .{"-fno-lto"},              .{"-fno-sanitize-coverage-trace-pc-guard"},
    .{"-fincremental"},                    .{"-fno-incremental"},          .{"--debug-rt"},            .{"-femit-bin"},
    .{"-search_paths_first"},              .{"-search_paths_first_static"}, .{"-search_dylibs_first"}, .{"-search_static_first"},
    .{"-search_dylibs_only"},              .{"-search_static_only"},       .{"--compress-debug-sections=none"},
});

/// Ignored options that take a parameter.
const ignored_flags_with_arg: std.StaticStringMap(void) = .initComptime(.{
    .{"-I"},        .{"-isystem"},      .{"-iquote"},  .{"-idirafter"},   .{"-iframework"}, .{"-iframeworkwithsysroot"},
    .{"-L"},        .{"-rpath"},        .{"--libc"},   .{"--sysroot"},    .{"--error-limit"}, .{"--debug-log"},
    .{"--dynamic-linker"}, .{"-z"},     .{"--image-base"},
});

/// Options that ask for something zap does not do, as the diagnostic's
/// message.
const unsupported_flags: std.StaticStringMap([]const u8) = .initComptime(.{
    .{ "-fno-entry", "zap does not build executables without an entry point yet ('-fno-entry')" },
    .{ "-fstrip", "zap does not strip debug info yet ('-fstrip'); remove '.strip = true'" },
    .{ "-fomit-frame-pointer", "zap always keeps frame pointers ('-fomit-frame-pointer'); remove '.omit_frame_pointer = true'" },
    .{ "-fno-error-tracing", "zap always has error return traces ('-fno-error-tracing'); remove '.error_tracing = false'" },
    .{ "-fsanitize-thread", "zap has no ThreadSanitizer ('-fsanitize-thread'); build this step with upstream zig" },
    .{ "-fno-valgrind", "zap always emits Valgrind client requests ('-fno-valgrind'); remove '.valgrind = false'" },
    .{ "-femit-asm", "zap does not emit assembly ('-femit-asm')" },
    .{ "-femit-implib", "zap does not emit import libraries ('-femit-implib')" },
    .{ "-femit-llvm-bc", "zap has no LLVM backend ('-femit-llvm-bc')" },
    .{ "-femit-llvm-ir", "zap has no LLVM backend ('-femit-llvm-ir')" },
    .{ "-femit-h", "zap does not emit C headers ('-femit-h')" },
    .{ "-fsanitize-coverage-trace-pc-guard", "zap does not instrument coverage ('-fsanitize-coverage-trace-pc-guard')" },
    .{ "-cflags", "zap does not compile C sources ('-cflags'); build this step with upstream zig" },
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

fn setUnsupported(opts: *Options, arena: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    if (opts.unsupported == null) opts.unsupported = std.fmt.allocPrint(arena, fmt, args) catch fatal("out of memory", .{});
}

pub fn parseOptions(arena: std.mem.Allocator, io: Io, command: Command, args_in: []const []const u8) !Options {
    var args = args_in;
    var root: ?[]const u8 = null;
    var positional_root = false;
    var opts: Options = .{ .command = command, .root_src_path = undefined };
    var test_filters: std.ArrayList([]const u8) = .empty;
    var deps: std.ArrayList([]const u8) = .empty;
    var modules: std.ArrayList(Frontend.ModuleArg) = .empty;
    // `-ffuzz` and `-fno-fuzz` are per module, as upstream's: each `-M`
    // takes the last one before it; a root file given by position takes
    // the last one left.
    var fuzz: ?bool = null;
    var root_fuzz: ?bool = null;
    var i: usize = 0;
    while (i < args.len) : (i +%= 1) {
        const arg = args[i];
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
            // On an executable, a preference that changes nothing a program
            // means, as with -fllvm: zap links it static and non-PIE, and
            // `builtin.position_independent_*` stay false. Objects and
            // libraries get position-independent code, as upstream's.
            if (command == .build_obj or command == .build_lib) {
                opts.pic = true;
                if (std.mem.eql(u8, arg, "-fPIE") and command == .build_obj) opts.pie = true;
            }
        } else if (std.mem.eql(u8, arg, "-dynamic")) {
            // Shared objects, which are position-independent; executables
            // stay static.
            if (command == .build_lib) {
                opts.dynamic = true;
                opts.pic = true;
            } else setUnsupported(&opts, arena, "zap links executables statically ('-dynamic'); build this step with upstream zig", .{});
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
            const eq = std.mem.indexOfScalar(u8, spec, '=') orelse {
                // A module without a root source file holds C sources or
                // link objects.
                setUnsupported(&opts, arena, "zap does not build modules without a Zig root source file ('{s}'); build this step with upstream zig", .{arg});
                continue;
            };
            if (root == null) {
                root = spec[eq + 1 ..];
                opts.root_name = spec[0..eq];
                opts.root_deps = try deps.toOwnedSlice(arena);
                root_fuzz = fuzz;
            } else try modules.append(arena, .{ .name = spec[0..eq], .path = spec[eq + 1 ..], .deps = try deps.toOwnedSlice(arena), .fuzz = fuzz });
            fuzz = null;
        } else if (std.mem.startsWith(u8, arg, "--error-format=")) {
            const v = arg["--error-format=".len..];
            opts.error_format = std.meta.stringToEnum(diag.Format, v) orelse fatal("invalid --error-format '{s}': expected 'text' or 'json'", .{v});
        } else if (std.mem.eql(u8, arg, "--debug-dump-ir")) {
            opts.dump_ir = true;
        } else if (std.mem.eql(u8, arg, "--stack")) {
            const v = nextArg(args, &i, arg);
            opts.stack_size = std.fmt.parseUnsigned(u64, v, 0) catch fatal("invalid stack size: '{s}'", .{v});
        } else if (ignored_flags.has(arg)) {
            // Changes nothing zap does.
        } else if (ignored_flags_with_arg.has(arg)) {
            _ = nextArg(args, &i, arg);
        } else if (std.mem.startsWith(u8, arg, "-D") or std.mem.startsWith(u8, arg, "--build-id")) {
            // A C macro; the build ID of a linked binary.
        } else if (std.mem.startsWith(u8, arg, "-ofmt=")) {
            if (!std.mem.eql(u8, arg, "-ofmt=elf")) setUnsupported(&opts, arena, "zap emits ELF on Linux only ('{s}')", .{arg});
        } else if (std.mem.startsWith(u8, arg, "-O")) {
            setUnsupported(&opts, arena, "zap builds only Debug ('{s}'); drop the release mode (-Doptimize, --release) or build this step with upstream zig", .{arg});
        } else if (std.mem.eql(u8, arg, "-lc") or std.mem.eql(u8, arg, "-lc++") or std.mem.startsWith(u8, arg, "-l") or
            std.mem.startsWith(u8, arg, "-needed-l") or std.mem.startsWith(u8, arg, "-weak-l"))
        {
            setUnsupported(&opts, arena, "zap does not link libc or system libraries ('{s}'); build this step with upstream zig", .{arg});
        } else if (unsupported_flags.get(arg)) |msg| {
            setUnsupported(&opts, arena, "{s}", .{msg});
            // Their parameters: the C flags up to `--`, the language.
            if (std.mem.eql(u8, arg, "-cflags") or std.mem.eql(u8, arg, "-rcflags")) {
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
            if (std.mem.eql(u8, ext, ".o") or std.mem.eql(u8, ext, ".a") or std.mem.eql(u8, ext, ".so") or std.mem.indexOf(u8, arg, ".so.") != null or std.mem.eql(u8, ext, ".obj") or std.mem.eql(u8, ext, ".lib"))
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
    opts.root_src_path = root orelse if (opts.unsupported != null) "" else fatal("expected a root source file", .{});
    opts.test_filters = test_filters.items;
    opts.modules = modules.items;
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
    opts.root_fuzz = root_fuzz orelse fuzz orelse false;
    const seen = try arena.alloc(bool, modules.items.len);
    @memset(seen, false);
    inheritFuzz(modules.items, seen, opts.root_deps, opts.root_fuzz);
    for (modules.items) |*m| {
        if (m.fuzz == null) m.fuzz = opts.root_fuzz; // no module depends on it
    }
    opts.fuzz = opts.root_fuzz or for (modules.items) |m| {
        if (m.fuzz.?) break true;
    } else false;
    return opts;
}

/// `-ffuzz` per module, as upstream's `Module.create`: a module without
/// its own flag takes that of the module that first depends on it, depth
/// first from the root module, whose `deps` and flag are given. `seen`
/// has a slot per module.
fn inheritFuzz(modules: []Frontend.ModuleArg, seen: []bool, deps: []const []const u8, parent: bool) void {
    for (deps) |spec| {
        const name = if (std.mem.indexOfScalar(u8, spec, '=')) |e| spec[e + 1 ..] else spec;
        for (modules, seen) |*m, *s| {
            if (!std.mem.eql(u8, m.name, name)) continue;
            if (s.*) break;
            s.* = true;
            m.fuzz = m.fuzz orelse parent;
            inheritFuzz(modules, seen, m.deps, m.fuzz.?);
            break;
        }
    }
}

/// Only the x86_64-linux backend exists so far; refuses aarch64-macos
/// rather than silently writing an x86_64 ELF.
fn checkTarget(opts: *Options, arena: std.mem.Allocator, target: []const u8) void {
    const native_ok = builtin.cpu.arch == .x86_64 and builtin.os.tag == .linux;
    if (std.mem.eql(u8, target, "x86_64-linux") or std.mem.eql(u8, target, "x86_64-linux-none") or
        (std.mem.eql(u8, target, "native") and native_ok))
    {} else if (std.mem.eql(u8, target, "aarch64-macos") or std.mem.eql(u8, target, "aarch64-macos-none") or
        std.mem.eql(u8, target, "native"))
    {
        setUnsupported(opts, arena, "zap does not implement aarch64-macos code generation yet ('{s}'); pass -target x86_64-linux", .{target});
    } else setUnsupported(opts, arena, "zap does not support the target '{s}'; it supports x86_64-linux and aarch64-macos", .{target});
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
    _ = @import("codegen/x86_64/Encoder.zig");
    _ = @import("link/MachO.zig");
    _ = @import("codegen/aarch64/Encoder.zig");
    _ = @import("codegen/Ssa.zig");
    _ = @import("InternPool.zig");
    _ = Zcu;
    _ = @import("Sema.zig");
    _ = @import("diag.zig");
    _ = Ir;
    _ = Emit;
}
