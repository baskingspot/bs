//! The generated `builtin` module: `@import("builtin")`.
//!
//! The text follows upstream Zig 0.17.1's `src/Builtin.zig` output for zap's
//! one Linux configuration: x86_64-linux-none, Debug or ReleaseSafe, the
//! self-hosted x86_64 backend, static linking.
//! Copyright (c) Zig contributors. MIT licensed (see upstream/LICENSE).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const OutputMode = enum { Exe, Obj, Lib };

pub const Options = struct {
    output_mode: OutputMode,
    is_test: bool,
    single_threaded: bool = false,
    /// `builtin.unwind_tables` (`-funwind-tables` and friends). zap emits
    /// asynchronous tables for each, which serve every kind of request.
    unwind_tables: std.lang.UnwindTables = .async,
    /// `-ffuzz`.
    fuzz: bool = false,
    /// `-O`, `-ferror-tracing` and `-fvalgrind`, resolved (`main.Options`).
    optimize: std.lang.Optimize = .debug,
    error_tracing: bool = true,
    valgrind: bool = true,
    /// `-fPIC` and `-fPIE` on objects and libraries (see
    /// "Position-independent code" in docs/architecture.md).
    pic: bool = false,
    pie: bool = false,
    /// `-dynamic` on a library.
    dynamic: bool = false,
    /// `-lc`: glibc of this version, linked dynamically. As upstream, the
    /// ABI is gnu, and glibc makes code position-independent
    /// (`requiresPic`), which zap's executables need not be. The start
    /// code, which glibc's crt1.o would provide, comes with it
    /// (`glibc_start`).
    glibc: ?std.SemanticVersion = null,
    /// `-lc++`.
    link_libcpp: bool = false,
    /// `-mcpu` (`cpu.resolve`).
    cpu: std.Target.Cpu = @import("cpu.zig").baseline,
};

/// zap's start code for executables that link glibc, in place of glibc's
/// crt1.o (see "C interop" in docs/architecture.md). It sits next to
/// builtin.zig, which imports it from a `comptime` block (not a
/// declaration, so `@typeInfo(builtin)` is upstream's).
pub const glibc_start =
    \\//! zap's start code for executables that link glibc, in place of
    \\//! glibc's crt1.o: `_start` calls `__libc_start_main` with the `main`
    \\//! that std's start code exports, as glibc's sysdeps/x86_64/start.S
    \\//! does. glibc 2.34 and later run the init arrays themselves when
    \\//! `init` is null, as their own crt1.o passes it.
    \\
    \\comptime {
    \\    @export(&_start, .{ .name = "_start" });
    \\    @export(&_IO_stdin_used, .{ .name = "_IO_stdin_used" });
    \\}
    \\
    \\/// The stdio ABI version, which glibc's crt1.o defines.
    \\const _IO_stdin_used: c_int = 0x20001;
    \\
    \\extern fn main(argc: c_int, argv: [*]?[*:0]u8, envp: [*]?[*:0]u8) callconv(.c) c_int;
    \\extern fn __libc_start_main(
    \\    main: *const fn (c_int, [*]?[*:0]u8, [*]?[*:0]u8) callconv(.c) c_int,
    \\    argc: c_int,
    \\    argv: [*]?[*:0]u8,
    \\    init: ?*const fn () callconv(.c) void,
    \\    fini: ?*const fn () callconv(.c) void,
    \\    rtld_fini: ?*const fn () callconv(.c) void,
    \\    stack_end: *anyopaque,
    \\) callconv(.c) noreturn;
    \\
    \\fn _start() callconv(.naked) noreturn {
    \\    asm volatile (".cfi_undefined %%rip");
    \\    // The loader passes the function that runs the libraries'
    \\    // destructors in rdx.
    \\    asm volatile (
    \\        \\ xorl %%ebp, %%ebp
    \\        \\ movq %%rsp, %%rdi
    \\        \\ movq %%rdx, %%rsi
    \\        \\ andq $-16, %%rsp
    \\        \\ callq %[startMain:P]
    \\        :
    \\        : [startMain] "X" (&startMain),
    \\    );
    \\}
    \\
    \\fn startMain(sp: [*]usize, rtld_fini: ?*const fn () callconv(.c) void) callconv(.c) noreturn {
    \\    @setRuntimeSafety(false);
    \\    __libc_start_main(&main, @intCast(sp[0]), @ptrCast(sp + 1), null, null, rtld_fini, sp);
    \\}
    \\
