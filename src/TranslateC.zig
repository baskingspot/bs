//! `bs translate-c`: translates a C header (or source) to Zig with
//! upstream's translate-c (`lib/compiler/translate-c`, on Aro), which bs
//! builds itself, as `bs build` does the build runner. `b.addTranslateC`
//! runs it as `bs translate-c <flags> <file> --listen=-` and imports the
//! output, `<local cache>/o/<digest>/<stem>.zig`, as a module.
//!
//! The arguments that reach Aro are upstream's (`Compilation.translateC`
//! with `addCommonCCArgs(.aro)`) for bs's target: Debug, the baseline
//! CPU, and with `-lc` glibc's headers from the zig lib directory, as
//! bs's `-lc` links (docs/slop/architecture.md, "C interop").
//!
//! A translation record, `<local cache>/bs/tc/<key>`, lists every file
//! Aro read (from its `-MD` depfile) with its stat and content hash, and
//! the output's hash. The key covers bs, the translate-c binary, the
//! working directory, the source path and the arguments, not the files'
//! contents, so the output stays at one path across header edits, and a
//! build whose files all stat as recorded runs nothing.

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const main = @import("main.zig");
const cache = @import("cache.zig");
const Frontend = @import("Frontend.zig");
const Incremental = @import("Incremental.zig");
const BuildRunner = @import("BuildRunner.zig");
const ToolRecord = @import("ToolRecord.zig");

const Request = struct {
    source: []const u8,
    link_libc: bool,
    /// The target's glibc, which the target triple names: the native
    /// system's without `-target`, as upstream's native target, with or
    /// without `-lc`; null for `x86_64-linux(-none)`.
    glibc_version: ?std.SemanticVersion,
    /// `-mcpu`, as for a compilation (`cpu.resolve`): it sets the macros
    /// the headers see (`__SSE4_1__`).
    cpu: std.Target.Cpu,
    /// The user's C flags (include directories, macros), in order.
    cc_args: []const []const u8,
    /// `std.zig.system.NativePaths`' include directories, after libc's:
    /// upstream's `native_system_include_paths`, which a native target
    /// gets when the command names system libraries.
    native_includes: []const []const u8 = &.{},
    listen: bool,
    zig_lib_dir: []const u8,
    cache_dirs: Frontend.CacheDirs,
    build_root: ?[]const u8,
    unsupported: ?[]const u8,
};

/// C flags that take a parameter, passed to Aro as given.
const cc_flags_with_arg: std.StaticStringMap(void) = .initComptime(.{
    .{"-I"}, .{"-isystem"}, .{"-iquote"}, .{"-idirafter"}, .{"-iframework"}, .{"-F"}, .{"-D"}, .{"-include"}, .{"--embed-dir"},
});

/// Options of `zig translate-c` that change nothing bs translates.
const ignored_flags: std.StaticStringMap(void) = .initComptime(.{
    .{"-fno-PIC"},          .{"-fPIC"},                .{"-fno-PIE"},      .{"-fPIE"},            .{"-fsingle-threaded"}, .{"-fno-single-threaded"},
    .{"-freference-trace"}, .{"-fno-reference-trace"}, .{"-fstack-check"}, .{"-fno-stack-check"},
});
const ignored_flags_with_arg: std.StaticStringMap(void) = .initComptime(.{
    .{"--name"}, .{"--color"}, .{"--error-limit"}, .{"--debug-log"},
});

