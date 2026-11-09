//! `bs build` of a Zig 0.16 project. Zig 0.16 keeps in the compiler what
//! 0.17 moved into its build runner (BuildRunner.zig compiles 0.17's), so
//! this is upstream 0.16's `cmdBuild` (its src/main.zig), ported:
//!
//! 1. fetch the packages, with upstream 0.17.1's fetcher (build.zig's
//!    `fetchModule`): the package format, hashes and `zig-pkg` directory
//!    did not change, and its generated `dependencies.zig` is 0.16's;
//! 2. compile 0.16's `lib/compiler/build_runner.zig` in Zig 0.16, with the
//!    project's build.zig as `@build`, `dependencies.zig` as
//!    `@dependencies`, and each package's build.zig as a module of its own;
//! 3. run it, and fetch and run it again while it exits for lazy packages
//!    that are not fetched yet (exit code 3, their hashes in `tmp/<nonce>`
//!    of the local cache).
//!
//! The runner compiles each step by running bs with `--listen=-`
//! (`main.serve`, which speaks 0.16's protocol to it), in Zig 0.16
//! through `BS_ZIG_VERSION`, which 0.16's std.Build does not know to pass.
//! The runner's web UI (`--webui`, `--fuzz`, `--time-report`) is
//! 0.16's, which bs does not serve.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Cache = std.Build.Cache;
const main = @import("main.zig");
const Frontend = @import("Frontend.zig");
const BuildRunner = @import("BuildRunner.zig");
const toolchain = @import("toolchain.zig");
const language = @import("language.zig");
const cache = @import("cache.zig");
const maker = @import("fetch");
const Package = maker.Package;
const Fetch = Package.Fetch;
const CliModule = maker.CliModule;

