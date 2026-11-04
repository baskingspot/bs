//! C and C++ source files, compiled by upstream's Clang (`zig clang`) with
//! the arguments upstream's `Compilation.addCCArgs` gives them for zap's
//! target and the baseline CPU, in Debug (docs/architecture.md, "C
//! interop"). zap never compiles C or C++ itself. With `-lc++`, an
//! executable also links libc++, libc++abi and libunwind, which this file
//! builds from the zig lib directory's sources as upstream's
//! `libs/libcxx.zig` and `libs/libunwind.zig` do, once per configuration,
//! into the global cache.
//!
//! The compiles start before analysis and run while Sema does; the build
//! adds their objects to its link inputs at its first sync point
//! (`Emit.sync`), before it pulls archive members and compiler_rt for
//! them. Each object has a record in `<local cache>/zap/tc/` (ToolRecord),
//! keyed by zap, upstream zig, the arguments and the source, which lists
//! the headers Clang read: a build whose files all stat as recorded runs
//! nothing.

const std = @import("std");
const Io = std.Io;
const cache = @import("cache.zig");
const diag = @import("diag.zig");
const ToolRecord = @import("ToolRecord.zig");

const CSource = @This();

/// As given on the command line: relative paths stay relative, as
/// upstream passes them to Clang (debug info and diagnostics name them so).
path: []const u8,
/// `-cflags ... --` in force where the file was given.
extra_flags: []const []const u8,
/// The owning module's C arguments (`-I`, `-D`, ...) and options.
cc_argv: []const []const u8,
flags: Flags,
lang: Lang = .c,

/// The languages Clang compiles here, as upstream's `FileExt` classifies
/// them; assembly only in libunwind.
pub const Lang = enum {
    c,
    cpp,
    asm_cpp,

    /// The language of a source file argument, by its extension, or null
    /// if it is not one zap compiles.
    pub fn ofPath(path: []const u8) ?Lang {
        const ext = std.fs.path.extension(path);
        if (std.mem.eql(u8, ext, ".c")) return .c;
        for ([_][]const u8{ ".C", ".cc", ".cpp", ".cxx", ".stub", ".c++" }) |e| if (std.mem.eql(u8, ext, e)) return .cpp;
        return null;
    }
};

/// The per-module options that change a C compile, as upstream's
/// `Module.create` resolves them: unset takes the root module's, then the
/// Debug default.
pub const Flags = struct {
    sanitize_c: ?std.zig.SanitizeC = null,
    red_zone: ?bool = null,
    no_builtin: ?bool = null,
    pic: ?bool = null,
    stack_protector: ?bool = null,
    /// The module's `-O` (`main.parseOptions` sets it): Debug or ReleaseSafe.
    optimize: ?std.lang.Optimize = null,

    pub fn inherit(f: Flags, root: Flags) Flags {
        var r = f;
        inline for (@typeInfo(Flags).@"struct".field_names) |name| {
            if (@field(r, name) == null) @field(r, name) = @field(root, name);
        }
        return r;
    }

    /// Takes a module option of the command line; false if `arg` is none.
    pub fn parse(f: *Flags, arg: []const u8) bool {
        const eql = std.mem.eql;
        if (eql(u8, arg, "-fsanitize-c") or eql(u8, arg, "-fsanitize-c=full")) {
            f.sanitize_c = .full;
        } else if (eql(u8, arg, "-fsanitize-c=trap")) {
            f.sanitize_c = .trap;
        } else if (eql(u8, arg, "-fno-sanitize-c")) {
            f.sanitize_c = .off;
        } else if (eql(u8, arg, "-mred-zone")) {
            f.red_zone = true;
        } else if (eql(u8, arg, "-mno-red-zone")) {
            f.red_zone = false;
        } else if (eql(u8, arg, "-fbuiltin")) {
            f.no_builtin = false;
        } else if (eql(u8, arg, "-fno-builtin")) {
            f.no_builtin = true;
        } else if (eql(u8, arg, "-fstack-protector")) {
            f.stack_protector = true;
        } else if (eql(u8, arg, "-fno-stack-protector")) {
            f.stack_protector = false;
        } else if (eql(u8, arg, "-fPIC")) {
            f.pic = true;
        } else if (eql(u8, arg, "-fno-PIC")) {
            f.pic = false;
        } else return false;
        return true;
    }
};

/// The compilation-wide settings of the C compiles.
pub const Options = struct {
    zig_lib_dir: []const u8,
    local_cache: []const u8,
    /// The target's glibc: with `-lc` the linked one; without, the native
    /// system's for the native target, as upstream's native target; null
    /// for `x86_64-linux`.
    glibc_version: ?std.SemanticVersion,
    link_libc: bool,
    /// `-lc++`: libc++'s headers and configuration for every source, as
    /// upstream gives them to C sources too.
    link_libcpp: bool = false,
    /// An executable with `-lc++`: build (or find) the C++ runtime
    /// libraries and link them (`Batch.Result.archives`).
    cxx_runtime: bool = false,
    /// An executable linking glibc with C inputs: build (or find) glibc's
    /// libc_nonshared.a (`atexit` and the others glibc's libc.so lacks)
    /// and link it last, as upstream does.
    libc_nonshared: bool = false,
    /// Where the runtime libraries go: `<global>/zap/o/<key>/`.
    global_cache: []const u8 = "",
    single_threaded: bool = false,
    /// Upstream's default stack protector for the compilation's C: with
    /// libc, unless its Zig code goes through the self-hosted backend,
    /// which has none (`Module.create`): a library of C only, or `-fllvm`.
    stack_protector: bool = false,
    pie: bool,
    function_sections: bool,
    data_sections: bool,
    unwind_tables: std.lang.UnwindTables,
    /// `cc_argv` left after the last `-M`, before every module's own.
    global_cc_argv: []const []const u8,
    /// `-isystem` directories after libc's (`main.Options.c_native_includes`).
    native_includes: []const []const u8 = &.{},
    /// `--verbose-cc`.
    verbose: bool = false,
};