fn parse(init: std.process.Init, args: []const []const u8) !Request {
    const arena = init.arena.allocator();
    const io = init.io;
    var source: ?[]const u8 = null;
    var cc_args: std.ArrayList([]const u8) = .empty;
    var named_libs = false;
    var opts: main.Options = .{ .command = .build_exe, .root_src_path = "" };
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--listen=-")) {
            opts.listen = true;
        } else if (std.mem.eql(u8, arg, "-target")) {
            opts.target = next(args, &i);
        } else if (std.mem.eql(u8, arg, "-mcpu") or std.mem.startsWith(u8, arg, "-mcpu=")) {
            const r = @import("cpu.zig").resolve(arena, io, if (arg.len > "-mcpu".len) arg["-mcpu=".len..] else next(args, &i));
            opts.cpu = r.cpu;
            if (r.refused) |msg| main.setUnsupported(&opts, arena, "{s}", .{msg});
        } else if (std.mem.eql(u8, arg, "--zig-lib-dir")) {
            opts.zig_lib_dir = next(args, &i);
        } else if (std.mem.eql(u8, arg, "--cache-dir")) {
            opts.cache_dir = next(args, &i);
        } else if (std.mem.eql(u8, arg, "--global-cache-dir")) {
            opts.global_cache_dir = next(args, &i);
        } else if (std.mem.eql(u8, arg, "--build-root")) {
            opts.build_root = next(args, &i);
        } else if (std.mem.eql(u8, arg, "-cflags")) {
            // Flags for C source files, of which translate-c has none
            // (upstream ignores them too).
            while (i + 1 < args.len and !std.mem.eql(u8, args[i + 1], "--")) i += 1;
            i += 1;
        } else if (std.mem.startsWith(u8, arg, "-O")) {
            // bs builds only Debug, so headers see Debug's macros (no
            // NDEBUG), as the code they are compiled into.
            if (arg.len == 2) i += 1;
        } else if (std.mem.startsWith(u8, arg, "-l")) {
            // glibc's libraries link libc; other libraries (the build
            // runner passes pkg-config's) add the native include
            // directories, as upstream's `want_native_include_dirs`.
            if (main.isGlibcLib(arg[2..])) opts.link_libc = true else if (!main.isLibcppLib(arg[2..])) named_libs = true;
        } else if (std.mem.startsWith(u8, arg, "-needed-l") or std.mem.startsWith(u8, arg, "-weak-l") or
            std.mem.startsWith(u8, arg, "-search_") or std.mem.eql(u8, arg, "-pthread"))
        {
            // Link options, which translate-c ignores, as upstream.
        } else if (std.mem.eql(u8, arg, "-L") or std.mem.eql(u8, arg, "-rpath")) {
            _ = next(args, &i);
        } else if (std.mem.startsWith(u8, arg, "-L")) {
            // A library directory, as above.
        } else if (cc_flags_with_arg.has(arg)) {
            try cc_args.appendSlice(arena, &.{ arg, next(args, &i) });
        } else if (std.mem.startsWith(u8, arg, "-I") or std.mem.startsWith(u8, arg, "-D") or std.mem.startsWith(u8, arg, "-U")) {
            try cc_args.append(arena, arg);
        } else if (ignored_flags.has(arg)) {
            // Changes nothing bs translates.
        } else if (ignored_flags_with_arg.has(arg)) {
            _ = next(args, &i);
        } else if (std.mem.startsWith(u8, arg, "-")) {
            main.setUnsupported(&opts, arena, "bs does not support the option '{s}' for translate-c", .{arg});
        } else if (source == null) {
            source = arg;
        } else {
            main.fatal("unexpected extra parameter: {s}", .{arg});
        }
    }
    const target = opts.target orelse "native";
    var native_includes: []const []const u8 = &.{};
    if (std.mem.eql(u8, target, "native")) {
        if (!(@import("builtin").cpu.arch == .x86_64 and @import("builtin").os.tag == .linux))
            main.setUnsupported(&opts, arena, "bs translates C only for x86_64-linux so far ('native'); pass -target x86_64-linux", .{})
        else if (std.zig.system.resolveTargetQuery(io, .{})) |native| {
            if (native.abi.isGnu()) opts.glibc_version = native.os.version_range.linux.glibc;
            if (named_libs) if (std.zig.system.NativePaths.detect(arena, io, &native, init.environ_map)) |paths| {
                native_includes = paths.include_dirs.items;
            } else |_| {};
        } else |_| {}
        if (opts.link_libc and opts.unsupported == null) main.resolveGlibc(&opts, arena, io);
    } else {
        // `checkTarget` takes `x86_64-linux-gnu` only with -lc; headers
        // translate for it without.
        const libc = opts.link_libc;
        opts.link_libc = true;
        main.checkTarget(&opts, arena, target);
        opts.link_libc = libc;
        if (opts.link_libc and opts.unsupported == null) main.resolveGlibc(&opts, arena, io);
    }
    return .{
        .source = source orelse if (opts.unsupported != null) "" else main.fatal("expected a C source file to translate", .{}),
        .link_libc = opts.link_libc,
        .glibc_version = opts.glibc_version,
        .cpu = opts.cpu,
        .cc_args = cc_args.items,
        .native_includes = native_includes,
        .listen = opts.listen,
        .zig_lib_dir = opts.zig_lib_dir orelse init.environ_map.get("ZIG_LIB_DIR") orelse build_options.zig_lib_dir,
        .cache_dirs = Frontend.resolveCacheDirs(arena, io, init.environ_map, .{ .local = opts.cache_dir, .global = opts.global_cache_dir }),
        .build_root = opts.build_root,
        .unsupported = opts.unsupported,
    };
}

fn next(args: []const []const u8, i: *usize) []const u8 {
    i.* += 1;
    if (i.* >= args.len) main.fatal("expected parameter after {s}", .{args[i.* - 1]});
    return args[i.*];
}

