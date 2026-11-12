//! `bs translate-c`: translates a C header (or source) to Zig with
//! upstream's translate-c (`lib/compiler/translate-c`, on Aro), which bs
//! builds itself, as `bs build` does the build runner. `b.addTranslateC`
//! runs it as `bs translate-c <flags> <file> --listen=-` and imports the
//! output, `<local cache>/o/<digest>/<stem>.zig`, as a module.
//!
//! The arguments that reach Aro are upstream's (`Compilation.translateC`
//! with `addCommonCCArgs(.aro)`) for bs's target: Debug, the baseline
//! CPU, and with `-lc` (always on macOS) libc's headers: the system's
//! for the native ABI (on macOS the SDK's), as upstream's, else those of
//! the zig lib directory (`CSource.libcIncludeDirs`;
//! docs/slop/architecture.md, "C interop").
//!
//! A translation record, `<local cache>/bs/tc/<key>`, lists every file
//! Aro read (from its `-MD` depfile) with its stat and content hash, and
//! the output's hash. The key covers bs, the translate-c binary, the
//! working directory, the source path and the arguments, not the files'
//! contents, so the output stays at one path across header edits, and a
//! build whose files all stat as recorded runs nothing.

const std = @import("std");
const Io = std.Io;
const main = @import("main.zig");
const cache = @import("cache.zig");
const Frontend = @import("Frontend.zig");
const Incremental = @import("Incremental.zig");
const BuildRunner = @import("BuildRunner.zig");
const ToolRecord = @import("ToolRecord.zig");
const CSource = @import("CSource.zig");
const toolchain = @import("toolchain.zig");
const language = @import("language.zig");
const InternPool = @import("InternPool.zig");
const Zcu = @import("Zcu.zig");
const cpu016 = @import("cpu016.zig");
const builtin = @import("builtin");