/// The compiles of one build, running while it analyzes.
pub const Batch = struct {
    gpa: std.mem.Allocator,
    io: Io,
    jobs: []Job,
    /// The C++ runtime libraries an executable links (`Options.cxx_runtime`).
    archives: []Archive = &.{},
    group: Io.Group = .init,
    next: std.atomic.Value(usize) = .init(0),
    /// Upstream zig, or why there is none.
    zig: Zig,
    /// How many sources Clang compiles: those whose record missed, and
    /// the C++ runtime libraries' sources when one is built.
    misses: usize = 0,
    paths: diag.Paths,
    verbose: bool,
    /// `wait`'s result, which later attempts of the build reuse.
    result_arena: std.heap.ArenaAllocator,
    result: ?Result = null,

    const Zig = union(enum) { path: []const u8, missing: []const u8 };

    const Job = struct {
        arena: std.heap.ArenaAllocator,
        source: []const u8,
        abs_source: []const u8,
        /// Clang's arguments, without the depfile and output paths, which
        /// go at `dep_at` and the end.
        argv: []const []const u8,
        dep_at: usize,
        /// Empty for a C++ runtime library's source, which has no record.
        record_path: []const u8,
        out_path: []const u8,
        /// The runtime library (`Batch.archives`) the object goes into.
        archive: ?u8 = null,
        old_output: ?cache.Hash = null,
        start_ns: i96,
        /// Set by `run`.
        state: union(enum) {
            pending,
            done,
            /// Clang failed, with its stderr.
            failed: []const u8,
            /// zap could not run it.
            err: []const u8,
        } = .pending,
        /// The files Clang read, zero-separated.
        inputs: []const u8 = "",
    };

    /// A C++ runtime library: in the global cache already, or built by
    /// this batch's jobs from `first` on into `tmp_dir`.
    const Archive = struct {
        path: []const u8,
        tmp_dir: []const u8 = "",
        first: usize = 0,
        len: usize = 0,
    };

    pub const Result = struct {
        /// In command-line order.
        objects: []const Object,
        /// The C++ runtime libraries, in link order.
        archives: []const Object = &.{},
        errors: []const diag.Diagnostic,
        /// Every file Clang read, zero-separated.
        inputs: []const u8,
    };

    fn worker(b: *Batch) void {
        while (true) {
            const i = b.next.fetchAdd(1, .monotonic);
            if (i >= b.jobs.len) return;
            const j = &b.jobs[i];
            if (j.state == .pending) run(b, j);
        }
    }

    fn run(b: *Batch, j: *Job) void {
        runFallible(b, j) catch |err| {
            j.state = .{ .err = std.fmt.allocPrint(j.arena.allocator(), "unable to compile '{s}': {t}", .{ j.source, err }) catch "out of memory" };
        };
    }

    fn runFallible(b: *Batch, j: *Job) !void {
        const arena = j.arena.allocator();
        const io = b.io;
        const zig = switch (b.zig) {
            .path => |p| p,
            .missing => |msg| {
                j.state = .{ .err = msg };
                return;
            },
        };
        // A runtime library's object goes straight into its build
        // directory; a record's output, once Clang succeeds.
        const dep_path, const tmp_out = if (j.archive != null) .{ try std.fmt.allocPrint(arena, "{s}.d", .{j.out_path}), j.out_path } else paths: {
            const tmp_dir = try std.fs.path.join(arena, &.{ std.fs.path.dirname(std.fs.path.dirname(j.record_path).?).?, "tmp" });
            try Io.Dir.cwd().createDirPath(io, tmp_dir);
            var rand: [8]u8 = undefined;
            io.random(&rand);
            const tmp_base = try std.fs.path.join(arena, &.{ tmp_dir, &std.fmt.bytesToHex(rand, .lower) });
            break :paths .{ try std.fmt.allocPrint(arena, "{s}-cc.d", .{tmp_base}), try std.fmt.allocPrint(arena, "{s}-cc.o", .{tmp_base}) };
        };
        defer Io.Dir.cwd().deleteFile(io, dep_path) catch {};
        defer if (j.archive == null) Io.Dir.cwd().deleteFile(io, tmp_out) catch {};
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(arena, zig);
        try argv.appendSlice(arena, j.argv[1..j.dep_at]);
        try argv.appendSlice(arena, &.{ "-MD", "-MV", "-MF", dep_path });
        try argv.appendSlice(arena, j.argv[j.dep_at..]);
        try argv.appendSlice(arena, &.{ "-c", "-o", tmp_out });
        if (b.verbose) std.log.info("{f}", .{std.zig.SubprocessCommand{ .argv = argv.items }});
        // Warnings can run to megabytes (highway's -Wall -Wextra: 17 MB
        // for one file); only a failure keeps them, for its errors.
        var run_arena: std.heap.ArenaAllocator = .init(b.gpa);
        defer run_arena.deinit();
        const res = try std.process.run(run_arena.allocator(), io, .{
            .argv = argv.items,
            .stdout_limit = .limited(1 << 20),
            .stderr_limit = .unlimited,
        });
        if (!res.term.success()) {
            j.state = .{ .failed = if (res.stderr.len != 0) try arena.dupe(u8, res.stderr) else try std.fmt.allocPrint(arena, "clang failed ({f})", .{res.term}) };
            return;
        }
        if (j.archive != null) {
            j.state = .done;
            return;
        }
        // Warnings print as upstream's `zig cc` would; upstream's build
        // drops them, so only `ZAP_CC_WARNINGS` shows them.
        j.inputs = try ToolRecord.commit(arena, io, .{
            .record_path = j.record_path,
            .out_path = j.out_path,
            .tmp_out = tmp_out,
            .dep_path = dep_path,
            .source = j.abs_source,
            .old_output = j.old_output,
            .start_ns = j.start_ns,
        });
        j.state = .done;
    }

    /// Waits for every compile, once.
    pub fn wait(b: *Batch) !*const Result {
        if (b.result) |*r| return r;
        // Work on the compiles nobody started (no concurrency).
        b.worker();
        try b.group.await(b.io);
        const arena = b.result_arena.allocator();
        const paths = b.paths;
        var objects: std.ArrayList(Object) = .empty;
        var errors: std.ArrayList(diag.Diagnostic) = .empty;
        var inputs: std.ArrayList(u8) = .empty;
        for (b.jobs) |*j| {
            if (j.inputs.len != 0) {
                if (inputs.items.len != 0) try inputs.append(arena, 0);
                try inputs.appendSlice(arena, j.inputs);
            }
            switch (j.state) {
                .pending => unreachable,
                .done => {
                    if (j.archive != null) continue;
                    const bytes = Io.Dir.cwd().readFileAlloc(b.io, j.out_path, arena, .unlimited) catch |err| {
                        try errors.append(arena, .{ .loc = null, .msg = try std.fmt.allocPrint(arena, "unable to read the object of '{s}' ({s}): {t}", .{ j.source, j.out_path, err }) });
                        continue;
                    };
                    try objects.append(arena, .{ .path = try arena.dupe(u8, j.out_path), .bytes = bytes, .member = try arena.dupe(u8, std.fs.path.basename(j.out_path)) });
                },
                .failed => |stderr| try clangErrors(arena, paths, j.source, stderr, &errors),
                .err => |msg| try errors.append(arena, .{ .loc = null, .msg = try arena.dupe(u8, msg) }),
            }
        }
        var archives: std.ArrayList(Object) = .empty;
        for (b.archives) |a| {
            if (a.len != 0) {
                b.writeArchive(arena, a) catch |err| {
                    try errors.append(arena, .{ .loc = null, .msg = try std.fmt.allocPrint(arena, "unable to build '{s}': {t}", .{ a.path, err }) });
                    continue;
                };
            }
            const bytes = Io.Dir.cwd().readFileAlloc(b.io, a.path, arena, .unlimited) catch |err| {
                try errors.append(arena, .{ .loc = null, .msg = try std.fmt.allocPrint(arena, "unable to read '{s}': {t}", .{ a.path, err }) });
                continue;
            };
            try archives.append(arena, .{ .path = a.path, .bytes = bytes, .member = std.fs.path.basename(a.path) });
        }
        b.result = .{ .objects = objects.items, .archives = archives.items, .errors = errors.items, .inputs = inputs.items };
        return &b.result.?;
    }

    /// Archives a runtime library's objects into the global cache, unless
    /// one of them failed to compile (its error is reported already).
    fn writeArchive(b: *Batch, arena: std.mem.Allocator, a: Archive) !void {
        const io = b.io;
        defer Io.Dir.cwd().deleteTree(io, a.tmp_dir) catch {};
        const jobs = b.jobs[a.first..][0..a.len];
        for (jobs) |j| if (j.state != .done) return error.CompileFailed;
        const members = try arena.alloc(@import("link/Archive.zig").Input, jobs.len);
        for (members, jobs) |*m, j| m.* = .{ .name = std.fs.path.basename(j.out_path), .bytes = try Io.Dir.cwd().readFileAlloc(io, j.out_path, arena, .unlimited) };
        try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(a.path).?);
        try @import("link/Archive.zig").write(b.gpa, io, Io.Dir.cwd(), a.path, members);
    }
};