pub fn run(init: std.process.Init, args: []const []const u8) !void {
    const req = try parse(init, args);
    if (req.listen) return serve(init, &req);
    if (req.unsupported) |msg| main.fatal("{s}", .{msg});
    const r = try translate(init, &req);
    const io = init.io;
    if (r.errors) |body| {
        var bundle = try std.zig.Server.allocErrorBundle(init.gpa, body);
        defer bundle.deinit(init.gpa);
        bundle.renderToStderr(io, .{}, std.zig.Color.settingFromEnvironment(init.environ_map)) catch {};
        std.process.exit(1);
    }
    const contents = try Io.Dir.cwd().readFileAlloc(io, r.out_path, init.arena.allocator(), .unlimited);
    try Io.File.stdout().writeStreamingAll(io, contents);
}

fn serve(init: std.process.Init, req: *const Request) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    var in_buf: [256]u8 = undefined;
    var out_buf: [4096]u8 = undefined;
    var in = Io.File.stdin().readerStreaming(io, &in_buf);
    var out = Io.File.stdout().writerStreaming(io, &out_buf);
    var server: std.zig.Server = .{ .in = &in.interface, .out = &out.interface };
    try server.serveStringMessage(.zig_version, main.zig_version);
    try server.serveConfig(.{ .flags = .{
        .output_mode = .Obj,
        .link_mode = if (req.link_libc) .dynamic else .static,
        .link_libc = req.link_libc,
        .link_libcpp = false,
        .link_libunwind = false,
        .pie = false,
    } });
    while (true) {
        const hdr = server.receiveMessage() catch |err| switch (err) {
            error.EndOfStream => std.process.exit(0),
            else => |e| return e,
        };
        switch (hdr.tag) {
            .exit => std.process.exit(0),
            .update => {
                try server.in.discardAll(hdr.bytes_len);
                if (req.unsupported) |msg| {
                    try main.serveUnsupported(&server, init.gpa, msg);
                    continue;
                }
                const r = try translate(init, req);
                const prefixed = try main.prefixInputs(arena, io, r.inputs, .{
                    .zig_lib_dir = req.zig_lib_dir,
                    .cache_dirs = req.cache_dirs,
                    .build_root = req.build_root,
                });
                if (prefixed.len != 0) try server.serveStringMessage(.file_system_inputs, prefixed);
                if (r.errors) |body| {
                    try server.serveStringMessage(.error_bundle, body);
                } else {
                    try server.serveEmitDigest(&r.digest, .{ .flags = .{ .cache_hit = r.cache_hit } });
                }
            },
            else => main.fatal("unrecognized message from client: 0x{x}", .{@backingInt(hdr.tag)}),
        }
    }
}

const Result = struct {
    digest: [16]u8,
    cache_hit: bool,
    out_path: []const u8,
    /// The files Aro read, zero-separated, for `file_system_inputs`.
    inputs: []const u8,
    /// An ErrorBundle message body, when Aro reported errors.
    errors: ?[]const u8 = null,
};

