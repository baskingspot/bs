//! `bs build`: compiles upstream's build runner (`lib/compiler/Maker.zig`)
//! with bs and replaces bs with it, as upstream's `zig build` does, but
//! with `--zig=<bs>`: the runner then compiles `build.zig` (with
//! `lib/compiler/configurer.zig`) and every compile step by running bs
//! with `--listen=-` (`main.serve`).
//!
//! Upstream compiles the runner once per global cache in ReleaseSafe with
//! LLVM (75 s on the bench orb); bs compiles it in ReleaseSafe too (its
//! one code generation, but std's ReleaseSafe paths: no allocation stack
//! traces, no error return traces, `.info` logging), once per bs binary
//! and zig lib directory, into `<global cache>/bs/o/<hash>/maker`, and a
//! build with nothing changed reuses it without relinking.

const std = @import("std");
const Io = std.Io;
const main = @import("main.zig");
const cache = @import("cache.zig");
const Frontend = @import("Frontend.zig");
const Incremental = @import("Incremental.zig");
const toolchain = @import("toolchain.zig");
const language = @import("language.zig");
const Build16 = @import("Build16.zig");

pub fn run(init: std.process.Init, args: []const []const u8) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const env = init.environ_map;
    var user_args = args;
    // As upstream, `--zig-lib=` is only recognized first.
    var lib_override: ?[]const u8 = null;
    if (user_args.len != 0 and std.mem.startsWith(u8, user_args[0], "--zig-lib=")) {
        lib_override = user_args[0]["--zig-lib=".len..];
        user_args = user_args[1..];
    }
    const cwd = try std.process.currentPathAlloc(io, arena);
    const dirs = Frontend.resolveCacheDirs(arena, io, env, .{ .local_is_global = true });
    const global = try Io.Dir.path.resolveAlloc(arena, &.{ cwd, dirs.global });
    // The root package's language is every compilation's (`BS_ZIG_VERSION`
    // for the compilations the runner asks for).
    const choice: language.Choice = if (try buildRoot(arena, io, cwd, user_args)) |root| try language.forBuild(arena, io, env, root) else .{ .language = .newest, .source = .default };
    // Zig 0.16 fetches and runs its build runner from the compiler.
    if (choice.language == .zig_0_16) return Build16.run(init, args, choice);
    const lib = try toolchain.libDir(arena, io, env, global, lib_override, choice.language);
    if (choice.source == .zon) try env.put("BS_ZIG_VERSION", choice.language.name());
    const zig_lib_dir = try Io.Dir.path.resolveAlloc(arena, &.{ cwd, lib.path });

    // One runner per bs binary, zig lib directory and mode.
    const mode = "-OReleaseSafe";
    const seed, _ = try Incremental.compilationKey(arena, io, &.{}, zig_lib_dir, choice.language, "x86_64-linux");
    const runner_hash = cache.hash(2, try std.mem.concat(arena, u8, &.{ std.mem.asBytes(&seed), zig_lib_dir, mode }));
    const runner_dir = try arena.print("{s}/bs/o/{x:0>32}", .{ global, runner_hash });
    try Io.Dir.cwd().createDirPath(io, runner_dir);
    const runner_path = try Io.Dir.path.join(arena, &.{ runner_dir, "maker" });
    // Held until the runner replaces this process (the file closes on
    // exec), so that maintenance keeps the runner it finds.
    _ = cache.useTool(io, runner_dir) catch {}; // ziglint-ignore: Z026 -- cache upkeep is best effort
    // With the default zig lib directory, upstream zig 0.17.1's, which
    // nobody edits, a runner that is as the last check left it is current:
    // that saves the check's stat of every source the runner imports
    // (about 3 ms of a 38 ms no-change build). Another lib directory, given
    // with `--zig-lib=` or ZIG_LIB_DIR, may be a source tree under edit,
    // so it is always checked.
    const stamp_path = try Io.Dir.path.join(arena, &.{ runner_dir, "maker.stat" });
    if (!(lib.trusted and toolUnchanged(io, runner_path, stamp_path))) {
        try compileTool(init, runner_dir, &.{
            "bs",                 "build-exe",
            mode,                 try arena.print("-Mroot={s}/compiler/Maker.zig", .{zig_lib_dir}),
            "--name",             "maker",
            "--zig-lib-dir",      zig_lib_dir,
            "--cache-dir",        global,
            "--global-cache-dir", global,
        }, "Compiling build runner", "build runner", try arena.print("{s}/compiler/Maker.zig", .{zig_lib_dir}), null);
        noteTool(io, runner_path, stamp_path);
    }

    // This bs's identity where the runner's caches see it (`compiler_file`).
    if (try localCacheDir(arena, io, env, cwd, user_args)) |local| {
        noteCompiler(io, local, &std.fmt.bytesToHex(std.mem.asBytes(&seed), .lower));
    }

    const self_exe = try std.process.executablePathAlloc(io, arena);
    var seed_bytes: [4]u8 = undefined;
    io.random(&seed_bytes);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{
        runner_path,
        "build",
        try arena.print("--zig-lib={s}", .{zig_lib_dir}),
        try arena.print("--zig={s}", .{self_exe}),
        try arena.print("--global-cache={s}", .{global}),
        try arena.print("--seed=0x{x}", .{std.mem.readInt(u32, &seed_bytes, .little)}),
    });
    try argv.appendSlice(arena, user_args);
    if (env.get("ZIG_VERBOSE_CMD") != null) std.log.info("{f}", .{std.zig.SubprocessCommand{ .argv = argv.items }});
    const err = std.process.replace(io, .{ .argv = argv.items, .environ_map = env });
    main.fatal("the following command failed to execve with '{t}':\n{s}", .{ err, try std.mem.join(arena, " ", argv.items) });
}