/// Where the objects are, in command-line order, compiled or not yet:
/// a record's output keeps its path across edits of the source. Then the
/// C++ runtime libraries, whose paths name their configuration.
pub fn objectPaths(b: *const Batch, arena: std.mem.Allocator) ![]const []const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    for (b.jobs) |j| if (j.archive == null) try paths.append(arena, try arena.dupe(u8, j.out_path));
    for (b.archives) |a| try paths.append(arena, try arena.dupe(u8, a.path));
    return paths.items;
}

/// For a batch that compiled nothing (`misses == 0`): what its objects and
/// the archive at `archive_path` are on disk (path, inode, size, mtime),
/// or null if one is missing. An archive written from these objects keeps
/// its stamp until one of them changes.
pub fn archiveStamp(b: *const Batch, arena: std.mem.Allocator, archive_path: []const u8) !?cache.Hash {
    var id: std.ArrayList(u8) = .empty;
    for (b.jobs) |j| if (j.archive == null) {
        const st = Io.Dir.cwd().statFile(b.io, j.out_path, .{}) catch return null;
        try id.print(arena, "{s}\x00{d}\x00{d}\x00{d}\x00", .{ j.out_path, st.inode, st.size, st.mtime.toNanoseconds() });
    };
    const st = Io.Dir.cwd().statFile(b.io, archive_path, .{}) catch return null;
    try id.print(arena, "{s}\x00{d}\x00{d}\x00{d}\x00", .{ archive_path, st.inode, st.size, st.mtime.toNanoseconds() });
    return cache.hash(3, id.items);
}

/// The files the sources read, zero-separated, as `wait` reports them,
/// for a batch that compiled nothing.
pub fn hitInputs(b: *const Batch, arena: std.mem.Allocator) ![]const u8 {
    var inputs: std.ArrayList(u8) = .empty;
    for (b.jobs) |j| if (j.inputs.len != 0) {
        if (inputs.items.len != 0) try inputs.append(arena, 0);
        try inputs.appendSlice(arena, j.inputs);
    };
    return inputs.items;
}

pub const Object = struct {
    path: []const u8,
    bytes: []const u8,
    /// Its name in a static library: the source's stem, `.o`.
    member: []const u8,
};