pub fn run(init: std.process.Init, args: []const []const u8, choice: language.Choice) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const env = init.environ_map;

    var build_file: ?[]const u8 = null;
    var lib_override: ?[]const u8 = null;
    var global_override: ?[]const u8 = null;
    var local_override: ?[]const u8 = std.zig.EnvVar.ZIG_LOCAL_CACHE_DIR.get(env);
    var runner_override: ?[]const u8 = env.get("ZIG_BUILD_RUNNER");
    var fork_paths: std.ArrayList([]const u8) = .empty;
    var reference_trace: ?u32 = null;
    var debug_compile_errors = false;
    var fetch_only = false;
    var fetch_mode: Fetch.JobQueue.Mode = .needed;
    var system_pkg_dir: ?[]const u8 = null;
    var color: std.zig.Color = .auto;
    var seed: []const u8 = undefined;
    {
        var seed_bytes: [4]u8 = undefined;
        io.random(&seed_bytes);
        seed = try arena.print("0x{x}", .{std.mem.readInt(u32, &seed_bytes, .little)});
    }
    var nonce_bytes: [8]u8 = undefined;
    io.random(&nonce_bytes);
    const nonce = std.fmt.bytesToHex(nonce_bytes, .lower);

    // The runner's own arguments, as 0.16's compiler passes them on: all
    // but those it takes for itself.
    var child_args: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            try child_args.appendSlice(arena, args[i..]);
            break;
        }
        if (std.mem.startsWith(u8, arg, "-")) {
            if (takesValue(arg)) |taken| {
                if (i + 1 >= args.len) main.fatal("expected argument after '{s}'", .{arg});
                i += 1;
                const value = args[i];
                switch (taken) {
                    .build_file => build_file = value,
                    .zig_lib_dir => lib_override = value,
                    .build_runner => runner_override = value,
                    .cache_dir => local_override = value,
                    .global_cache_dir => global_override = value,
                    .system => {
                        system_pkg_dir = value;
                        try child_args.append(arena, "--system");
                    },
                    .seed => seed = value,
                    .debug_log, .color => {
                        if (taken == .color) color = std.meta.stringToEnum(std.zig.Color, value) orelse
                            main.fatal("expected [auto|on|off] after {s}, found '{s}'", .{ arg, value });
                        try child_args.appendSlice(arena, &.{ arg, value });
                    },
                }
                continue;
            }
            if (std.mem.startsWith(u8, arg, "--fork=")) {
                try fork_paths.append(arena, arg["--fork=".len..]);
                continue;
            }
            if (std.mem.eql(u8, arg, "--webui") or std.mem.startsWith(u8, arg, "--webui=") or
                std.mem.eql(u8, arg, "--fuzz") or std.mem.eql(u8, arg, "--time-report"))
            {
                main.fatal("'{s}' starts Zig 0.16's build web UI, which bs does not serve; build this Zig 0.16 project with upstream zig 0.16.0 for it", .{arg});
            }
            if (std.mem.eql(u8, arg, "-freference-trace")) {
                reference_trace = 256;
            } else if (std.mem.startsWith(u8, arg, "-freference-trace=")) {
                const n = arg["-freference-trace=".len..];
                reference_trace = std.fmt.parseUnsigned(u32, n, 10) catch
                    main.fatal("unable to parse reference_trace count '{s}'", .{n});
            } else if (std.mem.eql(u8, arg, "-fno-reference-trace")) {
                reference_trace = null;
            } else if (std.mem.eql(u8, arg, "--debug-compile-errors")) {
                debug_compile_errors = true;
            } else if (std.mem.eql(u8, arg, "--fetch")) {
                fetch_only = true;
            } else if (std.mem.startsWith(u8, arg, "--fetch=")) {
                fetch_only = true;
                fetch_mode = std.meta.stringToEnum(Fetch.JobQueue.Mode, arg["--fetch=".len..]) orelse
                    main.fatal("expected [needed|all] after '--fetch=', found '{s}'", .{arg["--fetch=".len..]});
            }
        }
        try child_args.append(arena, arg);
    }

    const cwd = try std.process.currentPathAlloc(io, arena);
    const build_root = try findBuildRoot(arena, io, cwd, build_file);
    const dirs = Frontend.resolveCacheDirs(arena, io, env, .{ .global = global_override, .local_is_global = true });
    const global = try Io.Dir.path.resolveAlloc(arena, &.{ cwd, dirs.global });
    const local = try Io.Dir.path.resolveAlloc(arena, &.{ cwd, local_override orelse try Io.Dir.path.join(arena, &.{ build_root, ".zig-cache" }) });
    const lib = try Io.Dir.path.resolveAlloc(arena, &.{ cwd, (try toolchain.libDir(arena, io, env, global, lib_override, choice.language)).path });
    // Every compilation the runner asks bs for is in the root package's
    // language, which 0.16's std.Build does not pass on.
    try env.put("BS_ZIG_VERSION", choice.language.name());

    var forks: std.ArrayList(Fetch.JobQueue.Fork) = .empty;
    for (fork_paths.items) |p| try forks.append(arena, try loadFork(arena, io, p, color));

    const runner_root = if (runner_override) |r| try Io.Dir.path.resolveAlloc(arena, &.{ cwd, r }) else try Io.Dir.path.join(arena, &.{ lib, "compiler", "build_runner.zig" });
    const self_exe = try std.process.executablePathAlloc(io, arena);

    // One display for the whole command, as upstream's: a process starts
    // std.Progress once, and a lazy fetch compiles the runner again.
    const prog = std.Progress.start(io, .{ .disable_printing = color == .off, .root_name = "Compile Build Script" });
    defer prog.end();

    var unlazy_set: Fetch.JobQueue.UnlazySet = .{};
    while (true) {
        const modules = try fetchPackages(init, .{
            .build_root = build_root,
            .build_zig_basename = if (build_file) |bf| Io.Dir.path.basename(bf) else std.zig.build_zig_basename,
            .local = local,
            .global = global,
            .system_pkg_dir = system_pkg_dir,
            .mode = fetch_mode,
            .unlazy_set = unlazy_set,
            .forks = forks.items,
            .color = color,
            .prog = prog,
        });
        if (fetch_only) std.process.exit(0);

        var compile_args: std.ArrayList([]const u8) = .empty;
        try compile_args.appendSlice(arena, &.{
            "bs",                 "build-exe",
            "--name",             "build",
            "--zig-lib-dir",      lib,
            "--cache-dir",        local,
            "--global-cache-dir", global,
        });
        if (reference_trace) |n| try compile_args.append(arena, try arena.print("-freference-trace={d}", .{n}));
        if (debug_compile_errors) try compile_args.append(arena, "--debug-compile-errors");
        try compile_args.appendSlice(arena, &.{ "--dep", "@build", "--dep", "@dependencies", try arena.print("-Mroot={s}", .{runner_root}) });
        try compile_args.appendSlice(arena, modules);
        // One runner per build file and set of packages, as upstream's
        // `o/<digest>`: zls's tests build several build files of one
        // directory at once.
        const runner_dir = try arena.print("{s}/bs/build-runner/{x:0>32}", .{ local, cache.hash(0, try std.mem.join(arena, "\x00", compile_args.items)) });
        try Io.Dir.cwd().createDirPath(io, runner_dir);
        const runner_path = try Io.Dir.path.join(arena, &.{ runner_dir, "build" });
        // Said for the build.zig.zon that chose, not for the BS_ZIG_VERSION
        // that bs set from it.
        main.checkSupported(init.environ_map, choice);
        try BuildRunner.compileTool(init, runner_dir, compile_args.items, prog, "build runner", runner_root, null);

        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &.{ runner_path, self_exe, lib, build_root, local, global, "--seed", seed, try arena.print("-Z{s}", .{&nonce}) });
        try argv.appendSlice(arena, child_args.items);
        if (env.get("ZIG_VERBOSE_CMD") != null) std.log.info("{f}", .{std.zig.SubprocessCommand{ .argv = argv.items }});
        const term = term: {
            // The runner draws its own progress meanwhile.
            _ = try io.lockStderr(&.{}, .no_color);
            defer io.unlockStderr();
            var child = std.process.spawn(io, .{ .argv = argv.items, .environ_map = env }) catch |err|
                main.fatal("failed to spawn build runner {s}: {t}", .{ runner_path, err });
            defer child.kill(io);
            break :term child.wait(io) catch |err| main.fatal("failed to wait build runner {s}: {t}", .{ runner_path, err });
        };
        const cmd = try std.mem.join(arena, " ", argv.items);
        switch (term) {
            .exited => |code| switch (code) {
                0 => return,
                // The runner reported compile errors itself.
                2 => std.process.exit(2),
                // The configure phase needs lazy packages that are not
                // fetched yet, whose hashes it wrote to `tmp/<nonce>`.
                3 => {
                    const tmp_sub_path = try Io.Dir.path.join(arena, &.{ "tmp", &nonce });
                    var local_dir = try Io.Dir.cwd().openDir(io, local, .{});
                    defer local_dir.close(io);
                    const hashes = local_dir.readFileAlloc(io, tmp_sub_path, arena, .limited(50 * 1024 * 1024)) catch |err|
                        main.fatal("unable to read results of configure phase from '{s}/{s}': {t}", .{ local, tmp_sub_path, err });
                    local_dir.deleteFile(io, tmp_sub_path) catch {}; // ziglint-ignore: Z026 -- a leftover temporary file is harmless
                    var it = std.mem.splitScalar(u8, hashes, '\n');
                    var any_errors = false;
                    while (it.next()) |hash| {
                        if (hash.len == 0) continue;
                        if (hash.len > Package.Hash.max_len) {
                            std.log.err("invalid digest (length {d} exceeds maximum): '{s}'", .{ hash.len, hash });
                            any_errors = true;
                            continue;
                        }
                        try unlazy_set.put(arena, .fromSlice(hash), {});
                    }
                    if (any_errors) std.process.exit(3);
                    if (system_pkg_dir) |p| {
                        // The system provides the packages; bs fetches none.
                        for (unlazy_set.keys()) |*hash| std.log.err("lazy dependency package not found: {s}" ++ Io.Dir.path.sep_str ++ "{s}", .{ p, hash.toSlice() });
                        std.log.info("remote package fetching disabled due to --system mode", .{});
                        std.log.info("dependencies might be avoidable depending on build configuration", .{});
                        std.process.exit(3);
                    }
                    continue;
                },
                else => main.fatal("the following build command failed with exit code {d}:\n{s}", .{ code, cmd }),
            },
            .signal => |sig| main.fatal("the following build command terminated with signal {t}:\n{s}", .{ sig, cmd }),
            .stopped => |sig| main.fatal("the following build command stopped with signal {t}:\n{s}", .{ sig, cmd }),
            .unknown => main.fatal("the following build command crashed:\n{s}", .{cmd}),
        }
    }
}

