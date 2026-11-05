//! C and C++ source files, compiled by upstream's Clang (`zig clang`) with
//! the arguments upstream's `Compilation.addCCArgs` gives them for bs's
//! target and the baseline CPU, in Debug (docs/slop/architecture.md, "C
//! interop"). bs never compiles C or C++ itself. With `-lc++`, an
//! executable also links libc++, libc++abi and libunwind, which this file
//! builds from the zig lib directory's sources as upstream's
//! `libs/libcxx.zig` and `libs/libunwind.zig` do, once per configuration,
//! into the global cache.
//!
//! The compiles start before analysis and run while Sema does; the build
//! adds their objects to its link inputs at its first sync point
//! (`Emit.sync`), before it pulls archive members and compiler_rt for
//! them. Each object has a record in `<local cache>/bs/tc/` (ToolRecord),
//! keyed by bs, upstream zig, the arguments and the source, which lists
//! the headers Clang read: a build whose files all stat as recorded runs
//! nothing.

const std = @import("std");
const Io = std.Io;
const cache = @import("cache.zig");
const diag = @import("diag.zig");
const ToolRecord = @import("ToolRecord.zig");
const toolchain = @import("toolchain.zig");
const cpu_mod = @import("cpu.zig");
const ar = @import("link/Archive.zig");
const Incremental = @import("Incremental.zig");
const main = @import("main.zig");
const Musl = @import("Musl.zig");

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
    /// `.m`: Objective-C, which takes C's arguments, as upstream's.
    objc,
    /// `.mm` and `.M`: Objective-C++, which takes C's arguments too
    /// (upstream adds `-nostdinc++` only for C++ proper).
    objcpp,
    /// `.S`: assembly through the C preprocessor.
    asm_cpp,
    /// `.s`: assembly as is, without include directories, defines or a
    /// depfile, as upstream's `.assembly`.
    assembly,

    /// The language of a source file argument, by its extension, or null
    /// if it is not one bs compiles.
    pub fn ofPath(path: []const u8) ?Lang {
        const ext = Io.Dir.path.extension(path);
        if (std.mem.eql(u8, ext, ".c")) return .c;
        for ([_][]const u8{ ".C", ".cc", ".cpp", ".cxx", ".stub", ".c++" }) |e| if (std.mem.eql(u8, ext, e)) return .cpp;
        if (std.mem.eql(u8, ext, ".m")) return .objc;
        if (std.mem.eql(u8, ext, ".mm") or std.mem.eql(u8, ext, ".M")) return .objcpp;
        if (std.mem.eql(u8, ext, ".S")) return .asm_cpp;
        if (std.mem.eql(u8, ext, ".s")) return .assembly;
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

    /// The sanitizer mode, as upstream's `Module.create` defaults it:
    /// full in Debug, trapping in ReleaseSafe, none in ReleaseFast and
    /// ReleaseSmall.
    pub fn sanitizeC(f: Flags) std.zig.SanitizeC {
        return f.sanitize_c orelse switch (f.optimize orelse .debug) {
            .debug => .full,
            .safe => .trap,
            .fast, .small => .off,
        };
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
    /// `-mcpu` (`cpu.resolve`).
    cpu: std.Target.Cpu = cpu_mod.baseline,
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
    /// A musl target (`x86_64-linux` is one): the triple's ABI, and with
    /// `link_libc` musl's headers, no PIC and libc++'s musl configuration.
    musl: bool = false,
    /// An executable linking musl (`main.Options.musl`): build (or find)
    /// musl's crt1.o and libc.a (Musl.zig) and link them, as upstream
    /// does, but crt1.o after the C objects (`objectPaths`) and libc.a
    /// after the other libraries.
    musl_libc: bool = false,
    /// Where the runtime libraries go: `<global>/bs/o/<key>/`.
    global_cache: []const u8 = "",
    single_threaded: bool = false,
    /// Upstream's default stack protector for the compilation's C: with
    /// libc, unless its Zig code goes through the self-hosted backend,
    /// which has none (`Module.create`): a library of C only, or `-fllvm`.
    stack_protector: bool = false,
    /// A shared library's sources are position-independent, as upstream
    /// requires (`requiresPIC`).
    pic: bool = false,
    pie: bool,
    function_sections: bool,
    data_sections: bool,
    unwind_tables: std.lang.UnwindTables,
    /// `cc_argv` left after the last `-M`, before every module's own.
    global_cc_argv: []const []const u8,
    /// `-isystem` directories after libc's (`main.Options.c_native_includes`).
    native_includes: []const []const u8 = &.{},
    /// The native ABI (no `-target`): libc's headers are the system's
    /// (`libcIncludeDirs`).
    native_abi: bool = false,
    /// `--verbose-cc`.
    verbose: bool = false,
    /// aarch64-macos (apple_m1 and libSystem's headers, which every
    /// compile sees, as Darwin always links libc), not x86_64-linux.
    macos: bool = false,
    /// With `macos`: the macOS versions (`-mmacos-version-min`).
    macos_version: std.SemanticVersion.Range = undefined,
};

/// The compiles of one build, running while it analyzes.
pub const Batch = struct {
    gpa: std.mem.Allocator,
    io: Io,
    jobs: []Job,
    /// The C++ runtime libraries an executable links (`Options.cxx_runtime`).
    archives: []Archive = &.{},
    /// The tool directories of the runtime libraries found in the global
    /// cache, held until `destroy` so that maintenance keeps them
    /// (`cache.useTool`).
    tool_locks: std.ArrayList(Io.File) = .empty,
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
    /// The batch's summary (`Summary`): where it goes, whether this build
    /// took the sources' objects from it instead of their records, and
    /// then the files they read, each once, zero-separated.
    summary_path: []const u8 = "",
    summary_hit: bool = false,
    summary_inputs: []const u8 = "",
    start_ns: i96 = 0,

    const Zig = union(enum) { path: []const u8, missing: []const u8 };

    const Job = struct {
        arena: std.heap.ArenaAllocator,
        source: []const u8,
        abs_source: []const u8,
        /// Clang's arguments, without the depfile and output paths, which
        /// go at `dep_at` and the end.
        argv: []const []const u8,
        dep_at: usize,
        /// Whether Clang writes a depfile; not for `.s` sources, whose
        /// records hold only the source.
        depfile: bool = true,
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
            /// bs could not run it.
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
        /// The library is its one object (musl's crt1.o), linked as an
        /// object (`Result.runtime_objects`).
        object: bool = false,
    };

    pub const Result = struct {
        /// In command-line order.
        objects: []const Object,
        /// The C++ runtime libraries, in link order.
        archives: []const Object = &.{},
        /// The runtime libraries that are one object (musl's crt1.o),
        /// linked after `objects`, before `archives`.
        runtime_objects: []const Object = &.{},
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
            j.state = .{ .err = j.arena.allocator().print("unable to compile '{s}': {t}", .{ j.source, err }) catch "out of memory" };
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
        const dep_path, const tmp_out = if (j.archive != null) .{ try arena.print("{s}.d", .{j.out_path}), j.out_path } else paths: {
            const tmp_dir = try Io.Dir.path.join(arena, &.{ Io.Dir.path.dirname(Io.Dir.path.dirname(j.record_path).?).?, "tmp" });
            try Io.Dir.cwd().createDirPath(io, tmp_dir);
            var rand: [8]u8 = undefined;
            io.random(&rand);
            const tmp_base = try Io.Dir.path.join(arena, &.{ tmp_dir, &std.fmt.bytesToHex(rand, .lower) });
            break :paths .{ try arena.print("{s}-cc.d", .{tmp_base}), try arena.print("{s}-cc.o", .{tmp_base}) };
        };
        defer Io.Dir.cwd().deleteFile(io, dep_path) catch {};
        defer if (j.archive == null) Io.Dir.cwd().deleteFile(io, tmp_out) catch {};
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(arena, zig);
        try argv.appendSlice(arena, j.argv[1..j.dep_at]);
        if (j.depfile) try argv.appendSlice(arena, &.{ "-MD", "-MV", "-MF", dep_path });
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
            j.state = .{ .failed = if (res.stderr.len != 0) try arena.dupe(u8, res.stderr) else try arena.print("clang failed ({f})", .{res.term}) };
            return;
        }
        if (j.archive != null) {
            j.state = .done;
            return;
        }
        // Warnings print as upstream's `zig cc` would; upstream's build
        // drops them, so only `BS_CC_WARNINGS` shows them.
        j.inputs = try ToolRecord.commit(arena, io, .{
            .record_path = j.record_path,
            .out_path = j.out_path,
            .tmp_out = tmp_out,
            .dep_path = if (j.depfile) dep_path else "",
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
        try inputs.appendSlice(arena, b.summary_inputs);
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
                        try errors.append(arena, .{ .loc = null, .msg = try arena.print("unable to read the object of '{s}' ({s}): {t}", .{ j.source, j.out_path, err }) });
                        continue;
                    };
                    try objects.append(arena, .{ .path = try arena.dupe(u8, j.out_path), .bytes = bytes, .member = try arena.dupe(u8, Io.Dir.path.basename(j.out_path)) });
                },
                .failed => |stderr| try clangErrors(arena, paths, j.source, stderr, &errors),
                .err => |msg| try errors.append(arena, .{ .loc = null, .msg = try arena.dupe(u8, msg) }),
            }
        }
        var archives: std.ArrayList(Object) = .empty;
        var runtime_objects: std.ArrayList(Object) = .empty;
        for (b.archives) |a| {
            if (a.len != 0) {
                b.writeArchive(arena, a) catch |err| {
                    try errors.append(arena, .{ .loc = null, .msg = try arena.print("unable to build '{s}': {t}", .{ a.path, err }) });
                    continue;
                };
            }
            const bytes = Io.Dir.cwd().readFileAlloc(b.io, a.path, arena, .unlimited) catch |err| {
                try errors.append(arena, .{ .loc = null, .msg = try arena.print("unable to read '{s}': {t}", .{ a.path, err }) });
                continue;
            };
            try (if (a.object) &runtime_objects else &archives).append(arena, .{ .path = a.path, .bytes = bytes, .member = Io.Dir.path.basename(a.path) });
        }
        b.result = .{ .objects = objects.items, .archives = archives.items, .runtime_objects = runtime_objects.items, .errors = errors.items, .inputs = inputs.items };
        if (errors.items.len == 0) b.writeSummary();
        return &b.result.?;
    }

    /// Writes the batch's summary (`Summary`) when every source's object is
    /// done and no file is too new to trust its mtime; else the next build
    /// checks the records. Best effort.
    pub fn writeSummary(b: *Batch) void {
        b.writeSummaryOrFail() catch {}; // ziglint-ignore: Z026 -- cache upkeep is best effort
    }

    fn writeSummaryOrFail(b: *Batch) !void {
        if (b.summary_hit or b.summary_path.len == 0) return;
        const io = b.io;
        var arena_state: std.heap.ArenaAllocator = .init(b.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var entries: std.ArrayList(Summary.Entry) = .empty;
        var paths: std.ArrayList(u8) = .empty;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        var objects: u32 = 0;
        // Objects need no racy window: a changed one is renamed into place,
        // a new inode.
        for (b.jobs) |j| if (j.archive == null) {
            if (j.state != .done) return;
            try Summary.add(arena, io, null, &entries, &paths, j.out_path);
            objects += 1;
        };
        for (b.jobs) |j| if (j.archive == null) {
            var it = std.mem.splitScalar(u8, j.inputs, 0);
            while (it.next()) |p| if (p.len != 0 and !(try seen.getOrPut(arena, p)).found_existing)
                try Summary.add(arena, io, b.start_ns, &entries, &paths, p);
        };
        const header: Summary.Header = .{ .objects = objects, .files = @intCast(entries.items.len), .paths_len = @intCast(paths.items.len) };
        try Io.Dir.cwd().createDirPath(io, Io.Dir.path.dirname(b.summary_path).?);
        try cache.writeReplace(io, Io.Dir.cwd(), b.summary_path, &.{ std.mem.asBytes(&header), std.mem.sliceAsBytes(entries.items), paths.items });
    }

    /// Archives a runtime library's objects into the global cache, unless
    /// one of them failed to compile (its error is reported already).
    fn writeArchive(b: *Batch, arena: std.mem.Allocator, a: Archive) !void {
        const io = b.io;
        defer Io.Dir.cwd().deleteTree(io, a.tmp_dir) catch {};
        const jobs = b.jobs[a.first..][0..a.len];
        for (jobs) |j| if (j.state != .done) return error.CompileFailed;
        if (a.object) {
            try Io.Dir.cwd().createDirPath(io, Io.Dir.path.dirname(a.path).?);
            if (cache.useTool(io, Io.Dir.path.dirname(a.path).?)) |use| {
                b.tool_locks.append(b.gpa, use) catch |err| {
                    use.close(io);
                    return err;
                };
            } else |_| {}
            const bytes = try Io.Dir.cwd().readFileAlloc(io, jobs[0].out_path, arena, .unlimited);
            return cache.writeReplace(io, Io.Dir.cwd(), a.path, &.{bytes});
        }
        const members = try arena.alloc(ar.Input, jobs.len);
        for (members, jobs) |*m, j| m.* = .{ .name = Io.Dir.path.basename(j.out_path), .bytes = try Io.Dir.cwd().readFileAlloc(io, j.out_path, arena, .unlimited) };
        try Io.Dir.cwd().createDirPath(io, Io.Dir.path.dirname(a.path).?);
        // Marked as a tool, and held until the batch reads it.
        if (cache.useTool(io, Io.Dir.path.dirname(a.path).?)) |use| {
            b.tool_locks.append(b.gpa, use) catch |err| {
                use.close(io);
                return err;
            };
        } else |_| {}
        try ar.write(b.gpa, io, Io.Dir.cwd(), a.path, members);
    }
};