/// Starts compiling `sources`: looks each up in its record, and runs Clang
/// for the others on up to the CPU count of tasks while the caller goes on.
/// With `o.cxx_runtime`, also builds the C++ runtime libraries that are not
/// in the global cache.
pub fn start(gpa: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, sources: []const CSource, o: Options) !*Batch {
    const b = try gpa.create(Batch);
    errdefer gpa.destroy(b);
    b.* = .{ .gpa = gpa, .io = io, .jobs = &.{}, .zig = undefined, .paths = undefined, .verbose = o.verbose, .result_arena = .init(gpa) };
    const ra = b.result_arena.allocator();
    b.paths = try .init(ra, io, o.zig_lib_dir);
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const s = scratch.allocator();
    const cwd_path = try std.process.currentPathAlloc(io, s);
    const lib = try std.fs.path.resolve(ra, &.{ cwd_path, o.zig_lib_dir });
    const local = try std.fs.path.resolve(s, &.{ cwd_path, o.local_cache });
    const start_ns = Io.Clock.real.now(io).toNanoseconds();

    const zig = findZig(s, io, environ);
    // Upstream zig's identity goes into the key: another Clang compiles
    // other bytes.
    const zig_id = if (zig.found) |p| id: {
        const st = Io.Dir.cwd().statFile(io, p, .{}) catch break :id "";
        break :id try std.fmt.allocPrint(s, "{s}\x00{d}\x00{d}\x00{d}", .{ p, st.inode, st.size, st.mtime.toNanoseconds() });
    } else "";
    const target = try cTarget(io, o.glibc_version);
    const common = try commonArgs(ra, &target, lib, o);

    // The runtime libraries first, to know how many of their sources to
    // compile.
    var runtime: std.ArrayList(RuntimeJob) = .empty;
    var archives: std.ArrayList(Batch.Archive) = .empty;
    for (runtime_libs ++ [_]RuntimeLib{nonshared_lib}) |rl| {
        const is_nonshared = std.mem.eql(u8, rl.name, nonshared_lib.name);
        if (!(if (is_nonshared) o.libc_nonshared and zig.found != null else o.cxx_runtime)) continue;
        const first = runtime.items.len;
        if (is_nonshared) try nonsharedJobs(ra, &runtime, common, lib, o) else try runtimeJobs(ra, &runtime, rl, common, lib, o);
        // Keyed by upstream zig and every compile's arguments, which name
        // the lib directory's sources; not by zap, whose rebuilds do not
        // change the library.
        var h: std.ArrayList(u8) = .empty;
        try h.print(s, "zap c++ runtime 1\x00{s}\x00{s}\x00", .{ zig_id, rl.name });
        for (runtime.items[first..]) |rj| for (rj.argv) |a| try h.print(s, "{s}\x00", .{a});
        const hex = std.fmt.bytesToHex(@as([16]u8, @bitCast(cache.hash(2, h.items))), .lower);
        const path = try std.fs.path.join(ra, &.{ o.global_cache, "zap", "o", &hex, try std.fmt.allocPrint(s, "lib{s}.a", .{rl.name}) });
        if (Io.Dir.cwd().access(io, path, .{})) |_| {
            runtime.shrinkRetainingCapacity(first);
            try archives.append(ra, .{ .path = path });
        } else |_| {
            var rand: [8]u8 = undefined;
            io.random(&rand);
            const tmp_dir = try std.fs.path.join(ra, &.{ o.global_cache, "zap", "tmp", try std.fmt.allocPrint(s, "{s}-{s}", .{ rl.name, &std.fmt.bytesToHex(rand, .lower) }) });
            try Io.Dir.cwd().createDirPath(io, tmp_dir);
            try archives.append(ra, .{ .path = path, .tmp_dir = tmp_dir, .first = sources.len + first, .len = runtime.items.len - first });
        }
    }
    b.archives = archives.items;
    b.jobs = try gpa.alloc(Batch.Job, sources.len + runtime.items.len);
    for (b.jobs) |*j| j.arena = .init(gpa);

    var misses: usize = 0;
    var stats: ToolRecord.Stats = .empty;
    for (sources, b.jobs[0..sources.len]) |src, *j| {
        const arena = j.arena.allocator();
        var argv: std.ArrayList([]const u8) = .empty;
        const dep_at = try appendArgs(arena, &argv, common, src.path, .{
            .lang = src.lang,
            .optimize = src.flags.optimize orelse .debug,
            // As upstream's `Module.create`: trapping in ReleaseSafe, none
            // in ReleaseFast and ReleaseSmall.
            .sanitize_c = src.flags.sanitize_c orelse @as(std.zig.SanitizeC, switch (src.flags.optimize orelse .debug) {
                .debug => .full,
                .safe => .trap,
                .fast, .small => .off,
            }),
            .red_zone = src.flags.red_zone orelse true,
            .no_builtin = src.flags.no_builtin orelse false,
            .stack_protector = o.link_libc and (src.flags.stack_protector orelse o.stack_protector),
            // glibc requires PIC (`requiresPic`); else the module's, default off.
            .pic = o.link_libc or (src.flags.pic orelse false),
            .pie = o.pie,
            .function_sections = o.function_sections,
            .data_sections = o.data_sections,
            .unwind_tables = o.unwind_tables,
            .link_libc = o.link_libc,
            .native = true,
            .libcpp = o.link_libcpp,
            .libunwind = o.link_libcpp,
        });
        try argv.appendSlice(arena, o.global_cc_argv);
        try argv.appendSlice(arena, src.cc_argv);
        try argv.appendSlice(arena, src.extra_flags);
        const abs_source = try std.fs.path.resolve(arena, &.{ cwd_path, src.path });

        var key_args: std.ArrayList([]const u8) = .empty;
        try key_args.appendSlice(s, argv.items[1..]);
        try key_args.append(s, abs_source);
        const key = try ToolRecord.key(s, io, "cc", zig_id, lib, key_args.items);
        const hex = std.fmt.bytesToHex(@as([16]u8, @bitCast(key)), .lower);
        j.* = .{
            .arena = j.arena,
            .source = src.path,
            .abs_source = abs_source,
            .argv = argv.items,
            .dep_at = dep_at,
            .record_path = try std.fs.path.join(arena, &.{ local, "zap", "tc", &hex }),
            .out_path = try std.fs.path.join(arena, &.{ local, "o", &hex, try std.fmt.allocPrint(arena, "{s}.o", .{std.fs.path.stem(src.path)}) }),
            .start_ns = start_ns,
        };
        if (try ToolRecord.check(arena, io, j.record_path, j.out_path, start_ns, s, &stats)) |c| switch (c) {
            .hit => |inputs| {
                j.inputs = inputs;
                j.state = .done;
                continue;
            },
            .miss => |h| j.old_output = h,
        };
        misses += 1;
    }
    for (archives.items, 0..) |a, ai| if (a.len != 0) for (runtime.items[a.first - sources.len ..][0..a.len], b.jobs[a.first..][0..a.len]) |rj, *j| {
        j.* = .{
            .arena = j.arena,
            .source = rj.argv[2],
            .abs_source = rj.argv[2],
            .argv = rj.argv,
            .dep_at = rj.dep_at,
            .record_path = "",
            .out_path = try std.fs.path.join(ra, &.{ a.tmp_dir, try std.fmt.allocPrint(ra, "{s}.o", .{std.fs.path.stem(rj.argv[2])}) }),
            .archive = @intCast(ai),
            .start_ns = start_ns,
        };
        misses += 1;
    };
    // Only a build that compiles C needs upstream zig, and checks its
    // version once.
    b.zig = if (misses == 0) .{ .path = "" } else if (zig.found) |p|
        if (try checkZig(s, io, p)) |msg| .{ .missing = try gpa.dupe(u8, msg) } else .{ .path = try gpa.dupe(u8, p) }
    else
        .{ .missing = try std.fmt.allocPrint(gpa, "compiling C sources needs upstream zig 0.17.0; zap looked for it in ZAP_ZIG, as 'zig' on PATH, and in {s}", .{zig.looked}) };
    b.misses = misses;
    const workers = @min(misses, std.Thread.getCpuCount() catch 1);
    for (0..workers) |_| b.group.concurrent(io, Batch.worker, .{b}) catch break;
    return b;
}

pub fn destroy(b: *Batch) void {
    const gpa = b.gpa;
    b.group.cancel(b.io);
    switch (b.zig) {
        .path => |p| if (p.len != 0) gpa.free(p),
        .missing => |m| gpa.free(m),
    }
    for (b.jobs) |*j| j.arena.deinit();
    gpa.free(b.jobs);
    b.result_arena.deinit();
    gpa.destroy(b);
}

/// The target C compiles for: glibc's version names the ABI, as the
/// native target does upstream; zap's CPU is the baseline.
pub fn cTarget(io: Io, glibc_version: ?std.SemanticVersion) !std.Target {
    var buf: [64]u8 = undefined;
    const text = if (glibc_version) |v| try std.fmt.bufPrint(&buf, "x86_64-linux-gnu.{f}", .{v}) else "x86_64-linux-none";
    const query = try std.Target.Query.parse(.{ .arch_os_abi = text, .cpu_features = "baseline" });
    return std.zig.system.resolveTargetQuery(io, query);
}

/// The arguments that depend only on the target and the lib directory.
const Common = struct {
    triple: []const u8,
    /// `-D__GLIBC_MINOR__=<n>` with `-lc`.
    glibc_minor: []const u8,
    lib: []const u8,
    /// The glibc headers' `-isystem` pairs, with `-lc`.
    libc_includes: []const []const u8,
    /// The native include directories' `-isystem` pairs, for the user's
    /// sources only, as upstream's runtime libraries have none.
    native_includes: []const []const u8,
    /// libc++'s configuration (`libcxx.addCxxArgs`), for every source of a
    /// `-lc++` compilation and for libc++'s and libc++abi's own.
    cxx_defines: []const []const u8,
    /// `-Xclang -target-cpu ...` and every feature.
    features: []const []const u8,
    /// The same for the assembler (`-Xclangas`), for assembly sources.
    asm_features: []const []const u8,
};