const Request = struct {
    source: []const u8,
    /// `@cImport`'s C source, in place of `source`: written to
    /// `cimport.h` in the output's directory, whose key covers the
    /// contents, so that the output is `cimport.zig`, as upstream's.
    c_src: ?[]const u8 = null,
    target: InternPool.Target,
    link_libc: bool,
    /// The target's glibc, which the target triple names: the native
    /// system's without `-target`, as upstream's native target, with or
    /// without `-lc`; null for musl and none ABIs.
    glibc_version: ?std.SemanticVersion,
    /// aarch64-macos: the macOS versions (`main.Options.macos_version`):
    /// the native system's without `-target`, as upstream's.
    macos_version: std.SemanticVersion.Range,
    /// A musl target (`x86_64-linux` is one), with or without `-lc`: the
    /// triple's ABI, and with `-lc` musl's headers, not
    /// position-independent, as upstream's.
    musl: bool,
    /// `-mcpu`, as for a compilation (`cpu.resolve`): it sets the macros
    /// the headers see (`__SSE4_1__`).
    cpu: std.Target.Cpu,
    /// Zig 0.16: `cpu` in 0.16's names (`cpu016.resolve`), which 0.16's
    /// translate-c takes in `-mcpu`.
    cpu_016: ?cpu016.Names = null,
    /// The user's C flags (include directories, macros), in order.
    cc_args: []const []const u8,
    /// `std.zig.system.NativePaths`' include directories, after libc's:
    /// upstream's `native_system_include_paths`, which a native target
    /// gets when the command names system libraries.
    native_includes: []const []const u8 = &.{},
    /// The native ABI (no `-target`): libc's headers are the system's
    /// (`CSource.libcIncludeDirs`), as upstream's.
    native_abi: bool = false,
    listen: bool,
    zig_lib: toolchain.LibDir,
    /// The Zig language of the translation: of the Zig it writes, and of
    /// the translate-c that writes it.
    language: language.Language,
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
    var mcpu: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--listen=-")) {
            opts.listen = true;
        } else if (std.mem.eql(u8, arg, "-target")) {
            opts.target = next(args, &i);
        } else if (std.mem.eql(u8, arg, "-mcpu") or std.mem.startsWith(u8, arg, "-mcpu=")) {
            mcpu = if (arg.len > "-mcpu".len) arg["-mcpu=".len..] else next(args, &i);
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
            main.setUnsupported(&opts, "bs does not support the option '{s}' for translate-c", arena, .{arg});
        } else if (source == null) {
            source = arg;
        } else {
            main.fatal("unexpected extra parameter: {s}", .{arg});
        }
    }
    const target = opts.target orelse "native";
    var native_includes: []const []const u8 = &.{};
    main.checkTarget(&opts, arena, io, target);
    if (named_libs and opts.unsupported == null and std.mem.eql(u8, target, "native") and builtin.os.tag == .linux) {
        if (std.zig.system.resolveTargetQuery(io, .{})) |native| {
            if (std.zig.system.NativePaths.detect(arena, io, &native, init.environ_map)) |paths| {
                native_includes = paths.include_dirs.items;
            } else |_| {}
        } else |_| {}
    }
    if (opts.link_libc and opts.unsupported == null and opts.bs_target != .aarch64_macos) main.resolveGlibc(&opts, arena);
    // The CPU of the code bs compiles the headers into.
    main.resolveCpu(&opts, arena, io, mcpu);
    // Darwin always links libc (libSystem), as upstream's
    // `requiresLibC`, so its headers are always on the include path.
    if (opts.bs_target == .aarch64_macos) opts.link_libc = true;
    const cache_dirs = Frontend.resolveCacheDirs(arena, io, init.environ_map, .{ .local = opts.cache_dir, .global = opts.global_cache_dir });
    const choice = try language.resolve(arena, io, init.environ_map, null, null);
    return .{
        .source = source orelse if (opts.unsupported != null) "" else main.fatal("expected a C source file to translate", .{}),
        .target = opts.bs_target,
        .link_libc = opts.link_libc,
        .glibc_version = opts.glibc_version,
        .macos_version = opts.macos_version,
        .musl = if (opts.linux) |t| t.abi == .musl else false,
        .cpu = opts.cpu,
        .cpu_016 = if (choice.language == .zig_0_16 and opts.unsupported == null) try cpu016.resolve(arena, opts.bs_target.arch(), opts.bs_target == .aarch64_macos, mcpu, std.mem.eql(u8, target, "native"), opts.cpu) else null,
        .cc_args = cc_args.items,
        .native_includes = native_includes,
        .native_abi = std.mem.eql(u8, target, "native"),
        .listen = opts.listen,
        .zig_lib = try toolchain.libDir(arena, io, init.environ_map, cache_dirs.global, opts.zig_lib_dir, choice.language),
        .language = choice.language,
        .cache_dirs = cache_dirs,
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
        bundle.renderToStderr(io, .{}, std.zig.Color.settingFromEnvironment(init.environ_map)) catch {}; // ziglint-ignore: Z026 -- stderr is where it would be reported
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
    try server.serveStringMessage(.zig_version, req.language.versionString());
    // Zig 0.16's protocol has no `config` message.
    if (req.language != .zig_0_16) try server.serveConfig(.{ .flags = .{
        .output_mode = .Obj,
        .link_mode = if (req.link_libc and !req.musl) .dynamic else .static,
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
                    .zig_lib_dir = req.zig_lib.path,
                    .trusted_lib = req.zig_lib.trusted,
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
    const lib = try Io.Dir.path.resolveAlloc(arena, &.{ cwd_path, req.zig_lib.path });
    const global = try Io.Dir.path.resolveAlloc(arena, &.{ cwd_path, req.cache_dirs.global });
    const local = req.cache_dirs.local;

    // As the build runner, translate-c from the default lib directory is
    // trusted not to change.
    const exe, const exe_hash, const use = try ensureBinary(init, lib, req.language, global, req.zig_lib.trusted, req.c_src != null);
    defer if (use) |f| f.close(io);

    // Upstream's arguments, with the depfile and output paths left for
    // last so that the key does not depend on them.
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{
        exe,                                      "--zig-integration",
        try arena.print("--zig-lib={s}", .{lib}), "--",
        "-x",                                     "c",
        "-isystem",                               try Io.Dir.path.join(arena, &.{ lib, "compiler", "aro", "include" }),
    });
    // Darwin code is always position-independent.
    const macos = req.target == .aarch64_macos;
    try argv.appendSlice(arena, &.{
        if (macos) "-fPIE" else "-fno-PIE", if (req.link_libc and !req.musl) "-fPIC" else "-fno-PIC",
        "-gdwarf-4",                        "-gdwarf32",
        "-fno-lto",                         "-fhosted",
        "-nostdinc",
    });
    var target = if (macos) try CSource.macosTarget(io, req.macos_version) else target: {
        const query_text = if (req.glibc_version) |v| try arena.print("{t}-linux-gnu.{f}", .{ req.cpu.arch, v }) else try arena.print("{t}-linux-{s}", .{ req.cpu.arch, if (req.musl) "musl" else "none" });
        break :target try std.zig.system.resolveTargetQuery(io, try std.Target.Query.parse(.{ .arch_os_abi = query_text, .cpu_features = "baseline" }));
    };
    target.cpu = req.cpu;
    if (req.link_libc and !macos and !req.musl) try argv.append(arena, try arena.print("-D__GLIBC_MINOR__={d}", .{req.glibc_version.?.minor}));
    try argv.appendSlice(arena, &.{ "-isystem", try Io.Dir.path.join(arena, &.{ lib, "include" }) });
    const libc_dirs: CSource.LibcDirs = if (req.link_libc) try CSource.libcIncludeDirs(arena, io, init.environ_map, global, lib, &target, req.native_abi) else .{ .includes = &.{} };
    for (libc_dirs.includes) |d| try argv.appendSlice(arena, &.{ "-isystem", d });
    for (req.native_includes) |d| try argv.appendSlice(arena, &.{ "-isystem", d });
    for (libc_dirs.frameworks) |d| try argv.appendSlice(arena, &.{ "-iframework", d });
    const mcpu = if (req.cpu_016) |names| try mcpu016Arg(arena, target.cpu.arch, names) else try mcpuArg(arena, &target);
    try argv.appendSlice(arena, &.{ "-O0", "-target", try target.zigTriple(arena), mcpu });
    try argv.appendSlice(arena, req.cc_args);

    // The key: the binary's contents, which bs's code generation makes
    // (a new bs that builds the same bytes keeps the records), the working
    // directory and the arguments, and the source's path or `@cImport`'s
    // source itself.
    var key_args: std.ArrayList([]const u8) = .empty;
    try key_args.appendSlice(arena, argv.items[1..]);
    try key_args.append(arena, if (req.c_src) |c_src| try std.mem.concat(arena, u8, &.{ "@cImport\x00", c_src }) else try Io.Dir.path.resolveAlloc(arena, &.{ cwd_path, req.source }));
    const key = try ToolRecord.key(arena, io, "translate-c", &std.fmt.bytesToHex(@as([16]u8, @bitCast(exe_hash)), .lower), lib, key_args.items);
    const digest: [16]u8 = @bitCast(key);
    const hex = std.fmt.bytesToHex(digest, .lower);
    const record_path = try Io.Dir.path.join(arena, &.{ local, "bs", "tc", &hex });
    const out_dir = try Io.Dir.path.join(arena, &.{ local, "o", &hex });
    // `@cImport`'s source goes beside its output, where the cache's
    // trimming deletes both, unless it is there from an earlier build.
    const source_arg = if (req.c_src) |c_src| path: {
        const h_path = try Io.Dir.path.join(arena, &.{ out_dir, "cimport.h" });
        if (cwd.access(io, h_path, .{})) |_| {} else |_| {
            try cwd.createDirPath(io, out_dir);
            try cache.writeReplace(io, cwd, h_path, &.{c_src});
        }
        break :path h_path;
    } else req.source;
    const source = try Io.Dir.path.resolveAlloc(arena, &.{ cwd_path, source_arg });
    const out_path = try Io.Dir.path.join(arena, &.{ out_dir, try arena.print("{s}.zig", .{Io.Dir.path.stem(source)}) });

    var old_output: ?cache.Hash = null;
    if (try ToolRecord.check(arena, arena, io, record_path, out_path, start_ns, null)) |c| switch (c) {
        .hit => |inputs| return .{ .digest = digest, .cache_hit = true, .out_path = out_path, .inputs = inputs },
        .miss => |h| old_output = h,
    };

    // Translate into the local cache's `bs/tmp`, then move the output
    // into place.
    const tmp_dir = try Io.Dir.path.join(arena, &.{ local, "bs", "tmp" });
    try cwd.createDirPath(io, tmp_dir);
    var rand: [8]u8 = undefined;
    io.random(&rand);
    const tmp_base = try Io.Dir.path.join(arena, &.{ tmp_dir, &std.fmt.bytesToHex(rand, .lower) });
    const dep_path = try arena.print("{s}-tc.d", .{tmp_base});
    const tmp_out = try arena.print("{s}-tc.zig", .{tmp_base});
    defer cwd.deleteFile(io, dep_path) catch {};
    defer cwd.deleteFile(io, tmp_out) catch {};
    // The source as given, as upstream, so that diagnostics name it so.
    try argv.appendSlice(arena, &.{ "-MD", "-MV", "-MF", dep_path, source_arg, "-o", tmp_out });
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

/// Zig 0.16's `@cImport`: translates `c_src` for `job`'s target with
/// upstream's arguments (`Compilation.cImport`), after the compilation's
/// C flags those of the importing module, `cc_argv`. The translation is
/// recorded and reused as `bs translate-c`'s.
pub fn cImport(init: std.process.Init, job: *const main.Job, c_src: []const u8, cc_argv: []const []const u8) !Zcu.CImport {
    const opts = &job.opts;
    const macos = opts.bs_target == .aarch64_macos;
    const req: Request = .{
        .source = "cimport.h",
        .c_src = c_src,
        .target = opts.bs_target,
        // Darwin always links libc (libSystem), as in `parse`.
        .link_libc = opts.link_libc or macos,
        .glibc_version = if (macos) null else opts.glibc_version,
        .macos_version = opts.macos_version,
        .musl = if (opts.linux) |t| t.abi == .musl else false,
        .cpu = opts.cpu,
        .cpu_016 = job.cpu_016,
        .cc_args = try std.mem.concat(init.arena.allocator(), []const u8, &.{ opts.c_global_cc_argv, cc_argv }),
        .native_includes = opts.c_native_includes,
        .native_abi = opts.target == null or std.mem.eql(u8, opts.target.?, "native"),
        .listen = false,
        .zig_lib = .{ .path = job.zig_lib_dir, .trusted = job.trusted_lib },
        .language = opts.language.language,
        .cache_dirs = job.cache_dirs,
        .build_root = null,
        .unsupported = null,
    };
    const r = try translate(init, &req);
    return .{ .dir = Io.Dir.path.dirname(r.out_path).?, .inputs = r.inputs, .errors = r.errors };
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

/// 0.16's `-mcpu`, as `mcpuArg`, from 0.16's tables.
fn mcpu016Arg(arena: std.mem.Allocator, arch: std.Target.Cpu.Arch, names: cpu016.Names) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.print(arena, "-mcpu={s}", .{names.model});
    var on = names.features;
    for (cpu016.features(arch)) |feature| {
        // `names.features` is in the tables' order.
        const enabled = on.len != 0 and std.mem.eql(u8, on[0], feature.name);
        if (enabled) on = on[1..];
        try buf.print(arena, "{c}{s}", .{ "-+"[@intFromBool(enabled)], feature.name });
    }
    return buf.items;
}

/// Builds translate-c once per bs binary and zig lib directory, into
/// `<global cache>/bs/o/<hash>/translate-c`, as the build runner, and
/// returns its path and the hash of its contents, kept beside it in
/// `translate-c.hash` while the binary stats as the stamp says. Also
/// returns the directory's use (`cache.useTool`), held while the binary
/// runs. `separate` builds it in a child process.
fn ensureBinary(init: std.process.Init, lib: []const u8, lang: language.Language, global: []const u8, trusted: bool, separate: bool) !struct { []const u8, cache.Hash, ?Io.File } {
    const arena = init.arena.allocator();
    const io = init.io;
    const seed, _ = try Incremental.compilationKey(arena, io, &.{}, lib, lang, "x86_64-linux");
    const dir_hash = cache.hash(3, try std.mem.concat(arena, u8, &.{ std.mem.asBytes(&seed), lib }));
    const dir = try arena.print("{s}/bs/o/{x:0>32}", .{ global, dir_hash });
    const exe = try Io.Dir.path.join(arena, &.{ dir, "translate-c" });
    const stamp = try Io.Dir.path.join(arena, &.{ dir, "translate-c.stat" });
    const hash_path = try Io.Dir.path.join(arena, &.{ dir, "translate-c.hash" });
    try Io.Dir.cwd().createDirPath(io, dir);
    const use = cache.useTool(io, dir) catch null;
    errdefer if (use) |f| f.close(io);
    if (trusted and BuildRunner.toolUnchanged(io, exe, stamp)) if (readHash(io, hash_path)) |h| return .{ exe, h, use };
    // In ReleaseSafe, as the build runner: std's ReleaseSafe paths, so the
    // allocator records no stack trace per allocation, which took more
    // than half of a Debug build's time translating a header. `-O` sets
    // the modules that follow it.
    const compile_args: []const []const u8 = &.{
        "bs",
        "build-exe",
        "--name",
        "translate-c",
        "--zig-lib-dir",
        lib,
        "--cache-dir",
        global,
        "--global-cache-dir",
        global,
        "-OReleaseSafe",
        "--dep",
        "aro",
        try arena.print("-Mroot={s}/compiler/translate-c/main.zig", .{lib}),
        "-OReleaseSafe",
        try arena.print("-Maro={s}/compiler/aro/aro.zig", .{lib}),
    };
    const root = try arena.print("{s}/compiler/translate-c/main.zig", .{lib});
    if (!separate) {
        const prog = std.Progress.start(io, .{ .root_name = "Compiling translate-c (first time setup)" });
        defer prog.end();
        try BuildRunner.compileTool(init, dir, compile_args, prog, "translate-c", root, try arena.print("{s}/compiler", .{lib}));
    } else {
        // `@cImport`, in the middle of a compilation, which compileTool's
        // change of directory and progress display would disturb: the
        // same build in a child bs, from the same directory, which keys
        // its cache the same way.
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(arena, try std.process.executablePathAlloc(io, arena));
        try argv.appendSlice(arena, compile_args[1..]);
        try argv.appendSlice(arena, &.{ "--bs-root-dir", try arena.print("{s}/compiler", .{lib}), "--zig-version", lang.versionString() });
        var env = try init.environ_map.clone(arena);
        _ = env.swapRemove("ZIG_PROGRESS");
        const r = std.process.run(arena, io, .{ .argv = argv.items, .cwd = .{ .path = dir }, .environ_map = &env }) catch |err|
            main.fatal("unable to run bs to compile translate-c: {t}", .{err});
        if (!r.term.success()) main.fatal("bs could not compile translate-c ({s}):\n{s}", .{ root, r.stderr });
    }
    // The binary's contents, hashed again only when it changed.
    if (BuildRunner.toolUnchanged(io, exe, stamp)) if (readHash(io, hash_path)) |h| return .{ exe, h, use };
    const content = cache.hash(0, try Io.Dir.cwd().readFileAlloc(io, exe, arena, .unlimited));
    var bytes: [16]u8 = undefined;
    std.mem.writeInt(cache.Hash, &bytes, content, .little);
    // The stamp vouches for the hash file, so it follows it.
    if (Io.Dir.cwd().writeFile(io, .{ .sub_path = hash_path, .data = &bytes, .flags = .{} })) |_| BuildRunner.noteTool(io, exe, stamp) else |_| {}
    return .{ exe, content, use };
}

fn readHash(io: Io, path: []const u8) ?cache.Hash {
    var buf: [16]u8 = undefined;
    const bytes = Io.Dir.cwd().readFile(io, path, &buf) catch return null;
    if (bytes.len != 16) return null;
    return std.mem.readInt(cache.Hash, &buf, .little);
}