fn translate(init: std.process.Init, req: *const Request) !Result {
    const arena = init.arena.allocator();
    const io = init.io;
    const cwd_path = try std.process.currentPathAlloc(io, arena);
    const cwd = Io.Dir.cwd();
    const start_ns = Io.Clock.real.now(io).toNanoseconds();
    const lib = try std.fs.path.resolve(arena, &.{ cwd_path, req.zig_lib_dir });
    const global = try std.fs.path.resolve(arena, &.{ cwd_path, req.cache_dirs.global });
    const local = req.cache_dirs.local;
    const source = try std.fs.path.resolve(arena, &.{ cwd_path, req.source });

    // As the build runner, translate-c from the pinned release's lib
    // directory is trusted not to change.
    const trusted = init.environ_map.get("ZIG_LIB_DIR") == null and
        std.mem.eql(u8, lib, try std.fs.path.resolve(arena, &.{ cwd_path, build_options.zig_lib_dir }));
    const exe, const exe_hash = try ensureBinary(init, lib, global, trusted);

    // Upstream's arguments, with the depfile and output paths left for
    // last so that the key does not depend on them.
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{
        exe,                                                    "--zig-integration",
        try std.fmt.allocPrint(arena, "--zig-lib={s}", .{lib}), "--",
        "-x",                                                   "c",
        "-isystem",                                             try std.fs.path.join(arena, &.{ lib, "compiler", "aro", "include" }),
        "-fno-PIE",                                             if (req.link_libc) "-fPIC" else "-fno-PIC",
        "-gdwarf-4",                                            "-gdwarf32",
        "-fno-lto",                                             "-fhosted",
        "-nostdinc",
    });
    const query_text = if (req.glibc_version) |v| try std.fmt.allocPrint(arena, "x86_64-linux-gnu.{f}", .{v}) else "x86_64-linux-none";
    const query = try std.Target.Query.parse(.{ .arch_os_abi = query_text, .cpu_features = "baseline" });
    var target = try std.zig.system.resolveTargetQuery(io, query);
    target.cpu = req.cpu;
    if (req.link_libc) try argv.append(arena, try std.fmt.allocPrint(arena, "-D__GLIBC_MINOR__={d}", .{req.glibc_version.?.minor}));
    try argv.appendSlice(arena, &.{ "-isystem", try std.fs.path.join(arena, &.{ lib, "include" }) });
    if (req.link_libc) {
        const dirs = try std.zig.LibCDirs.detectFromBuilding(arena, .{ .root_dir = .cwd(), .sub_path = lib }, &target);
        for (dirs.libc_include_dir_list) |d| try argv.appendSlice(arena, &.{ "-isystem", d });
    }
    for (req.native_includes) |d| try argv.appendSlice(arena, &.{ "-isystem", d });
    try argv.appendSlice(arena, &.{ "-O0", "-target", try target.zigTriple(arena), try mcpuArg(arena, &target) });
    try argv.appendSlice(arena, req.cc_args);

    // The key: the binary's contents, which bs's code generation makes
    // (a new bs that builds the same bytes keeps the records), the working
    // directory and the arguments.
    var key_args: std.ArrayList([]const u8) = .empty;
    try key_args.appendSlice(arena, argv.items[1..]);
    try key_args.append(arena, source);
    const key = try ToolRecord.key(arena, io, "translate-c", &std.fmt.bytesToHex(@as([16]u8, @bitCast(exe_hash)), .lower), lib, key_args.items);
    const digest: [16]u8 = @bitCast(key);
    const hex = std.fmt.bytesToHex(digest, .lower);
    const record_path = try std.fs.path.join(arena, &.{ local, "bs", "tc", &hex });
    const out_dir = try std.fs.path.join(arena, &.{ local, "o", &hex });
    const out_path = try std.fs.path.join(arena, &.{ out_dir, try std.fmt.allocPrint(arena, "{s}.zig", .{std.fs.path.stem(source)}) });

    var old_output: ?cache.Hash = null;
    if (try ToolRecord.check(arena, io, record_path, out_path, start_ns, arena, null)) |c| switch (c) {
        .hit => |inputs| return .{ .digest = digest, .cache_hit = true, .out_path = out_path, .inputs = inputs },
        .miss => |h| old_output = h,
    };

    // Translate into the local cache's `bs/tmp`, then move the output
    // into place.
    const tmp_dir = try std.fs.path.join(arena, &.{ local, "bs", "tmp" });
    try cwd.createDirPath(io, tmp_dir);
    var rand: [8]u8 = undefined;
    io.random(&rand);
    const tmp_base = try std.fs.path.join(arena, &.{ tmp_dir, &std.fmt.bytesToHex(rand, .lower) });
    const dep_path = try std.fmt.allocPrint(arena, "{s}-tc.d", .{tmp_base});
    const tmp_out = try std.fmt.allocPrint(arena, "{s}-tc.zig", .{tmp_base});
    defer cwd.deleteFile(io, dep_path) catch {};
    defer cwd.deleteFile(io, tmp_out) catch {};
    // The source as given, as upstream, so that diagnostics name it so.
    try argv.appendSlice(arena, &.{ "-MD", "-MV", "-MF", dep_path, req.source, "-o", tmp_out });
    if (init.environ_map.get("ZIG_VERBOSE_CC") != null) std.log.info("{f}", .{std.zig.SubprocessCommand{ .argv = argv.items }});
    const res = std.process.run(arena, io, .{
        .argv = argv.items,
        .environ_map = init.environ_map,
        .stdout_limit = .unlimited,
        .stderr_limit = .unlimited,
    }) catch |err| main.fatal("unable to run translate-c ({s}): {t}", .{ exe, err });
    if (res.stderr.len != 0) try Io.File.stderr().writeStreamingAll(io, res.stderr);
    if (!res.term.success()) main.fatal("translate-c failed ({f}) translating '{s}'", .{ res.term, source });
    if (res.stdout.len != 0) {
        // `--zig-integration` reports Aro's errors as one ErrorBundle
        // message on stdout.
        var reader: Io.Reader = .fixed(res.stdout);
        const hdr = reader.takeStruct(std.zig.Server.Message.Header, .little) catch main.fatal("translate-c wrote an unreadable message", .{});
        const body = reader.take(hdr.bytes_len) catch main.fatal("translate-c wrote a truncated message", .{});
        if (hdr.tag != .error_bundle) main.fatal("unexpected message from translate-c: {t}", .{hdr.tag});
        return .{ .digest = digest, .cache_hit = false, .out_path = out_path, .inputs = source, .errors = body };
    }

    const inputs = ToolRecord.commit(arena, io, .{
        .record_path = record_path,
        .out_path = out_path,
        .tmp_out = tmp_out,
        .dep_path = dep_path,
        .source = source,
        .old_output = old_output,
        .start_ns = start_ns,
    }) catch |err| main.fatal("unable to record the translation of '{s}': {t}", .{ source, err });
    return .{ .digest = digest, .cache_hit = false, .out_path = out_path, .inputs = inputs };
}