fn commonArgs(arena: std.mem.Allocator, target: *const std.Target, lib: []const u8, o: Options) !Common {
    var libc_includes: std.ArrayList([]const u8) = .empty;
    if (o.link_libc) {
        const dirs = try std.zig.LibCDirs.detectFromBuilding(arena, .{ .root_dir = .cwd(), .sub_path = lib }, target);
        for (dirs.libc_include_dir_list) |d| try libc_includes.appendSlice(arena, &.{ "-isystem", d });
    }
    var native_includes: std.ArrayList([]const u8) = .empty;
    for (o.native_includes) |d| try native_includes.appendSlice(arena, &.{ "-isystem", d });
    var features: std.ArrayList([]const u8) = .empty;
    var asm_features: std.ArrayList([]const u8) = .empty;
    try features.appendSlice(arena, &.{ "-Xclang", "-target-cpu", "-Xclang", target.cpu.model.llvm_name.? });
    try asm_features.appendSlice(arena, &.{ "-Xclangas", "-target-cpu", "-Xclangas", target.cpu.model.llvm_name.? });
    for (target.cpu.arch.allFeaturesList(), 0..) |feature, i| {
        const name = feature.llvm_name orelse continue;
        if (std.mem.startsWith(u8, name, "soft-float") or std.mem.startsWith(u8, name, "hard-float") or std.mem.startsWith(u8, name, "x32")) continue;
        const on = target.cpu.features.isEnabled(@intCast(i));
        const f = try std.fmt.allocPrint(arena, "{c}{s}", .{ "-+"[@intFromBool(on)], name });
        try features.appendSlice(arena, &.{ "-Xclang", "-target-feature", "-Xclang", f });
        try asm_features.appendSlice(arena, &.{ "-Xclangas", "-target-feature", "-Xclangas", f });
    }
    // As upstream's `addCxxArgs` with the runtime libraries' optimization
    // (`compilerRtOptMode`: ReleaseFast on this target, for Debug too).
    var cxx: std.ArrayList([]const u8) = .empty;
    try cxx.appendSlice(arena, &.{
        "-D_LIBCPP_ABI_VERSION=1",
        "-D_LIBCPP_ABI_NAMESPACE=__1",
        if (o.single_threaded) "-D_LIBCPP_HAS_THREADS=0" else "-D_LIBCPP_HAS_THREADS=1",
        "-D_LIBCPP_HAS_MONOTONIC_CLOCK",
        "-D_LIBCPP_HAS_TERMINAL",
        "-D_LIBCPP_HAS_MUSL_LIBC=0",
        "-D_LIBCXXABI_DISABLE_VISIBILITY_ANNOTATIONS",
        "-D_LIBCPP_DISABLE_VISIBILITY_ANNOTATIONS",
        "-D_LIBCPP_HAS_VENDOR_AVAILABILITY_ANNOTATIONS=0",
        "-D_LIBCPP_HAS_FILESYSTEM=1",
        "-D_LIBCPP_HAS_RANDOM_DEVICE",
        "-D_LIBCPP_HAS_LOCALIZATION",
        "-D_LIBCPP_HAS_UNICODE",
        "-D_LIBCPP_HAS_WIDE_CHARACTERS",
        "-D_LIBCPP_HAS_NO_STD_MODULES",
        "-D_LIBCPP_HAS_TIME_ZONE_DATABASE",
        "-D_LIBCPP_PSTL_BACKEND_SERIAL",
        "-D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_NONE",
        "-D_LIBCPP_ASSERTION_SEMANTIC_DEFAULT=_LIBCPP_ASSERTION_SEMANTIC_IGNORE",
    });
    // glibc 2.16 introduced aligned_alloc.
    if (o.glibc_version) |v| if (v.order(.{ .major = 2, .minor = 16, .patch = 0 }) == .lt) try cxx.append(arena, "-D_LIBCPP_HAS_LIBRARY_ALIGNED_ALLOCATION=0");
    return .{
        .triple = try std.zig.llvm.Builder.tripleForTarget(arena, target),
        .glibc_minor = if (o.glibc_version) |v| try std.fmt.allocPrint(arena, "-D__GLIBC_MINOR__={d}", .{v.minor}) else "",
        .lib = lib,
        .libc_includes = libc_includes.items,
        .native_includes = native_includes.items,
        .cxx_defines = cxx.items,
        .features = features.items,
        .asm_features = asm_features.items,
    };
}

/// How one compile is configured: its language and its module's options,
/// as upstream's `addCCArgs` reads them.
const Mode = struct {
    lang: Lang,
    /// The module's optimization (Debug or ReleaseSafe), or the runtime
    /// libraries' (`compilerRtOptMode`: ReleaseFast).
    optimize: std.lang.Optimize = .debug,
    sanitize_c: std.zig.SanitizeC,
    red_zone: bool,
    no_builtin: bool,
    /// `-fstack-protector-strong` with upstream's buffer size.
    stack_protector: bool = false,
    pic: bool,
    pie: bool,
    function_sections: bool,
    data_sections: bool,
    unwind_tables: std.lang.UnwindTables,
    link_libc: bool,
    /// The native include directories (`Common.native_includes`).
    native: bool = false,
    /// libc++'s include directories and configuration (`-lc++`).
    libcpp: bool,
    /// libunwind's include directory, which `-lc++` links on Linux.
    libunwind: bool,
};

/// Appends `zig clang <path>` and upstream's arguments for it in
/// upstream's order (`addCCArgs`, `addCommonCCArgs`) up to the CPU
/// features, and returns where the depfile arguments go.
fn appendArgs(arena: std.mem.Allocator, argv: *std.ArrayList([]const u8), common: Common, path: []const u8, m: Mode) !usize {
    try argv.appendSlice(arena, &.{ "zig", "clang", path, "--no-default-config" });
    if (m.lang != .asm_cpp) try argv.append(arena, "-fno-caret-diagnostics");
    try argv.appendSlice(arena, &.{ "-target", common.triple });
    try argv.appendSlice(arena, &.{ if (m.pie) "-fPIE" else "-fno-PIE", if (m.pic) "-fPIC" else "-fno-PIC", "-gdwarf-4", "-gdwarf32", "-fno-lto" });
    const dep_at = argv.items.len;
    try argv.appendSlice(arena, &.{ "-fhosted", "-nostdinc" });
    if (m.lang == .cpp) try argv.append(arena, "-nostdinc++");
    switch (m.optimize) {
        .debug => {},
        .safe => try argv.append(arena, "-D_FORTIFY_SOURCE=2"),
        .fast, .small => try argv.append(arena, "-DNDEBUG"),
    }
    if (m.link_libc) try argv.append(arena, common.glibc_minor);
    if (m.libcpp) {
        try argv.appendSlice(arena, &.{ "-isystem", try std.fs.path.join(arena, &.{ common.lib, "libcxx", "include" }), "-isystem", try std.fs.path.join(arena, &.{ common.lib, "libcxxabi", "include" }) });
        try argv.appendSlice(arena, common.cxx_defines);
    }
    try argv.appendSlice(arena, &.{ "-isystem", try std.fs.path.join(arena, &.{ common.lib, "include" }) });
    if (m.link_libc) try argv.appendSlice(arena, common.libc_includes);
    if (m.native) try argv.appendSlice(arena, common.native_includes);
    if (m.libunwind) try argv.appendSlice(arena, &.{ "-isystem", try std.fs.path.join(arena, &.{ common.lib, "libunwind", "include" }) });
    if (m.lang != .asm_cpp) {
        try argv.append(arena, "-fno-spell-checking");
        if (m.optimize != .debug) try argv.append(arena, "-Werror=date-time");
        switch (m.sanitize_c) {
            .off => {},
            .trap => try argv.appendSlice(arena, &.{ "-fsanitize=undefined", "-fsanitize-trap=undefined" }),
            .full => try argv.appendSlice(arena, &.{ "-fsanitize=undefined", "-fno-sanitize=vptr", "-fno-sanitize=function" }),
        }
        try argv.append(arena, switch (m.optimize) {
            .debug => "-O0",
            .safe, .fast => "-O2",
            .small => "-Os",
        });
    }
    try argv.appendSlice(arena, &.{ if (m.red_zone) "-mred-zone" else "-mno-red-zone", "-fno-omit-frame-pointer" });
    // Upstream's Debug backend for Zig code has no stack protector, which
    // turns it off for the compilation's C too (`Module.create`); the
    // runtime libraries have none either.
    if (m.stack_protector) try argv.appendSlice(arena, &.{ "-fstack-protector-strong", "--param", "ssp-buffer-size=4" }) else try argv.append(arena, "-fno-stack-protector");
    try argv.append(arena, if (m.no_builtin) "-fno-builtin" else "-fbuiltin");
    try argv.append(arena, if (m.function_sections) "-ffunction-sections" else "-fno-function-sections");
    try argv.append(arena, if (m.data_sections) "-fdata-sections" else "-fno-data-sections");
    switch (m.unwind_tables) {
        .none => try argv.appendSlice(arena, &.{ "-fno-unwind-tables", "-fno-asynchronous-unwind-tables" }),
        .sync => try argv.appendSlice(arena, &.{ "-fno-asynchronous-unwind-tables", "-funwind-tables" }),
        .async => try argv.append(arena, "-fasynchronous-unwind-tables"),
    }
    try argv.appendSlice(arena, common.features);
    if (m.lang == .asm_cpp) try argv.appendSlice(arena, common.asm_features);
    return dep_at;
}