/// Under the project's local cache: the identity of the bs that last ran
/// `bs build` there (the store seed `Incremental.compilationKey` derives
/// from bs's executable), which `main.serve` reports as an input of every
/// compilation the runner asks for. The runner keys its configuration
/// cache and its steps' manifests on `builtin.zig_version_string`, which
/// is upstream's for every bs, and on their inputs: with this file among
/// them, a build by another bs configures and compiles again rather than
/// keep what the last one made (its build graph, its lint findings).
pub const compiler_file = "bs/compiler";

/// The runner's local cache for `user_args`, as `Maker.zig` finds it:
/// ZIG_LOCAL_CACHE_DIR or `--cache-dir`, else `.zig-cache` in the build
/// root (`buildRoot`). Null if there is none, which the runner reports.
fn localCacheDir(arena: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, cwd: []const u8, user_args: []const []const u8) !?[]const u8 {
    var override: ?[]const u8 = std.zig.EnvVar.ZIG_LOCAL_CACHE_DIR.get(env);
    var i: usize = 0;
    while (i < user_args.len) : (i += 1) {
        const arg = user_args[i];
        if (std.mem.eql(u8, arg, "--")) break;
        if (i + 1 == user_args.len) break;
        if (std.mem.eql(u8, arg, "--cache-dir")) {
            i += 1;
            override = user_args[i];
        } else if (std.mem.eql(u8, arg, "--build-file")) {
            i += 1;
        }
    }
    if (override) |p| {
        const local = try Io.Dir.path.resolveAlloc(arena, &.{ cwd, p });
        return local;
    }
    const local = try Io.Dir.path.join(arena, &.{ try buildRoot(arena, io, cwd, user_args) orelse return null, ".zig-cache" });
    return local;
}

/// The build root for `user_args`, as `Maker.zig` finds it: the directory
/// of `--build-file`, else the nearest one up from `cwd` that has
/// `build.zig`. Null if there is none.
fn buildRoot(arena: std.mem.Allocator, io: Io, cwd: []const u8, user_args: []const []const u8) !?[]const u8 {
    var build_file: ?[]const u8 = null;
    var i: usize = 0;
    while (i < user_args.len) : (i += 1) {
        const arg = user_args[i];
        if (std.mem.eql(u8, arg, "--")) break;
        if (i + 1 == user_args.len) break;
        if (std.mem.eql(u8, arg, "--cache-dir")) {
            i += 1;
        } else if (std.mem.eql(u8, arg, "--build-file")) {
            i += 1;
            build_file = user_args[i];
        }
    }
    var dir: []const u8 = if (build_file) |bf| try Io.Dir.path.resolveAlloc(arena, &.{ cwd, Io.Dir.path.dirname(bf) orelse "." }) else cwd;
    while (build_file == null) {
        if (Io.Dir.cwd().access(io, try Io.Dir.path.join(arena, &.{ dir, std.zig.build_zig_basename }), .{})) |_| break else |_| {}
        dir = Io.Dir.path.dirname(dir) orelse return null;
    }
    return dir;
}

