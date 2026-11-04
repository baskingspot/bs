//! C source files, compiled by upstream's Clang (`zig clang`) with the
//! arguments upstream's `Compilation.addCCArgs` gives them for zap's
//! target and the baseline CPU, in Debug (docs/architecture.md, "C
//! interop"). zap never compiles C itself.
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
const Incremental = @import("Incremental.zig");
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

/// The per-module options that change a C compile, as upstream's
/// `Module.create` resolves them: unset takes the root module's, then the
/// Debug default.
pub const Flags = struct {
    sanitize_c: ?std.zig.SanitizeC = null,
    red_zone: ?bool = null,
    no_builtin: ?bool = null,
    pic: ?bool = null,

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
    pie: bool,
    function_sections: bool,
    data_sections: bool,
    unwind_tables: std.lang.UnwindTables,
    /// `cc_argv` left after the last `-M`, before every module's own.
    global_cc_argv: []const []const u8,
    /// `--verbose-cc`.
    verbose: bool = false,
};

/// The compiles of one build, running while it analyzes.
pub const Batch = struct {
    gpa: std.mem.Allocator,
    io: Io,
    jobs: []Job,
    group: Io.Group = .init,
    next: std.atomic.Value(usize) = .init(0),
    /// Upstream zig, or why there is none.
    zig: Zig,
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
        record_path: []const u8,
        out_path: []const u8,
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

    pub const Result = struct {
        /// In command-line order.
        objects: []const Object,
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
        const tmp_dir = try std.fs.path.join(arena, &.{ std.fs.path.dirname(std.fs.path.dirname(j.record_path).?).?, "tmp" });
        try Io.Dir.cwd().createDirPath(io, tmp_dir);
        var rand: [8]u8 = undefined;
        io.random(&rand);
        const tmp_base = try std.fs.path.join(arena, &.{ tmp_dir, &std.fmt.bytesToHex(rand, .lower) });
        const dep_path = try std.fmt.allocPrint(arena, "{s}-cc.d", .{tmp_base});
        const tmp_out = try std.fmt.allocPrint(arena, "{s}-cc.o", .{tmp_base});
        defer Io.Dir.cwd().deleteFile(io, dep_path) catch {};
        defer Io.Dir.cwd().deleteFile(io, tmp_out) catch {};
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(arena, zig);
        try argv.appendSlice(arena, j.argv[1..j.dep_at]);
        try argv.appendSlice(arena, &.{ "-MD", "-MV", "-MF", dep_path });
        try argv.appendSlice(arena, j.argv[j.dep_at..]);
        try argv.appendSlice(arena, &.{ "-c", "-o", tmp_out });
        if (b.verbose) std.log.info("{f}", .{std.zig.SubprocessCommand{ .argv = argv.items }});
        const res = try std.process.run(arena, io, .{
            .argv = argv.items,
            .stdout_limit = .limited(1 << 20),
            .stderr_limit = .limited(16 << 20),
        });
        if (!res.term.success()) {
            j.state = .{ .failed = if (res.stderr.len != 0) res.stderr else try std.fmt.allocPrint(arena, "clang failed ({f})", .{res.term}) };
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
        b.result = .{ .objects = objects.items, .errors = errors.items, .inputs = inputs.items };
        return &b.result.?;
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
pub fn start(gpa: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, sources: []const CSource, o: Options) !*Batch {
    const b = try gpa.create(Batch);
    errdefer gpa.destroy(b);
    b.* = .{ .gpa = gpa, .io = io, .jobs = try gpa.alloc(Batch.Job, sources.len), .zig = undefined, .paths = undefined, .verbose = o.verbose, .result_arena = .init(gpa) };
    for (b.jobs) |*j| j.arena = .init(gpa);
    b.paths = try .init(b.result_arena.allocator(), io, o.zig_lib_dir);
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const s = scratch.allocator();
    const cwd_path = try std.process.currentPathAlloc(io, s);
    const lib = try std.fs.path.resolve(s, &.{ cwd_path, o.zig_lib_dir });
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
    const common = try commonArgs(b.result_arena.allocator(), &target, lib, o);

    var misses: usize = 0;
    for (sources, b.jobs) |src, *j| {
        const arena = j.arena.allocator();
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &.{ "zig", "clang", src.path });
        try argv.appendSlice(arena, common.before_dep);
        // glibc requires PIC (`requiresPic`); else the module's, default off.
        const pic = o.link_libc or (src.flags.pic orelse false);
        try argv.appendSlice(arena, &.{ if (o.pie) "-fPIE" else "-fno-PIE", if (pic) "-fPIC" else "-fno-PIC", "-gdwarf-4", "-gdwarf32", "-fno-lto" });
        const dep_at = argv.items.len;
        try moduleArgs(arena, &argv, common, src.flags, o);
        try argv.appendSlice(arena, common.features);
        try argv.appendSlice(arena, o.global_cc_argv);
        try argv.appendSlice(arena, src.cc_argv);
        try argv.appendSlice(arena, src.extra_flags);
        const abs_source = try std.fs.path.resolve(arena, &.{ cwd_path, src.path });

        var key_args: std.ArrayList([]const u8) = .empty;
        try key_args.append(s, zig_id);
        try key_args.appendSlice(s, argv.items[1..]);
        try key_args.append(s, abs_source);
        _, const key = try Incremental.compilationKey(s, io, key_args.items, lib, "cc");
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
        if (try ToolRecord.check(arena, io, j.record_path, j.out_path, start_ns)) |c| switch (c) {
            .hit => |inputs| {
                j.inputs = inputs;
                j.state = .done;
                continue;
            },
            .miss => |h| j.old_output = h,
        };
        misses += 1;
    }
    // Only a build that compiles C needs upstream zig, and checks its
    // version once.
    b.zig = if (misses == 0) .{ .path = "" } else if (zig.found) |p|
        if (try checkZig(s, io, p)) |msg| .{ .missing = try gpa.dupe(u8, msg) } else .{ .path = try gpa.dupe(u8, p) }
    else
        .{ .missing = try std.fmt.allocPrint(gpa, "compiling C sources needs upstream zig 0.17.0; zap looked for it in ZAP_ZIG, as 'zig' on PATH, and in {s}", .{zig.looked}) };
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

const Common = struct {
    /// From `--no-default-config` to before the depfile.
    before_dep: []const []const u8,
    /// glibc's macro and the include directories.
    includes: []const []const u8,
    /// `-Xclang -target-cpu ...` and every feature.
    features: []const []const u8,
};

/// The arguments every source shares, in upstream's order
/// (`addCCArgs`, `addCommonCCArgs`).
fn commonArgs(arena: std.mem.Allocator, target: *const std.Target, lib: []const u8, o: Options) !Common {
    var before: std.ArrayList([]const u8) = .empty;
    try before.appendSlice(arena, &.{ "--no-default-config", "-fno-caret-diagnostics", "-target", try std.zig.llvm.Builder.tripleForTarget(arena, target) });
    var includes: std.ArrayList([]const u8) = .empty;
    if (o.link_libc) try includes.append(arena, try std.fmt.allocPrint(arena, "-D__GLIBC_MINOR__={d}", .{o.glibc_version.?.minor}));
    try includes.appendSlice(arena, &.{ "-isystem", try std.fs.path.join(arena, &.{ lib, "include" }) });
    if (o.link_libc) {
        const dirs = try std.zig.LibCDirs.detectFromBuilding(arena, .{ .root_dir = .cwd(), .sub_path = lib }, target);
        for (dirs.libc_include_dir_list) |d| try includes.appendSlice(arena, &.{ "-isystem", d });
    }
    var features: std.ArrayList([]const u8) = .empty;
    try features.appendSlice(arena, &.{ "-Xclang", "-target-cpu", "-Xclang", target.cpu.model.llvm_name.? });
    for (target.cpu.arch.allFeaturesList(), 0..) |feature, i| {
        const name = feature.llvm_name orelse continue;
        if (std.mem.startsWith(u8, name, "soft-float") or std.mem.startsWith(u8, name, "hard-float") or std.mem.startsWith(u8, name, "x32")) continue;
        const on = target.cpu.features.isEnabled(@intCast(i));
        try features.appendSlice(arena, &.{ "-Xclang", "-target-feature", "-Xclang", try std.fmt.allocPrint(arena, "{c}{s}", .{ "-+"[@intFromBool(on)], name }) });
    }
    return .{ .before_dep = before.items, .includes = includes.items, .features = features.items };
}

/// The arguments after the depfile up to the CPU, some of which depend on
/// the module's options.
fn moduleArgs(arena: std.mem.Allocator, argv: *std.ArrayList([]const u8), common: Common, flags: Flags, o: Options) !void {
    try argv.appendSlice(arena, &.{ "-fhosted", "-nostdinc" });
    try argv.appendSlice(arena, common.includes);
    try argv.append(arena, "-fno-spell-checking");
    switch (flags.sanitize_c orelse .full) {
        .off => {},
        .trap => try argv.appendSlice(arena, &.{ "-fsanitize=undefined", "-fsanitize-trap=undefined" }),
        .full => try argv.appendSlice(arena, &.{ "-fsanitize=undefined", "-fno-sanitize=vptr", "-fno-sanitize=function" }),
    }
    try argv.appendSlice(arena, &.{ "-O0", if (flags.red_zone orelse true) "-mred-zone" else "-mno-red-zone", "-fno-omit-frame-pointer" });
    // Upstream's Debug backend for Zig code has no stack protector, which
    // turns it off for the compilation's C too (`Module.create`).
    try argv.append(arena, "-fno-stack-protector");
    try argv.append(arena, if (flags.no_builtin orelse false) "-fno-builtin" else "-fbuiltin");
    try argv.append(arena, if (o.function_sections) "-ffunction-sections" else "-fno-function-sections");
    try argv.append(arena, if (o.data_sections) "-fdata-sections" else "-fno-data-sections");
    switch (o.unwind_tables) {
        .none => try argv.appendSlice(arena, &.{ "-fno-unwind-tables", "-fno-asynchronous-unwind-tables" }),
        .sync => try argv.appendSlice(arena, &.{ "-fno-asynchronous-unwind-tables", "-funwind-tables" }),
        .async => try argv.append(arena, "-fasynchronous-unwind-tables"),
    }
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