// The C++ runtime libraries, as upstream's `src/libs/libcxx.zig` and
// `src/libs/libunwind.zig` build them for x86_64-linux-gnu.
// Copyright (c) Zig contributors. MIT licensed (see upstream/LICENSE).

const RuntimeLib = struct {
    /// `lib<name>.a`.
    name: []const u8,
    /// The sources, relative to the lib directory.
    dir: []const u8,
    files: []const []const u8,
    /// Sources only a multi-threaded build has.
    thread_files: []const []const u8 = &.{},
};

/// In link order, as upstream links them after the program's objects.
const runtime_libs = [_]RuntimeLib{
    .{ .name = "c++", .dir = "libcxx", .files = &libcxx_base_files, .thread_files = &libcxx_thread_files },
    .{ .name = "c++abi", .dir = "libcxxabi", .files = &libcxxabi_files },
    .{ .name = "unwind", .dir = "libunwind", .files = &unwind_files },
};

const libcxxabi_files = [_][]const u8{
    "src/cxa_aux_runtime.cpp",
    "src/cxa_default_handlers.cpp",
    "src/cxa_demangle.cpp",
    "src/cxa_exception_storage.cpp",
    "src/cxa_guard.cpp",
    "src/cxa_handlers.cpp",
    "src/cxa_vector.cpp",
    "src/cxa_virtual.cpp",
    "src/stdlib_exception.cpp",
    "src/stdlib_stdexcept.cpp",
    "src/stdlib_typeinfo.cpp",
    "src/stdlib_new_delete.cpp",
    "src/abort_message.cpp",
    "src/fallback_malloc.cpp",
    "src/private_typeinfo.cpp",
    "src/cxa_exception.cpp",
    "src/cxa_personality.cpp",
    // A single-threaded build leaves this one out.
    "src/cxa_thread_atexit.cpp",
};

// Upstream's list without `src/support/win32/` (Windows only) and
// `src/filesystem/int128_builtins.cpp`, which upstream omits.
const libcxx_base_files = [_][]const u8{
    "src/algorithm.cpp",
    "src/any.cpp",
    "src/bind.cpp",
    "src/call_once.cpp",
    "src/charconv.cpp",
    "src/chrono.cpp",
    "src/error_category.cpp",
    "src/exception.cpp",
    "src/expected.cpp",
    "src/filesystem/directory_entry.cpp",
    "src/filesystem/directory_iterator.cpp",
    "src/filesystem/filesystem_clock.cpp",
    "src/filesystem/filesystem_error.cpp",
    "src/filesystem/operations.cpp",
    "src/filesystem/path.cpp",
    "src/fstream.cpp",
    "src/functional.cpp",
    "src/hash.cpp",
    "src/ios.cpp",
    "src/ios.instantiations.cpp",
    "src/iostream.cpp",
    "src/locale.cpp",
    "src/memory.cpp",
    "src/memory_resource.cpp",
    "src/new.cpp",
    "src/new_handler.cpp",
    "src/new_helpers.cpp",
    "src/optional.cpp",
    "src/ostream.cpp",
    "src/print.cpp",
    "src/random.cpp",
    "src/random_shuffle.cpp",
    "src/regex.cpp",
    "src/ryu/d2fixed.cpp",
    "src/ryu/d2s.cpp",
    "src/ryu/f2s.cpp",
    "src/stdexcept.cpp",
    "src/string.cpp",
    "src/strstream.cpp",
    "src/system_error.cpp",
    "src/typeinfo.cpp",
    "src/valarray.cpp",
    "src/variant.cpp",
    "src/vector.cpp",
    "src/verbose_abort.cpp",
};

const libcxx_thread_files = [_][]const u8{
    "src/atomic.cpp",
    "src/barrier.cpp",
    "src/condition_variable.cpp",
    "src/condition_variable_destructor.cpp",
    "src/future.cpp",
    "src/mutex.cpp",
    "src/mutex_destructor.cpp",
    "src/shared_mutex.cpp",
    "src/thread.cpp",
};

const unwind_files = [_][]const u8{
    "src/libunwind.cpp",
    "src/Unwind-EHABI.cpp",
    "src/Unwind-seh.cpp",
    "src/UnwindLevel1.c",
    "src/UnwindLevel1-gcc-ext.c",
    "src/Unwind-sjlj.c",
    "src/Unwind-wasm.c",
    "src/UnwindRegistersRestore.S",
    "src/UnwindRegistersSave.S",
    "src/gcc_personality_v0.c",
};

/// glibc's libc_nonshared.a, as upstream's `src/libs/glibc.zig` builds it
/// for x86_64-linux-gnu: the functions glibc's libc.so leaves to every
/// executable (`atexit` calls `__cxa_atexit` with its `__dso_handle`).
/// Upstream builds and links it with every glibc executable; zap only
/// with C inputs, since Zig code references none of its functions.
const nonshared_lib: RuntimeLib = .{ .name = "c_nonshared", .dir = "libc/glibc", .files = &.{
    "stdlib/atexit.c",
    "stdlib/at_quick_exit.c",
    "sysdeps/pthread/pthread_atfork.c",
    "debug/stack_chk_fail_local.c",
} };