/// Where the objects are, in command-line order, compiled or not yet:
/// a record's output keeps its path across edits of the source. Then the
/// runtime libraries (musl's crt1.o first), whose paths name their
/// configuration.
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
    if (b.summary_hit) return b.summary_inputs;
    var inputs: std.ArrayList(u8) = .empty;
    for (b.jobs) |j| if (j.inputs.len != 0) {
        if (inputs.items.len != 0) try inputs.append(arena, 0);
        try inputs.appendSlice(arena, j.inputs);
    };
    return inputs.items;
}

/// A batch's summary, `<local cache>/bs/cb/<key>`: its sources' objects
/// in order, then every file their records list, each once, with the
/// stats (inode, size, mtime) they had when a build found every object
/// done. A build whose files all still stat so takes the objects without
/// computing Clang's arguments or reading a record (SDL3: 473 records
/// listing 190k files, a few thousand distinct). The key covers bs,
/// since bs's code turns the options into the records' keys, upstream
/// zig, the working and lib directories, the target's common Clang
/// arguments, the options and every source.
/// A summary older than `renew_ns` is not used, so that a build checks
/// the records again and renews their mtimes, by which the cache trims.
const Summary = struct {
    const magic = "ZAPCB001".*;
    const renew_ns = std.time.ns_per_hour;
    const Header = extern struct { magic: [8]u8 = magic, objects: u32, files: u32, paths_len: u32, _pad: u32 = 0 };
    const Entry = extern struct { inode: u64, size: u64, mtime: i64, path_len: u32, _pad: u32 = 0 };

    fn path(arena: std.mem.Allocator, io: Io, cwd: []const u8, local: []const u8, lib: []const u8, zig_id: []const u8, common: Common, sources: []const CSource, o: Options) ![]const u8 {
        _, const bs_key = try Incremental.compilationKey(arena, io, &.{}, lib, "c batch");
        var h: std.crypto.hash.Blake3 = .init(.{});
        h.update(std.mem.asBytes(&bs_key));
        h.update(zig_id);
        h.update(cwd);
        std.hash.autoHashStrat(&h, common, .DeepRecursive);
        std.hash.autoHashStrat(&h, o, .DeepRecursive);
        std.hash.autoHashStrat(&h, sources, .DeepRecursive);
        var key: [16]u8 = undefined;
        h.final(&key);
        return Io.Dir.path.join(arena, &.{ local, "bs", "cb", &std.fmt.bytesToHex(key, .lower) });
    }

    /// Appends file `p` with its stat, unless its mtime is too new to
    /// trust (ToolRecord's racy window).
    fn add(arena: std.mem.Allocator, io: Io, start_ns: ?i96, entries: *std.ArrayList(Entry), paths: *std.ArrayList(u8), p: []const u8) !void {
        const st = try Io.Dir.cwd().statFile(io, p, .{});
        if (start_ns) |ns| if (st.mtime.toNanoseconds() >= ns - 2 * std.time.ns_per_s) return error.RacyMtime;
        try entries.append(arena, .{ .inode = @intCast(st.inode), .size = st.size, .mtime = @intCast(st.mtime.toNanoseconds()), .path_len = @intCast(p.len) });
        try paths.appendSlice(arena, p);
    }

    /// Takes the sources' objects from the summary if every file stats as
    /// it records.
    fn check(b: *Batch, arena: std.mem.Allocator, sources: []const CSource) !bool {
        const io = b.io;
        const cwd = Io.Dir.cwd();
        const st = cwd.statFile(io, b.summary_path, .{}) catch return false;
        if (b.start_ns - st.mtime.toNanoseconds() > renew_ns) return false;
        const bytes = cwd.readFileAlloc(io, b.summary_path, arena, .limited(64 << 20)) catch return false;
        if (bytes.len < @sizeOf(Header)) return false;
        const header = std.mem.bytesToValue(Header, bytes[0..@sizeOf(Header)]);
        const entries_end = @sizeOf(Header) + @as(usize, header.files) * @sizeOf(Entry);
        if (!std.mem.eql(u8, &header.magic, &magic) or header.objects != sources.len or header.files < header.objects or
            bytes.len != entries_end + header.paths_len) return false;
        const entries = try arena.alloc(Entry, header.files);
        @memcpy(std.mem.sliceAsBytes(entries), bytes[@sizeOf(Header)..entries_end]);
        const paths = bytes[entries_end..];
        var at: usize = 0;
        for (entries) |e| {
            if (e.path_len > paths.len - at) return false;
            const fst = cwd.statFile(io, paths[at..][0..e.path_len], .{}) catch return false;
            at += e.path_len;
            if (e.inode != fst.inode or e.size != fst.size or e.mtime != fst.mtime.toNanoseconds()) return false;
        }
        at = 0;
        for (entries[0..header.objects], sources, b.jobs[0..sources.len]) |e, src, *j| {
            j.* = .{
                .arena = j.arena,
                .source = src.path,
                .abs_source = src.path,
                .argv = &.{},
                .dep_at = 0,
                .record_path = "",
                .out_path = paths[at..][0..e.path_len],
                .start_ns = b.start_ns,
                .state = .done,
            };
            at += e.path_len;
        }
        var inputs: std.ArrayList(u8) = .empty;
        for (entries[header.objects..]) |e| {
            if (inputs.items.len != 0) try inputs.append(arena, 0);
            try inputs.appendSlice(arena, paths[at..][0..e.path_len]);
            at += e.path_len;
        }
        b.summary_inputs = inputs.items;
        return true;
    }
};

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
    errdefer b.result_arena.deinit();
    errdefer {
        for (b.tool_locks.items) |f| f.close(io);
        b.tool_locks.deinit(gpa);
    }
    const ra = b.result_arena.allocator();
    b.paths = try .init(ra, io, o.zig_lib_dir);
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const s = scratch.allocator();
    const cwd_path = try std.process.currentPathAlloc(io, s);
    const lib = try Io.Dir.path.resolveAlloc(ra, &.{ cwd_path, o.zig_lib_dir });
    const local = try Io.Dir.path.resolveAlloc(s, &.{ cwd_path, o.local_cache });
    const start_ns = Io.Clock.real.now(io).toNanoseconds();

    const zig = toolchain.findZig(s, io, environ);
    // Upstream zig's identity goes into the key: another Clang compiles
    // other bytes.
    const zig_id = if (zig.found) |p| id: {
        const st = Io.Dir.cwd().statFile(io, p, .{}) catch break :id "";
        break :id try s.print("{s}\x00{d}\x00{d}\x00{d}", .{ p, st.inode, st.size, st.mtime.toNanoseconds() });
    } else "";
    const target = if (o.macos) try macosTarget(io, o.macos_version) else try cTarget(io, o.glibc_version, o.musl, o.cpu);
    const common = try commonArgs(ra, io, environ, &target, lib, o);

    // The runtime libraries first, to know how many of their sources to
    // compile.
    var runtime: std.ArrayList(RuntimeJob) = .empty;
    var archives: std.ArrayList(Batch.Archive) = .empty;
    // crt1.o first: it is the one runtime library linked as an object, and
    // `objectPaths` and `Emit.sync` link the objects before the archives.
    for ([_]RuntimeLib{musl_crt1} ++ runtime_libs ++ [_]RuntimeLib{ nonshared_lib, musl_libc }) |rl| {
        const is_nonshared = std.mem.eql(u8, rl.name, nonshared_lib.name);
        const is_musl = rl.musl;
        if (!(if (is_nonshared) o.libc_nonshared and zig.found != null else if (is_musl) o.musl_libc else o.cxx_runtime)) continue;
        const first = runtime.items.len;
        if (is_nonshared)
            try nonsharedJobs(ra, &runtime, common, lib, o)
        else if (is_musl)
            try muslJobs(ra, &runtime, rl, common, lib, o)
        else
            try runtimeJobs(ra, &runtime, rl, common, lib, o);
        // Keyed by upstream zig and every compile's arguments, which name
        // the lib directory's sources; not by bs, whose rebuilds do not
        // change the library.
        var h: std.ArrayList(u8) = .empty;
        try h.print(s, "bs c++ runtime 1\x00{s}\x00{s}\x00", .{ zig_id, rl.name });
        for (runtime.items[first..]) |rj| for (rj.argv) |a| try h.print(s, "{s}\x00", .{a});
        const hex = std.fmt.bytesToHex(@as([16]u8, @bitCast(cache.hash(2, h.items))), .lower);
        const path = try Io.Dir.path.join(ra, &.{ o.global_cache, "bs", "o", &hex, if (rl.object) try s.print("{s}.o", .{rl.name}) else try s.print("lib{s}.a", .{rl.name}) });
        const found = found: {
            const use = cache.useTool(io, Io.Dir.path.dirname(path).?) catch break :found false;
            Io.Dir.cwd().access(io, path, .{}) catch {
                use.close(io);
                break :found false;
            };
            b.tool_locks.append(gpa, use) catch |err| {
                use.close(io);
                return err;
            };
            break :found true;
        };
        if (found) {
            runtime.shrinkRetainingCapacity(first);
            try archives.append(ra, .{ .path = path, .object = rl.object });
        } else if (is_nonshared and sources.len == 0 and !o.cxx_runtime and try checkZig(s, io, zig.found.?) != null) {
            // A build of Zig only does not fail for want of upstream zig
            // 0.17.1; it links without libc_nonshared.a, as before.
            runtime.shrinkRetainingCapacity(first);
        } else {
            var rand: [8]u8 = undefined;
            io.random(&rand);
            const tmp_dir = try Io.Dir.path.join(ra, &.{ o.global_cache, "bs", "tmp", try s.print("{s}-{s}", .{ rl.name, &std.fmt.bytesToHex(rand, .lower) }) });
            try Io.Dir.cwd().createDirPath(io, tmp_dir);
            try archives.append(ra, .{ .path = path, .tmp_dir = tmp_dir, .first = sources.len + first, .len = runtime.items.len - first, .object = rl.object });
        }
    }
    b.archives = archives.items;
    b.jobs = try gpa.alloc(Batch.Job, sources.len + runtime.items.len);
    for (b.jobs) |*j| j.arena = .init(gpa);

    var misses: usize = 0;
    var stats: ToolRecord.Stats = .empty;
    b.start_ns = start_ns;
    if (sources.len != 0) {
        b.summary_path = try Summary.path(ra, io, cwd_path, local, lib, zig_id, common, sources, o);
        b.summary_hit = try Summary.check(b, ra, sources);
        if (b.summary_hit and environ.get("BS_CACHE_TIMING") != null)
            std.debug.print("cache: {d} C objects from the batch summary\n", .{sources.len});
    }
    if (!b.summary_hit) for (sources, b.jobs[0..sources.len]) |src, *j| {
        const arena = j.arena.allocator();
        var argv: std.ArrayList([]const u8) = .empty;
        const dep_at = try appendArgs(arena, &argv, common, src.path, .{
            .lang = src.lang,
            .optimize = src.flags.optimize orelse .debug,
            // As upstream's `Module.create`: trapping in ReleaseSafe, none
            // in ReleaseFast and ReleaseSmall.
            .sanitize_c = src.flags.sanitizeC(),
            .red_zone = src.flags.red_zone orelse true,
            .no_builtin = src.flags.no_builtin orelse false,
            .stack_protector = o.link_libc and (src.flags.stack_protector orelse o.stack_protector),
            // glibc and shared libraries require PIC (`requiresPic`); else
            // (musl too) the module's, default off.
            .pic = (o.link_libc and !o.musl) or o.pic or (src.flags.pic orelse false),
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
        const abs_source = try Io.Dir.path.resolveAlloc(arena, &.{ cwd_path, src.path });

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
            .depfile = src.lang != .assembly,
            .record_path = try Io.Dir.path.join(arena, &.{ local, "bs", "tc", &hex }),
            .out_path = try Io.Dir.path.join(arena, &.{ local, "o", &hex, try arena.print("{s}.o", .{Io.Dir.path.stem(src.path)}) }),
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
    };
    for (archives.items, 0..) |a, ai| if (a.len != 0) {
        // Members are named after their sources' stems; a stem that comes
        // again (musl's two `clone` sources) goes into a directory of its
        // own, as upstream's objects each go into their own.
        var stems: std.StringHashMapUnmanaged(u32) = .empty;
        for (runtime.items[a.first - sources.len ..][0..a.len], b.jobs[a.first..][0..a.len]) |rj, *j| {
            const stem = Io.Dir.path.stem(rj.argv[2]);
            const seen = try stems.getOrPut(s, stem);
            seen.value_ptr.* = if (seen.found_existing) seen.value_ptr.* + 1 else 0;
            const dir = if (seen.value_ptr.* == 0) a.tmp_dir else try ra.print("{s}/{d}", .{ a.tmp_dir, seen.value_ptr.* });
            if (seen.value_ptr.* != 0) try Io.Dir.cwd().createDirPath(io, dir);
            j.* = .{
                .arena = j.arena,
                .source = rj.argv[2],
                .abs_source = rj.argv[2],
                .argv = rj.argv,
                .dep_at = rj.dep_at,
                .depfile = !std.mem.endsWith(u8, rj.argv[2], ".s"),
                .record_path = "",
                .out_path = try Io.Dir.path.join(ra, &.{ dir, try ra.print("{s}.o", .{stem}) }),
                .archive = @intCast(ai),
                .start_ns = start_ns,
            };
            misses += 1;
        }
    };
    // Only a build that compiles C needs upstream zig, and checks its
    // version once.
    b.zig = if (misses == 0) .{ .path = "" } else if (zig.found) |p|
        if (try checkZig(s, io, p)) |msg| .{ .missing = try gpa.dupe(u8, msg) } else .{ .path = try gpa.dupe(u8, p) }
    else
        .{ .missing = try gpa.print("compiling C sources needs upstream zig 0.17.1; bs looked for it in BS_ZIG, as 'zig' on PATH, and in {s}", .{zig.looked}) };
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
    for (b.tool_locks.items) |f| f.close(b.io);
    b.tool_locks.deinit(gpa);
    b.result_arena.deinit();
    gpa.destroy(b);
}

/// The target C compiles for: `cpu`'s architecture, glibc's version names
/// the ABI, as the native target does upstream, and `cpu` is the
/// compilation's (`-mcpu`).
pub fn cTarget(io: Io, glibc_version: ?std.SemanticVersion, musl: bool, cpu: std.Target.Cpu) !std.Target {
    var buf: [64]u8 = undefined;
    const text = if (glibc_version) |v| try std.mem.print(&buf, "{t}-linux-gnu.{f}", .{ cpu.arch, v }) else try std.mem.print(&buf, "{t}-linux-{s}", .{ cpu.arch, if (musl) "musl" else "none" });
    const query = try std.Target.Query.parse(.{ .arch_os_abi = text, .cpu_features = "baseline" });
    var target = try std.zig.system.resolveTargetQuery(io, query);
    target.cpu = cpu;
    return target;
}

/// aarch64-macos for the macOS `versions` (`main.Options.macos_version`)
/// and apple_m1, which bs's own code is generated for.
pub fn macosTarget(io: Io, versions: std.SemanticVersion.Range) !std.Target {
    return std.zig.system.resolveTargetQuery(io, .{
        .cpu_arch = .aarch64,
        .os_tag = .macos,
        .os_version_min = .{ .semver = versions.min },
        .os_version_max = .{ .semver = versions.max },
        .abi = .none,
    });
}

/// The arguments that depend only on the target and the lib directory.
const Common = struct {
    triple: []const u8,
    /// `-mmacos-version-min=<min>` and the flag that quiets Clang about
    /// the triple's version too, as upstream passes on Darwin.
    os_args: []const []const u8 = &.{},
    /// `-D__GLIBC_MINOR__=<n>` with `-lc`.
    glibc_minor: []const u8,
    lib: []const u8,
    /// The glibc headers' `-isystem` pairs, with `-lc`.
    libc_includes: []const []const u8,
    /// The macOS SDK's `-iframework` pair, with its headers.
    libc_frameworks: []const []const u8,
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

fn commonArgs(arena: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, target: *const std.Target, lib: []const u8, o: Options) !Common {
    var libc_includes: std.ArrayList([]const u8) = .empty;
    var libc_frameworks: std.ArrayList([]const u8) = .empty;
    if (o.link_libc) {
        const dirs = try libcIncludeDirs(arena, io, environ, o.global_cache, lib, target, o.native_abi);
        for (dirs.includes) |d| try libc_includes.appendSlice(arena, &.{ "-isystem", d });
        for (dirs.frameworks) |d| try libc_frameworks.appendSlice(arena, &.{ "-iframework", d });
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
        const f = try arena.print("{c}{s}", .{ "-+"[@intFromBool(on)], name });
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
        if (o.musl) "-D_LIBCPP_HAS_MUSL_LIBC=1" else "-D_LIBCPP_HAS_MUSL_LIBC=0",
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
    const os_args: []const []const u8 = if (o.macos) os: {
        const min = target.os.version_range.semver.min;
        // In the arena: a literal with a runtime element would be a
        // temporary that dies with this block.
        break :os try arena.dupe([]const u8, &.{ try arena.print("-mmacos-version-min={d}.{d}.{d}", .{ min.major, min.minor, min.patch }), "-Wno-overriding-option" });
    } else &.{};
    return .{
        .os_args = os_args,
        .triple = try std.zig.llvm.Builder.tripleForTarget(arena, target),
        .glibc_minor = if (o.glibc_version) |v| try arena.print("-D__GLIBC_MINOR__={d}", .{v.minor}) else "",
        .lib = lib,
        .libc_includes = libc_includes.items,
        .libc_frameworks = libc_frameworks.items,
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
    const assembly = m.lang == .asm_cpp or m.lang == .assembly;
    if (!assembly) try argv.append(arena, "-fno-caret-diagnostics");
    try argv.appendSlice(arena, &.{ "-target", common.triple });
    try argv.appendSlice(arena, &.{ if (m.pie) "-fPIE" else "-fno-PIE", if (m.pic) "-fPIC" else "-fno-PIC" });
    try argv.appendSlice(arena, common.os_args);
    try argv.appendSlice(arena, &.{ "-gdwarf-4", "-gdwarf32", "-fno-lto" });
    const dep_at = argv.items.len;
    // Assembly as is takes no preprocessor or code generation flags, only
    // the assembler's CPU features.
    if (m.lang == .assembly) {
        try argv.appendSlice(arena, common.asm_features);
        return dep_at;
    }
    try argv.appendSlice(arena, &.{ "-fhosted", "-nostdinc" });
    if (m.lang == .cpp) try argv.append(arena, "-nostdinc++");
    switch (m.optimize) {
        .debug => {},
        .safe => try argv.append(arena, "-D_FORTIFY_SOURCE=2"),
        .fast, .small => try argv.append(arena, "-DNDEBUG"),
    }
    if (m.link_libc and common.glibc_minor.len != 0) try argv.append(arena, common.glibc_minor);
    if (m.libcpp) {
        try argv.appendSlice(arena, &.{ "-isystem", try Io.Dir.path.join(arena, &.{ common.lib, "libcxx", "include" }), "-isystem", try Io.Dir.path.join(arena, &.{ common.lib, "libcxxabi", "include" }) });
        try argv.appendSlice(arena, common.cxx_defines);
    }
    try argv.appendSlice(arena, &.{ "-isystem", try Io.Dir.path.join(arena, &.{ common.lib, "include" }) });
    if (m.link_libc) try argv.appendSlice(arena, common.libc_includes);
    if (m.native) try argv.appendSlice(arena, common.native_includes);
    if (m.libunwind) try argv.appendSlice(arena, &.{ "-isystem", try Io.Dir.path.join(arena, &.{ common.lib, "libunwind", "include" }) });
    if (m.link_libc) try argv.appendSlice(arena, common.libc_frameworks);
    if (!assembly) {
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
// Copyright (c) Zig contributors. MIT licensed (see LICENSE-ZIG).

const RuntimeLib = struct {
    /// `lib<name>.a`, or `<name>.o` for an object.
    name: []const u8,
    /// One object, linked as an object, not an archive.
    object: bool = false,
    /// musl's (`muslJobs`).
    musl: bool = false,
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
/// for x86_64-linux-gnu and aarch64-linux-gnu: the functions glibc's libc.so leaves to every
/// executable (`atexit` calls `__cxa_atexit` with its `__dso_handle`).
/// Upstream builds and links it with every glibc executable; bs only
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
    "io/stat-2.32.c",    "io/fstat-2.32.c",   "io/lstat-2.32.c",   "io/stat64-2.32.c",
    "io/fstat64-2.32.c", "io/lstat64-2.32.c", "io/fstatat-2.32.c", "io/fstatat64-2.32.c",
    "io/mknodat-2.32.c", "io/mknod-2.32.c",
};

/// Appends libc_nonshared.a's compiles, with upstream's flags: its
/// sub-compilation's (ReleaseFast, PIC, no sanitizer or stack protector,
/// no libc), then glibc's own build flags.
fn nonsharedJobs(arena: std.mem.Allocator, out: *std.ArrayList(RuntimeJob), common: Common, lib: []const u8, o: Options) !void {
    const join = Io.Dir.path.join;
    const v = o.glibc_version.?;
    const old_stat = v.order(.{ .major = 2, .minor = 32, .patch = 0 }) != .gt;
    const old_init = v.order(.{ .major = 2, .minor = 33, .patch = 0 }) != .gt;
    const g = try join(arena, &.{ lib, "libc", "glibc" });
    const sd = try join(arena, &.{ g, "sysdeps" });
    const linux = try join(arena, &.{ sd, "unix", "sysv", "linux" });
    // `add_include_dirs` for x86_64-linux-gnu and aarch64-linux-gnu: the
    // architecture's directories, then x86's for x86_64.
    const a64 = o.cpu.arch == .aarch64;
    const arch: []const u8 = if (a64) "aarch64" else "x86_64";
    var includes: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{
        try join(arena, &.{ g, "include" }),
        try join(arena, &.{ linux, arch }),
        if (a64) "" else try join(arena, &.{ linux, "x86" }),
        try join(arena, &.{ sd, arch, "nptl" }),
        if (a64) "" else try join(arena, &.{ sd, "x86", "nptl" }),
        try join(arena, &.{ linux, "generic" }),
        try join(arena, &.{ linux, "include" }),
        linux,
        try join(arena, &.{ sd, "nptl" }),
        try join(arena, &.{ sd, "pthread" }),
        try join(arena, &.{ sd, "unix", "sysv" }),
        try join(arena, &.{ sd, "unix", arch }),
        if (a64) "" else try join(arena, &.{ sd, "unix", "x86" }),
        try join(arena, &.{ sd, "unix" }),
        try join(arena, &.{ sd, arch }),
        if (a64) "" else try join(arena, &.{ sd, "x86" }),
        try join(arena, &.{ sd, "generic" }),
        g,
        try join(arena, &.{ lib, "libc", "include", if (a64) "aarch64-linux-gnu" else "x86_64-linux-gnu" }),
        try join(arena, &.{ lib, "libc", "include", "generic-glibc" }),
        try join(arena, &.{ lib, "libc", "include", if (a64) "aarch64-linux-any" else "x86_64-linux-any" }),
        try join(arena, &.{ lib, "libc", "include", "any-linux-any" }),
    }) |d| if (d.len != 0) try includes.appendSlice(arena, &.{ "-I", d });
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
            "-DNO_INITFINI",                                       "-D_LIBC_REENTRANT",
            "-include",                                            try join(arena, &.{ g, "include", "libc-modules.h" }),
            "-DMODULE_NAME=libc",                                  "-include",
            try join(arena, &.{ g, "include", "libc-symbols.h" }), "-DPIC",
            "-DLIBC_NONSHARED=1",                                  "-DTOP_NAMESPACE=glibc",
        });
        try out.append(arena, .{ .argv = argv.items, .dep_at = dep_at });
    };
}

/// musl's crt1.o and libc.a (Musl.zig), linked into every executable of
/// a musl target (`Options.musl_libc`).
const musl_crt1: RuntimeLib = .{ .name = "crt1", .dir = "libc/musl", .files = &.{"crt/crt1.c"}, .object = true, .musl = true };
const musl_libc: RuntimeLib = .{ .name = "c", .dir = "libc", .files = &.{}, .musl = true };

/// Appends musl's crt1.o or libc.a compiles, with upstream's flags: its
/// sub-compilation's (ReleaseFast, no sanitizer or stack protector,
/// `-fno-builtin`, sections, the compilation's PIC, which is off, and
/// unwind tables, no libc), then musl's own (`Musl.ccArgs`).
fn muslJobs(arena: std.mem.Allocator, out: *std.ArrayList(RuntimeJob), rl: RuntimeLib, common: Common, lib: []const u8, o: Options) !void {
    const files = if (rl.object) rl.files else try Musl.sources(arena, o.cpu.arch);
    for (files) |file| {
        const lang: Lang = if (std.mem.endsWith(u8, file, ".S")) .asm_cpp else if (std.mem.endsWith(u8, file, ".s")) .assembly else .c;
        var argv: std.ArrayList([]const u8) = .empty;
        const dep_at = try appendArgs(arena, &argv, common, try Io.Dir.path.join(arena, &.{ lib, rl.dir, file }), .{
            .lang = lang,
            .optimize = .fast,
            .sanitize_c = .off,
            .red_zone = true,
            .no_builtin = true,
            .pic = false,
            .pie = false,
            .function_sections = true,
            .data_sections = true,
            .unwind_tables = o.unwind_tables,
            .link_libc = false,
            .libcpp = false,
            .libunwind = false,
        });
        try argv.appendSlice(arena, try Musl.ccArgs(arena, lib, o.cpu.arch, Musl.wantsO3(file)));
        if (rl.object) try argv.append(arena, "-DCRT");
        try out.append(arena, .{ .argv = argv.items, .dep_at = dep_at });
    }
}

const RuntimeJob = struct { argv: []const []const u8, dep_at: usize };

/// Appends the compiles of runtime library `rl`, with the flags upstream's
/// sub-compilation gives each source: its root module's (ReleaseFast, PIC,
/// no sanitizer, sections, asynchronous unwind tables, glibc), then the
/// library's own.
fn runtimeJobs(arena: std.mem.Allocator, out: *std.ArrayList(RuntimeJob), rl: RuntimeLib, common: Common, lib: []const u8, o: Options) !void {
    const join = Io.Dir.path.join;
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
                .objc, .objcpp, .asm_cpp, .assembly => {},
            }
            try argv.appendSlice(arena, &.{ "-w", "-I", try join(arena, &.{ lib, "libunwind", "include" }), "-D_LIBUNWIND_HIDE_SYMBOLS", "-Wa,--noexecstack", "-fvisibility=hidden", "-fvisibility-inlines-hidden", "-fvisibility-global-new-delete=force-hidden", "-D_LIBUNWIND_IS_NATIVE_ONLY" });
            // The compilation's own mode, which is Debug.
            try argv.append(arena, "-D_DEBUG");
            if (!threads) try argv.append(arena, "-D_LIBUNWIND_HAS_NO_THREADS");
        } else if (is_cxxabi) {
            try argv.appendSlice(arena, common.cxx_defines);
            try argv.appendSlice(arena, &.{ "-w", "-DNDEBUG", "-D_LIBCPP_BUILDING_LIBRARY", "-D_LIBCXXABI_BUILDING_LIBRARY" });
            if (!threads) try argv.append(arena, "-D_LIBCXXABI_HAS_NO_THREADS");
            // glibc 2.18 and later only, not musl.
            if (o.glibc_version) |v| if (v.order(.{ .major = 2, .minor = 18, .patch = 0 }) != .lt) try argv.append(arena, "-DHAVE___CXA_THREAD_ATEXIT_IMPL");
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

/// libc's header directories: `-isystem` and `-iframework`, in order.
pub const LibcDirs = struct {
    includes: []const []const u8,
    frameworks: []const []const u8 = &.{},
};

/// libc's header directories for `target`, as upstream's
/// `std.zig.LibCDirs.detect`: with the native ABI, the system libc
/// installation's (`nativeLibcIncludes`; on macOS the SDK's,
/// `darwinSdk`), else, or when there is no system C compiler or SDK, the
/// zig lib directory's headers.
pub fn libcIncludeDirs(arena: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, global_cache: []const u8, lib: []const u8, target: *const std.Target, native_abi: bool) !LibcDirs {
    if (native_abi and target.os.tag == .macos) {
        if (try darwinSdk(arena, io, environ, global_cache)) |sdk| return .{
            .includes = try arena.dupe([]const u8, &.{try Io.Dir.path.join(arena, &.{ sdk, "usr", "include" })}),
            .frameworks = try arena.dupe([]const u8, &.{try Io.Dir.path.join(arena, &.{ sdk, "System", "Library", "Frameworks" })}),
        };
    } else if (native_abi) if (nativeLibcIncludes(arena, io, environ, global_cache) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => main.fatal("failed to find libc installation: {t}", .{err}),
    }) |dirs| return .{ .includes = dirs };
    return .{ .includes = (try std.zig.LibCDirs.detectFromBuilding(arena, .{ .root_dir = .cwd(), .sub_path = lib }, target)).libc_include_dir_list };
}

/// The macOS SDK, as upstream's `LibCInstallation.findNative` finds it
/// (`std.zig.system.darwin`): `xcode-select --print-path` must answer,
/// so that no Command Line Tools installation prompt opens, then `xcrun
/// --sdk macosx --show-sdk-path` names it. Null when either fails, where
/// upstream falls back to its own headers. Kept in `<global>/bs/libc/`
/// as `nativeLibcIncludes`'s answer, keyed by what selects the developer
/// directory (`xcode-select -s`'s link, `DEVELOPER_DIR`) and the SDK
/// (`SDKROOT`) and by `PATH`.
pub fn darwinSdk(arena: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, global_cache: []const u8) !?[]const u8 {
    var key: std.ArrayList(u8) = .empty;
    try key.appendSlice(arena, "bs darwin sdk 1\x00");
    for ([_][]const u8{ "/var/db/xcode_select_link", "/usr/share/xcode-select/xcode_dir_path" }) |link| {
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const n = Io.Dir.cwd().readLink(io, link, &buf) catch 0;
        try key.print(arena, "{s}\x00", .{buf[0..n]});
    }
    for ([_][]const u8{ "DEVELOPER_DIR", "SDKROOT", "PATH" }) |name|
        try key.print(arena, "{s}={s}\x00", .{ name, environ.get(name) orelse "" });
    const record = try libcRecordPath(arena, global_cache, key.items);
    if (try readLibcRecord(arena, io, record)) |dirs| if (dirs.len == 1) {
        // A record whose SDK went away is xcrun's to answer.
        if (Io.Dir.cwd().access(io, try Io.Dir.path.join(arena, &.{ dirs[0], "usr", "include", "stdlib.h" }), .{})) |_| return dirs[0] else |_| {}
    };

    const select = runCc(arena, io, &.{ "xcode-select", "--print-path" }, environ) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.CCompilerFailed => return null,
    };
    if (select.stdout.len == 0) return null;
    const xcrun = runCc(arena, io, &.{ "xcrun", "--sdk", "macosx", "--show-sdk-path" }, environ) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.CCompilerFailed => return null,
    };
    const sdk = std.mem.trimEnd(u8, xcrun.stdout, "\r\n");
    writeLibcRecord(io, record, &.{sdk});
    return sdk;
}