/// Upstream's `-mcpu`: the model and every feature, each `+` or `-`.
fn mcpuArg(arena: std.mem.Allocator, target: *const std.Target) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.print(arena, "-mcpu={s}", .{target.cpu.model.name});
    for (target.cpu.arch.allFeaturesList(), 0..) |feature, i| {
        const on = target.cpu.features.isEnabled(@intCast(i));
        try buf.print(arena, "{c}{s}", .{ "-+"[@intFromBool(on)], feature.name });
    }
    return buf.items;
}

/// Builds translate-c once per bs binary and zig lib directory, into
/// `<global cache>/bs/o/<hash>/translate-c`, as the build runner, and
/// returns its path and the hash of its contents, kept beside it in
/// `translate-c.hash` while the binary stats as the stamp says.
fn ensureBinary(init: std.process.Init, lib: []const u8, global: []const u8, trusted: bool) !struct { []const u8, cache.Hash } {
    const arena = init.arena.allocator();
    const io = init.io;
    const seed, _ = try Incremental.compilationKey(arena, io, &.{}, lib, "x86_64-linux");
    const dir_hash = cache.hash(3, try std.mem.concat(arena, u8, &.{ std.mem.asBytes(&seed), lib }));
    const dir = try std.fmt.allocPrint(arena, "{s}/bs/o/{x:0>32}", .{ global, dir_hash });
    const exe = try std.fs.path.join(arena, &.{ dir, "translate-c" });
    const stamp = try std.fs.path.join(arena, &.{ dir, "translate-c.stat" });
    const hash_path = try std.fs.path.join(arena, &.{ dir, "translate-c.hash" });
    if (trusted and BuildRunner.toolUnchanged(io, exe, stamp)) if (readHash(io, hash_path)) |h| return .{ exe, h };
    try Io.Dir.cwd().createDirPath(io, dir);
    try BuildRunner.compileTool(init, dir, &.{
        "bs",                                                                              "build-exe",
        "--dep",                                                                           "aro",
        try std.fmt.allocPrint(arena, "-Mroot={s}/compiler/translate-c/main.zig", .{lib}), try std.fmt.allocPrint(arena, "-Maro={s}/compiler/aro/aro.zig", .{lib}),
        "--name",                                                                          "translate-c",
        "--zig-lib-dir",                                                                   lib,
        "--cache-dir",                                                                     global,
        "--global-cache-dir",                                                              global,
    }, "Compiling translate-c (first time setup)", "translate-c", try std.fmt.allocPrint(arena, "{s}/compiler/translate-c/main.zig", .{lib}), try std.fmt.allocPrint(arena, "{s}/compiler", .{lib}));
    // The binary's contents, hashed again only when it changed.
    if (BuildRunner.toolUnchanged(io, exe, stamp)) if (readHash(io, hash_path)) |h| return .{ exe, h };
    const content = cache.hash(0, try Io.Dir.cwd().readFileAlloc(io, exe, arena, .unlimited));
    var bytes: [16]u8 = undefined;
    std.mem.writeInt(cache.Hash, &bytes, content, .little);
    // The stamp vouches for the hash file, so it follows it.
    if (Io.Dir.cwd().writeFile(io, .{ .sub_path = hash_path, .data = &bytes, .flags = .{} })) |_| BuildRunner.noteTool(io, exe, stamp) else |_| {}
    return .{ exe, content };
}

fn readHash(io: Io, path: []const u8) ?cache.Hash {
    var buf: [16]u8 = undefined;
    const bytes = Io.Dir.cwd().readFile(io, path, &buf) catch return null;
    if (bytes.len != 16) return null;
    return std.mem.readInt(cache.Hash, &buf, .little);
}