/// For glibc 2.32 and older: the stat functions, which libc.so versions
/// only from 2.33 on.
const nonshared_stat_files = [_][]const u8{
    "io/stat-2.32.c",     "io/fstat-2.32.c",   "io/lstat-2.32.c",   "io/stat64-2.32.c",
    "io/fstat64-2.32.c",  "io/lstat64-2.32.c", "io/fstatat-2.32.c", "io/fstatat64-2.32.c",
    "io/mknodat-2.32.c",  "io/mknod-2.32.c",
};

/// Appends libc_nonshared.a's compiles, with upstream's flags: its
/// sub-compilation's (ReleaseFast, PIC, no sanitizer or stack protector,
/// no libc), then glibc's own build flags.
fn nonsharedJobs(arena: std.mem.Allocator, out: *std.ArrayList(RuntimeJob), common: Common, lib: []const u8, o: Options) !void {
    const join = std.fs.path.join;
    const v = o.glibc_version.?;
    const old_stat = v.order(.{ .major = 2, .minor = 32, .patch = 0 }) != .gt;
    const old_init = v.order(.{ .major = 2, .minor = 33, .patch = 0 }) != .gt;
    const g = try join(arena, &.{ lib, "libc", "glibc" });
    const sd = try join(arena, &.{ g, "sysdeps" });
    const linux = try join(arena, &.{ sd, "unix", "sysv", "linux" });
    // `add_include_dirs` for x86_64-linux-gnu.
    var includes: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{
        try join(arena, &.{ g, "include" }),
        try join(arena, &.{ linux, "x86_64" }),                try join(arena, &.{ linux, "x86" }),
        try join(arena, &.{ sd, "x86_64", "nptl" }),           try join(arena, &.{ sd, "x86", "nptl" }),
        try join(arena, &.{ linux, "generic" }),               try join(arena, &.{ linux, "include" }),
        linux,                                                 try join(arena, &.{ sd, "nptl" }),
        try join(arena, &.{ sd, "pthread" }),                  try join(arena, &.{ sd, "unix", "sysv" }),
        try join(arena, &.{ sd, "unix", "x86_64" }),           try join(arena, &.{ sd, "unix", "x86" }),
        try join(arena, &.{ sd, "unix" }),                     try join(arena, &.{ sd, "x86_64" }),
        try join(arena, &.{ sd, "x86" }),                      try join(arena, &.{ sd, "generic" }),
        g,                                                     try join(arena, &.{ lib, "libc", "include", "x86_64-linux-gnu" }),
        try join(arena, &.{ lib, "libc", "include", "generic-glibc" }), try join(arena, &.{ lib, "libc", "include", "x86_64-linux-any" }),
        try join(arena, &.{ lib, "libc", "include", "any-linux-any" }),
    }) |d| try includes.appendSlice(arena, &.{ "-I", d });
    for ([3][]const []const u8{ nonshared_lib.files, if (old_stat) &nonshared_stat_files else &.{}, if (old_init) &.{"csu/elf-init-2.33.c"} else &.{} }) |files| for (files) |file| {
        var argv: std.ArrayList([]const u8) = .empty;
        const dep_at = try appendArgs(arena, &argv, common, try join(arena, &.{ g, file }), .{
            .lang = .c,
            .optimize = .fast,
            .sanitize_c = .off,
            .red_zone = true,
            .no_builtin = false,
            .pic = true,
            .pie = false,
            .function_sections = false,
            .data_sections = false,
            .unwind_tables = o.unwind_tables,
            .link_libc = false,
            .libcpp = false,
            .libunwind = false,
        });
        try argv.appendSlice(arena, &.{ "-w", "-std=gnu11", "-fgnu89-inline", "-fmerge-all-constants", "-frounding-math", "-fno-common", "-fmath-errno", "-ftls-model=initial-exec", "-Qunused-arguments" });
        try argv.appendSlice(arena, includes.items);
        try argv.appendSlice(arena, &.{
            "-DNO_INITFINI",                          "-D_LIBC_REENTRANT",
            "-include",                               try join(arena, &.{ g, "include", "libc-modules.h" }),
            "-DMODULE_NAME=libc",                     "-include",
            try join(arena, &.{ g, "include", "libc-symbols.h" }), "-DPIC",
            "-DLIBC_NONSHARED=1",                     "-DTOP_NAMESPACE=glibc",
        });
        try out.append(arena, .{ .argv = argv.items, .dep_at = dep_at });
    };
}

const RuntimeJob = struct { argv: []const []const u8, dep_at: usize };

/// Appends the compiles of runtime library `rl`, with the flags upstream's
/// sub-compilation gives each source: its root module's (ReleaseFast, PIC,
/// no sanitizer, sections, asynchronous unwind tables, glibc), then the
/// library's own.
fn runtimeJobs(arena: std.mem.Allocator, out: *std.ArrayList(RuntimeJob), rl: RuntimeLib, common: Common, lib: []const u8, o: Options) !void {
    const join = std.fs.path.join;
    const cxx_include = try join(arena, &.{ lib, "libcxx", "include" });
    const cxxabi_include = try join(arena, &.{ lib, "libcxxabi", "include" });
    const cxx_src_include = try join(arena, &.{ lib, "libcxx", "src" });
    const threads = !o.single_threaded;
    for ([2][]const []const u8{ rl.files, if (threads) rl.thread_files else &.{} }) |files| for (files) |file| {
        const is_cxxabi = std.mem.eql(u8, rl.name, "c++abi");
        if (is_cxxabi and !threads and std.mem.eql(u8, file, "src/cxa_thread_atexit.cpp")) continue;
        const path = try join(arena, &.{ lib, rl.dir, file });
        const lang: Lang = if (std.mem.endsWith(u8, file, ".S")) .asm_cpp else if (std.mem.endsWith(u8, file, ".c")) .c else .cpp;
        var argv: std.ArrayList([]const u8) = .empty;
        const dep_at = try appendArgs(arena, &argv, common, path, .{
            .lang = lang,
            .optimize = .fast,
            .sanitize_c = .off,
            .red_zone = true,
            .no_builtin = false,
            .pic = true,
            .pie = false,
            .function_sections = true,
            .data_sections = true,
            .unwind_tables = .async,
            .link_libc = true,
            .libcpp = false,
            .libunwind = false,
        });
        if (std.mem.eql(u8, rl.name, "unwind")) {
            switch (lang) {
                .c => try argv.appendSlice(arena, &.{ "-std=c99", "-fexceptions" }),
                .cpp => try argv.appendSlice(arena, &.{ "-fno-exceptions", "-fno-rtti" }),
                .asm_cpp => {},
            }
            try argv.appendSlice(arena, &.{ "-w", "-I", try join(arena, &.{ lib, "libunwind", "include" }), "-D_LIBUNWIND_HIDE_SYMBOLS", "-Wa,--noexecstack", "-fvisibility=hidden", "-fvisibility-inlines-hidden", "-fvisibility-global-new-delete=force-hidden", "-D_LIBUNWIND_IS_NATIVE_ONLY" });
            // The compilation's own mode, which is Debug.
            try argv.append(arena, "-D_DEBUG");
            if (!threads) try argv.append(arena, "-D_LIBUNWIND_HAS_NO_THREADS");
        } else if (is_cxxabi) {
            try argv.appendSlice(arena, common.cxx_defines);
            try argv.appendSlice(arena, &.{ "-w", "-DNDEBUG", "-D_LIBCPP_BUILDING_LIBRARY", "-D_LIBCXXABI_BUILDING_LIBRARY" });
            if (!threads) try argv.append(arena, "-D_LIBCXXABI_HAS_NO_THREADS");
            if (o.glibc_version.?.order(.{ .major = 2, .minor = 18, .patch = 0 }) != .lt) try argv.append(arena, "-DHAVE___CXA_THREAD_ATEXIT_IMPL");
            try argv.appendSlice(arena, &.{ "-fvisibility=hidden", "-fvisibility-inlines-hidden", "-nostdinc++", "-fstrict-aliasing", "-std=c++23" });
            try argv.appendSlice(arena, &.{ "-I", cxxabi_include, "-I", cxx_include, "-I", cxx_src_include });
        } else {
            try argv.appendSlice(arena, common.cxx_defines);
            try argv.appendSlice(arena, &.{ "-w", "-DNDEBUG", "-DLIBC_NAMESPACE=__llvm_libc_common_utils", "-D_LIBCPP_BUILDING_LIBRARY", "-DLIBCXX_BUILDING_LIBCXXABI", "-D_LIBCPP_HAS_NO_PRAGMA_SYSTEM_HEADER", "-fvisibility=hidden", "-fvisibility-inlines-hidden", "-faligned-allocation", "-nostdinc++", "-std=c++23" });
            try argv.appendSlice(arena, &.{ "-I", cxx_include, "-I", cxxabi_include, "-I", cxx_src_include, "-I", try join(arena, &.{ lib, "libcxx", "libc" }) });
        }
        try out.append(arena, .{ .argv = argv.items, .dep_at = dep_at });
    };
}