/// The version of the SDK an aarch64-macos build links against, as
/// upstream's linker reads it from `SDKSettings.json`: the system SDK's
/// (`darwinSdk`) for the `native` target when one is installed, else the
/// zig lib directory's (`libc/darwin`). Null when the file names none.
pub fn darwinSdkVersion(arena: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, global_cache: []const u8, lib: []const u8, native: bool) !?std.SemanticVersion {
    const sdk = if (native) try darwinSdk(arena, io, environ, global_cache) else null;
    const path = if (sdk) |dir| try Io.Dir.path.join(arena, &.{ dir, "SDKSettings.json" }) else try Io.Dir.path.join(arena, &.{ lib, "libc", "darwin", "SDKSettings.json" });
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 24)) catch return null;
    const settings = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch return null;
    if (settings != .object) return null;
    const version = settings.object.get("Version") orelse return null;
    if (version != .string) return null;
    return std.Target.Query.parseVersion(version.string) catch null;
}

fn libcRecordPath(arena: std.mem.Allocator, global_cache: []const u8, key: []const u8) ![]const u8 {
    const hex = std.fmt.bytesToHex(@as([16]u8, @bitCast(cache.hash(2, key))), .lower);
    return Io.Dir.path.join(arena, &.{ global_cache, "bs", "libc", &hex });
}