/// The options of 0.16's `zig build` that take a value.
const Taken = enum { build_file, zig_lib_dir, build_runner, cache_dir, global_cache_dir, system, seed, debug_log, color };

fn takesValue(arg: []const u8) ?Taken {
    const map: std.StaticStringMap(Taken) = .initComptime(.{
        .{ "--build-file", .build_file },
        .{ "--zig-lib-dir", .zig_lib_dir },
        .{ "--build-runner", .build_runner },
        .{ "--cache-dir", .cache_dir },
        .{ "--global-cache-dir", .global_cache_dir },
        .{ "--system", .system },
        .{ "--seed", .seed },
        .{ "--debug-log", .debug_log },
        .{ "--color", .color },
    });
    return map.get(arg);
}

/// The directory of `build_file`, else the nearest one up from `cwd` that
/// has a build.zig, as 0.16's `findBuildRoot`.
fn findBuildRoot(arena: Allocator, io: Io, cwd: []const u8, build_file: ?[]const u8) ![]const u8 {
    if (build_file) |bf| {
        const abs = try Io.Dir.path.resolveAlloc(arena, &.{ cwd, bf });
        Io.Dir.cwd().access(io, abs, .{}) catch |err| main.fatal("unable to access build file '{s}': {t}", .{ bf, err });
        return Io.Dir.path.dirname(abs).?;
    }
    var dir = cwd;
    while (true) {
        if (Io.Dir.cwd().access(io, try Io.Dir.path.join(arena, &.{ dir, std.zig.build_zig_basename }), .{})) |_| return dir else |_| {}
        dir = Io.Dir.path.dirname(dir) orelse main.fatal("no build.zig file found, in the current directory or any parent directories", .{});
    }
}