const Found = struct { found: ?[]const u8, looked: []const u8 };

/// Upstream zig: `ZAP_ZIG`, else `zig` on PATH, else where `.agents/setup`
/// installs it.
fn findZig(arena: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map) Found {
    const cwd = Io.Dir.cwd();
    if (environ.get("ZAP_ZIG")) |p| return .{ .found = p, .looked = p };
    if (environ.get("PATH")) |path| {
        var it = std.mem.tokenizeScalar(u8, path, ':');
        while (it.next()) |dir| {
            const p = std.fs.path.join(arena, &.{ dir, "zig" }) catch continue;
            if (cwd.access(io, p, .{ .execute = true })) |_| return .{ .found = p, .looked = p } else |_| {}
        }
    }
    const home = environ.get("HOME") orelse return .{ .found = null, .looked = "~/.cache/zap" };
    const host = @tagName(@import("builtin").cpu.arch) ++ "-" ++ @tagName(@import("builtin").os.tag);
    for ([_][]const u8{ "zig-0.17.0", "zig-" ++ host ++ "-0.17.0" }) |sub| {
        const p = std.fs.path.join(arena, &.{ home, ".cache", "zap", sub, "zig" }) catch continue;
        if (cwd.access(io, p, .{ .execute = true })) |_| return .{ .found = p, .looked = p } else |_| {}
    }
    return .{ .found = null, .looked = std.fs.path.join(arena, &.{ home, ".cache", "zap", "zig-" ++ host ++ "-0.17.0" }) catch "~/.cache/zap" };
}

/// Null when `zig` is upstream's 0.17.0, else why not.
fn checkZig(arena: std.mem.Allocator, io: Io, zig: []const u8) !?[]const u8 {
    const res = std.process.run(arena, io, .{ .argv = &.{ zig, "version" } }) catch |err|
        return try std.fmt.allocPrint(arena, "compiling C sources needs upstream zig 0.17.0; unable to run '{s}': {t}", .{ zig, err });
    const version = std.mem.trim(u8, res.stdout, " \n");
    if (res.term.success() and std.mem.eql(u8, version, "0.17.0")) return null;
    return try std.fmt.allocPrint(arena, "compiling C sources needs upstream zig 0.17.0; '{s}' is version '{s}' (set ZAP_ZIG to upstream 0.17.0)", .{ zig, version });
}

/// Clang's errors and their notes, as diagnostics: `path:line:col: error:
/// message` lines (`-fno-caret-diagnostics`), or all of stderr when none
/// parses.
fn clangErrors(arena: std.mem.Allocator, paths: diag.Paths, source: []const u8, stderr: []const u8, out: *std.ArrayList(diag.Diagnostic)) !void {
    const first = out.items.len;
    var notes: std.ArrayList(diag.Note) = .empty;
    var it = std.mem.splitScalar(u8, stderr, '\n');
    while (it.next()) |line| {
        const kind, const loc, const msg = parseLine(arena, paths, line) orelse continue;
        switch (kind) {
            .err => {
                if (out.items.len > first) out.items[out.items.len - 1].notes = try notes.toOwnedSlice(arena);
                try out.append(arena, .{ .loc = loc, .msg = msg });
            },
            .note => if (out.items.len > first) try notes.append(arena, .{ .loc = loc, .msg = msg }),
        }
    }
    if (out.items.len > first) {
        out.items[out.items.len - 1].notes = try notes.toOwnedSlice(arena);
    } else {
        try out.append(arena, .{ .loc = null, .msg = try std.fmt.allocPrint(arena, "unable to compile '{s}': {s}", .{ source, std.mem.trimEnd(u8, stderr, "\n") }) });
    }
}

fn parseLine(arena: std.mem.Allocator, paths: diag.Paths, line: []const u8) ?struct { enum { err, note }, ?diag.Loc, []const u8 } {
    inline for (.{ .{ ": error: ", .err }, .{ ": fatal error: ", .err }, .{ ": note: ", .note } }) |k| {
        if (std.mem.indexOf(u8, line, k[0])) |at| {
            const msg = line[at + k[0].len ..];
            return .{ k[1], locOf(arena, paths, line[0..at]), msg };
        }
    }
    if (std.mem.startsWith(u8, line, "error: ")) return .{ .err, null, line["error: ".len..] };
    return null;
}

/// `path:line:col` as a location in the file, read again.
fn locOf(arena: std.mem.Allocator, paths: diag.Paths, text: []const u8) ?diag.Loc {
    var it = std.mem.splitBackwardsScalar(u8, text, ':');
    const col = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const line = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const path = it.rest();
    if (line == 0 or col == 0) return null;
    const source = Io.Dir.cwd().readFileAlloc(paths.io, path, arena, .limited(64 << 20)) catch return null;
    var offset: usize = 0;
    var l: u32 = 1;
    while (l < line) : (l += 1) offset = (std.mem.indexOfScalarPos(u8, source, offset, '\n') orelse return null) + 1;
    offset = @min(offset + col - 1, source.len);
    const o: u32 = @intCast(offset);
    return paths.loc(arena, path, source, o, o, o, false) catch null;
}