/// The directories a libc record lists, NUL-separated.
fn readLibcRecord(arena: std.mem.Allocator, io: Io, record: []const u8) !?[]const []const u8 {
    const bytes = Io.Dir.cwd().readFileAlloc(io, record, arena, .limited(64 * 1024)) catch return null;
    var dirs: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, bytes, 0);
    while (it.next()) |d| try dirs.append(arena, d);
    return if (dirs.items.len == 0) null else dirs.items;
}

/// Best effort: without the record, the next build asks again.
fn writeLibcRecord(io: Io, record: []const u8, dirs: []const []const u8) void {
    if (Io.Dir.path.dirname(record)) |d| Io.Dir.cwd().createDirPath(io, d) catch {}; // ziglint-ignore: Z026 -- cache upkeep is best effort
    var parts: [4][]const u8 = undefined;
    for (dirs, 0..) |d, k| {
        parts[2 * k] = d;
        parts[2 * k + 1] = "\x00";
    }
    cache.writeReplace(io, Io.Dir.cwd(), record, parts[0 .. 2 * dirs.len]) catch {}; // ziglint-ignore: Z026 -- cache upkeep is best effort
}

// The detection below follows upstream's `std.zig.LibCInstallation`
// (`findNativeIncludeDirPosix`, `appendCcExe`) and `std.zig.LibCDirs`
// (`detectFromInstallation`), Copyright (c) Zig contributors, MIT license.