fn loadFork(arena: Allocator, io: Io, cwd_relative_path: []const u8, color: std.zig.Color) !Fetch.JobQueue.Fork {
    const path: Cache.Path = .{ .root_dir = .cwd(), .sub_path = cwd_relative_path };
    var fork: Fetch.JobQueue.Fork = .{ .path = path, .manifest_ast = undefined, .manifest = undefined, .uses = 0 };
    var error_bundle: std.zig.ErrorBundle.Wip = try .init(arena);
    const manifest_path = try path.join(arena, Package.Manifest.basename);
    Package.Manifest.load(io, arena, manifest_path, &fork.manifest_ast, &error_bundle, &fork.manifest, true) catch |err| switch (err) {
        error.ErrorsBundled => {
            var errors = try error_bundle.toOwnedBundle("");
            errors.renderToStderr(io, .{}, color) catch {}; // ziglint-ignore: Z026 -- stderr is where it would be reported
            std.process.exit(1);
        },
        else => |e| main.fatal("failed to load package manifest {f}: {t}", .{ manifest_path, e }),
    };
    return fork;
}

const FetchOptions = struct {
    build_root: []const u8,
    /// `--build-file`'s, else build.zig: the `@build` module's root.
    build_zig_basename: []const u8,
    local: []const u8,
    global: []const u8,
    system_pkg_dir: ?[]const u8,
    mode: Fetch.JobQueue.Mode,
    unlazy_set: Fetch.JobQueue.UnlazySet,
    forks: []Fetch.JobQueue.Fork,
    color: std.zig.Color,
    prog: std.Progress.Node,
};