;

/// The root file of an executable whose main is C's (a module of C sources
/// only, linking glibc). Upstream analyzes no Zig for it; zap's executables
/// need a Zig root for the start code, compiler_rt and ubsan_rt. std's
/// start code still runs, and declares `_start` unless the root does;
/// `glibc_start.zig` exports it.
pub const c_main =
    \\//! zap's root file for an executable whose `main` is C's: glibc_start.zig
    \\//! calls it, and std's start code exports neither `main` nor `_start`.
    \\
    \\pub const _start = {};
    \\
;

/// Writes `c_main` to `<cache_dir>/c_main/<content hash>/c_main.zig` unless
/// it is already there, and returns that path.
pub fn writeCMain(gpa: Allocator, io: Io, cache_dir: []const u8) ![]u8 {
    var hash: [16]u8 = undefined;
    std.crypto.hash.Blake3.hash(c_main, &hash, .{});
    const path = try std.fmt.allocPrint(gpa, "{s}/c_main/{x}/c_main.zig", .{ cache_dir, &hash });
    errdefer gpa.free(path);
    const cwd = Io.Dir.cwd();
    if (cwd.access(io, path, .{})) |_| return path else |_| {}
    var atomic = try cwd.createFileAtomic(io, path, .{ .make_path = true, .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, c_main);
    try atomic.replace(io);
    return path;
}

pub fn generate(gpa: Allocator, opts: Options) Allocator.Error![]u8 {
    const libc = opts.glibc != null;
    // Objects and static libraries with -lc stay static and take no start
    // code, as upstream's (`--show-builtin`).
    const exe_libc = libc and opts.output_mode == .Exe;
    const glibc = opts.glibc orelse std.SemanticVersion{ .major = 2, .minor = 31, .patch = 0 };
    // As upstream: every enabled feature, in the feature list's order.
    var features: std.ArrayList(u8) = .empty;
    defer features.deinit(gpa);
    for (opts.cpu.arch.allFeaturesList(), 0..) |feature, i| {
        if (opts.cpu.features.isEnabled(@intCast(i))) try features.print(gpa, "        .{f},\n", .{std.zig.fmtIdPU(feature.name)});
    }
    return std.fmt.allocPrint(gpa,
    \\const std = @import("std");
    \\pub const zig_version = std.SemanticVersion.parse(zig_version_string) catch unreachable;
    \\pub const zig_version_string = "0.17.1";
    \\pub const zig_backend = std.lang.CompilerBackend.stage2_x86_64;
    \\
    \\pub const output_mode: std.lang.OutputMode = .{s};
    \\pub const link_mode: std.lang.LinkMode = .{s};
    \\pub const unwind_tables: std.lang.UnwindTables = .{s};
    \\pub const is_test = {s};
    \\pub const single_threaded = {s};
    \\/// Deprecated; to be removed in 0.18.0. Use `target.abi` instead.
    \\pub const abi: std.Target.Abi = .{s};
    \\/// Deprecated; to be removed in 0.18.0. Use `target.cpu` instead.
    \\pub const cpu: std.Target.Cpu = .{{
    \\    .arch = .x86_64,
    \\    .model = &std.Target.x86.cpu.{f},
    \\    .features = std.Target.x86.featureSet(&.{{
    \\{s}    }}),
    \\}};
    \\/// Deprecated; to be removed in 0.18.0. Use `target.os` instead.
    \\pub const os: std.Target.Os = .{{
    \\    .tag = .linux,
    \\    .version_range = .{{ .linux = .{{
    \\        .range = .{{
    \\            .min = .{{
    \\                .major = 5,
    \\                .minor = 10,
    \\                .patch = 0,
    \\            }},
    \\            .max = .{{
    \\                .major = 7,
    \\                .minor = 2,
    \\                .patch = 0,
    \\            }},
    \\        }},
    \\        .glibc = .{{
    \\            .major = {d},
    \\            .minor = {d},
    \\            .patch = {d},
    \\        }},
    \\        .android = 29,
    \\    }}}},
    \\}};
    \\pub const target: std.Target = .{{
    \\    .cpu = cpu,
    \\    .os = os,
    \\    .abi = abi,
    \\    .ofmt = object_format,
    \\    .dynamic_linker = {s},
    \\}};
    \\/// Deprecated; to be removed in 0.18.0. Use `target.ofmt` instead.
    \\pub const object_format: std.Target.ObjectFormat = .elf;
    \\/// Deprecated, to be removed after 0.18.0
    \\pub const mode = optimize;
    \\pub const optimize: std.lang.Optimize = .{s};
    \\pub const link_libc = {s};
    \\pub const link_libcpp = {s};
    \\pub const have_error_return_tracing = {s};
    \\pub const valgrind_support = {s};
    \\pub const sanitize_thread = false;
    \\pub const fuzz = {s};
    \\pub const position_independent_code = {s};
    \\pub const position_independent_executable = {s};
    \\pub const strip_debug_info = false;
    \\pub const code_model: std.lang.CodeModel = .default;
    \\pub const omit_frame_pointer = false;
    \\pub var test_functions: []const std.lang.TestFn = &.{{}}; // overwritten later
    \\{s}
    , .{
        @tagName(opts.output_mode),
        if (opts.dynamic or exe_libc) "dynamic" else "static",
        @tagName(opts.unwind_tables),
        if (opts.is_test) "true" else "false",
        if (opts.single_threaded) "true" else "false",
        if (libc) "gnu" else "none",
        std.zig.fmtIdPU(opts.cpu.model.name),
        features.items,
        glibc.major,
        glibc.minor,
        glibc.patch,
        if (libc) ".init(\"/lib64/ld-linux-x86-64.so.2\")" else ".none",
        @tagName(opts.optimize),
        if (libc) "true" else "false",
        if (opts.link_libcpp) "true" else "false",
        if (opts.error_tracing) "true" else "false",
        if (opts.valgrind) "true" else "false",
        if (opts.fuzz) "true" else "false",
        if (opts.pic or libc) "true" else "false",
        if (opts.pie) "true" else "false",
        if (exe_libc) "comptime {\n    _ = @import(\"glibc_start.zig\");\n}\n" else "",
    });
}

/// Writes the generated source to `<cache_dir>/builtin/<content hash>/builtin.zig`
/// unless it is already there, and returns that directory.
pub fn writeToCache(gpa: Allocator, io: Io, cache_dir: []const u8, opts: Options) ![]u8 {
    const source = try generate(gpa, opts);
    defer gpa.free(source);
    var hash: [16]u8 = undefined;
    var hasher: std.crypto.hash.Blake3 = .init(.{});
    hasher.update(source);
    if (opts.glibc != null) hasher.update(glibc_start);
    hasher.final(&hash);
    const dir = try std.fmt.allocPrint(gpa, "{s}/builtin/{x}", .{ cache_dir, &hash });
    errdefer gpa.free(dir);
    const path = try std.fs.path.join(gpa, &.{ dir, "builtin.zig" });
    defer gpa.free(path);
    const cwd = Io.Dir.cwd();
    if (cwd.access(io, path, .{})) |_| return dir else |_| {}
    // The start file first: builtin.zig's presence says the directory is
    // complete.
    if (opts.glibc != null) {
        const start_path = try std.fs.path.join(gpa, &.{ dir, "glibc_start.zig" });
        defer gpa.free(start_path);
        var atomic = try cwd.createFileAtomic(io, start_path, .{ .make_path = true, .replace = true });
        defer atomic.deinit(io);
        try atomic.file.writeStreamingAll(io, glibc_start);
        try atomic.replace(io);
    }
    // Atomic, so concurrent builds never see a partial file.
    var atomic = try cwd.createFileAtomic(io, path, .{ .make_path = true, .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, source);
    try atomic.replace(io);
    return dir;
}