/// The system libc installation's include directories, as upstream finds
/// them for a native target: the C compiler (`$CC`, split on spaces, else
/// `cc`) lists its search path (`-E -Wp,-v -xc /dev/null`); from the last
/// entry back, the first directory with `stdlib.h` and the first with
/// `sys/errno.h`. Null when the compiler cannot run or lists nothing,
/// where upstream falls back to its own headers. The answer is kept in
/// `<global>/bs/libc/<key>`, keyed by the compiler's identity and the
/// environment it searches with, so that a build does not run it again.
fn nativeLibcIncludes(arena: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, global_cache: []const u8) !?[]const []const u8 {
    const inf_loop_env_key = "ZIG_IS_DETECTING_LIBC_PATHS";
    const skip_cc_env_var = if (environ.get(inf_loop_env_key)) |phase|
        (if (std.mem.eql(u8, phase, "1")) true else return error.ZigIsTheCCompiler)
    else
        false;
    var argv: std.ArrayList([]const u8) = .empty;
    if (skip_cc_env_var) try argv.append(arena, "cc") else if (environ.get("CC")) |cc| {
        var it = std.mem.tokenizeScalar(u8, cc, ' ');
        while (it.next()) |arg| try argv.append(arena, arg);
    }
    if (argv.items.len == 0) try argv.append(arena, "cc");

    // The key: the compiler's file and what changes where it looks.
    var key: std.ArrayList(u8) = .empty;
    try key.print(arena, "bs native libc 1\x00{d}\x00", .{@intFromBool(skip_cc_env_var)});
    for (argv.items) |a| try key.print(arena, "{s}\x00", .{a});
    const exe = argv.items[0];
    const exe_path: ?[]const u8 = if (std.mem.findScalar(u8, exe, '/') != null) exe else p: {
        var it = std.mem.tokenizeScalar(u8, environ.get("PATH") orelse "", ':');
        while (it.next()) |dir| {
            const p = try Io.Dir.path.join(arena, &.{ dir, exe });
            if (Io.Dir.cwd().access(io, p, .{ .execute = true })) |_| break :p p else |_| {}
        }
        break :p null;
    };
    const exe_stat = if (exe_path) |p| Io.Dir.cwd().statFile(io, p, .{}) catch null else null;
    if (exe_stat) |st| try key.print(arena, "{s}\x00{d}\x00{d}\x00{d}\x00", .{ exe_path.?, st.inode, st.size, st.mtime.toNanoseconds() });
    for ([_][]const u8{ "PATH", "CPATH", "C_INCLUDE_PATH", "GCC_EXEC_PREFIX", "COMPILER_PATH", "NIX_CFLAGS_COMPILE", "NIX_CC" }) |name|
        try key.print(arena, "{s}={s}\x00", .{ name, environ.get(name) orelse "" });
    const record = try libcRecordPath(arena, global_cache, key.items);
    if (exe_stat != null) if (try readLibcRecord(arena, io, record)) |dirs| {
        // A record whose headers went away is the compiler's to answer.
        if (Io.Dir.cwd().access(io, try Io.Dir.path.join(arena, &.{ dirs[0], "stdlib.h" }), .{})) |_| return dirs else |_| {}
    };

    var env = try environ.clone(arena);
    try env.put(inf_loop_env_key, if (skip_cc_env_var) "2" else "1");
    const cc_argv = try arena.dupe([]const u8, argv.items);
    try argv.appendSlice(arena, &.{ "-E", "-Wp,-v", "-xc", "/dev/null" });
    const res = runCc(arena, io, argv.items, &env) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.CCompilerFailed => return null,
    };
    var search_paths: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.tokenizeAny(u8, res.stderr, "\n\r");
    while (lines.next()) |line| if (line.len != 0 and line[0] == ' ') try search_paths.append(arena, std.mem.trimStart(u8, line, " "));
    if (search_paths.items.len == 0) return null;
    var include_dir: ?[]const u8 = null;
    var sys_include_dir: ?[]const u8 = null;
    var i = search_paths.items.len;
    while (i > 0) {
        i -= 1;
        const dir = search_paths.items[i];
        if (include_dir == null) if (Io.Dir.cwd().access(io, try Io.Dir.path.join(arena, &.{ dir, "stdlib.h" }), .{})) |_| {
            include_dir = dir;
        } else |_| {};
        if (sys_include_dir == null) if (Io.Dir.cwd().access(io, try Io.Dir.path.join(arena, &.{ dir, "sys", "errno.h" }), .{})) |_| {
            sys_include_dir = dir;
        } else |_| {};
        if (include_dir != null and sys_include_dir != null) break;
    }
    if (include_dir == null or sys_include_dir == null) return error.LibCStdLibHeaderNotFound;
    // Upstream's detection also asks for the C runtime and GCC's objects,
    // and fails without them (`findNativeCrtDirPosix`,
    // `findNativeGccDirPosix`), though bs links its own.
    for ([_][]const u8{ "crt1.o", "crtbeginS.o" }) |basename| {
        const print = try std.mem.concat(arena, []const u8, &.{ cc_argv, &.{try arena.print("-print-file-name={s}", .{basename})} });
        const out = runCc(arena, io, print, &env) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.CCompilerFailed => return null,
        };
        var it = std.mem.tokenizeAny(u8, out.stdout, "\n\r");
        const line = it.next() orelse return error.LibCRuntimeNotFound;
        if (std.mem.eql(u8, line, basename) or Io.Dir.path.dirname(line) == null) return error.LibCRuntimeNotFound;
    }
    const dirs: []const []const u8 = if (std.mem.eql(u8, include_dir.?, sys_include_dir.?))
        try arena.dupe([]const u8, &.{include_dir.?})
    else
        try arena.dupe([]const u8, &.{ include_dir.?, sys_include_dir.? });
    if (exe_stat != null) writeLibcRecord(io, record, dirs);
    return dirs;
}