/// Fetches the root package's dependencies, as 0.16's `cmdBuild` (and
/// 0.17's `Maker.configure`), writes `dependencies.zig`, and returns the
/// `--dep` and `-M` arguments of the runner's `@build` and
/// `@dependencies` modules and of each package's build.zig. Exits on a
/// fetch error, which it reports.
fn fetchPackages(init: std.process.Init, o: FetchOptions) ![]const []const u8 {
    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const io = init.io;
    const prog = o.prog.start("Fetch Packages", 0);
    defer prog.end();

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    if (o.system_pkg_dir == null) try http_client.initDefaultProxies(arena, init.environ_map);

    const build_root_dir: Cache.Directory = .{ .path = o.build_root, .handle = try Io.Dir.cwd().openDir(io, o.build_root, .{}) };
    const local_dir: Cache.Directory = .{ .path = o.local, .handle = try Io.Dir.cwd().createDirPathOpen(io, o.local, .{}) };
    const global_dir: Cache.Directory = .{ .path = o.global, .handle = try Io.Dir.cwd().createDirPathOpen(io, o.global, .{}) };
    const local_storage: Fetch.LocalStorage = .{
        .cache_root = .{ .root_dir = local_dir },
        .pkg_root = if (o.system_pkg_dir) |p| .initCwd(p) else .{ .root_dir = build_root_dir, .sub_path = "zig-pkg" },
    };

    var fork_set: Fetch.JobQueue.ForkSet = .{};
    for (o.forks) |f| try fork_set.put(arena, f, {});
    var job_queue: Fetch.JobQueue = .{
        .io = io,
        .http_client = &http_client,
        .global_cache = global_dir,
        .local_storage = &local_storage,
        .recursive = true,
        .debug_hash = false,
        .unlazy_set = o.unlazy_set,
        .fork_set = fork_set,
        .mode = o.mode,
        .prog_node = prog,
        .read_only = o.system_pkg_dir != null,
    };
    defer job_queue.deinit();
    try job_queue.all_fetches.ensureUnusedCapacity(gpa, 1);
    try job_queue.table.ensureUnusedCapacity(gpa, 1);

    const build_mod = try arena.create(CliModule);
    build_mod.* = .{ .name = "@build", .root_path = try Io.Dir.path.join(arena, &.{ o.build_root, o.build_zig_basename }) };
    const phantom_package_root: Cache.Path = .{ .root_dir = build_root_dir };
    var fetch: Fetch = .{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .location = .{ .relative_path = phantom_package_root },
        .location_tok = 0,
        .hash_tok = .none,
        .name_tok = 0,
        .lazy_status = .eager,
        .remote_package_root = phantom_package_root,
        .parent_package_root = phantom_package_root,
        .parent_manifest_ast = null,
        .prog_node = prog,
        .job_queue = &job_queue,
        .omit_missing_hash_error = true,
        .allow_missing_paths_field = false,
        .use_latest_commit = false,

        .package_root = undefined,
        .error_bundle = undefined,
        .manifest = undefined,
        .manifest_ast = undefined,
        .have_manifest = false,
        .computed_hash = undefined,
        .has_build_zig = true,
        .oom_flag = false,
        .latest_commit = null,

        .cli_module = build_mod,
    };
    job_queue.all_fetches.appendAssumeCapacity(&fetch);
    job_queue.table.putAssumeCapacityNoClobber(Fetch.relativePathDigest(phantom_package_root, global_dir), &fetch);
    job_queue.group.async(io, Fetch.workerRun, .{ &fetch, "root" });
    try job_queue.group.await(io);

    // Forks unused are an error, before the manifests' errors, which a
    // fork can prevent.
    var any_unused = false;
    for (job_queue.fork_set.keys()) |*fork| {
        if (fork.uses == 0) {
            std.log.err("fork {f} matched no {s} packages", .{ fork.path, fork.manifest.name });
            any_unused = true;
        } else {
            std.log.info("fork {f} matched {d} {s} packages", .{ fork.path, fork.uses, fork.manifest.name });
        }
    }
    if (any_unused) std.process.exit(1);
    try job_queue.consolidateErrors();
    if (fetch.error_bundle.root_list.items.len > 0) {
        var errors = try fetch.error_bundle.toOwnedBundle("");
        errors.renderToStderr(io, .{}, o.color) catch {}; // ziglint-ignore: Z026 -- stderr is where it would be reported
        std.process.exit(1);
    }

    // dependencies.zig, in a local cache directory named after the hash of
    // its contents, as 0.16's `createDependenciesModule`.
    var source: Io.Writer.Allocating = .init(arena);
    try job_queue.createDependenciesSource(&source.writer);
    var hh: Cache.HashHelper = .{};
    hh.addBytes(language.Language.zig_0_16.versionString());
    hh.addBytes(source.written());
    const deps_sub_path = try Io.Dir.path.join(arena, &.{ "o", &hh.final(), "dependencies.zig" });
    {
        var atomic = try local_dir.handle.createFileAtomic(io, deps_sub_path, .{ .make_path = true, .replace = true });
        defer atomic.deinit(io);
        try atomic.file.writeStreamingAll(io, source.written());
        try atomic.replace(io);
    }
    const deps_mod = try arena.create(CliModule);
    deps_mod.* = .{ .name = "@dependencies", .root_path = try Io.Dir.path.join(arena, &.{ o.local, deps_sub_path }) };

    // A module for each package's build.zig, named by its hash (a fork's
    // by its path), which each build.zig that depends on it imports by
    // the dependency's name.
    const hashes = job_queue.table.keys();
    const fetches = job_queue.table.values();
    try deps_mod.deps.ensureUnusedCapacity(arena, @intCast(hashes.len));
    for (hashes, fetches) |*hash, f| {
        if (f == &fetch or !f.has_build_zig) continue;
        if (f.have_manifest) {
            const project_id: Package.ProjectId = .init(f.manifest.name, f.manifest.id);
            if (job_queue.fork_set.getKeyPtrAdapted(project_id, @as(Fetch.JobQueue.Fork.Adapter, .{}))) |fork| {
                const path = try fork.path.toString(arena);
                const gop = deps_mod.deps.getOrPutAssumeCapacity(path);
                if (!gop.found_existing) {
                    const m = try arena.create(CliModule);
                    m.* = .{ .root_path = try f.package_root.toString(arena), .name = path };
                    gop.value_ptr.* = m;
                }
                f.cli_module = gop.value_ptr.*;
                continue;
            }
        }
        const name = try arena.dupe(u8, hash.toSlice());
        const m = try arena.create(CliModule);
        m.* = .{ .root_path = try f.package_root.toString(arena), .name = name };
        deps_mod.deps.putAssumeCapacityNoClobber(name, m);
        f.cli_module = m;
    }
    for (fetches) |f| {
        if (!f.have_manifest) continue;
        const mod = f.cli_module orelse continue;
        const man = &f.manifest;
        try mod.deps.ensureUnusedCapacity(arena, @intCast(man.dependencies.count()));
        for (man.dependencies.keys(), man.dependencies.values()) |name, dep| {
            const dep_digest = Fetch.depDigest(f.package_root, global_dir, dep) orelse continue;
            const dep_mod = job_queue.table.get(dep_digest).?.cli_module orelse continue;
            mod.deps.putAssumeCapacityNoClobber(try arena.dupe(u8, name), dep_mod);
        }
    }

    var argv: std.ArrayList([]const u8) = .empty;
    for (deps_mod.deps.values()) |dep| {
        const m: CliModule = .{ .name = dep.name, .root_path = try Io.Dir.path.join(arena, &.{ dep.root_path, std.zig.build_zig_basename }), .deps = dep.deps };
        try m.lower(arena, &argv);
    }
    try deps_mod.lower(arena, &argv);
    try build_mod.lower(arena, &argv);
    return argv.items;
}