/// Writes `id` to `compiler_file` under `local` unless it is there
/// already, so that a build by the same bs leaves the file's stat alone.
/// Best effort: without it, the runner keeps what another bs made.
fn noteCompiler(io: Io, local: []const u8, id: []const u8) void {
    var dir = Io.Dir.cwd().createDirPathOpen(io, local, .{}) catch return;
    defer dir.close(io);
    var buf: [64]u8 = undefined;
    if (dir.readFile(io, compiler_file, &buf)) |old| {
        if (std.mem.eql(u8, old, id)) return;
    } else |_| {}
    dir.createDirPath(io, Io.Dir.path.dirname(compiler_file).?) catch return;
    cache.writeReplace(io, dir, compiler_file, &.{id}) catch {}; // ziglint-ignore: Z026 -- best effort, as the doc comment says
}

/// Compiles one of upstream's programs that bs runs (the build runner,
/// translate-c) with `compile_args`, from `dir`, where its binary goes.
/// `root_dir` is the root module's directory if not the root file's.
pub fn compileTool(init: std.process.Init, dir: []const u8, compile_args: []const []const u8, progress: []const u8, what: []const u8, root: []const u8, root_dir: ?[]const u8) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const cwd = try std.process.currentPathAlloc(io, arena);
    // Compiled from its own directory, so that the compilation's key (which
    // includes the working directory) is the same for every project.
    try std.process.setCurrentPath(io, dir);
    var opts = try main.parseOptions(arena, io, init.environ_map, .build_exe, compile_args[2..]);
    opts.root_dir = root_dir;
    const job: main.Job = try .init(init, compile_args, opts);
    {
        const prog = std.Progress.start(io, .{ .root_name = progress });
        defer prog.end();
        var inc = job.openCache(job.stem);
        defer if (inc) |*i| i.close();
        switch (try main.compile(init, &job, if (inc) |*i| i else null, job.stem, null, prog, null)) {
            .ok => {},
            .errors => |diags| {
                main.printDiagnostics(io, diags, .text) catch {}; // ziglint-ignore: Z026 -- stderr is where it would be reported
                main.fatal("bs could not compile the {s} ({s})", .{ what, root });
            },
            .failed => main.fatal("bs could not link the {s} ({s})", .{ what, root }),
        }
    }
    try std.process.setCurrentPath(io, cwd);
}

/// A tool's stat, as `noteTool` recorded it after the last check.
const RunnerStat = extern struct { inode: u64, size: u64, mtime: i64 };

fn runnerStat(io: Io, path: []const u8) ?RunnerStat {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    return .{ .inode = @intCast(st.inode), .size = st.size, .mtime = @intCast(st.mtime.toNanoseconds()) };
}

pub fn toolUnchanged(io: Io, runner_path: []const u8, stamp_path: []const u8) bool {
    var buf: [@sizeOf(RunnerStat)]u8 = undefined;
    const bytes = Io.Dir.cwd().readFile(io, stamp_path, &buf) catch return false;
    if (bytes.len != buf.len) return false;
    const now = runnerStat(io, runner_path) orelse return false;
    return std.mem.eql(u8, std.mem.asBytes(&now), bytes);
}

/// Records the stat of a tool that was just checked. Best effort.
pub fn noteTool(io: Io, runner_path: []const u8, stamp_path: []const u8) void {
    const st = runnerStat(io, runner_path) orelse return;
    var atomic = Io.Dir.cwd().createFileAtomic(io, stamp_path, .{ .replace = true }) catch return;
    defer atomic.deinit(io);
    atomic.file.writeStreamingAll(io, std.mem.asBytes(&st)) catch return;
    atomic.replace(io) catch {}; // ziglint-ignore: Z026 -- cache upkeep is best effort
}