/// Runs the C compiler (or xcrun) for `nativeLibcIncludes` and
/// `darwinSdk`: `CCompilerFailed` when it cannot start or does not exit
/// with 0, where upstream falls back to its own headers.
fn runCc(arena: std.mem.Allocator, io: Io, argv: []const []const u8, env: *const std.process.Environ.Map) !std.process.RunResult {
    const res = std.process.run(arena, io, .{
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .argv = argv,
        .environ_map = env,
        .expand_arg0 = .expand,
    }) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return error.CCompilerFailed,
    };
    if (!res.term.success()) return error.CCompilerFailed;
    return res;
}

/// Null when `zig` is upstream's 0.17.1, else why not.
fn checkZig(arena: std.mem.Allocator, io: Io, zig: []const u8) !?[]const u8 {
    const res = std.process.run(arena, io, .{ .argv = &.{ zig, "version" } }) catch |err| {
        const why = try arena.print("compiling C sources needs upstream zig 0.17.1; unable to run '{s}': {t}", .{ zig, err });
        return why;
    };
    const version = std.mem.trim(u8, res.stdout, " \n");
    if (res.term.success() and std.mem.eql(u8, version, "0.17.1")) return null;
    const why = try arena.print("compiling C sources needs upstream zig 0.17.1; '{s}' is version '{s}' (set BS_ZIG to upstream 0.17.1)", .{ zig, version });
    return why;
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
        try out.append(arena, .{ .loc = null, .msg = try arena.print("unable to compile '{s}': {s}", .{ source, std.mem.trimEnd(u8, stderr, "\n") }) });
    }
}

fn parseLine(arena: std.mem.Allocator, paths: diag.Paths, line: []const u8) ?struct { enum { err, note }, ?diag.Loc, []const u8 } {
    inline for (.{ .{ ": error: ", .err }, .{ ": fatal error: ", .err }, .{ ": note: ", .note } }) |k| {
        if (std.mem.find(u8, line, k[0])) |at| {
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
    while (l < line) : (l += 1) offset = (std.mem.findScalarPos(u8, source, offset, '\n') orelse return null) + 1;
    offset = @min(offset + col - 1, source.len);
    const o: u32 = @intCast(offset);
    return paths.loc(arena, path, source, o, o, o, false) catch null;
}
