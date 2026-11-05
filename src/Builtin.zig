//! The generated `builtin` module: `@import("builtin")`.
//!
//! The text follows upstream Zig 0.17.1's `src/Builtin.zig` output for
//! bs's targets, Debug or ReleaseSafe: x86_64-linux-none with the
//! self-hosted x86_64 backend, linked statically unless it links glibc,
//! aarch64-linux-none (CPU `generic`) with LLVM, linked statically, and
//! aarch64-macos (CPU `apple_m1`, macOS 15.0 to 27.0 as `-target
//! aarch64-macos` gives, or the versions the target names) with LLVM,
//! linked against libSystem.
//! `zig_backend` is upstream's Debug default for the target, so std takes
//! the code paths it takes with upstream.
//! Copyright (c) Zig contributors. MIT licensed (see LICENSE-ZIG).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const InternPool = @import("InternPool.zig");
const cpu_mod = @import("cpu.zig");

pub const OutputMode = enum { Exe, Obj, Lib };

/// `-target aarch64-macos`'s versions, as upstream's
/// (`std.Target.Os.VersionRange.default`).
pub const macos_default: std.SemanticVersion.Range = .{ .min = .{ .major = 15, .minor = 0, .patch = 0 }, .max = .{ .major = 27, .minor = 0, .patch = 0 } };

pub const Options = struct {
    output_mode: OutputMode,
    is_test: bool,
    single_threaded: bool = false,
    /// `builtin.unwind_tables` (`-funwind-tables` and friends). bs emits
    /// asynchronous tables for each, which serve every kind of request.
    unwind_tables: std.lang.UnwindTables = .async,
    /// `-ffuzz`.
    fuzz: bool = false,
    /// `-O`, `-ferror-tracing` and `-fvalgrind`, resolved (`main.Options`).
    optimize: std.lang.Optimize = .debug,
    error_tracing: bool = true,
    valgrind: bool = true,
    /// `-fstrip`.
    strip: bool = false,
    /// `-fPIC` and `-fPIE` on objects and libraries (see
    /// "Position-independent code" in docs/slop/architecture.md).
    pic: bool = false,
    pie: bool = false,
    /// `-dynamic` on a library.
    dynamic: bool = false,
    /// `-lc`: glibc of this version, linked dynamically. As upstream, the
    /// ABI is gnu, and glibc makes code position-independent
    /// (`requiresPic`), which bs's executables need not be. The start
    /// code, which glibc's crt1.o would provide, comes with it
    /// (`glibc_start`).
    glibc: ?std.SemanticVersion = null,
    /// `-lc` with a musl target: musl's libc.a and crt1.o, linked
    /// statically, which bring the start code; code stays as it is
    /// without libc (no PIC).
    musl: bool = false,
    /// Whether this builtin brings the start code with `glibc`: the root
    /// module's does; the builtin of a module whose options differ (see
    /// `main`) does not, or the program would export `_start` twice.
    start_code: bool = true,
    /// Linux: the target as upstream resolves it (`main.checkTarget`),
    /// whose ABI, kernel and glibc versions and dynamic linker builtin
    /// states; without one, x86_64-linux-none.
    linux: ?std.Target = null,
    /// aarch64-macos: the macOS versions (`main.checkTarget`).
    macos: std.SemanticVersion.Range = macos_default,
    /// `-lc++`.
    link_libcpp: bool = false,
    /// `-mcpu` (`cpu.resolve`).
    cpu: std.Target.Cpu = cpu_mod.baseline,
    target: InternPool.Target = .x86_64_linux,
};

/// bs's start code for executables that link glibc, in place of glibc's
/// crt1.o (see "C interop" in docs/slop/architecture.md). It sits next to
/// builtin.zig, which imports it from a `comptime` block (not a
/// declaration, so `@typeInfo(builtin)` is upstream's).
pub const glibc_start =
    \\//! bs's start code for executables that link glibc, in place of
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

/// `glibc_start` for aarch64, as glibc's sysdeps/aarch64/start.S: the
/// loader passes the destructors' function in x0.
pub const glibc_start_aarch64 =
    \\//! bs's start code for executables that link glibc, in place of
    \\//! glibc's crt1.o: `_start` calls `__libc_start_main` with the `main`
    \\//! that std's start code exports, as glibc's sysdeps/aarch64/start.S
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
    \\    asm volatile (".cfi_undefined lr");
    \\    asm volatile (
    \\        \\ mov fp, #0
    \\        \\ mov lr, #0
    \\        \\ mov x1, x0
    \\        \\ mov x0, sp
    \\        \\ and sp, x0, #-16
    \\        \\ b %[startMain]
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

/// The start code `glibc_start` names for `arch`.
pub fn glibcStart(arch: std.Target.Cpu.Arch) []const u8 {
    return if (arch == .aarch64) glibc_start_aarch64 else glibc_start;
}

/// The root file of an executable whose main is C's (a module of C sources
/// only, linking glibc) or of a shared library of C only. Upstream analyzes
/// no Zig for them; bs's need a Zig root for the start code, compiler_rt
/// and ubsan_rt. std's
/// start code still runs, and declares `_start` unless the root does;
/// `glibc_start.zig` exports it. Its std options are those of upstream's
/// ubsan_rt.zig root, the only Zig upstream links into C: no networking
/// (std's I/O would import the socket functions), and no segfault
/// handler, which upstream's crt1.o does not install.
pub const c_main =
    \\//! bs's root file for an executable whose `main` is C's: glibc_start.zig
    \\//! calls it, and std's start code exports neither `main` nor `_start`;
    \\//! also for one linked from objects alone, one of which has `_start`.
    \\
    \\pub const _start = {};
    \\pub const std_options: @import("std").Options = .{ .networking = false, .enable_segfault_handler = false };
    \\
;

/// `c_main` when no UBSan runtime reports for C (`-fsanitize-c=full`):
/// upstream's crt1.o and compiler_rt have no panic handler, so neither
/// does bs's start code and compiler_rt, and std's handler and its I/O,
/// whose libc functions older glibc lacks, stay out.
const c_main_no_panic = c_main ++
    \\pub const panic = @import("std").debug.no_panic;
    \\
;

/// Writes `c_main` (or `c_main_no_panic`) to
/// `<cache_dir>/c_main/<content hash>/c_main.zig` unless it is already
/// there, and returns that path.
pub fn writeCMain(gpa: Allocator, io: Io, cache_dir: []const u8, no_panic: bool) ![]u8 {
    const src = if (no_panic) c_main_no_panic else c_main;
    var hash: [16]u8 = undefined;
    std.crypto.hash.Blake3.hash(src, &hash, .{});
    const path = try gpa.print("{s}/c_main/{x}/c_main.zig", .{ cache_dir, &hash });
    errdefer gpa.free(path);
    const cwd = Io.Dir.cwd();
    if (cwd.access(io, path, .{})) |_| return path else |_| {}
    var atomic = try cwd.createFileAtomic(io, path, .{ .make_path = true, .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, src);
    try atomic.replace(io);
    return path;
}

pub fn generate(gpa: Allocator, opts: Options) Allocator.Error![]u8 {
    if (opts.target == .aarch64_macos) return gpa.print(
        \\const std = @import("std");
        \\pub const zig_version = std.SemanticVersion.parse(zig_version_string) catch unreachable;
        \\pub const zig_version_string = "0.17.1";
        \\pub const zig_backend = std.lang.CompilerBackend.stage2_llvm;
        \\
        \\pub const output_mode: std.lang.OutputMode = .{s};
        \\pub const link_mode: std.lang.LinkMode = .dynamic;
        \\pub const unwind_tables: std.lang.UnwindTables = .{s};
        \\pub const is_test = {s};
        \\pub const single_threaded = {s};
        \\/// Deprecated; to be removed in 0.18.0. Use `target.abi` instead.
        \\pub const abi: std.Target.Abi = .none;
        \\/// Deprecated; to be removed in 0.18.0. Use `target.cpu` instead.
        \\pub const cpu: std.Target.Cpu = .{{
        \\    .arch = .aarch64,
        \\    .model = &std.Target.aarch64.cpu.apple_m1,
        \\    .features = std.Target.aarch64.featureSet(&.{{
        \\        .aes,
        \\        .aggressive_fma,
        \\        .alternate_sextload_cvt_f32_pattern,
        \\        .altnzcv,
        \\        .am,
        \\        .arith_bcc_fusion,
        \\        .arith_cbz_fusion,
        \\        .ccdp,
        \\        .ccidx,
        \\        .ccpp,
        \\        .complxnum,
        \\        .contextidr_el2,
        \\        .crc,
        \\        .disable_latency_sched_heuristic,
        \\        .dit,
        \\        .dotprod,
        \\        .el2vmsa,
        \\        .el3,
        \\        .flagm,
        \\        .fp16fml,
        \\        .fp_armv8,
        \\        .fptoint,
        \\        .fullfp16,
        \\        .fuse_address,
        \\        .fuse_arith_logic,
        \\        .fuse_crypto_eor,
        \\        .fuse_csel,
        \\        .fuse_literals,
        \\        .jsconv,
        \\        .lor,
        \\        .lse,
        \\        .lse2,
        \\        .max_interleave_factor_4,
        \\        .mpam,
        \\        .neon,
        \\        .no_zcz_fpr64,
        \\        .nv,
        \\        .pan,
        \\        .pan_rwv,
        \\        .pauth,
        \\        .perfmon,
        \\        .predres,
        \\        .ras,
        \\        .rcpc,
        \\        .rcpc_immo,
        \\        .rdm,
        \\        .sb,
        \\        .sel2,
        \\        .sha2,
        \\        .sha3,
        \\        .specrestrict,
        \\        .ssbs,
        \\        .store_pair_suppress,
        \\        .tlb_rmi,
        \\        .tracev8_4,
        \\        .uaops,
        \\        .v8_1a,
        \\        .v8_2a,
        \\        .v8_3a,
        \\        .v8_4a,
        \\        .v8a,
        \\        .vh,
        \\        .zcm_fpr128,
        \\        .zcm_gpr64,
        \\        .zcz_fpr128,
        \\        .zcz_gpr32,
        \\        .zcz_gpr64,
        \\    }}),
        \\}};
        \\/// Deprecated; to be removed in 0.18.0. Use `target.os` instead.
        \\pub const os: std.Target.Os = .{{
        \\    .tag = .macos,
        \\    .version_range = .{{ .semver = .{{
        \\        .min = .{{
        \\            .major = {d},
        \\            .minor = {d},
        \\            .patch = {d},
        \\        }},
        \\        .max = .{{
        \\            .major = {d},
        \\            .minor = {d},
        \\            .patch = {d},
        \\        }},
        \\    }}}},
        \\}};
        \\pub const target: std.Target = .{{
        \\    .cpu = cpu,
        \\    .os = os,
        \\    .abi = abi,
        \\    .ofmt = object_format,
        \\    .dynamic_linker = .init("/usr/lib/dyld"),
        \\}};
        \\/// Deprecated; to be removed in 0.18.0. Use `target.ofmt` instead.
        \\pub const object_format: std.Target.ObjectFormat = .macho;
        \\/// Deprecated, to be removed after 0.18.0
        \\pub const mode = optimize;
        \\pub const optimize: std.lang.Optimize = .{s};
        \\pub const link_libc = true;
        \\pub const link_libcpp = {s};
        \\pub const have_error_return_tracing = {s};
        \\pub const valgrind_support = false;
        \\pub const sanitize_thread = false;
        \\pub const fuzz = {s};
        \\pub const position_independent_code = true;
        \\pub const position_independent_executable = true;
        \\pub const strip_debug_info = {s};
        \\pub const code_model: std.lang.CodeModel = .default;
        \\pub const omit_frame_pointer = false;
        \\pub var test_functions: []const std.lang.TestFn = &.{{}}; // overwritten later
        \\
    , .{
        @tagName(opts.output_mode),
        @tagName(opts.unwind_tables),
        if (opts.is_test) "true" else "false",
        if (opts.single_threaded) "true" else "false",
        opts.macos.min.major,
        opts.macos.min.minor,
        opts.macos.min.patch,
        opts.macos.max.major,
        opts.macos.max.minor,
        opts.macos.max.patch,
        @tagName(opts.optimize),
        if (opts.link_libcpp) "true" else "false",
        if (opts.error_tracing) "true" else "false",
        if (opts.fuzz) "true" else "false",
        if (opts.strip) "true" else "false",
    });
    const libc = opts.glibc != null or opts.musl;
    // Objects and static libraries with -lc stay static and take no start
    // code, as upstream's (`--show-builtin`); so do musl's executables.
    const exe_libc = opts.glibc != null and opts.output_mode == .Exe;
    const abi: std.Target.Abi = if (opts.linux) |t| t.abi else .none;
    const versions: std.Target.Os.LinuxVersionRange = if (opts.linux) |t| t.os.version_range.linux else .{
        .range = .{ .min = .{ .major = 5, .minor = 10, .patch = 0 }, .max = .{ .major = 7, .minor = 2, .patch = 0 } },
        .glibc = .{ .major = 2, .minor = 31, .patch = 0 },
        .android = 29,
    };
    const glibc = opts.glibc orelse versions.glibc;
    var ld_buf: [255 * 4 + 16]u8 = undefined;
    const dynamic_linker = if (opts.linux) |t| if (t.dynamic_linker.get()) |ld|
        std.mem.print(&ld_buf, ".init(\"{f}\")", .{std.zig.fmtString(ld)}) catch unreachable
    else
        ".none" else ".none";
    const cpu_ns = switch (opts.cpu.arch) {
        .x86_64 => "x86",
        else => @tagName(opts.cpu.arch),
    };
    // As upstream: every enabled feature, in the feature list's order.
    var features: std.ArrayList(u8) = .empty;
    defer features.deinit(gpa);
    for (opts.cpu.arch.allFeaturesList(), 0..) |feature, i| {
        if (opts.cpu.features.isEnabled(@intCast(i))) try features.print(gpa, "        .{f},\n", .{std.zig.fmtIdPU(feature.name)});
    }
    // Two calls: format takes at most 32 arguments.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.print(gpa,
        \\const std = @import("std");
        \\pub const zig_version = std.SemanticVersion.parse(zig_version_string) catch unreachable;
        \\pub const zig_version_string = "0.17.1";
        \\pub const zig_backend = std.lang.CompilerBackend.{s};
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
        \\    .arch = .{s},
        \\    .model = &std.Target.{s}.cpu.{f},
        \\    .features = std.Target.{s}.featureSet(&.{{
        \\{s}    }}),
        \\}};
        \\/// Deprecated; to be removed in 0.18.0. Use `target.os` instead.
        \\pub const os: std.Target.Os = .{{
        \\    .tag = .linux,
        \\    .version_range = .{{ .linux = .{{
        \\        .range = .{{
        \\            .min = .{{
        \\                .major = {d},
        \\                .minor = {d},
        \\                .patch = {d},
        \\            }},
        \\            .max = .{{
        \\                .major = {d},
        \\                .minor = {d},
        \\                .patch = {d},
        \\            }},
        \\        }},
        \\        .glibc = .{{
        \\            .major = {d},
        \\            .minor = {d},
        \\            .patch = {d},
        \\        }},
        \\        .android = {d},
        \\    }}}},
        \\}};
        \\
    , .{
        // Upstream's Debug default: its own backend on x86_64-linux, LLVM
        // on aarch64-linux.
        if (opts.target == .x86_64_linux) "stage2_x86_64" else "stage2_llvm",
        @tagName(opts.output_mode),
        if (opts.dynamic or exe_libc) "dynamic" else "static",
        @tagName(opts.unwind_tables),
        if (opts.is_test) "true" else "false",
        if (opts.single_threaded) "true" else "false",
        @tagName(abi),
        @tagName(opts.cpu.arch),
        cpu_ns,
        std.zig.fmtIdPU(opts.cpu.model.name),
        cpu_ns,
        features.items,
        versions.range.min.major,
        versions.range.min.minor,
        versions.range.min.patch,
        versions.range.max.major,
        versions.range.max.minor,
        versions.range.max.patch,
        glibc.major,
        glibc.minor,
        glibc.patch,
        versions.android,
    });
    try out.print(gpa,
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
        \\pub const strip_debug_info = {s};
        \\pub const code_model: std.lang.CodeModel = .default;
        \\pub const omit_frame_pointer = false;
        \\pub var test_functions: []const std.lang.TestFn = &.{{}}; // overwritten later
        \\{s}
    , .{
        dynamic_linker,
        @tagName(opts.optimize),
        if (libc) "true" else "false",
        if (opts.link_libcpp) "true" else "false",
        if (opts.error_tracing) "true" else "false",
        if (opts.valgrind) "true" else "false",
        if (opts.fuzz) "true" else "false",
        if (opts.pic or opts.glibc != null) "true" else "false",
        if (opts.pie) "true" else "false",
        if (opts.strip) "true" else "false",
        if (exe_libc and opts.start_code) "comptime {\n    _ = @import(\"glibc_start.zig\");\n}\n" else "",
    });
    return out.toOwnedSlice(gpa);
}

/// Writes the generated source to `<cache_dir>/builtin/<content hash>/builtin.zig`
/// unless it is already there, and returns that directory.
pub fn writeToCache(gpa: Allocator, io: Io, cache_dir: []const u8, opts: Options) ![]u8 {
    const source = try generate(gpa, opts);
    defer gpa.free(source);
    var hash: [16]u8 = undefined;
    var hasher: std.crypto.hash.Blake3 = .init(.{});
    hasher.update(source);
    const start = opts.glibc != null and opts.start_code;
    if (start) hasher.update(glibcStart(opts.cpu.arch));
    hasher.final(&hash);
    const dir = try gpa.print("{s}/builtin/{x}", .{ cache_dir, &hash });
    errdefer gpa.free(dir);
    const path = try Io.Dir.path.join(gpa, &.{ dir, "builtin.zig" });
    defer gpa.free(path);
    const cwd = Io.Dir.cwd();
    if (cwd.access(io, path, .{})) |_| return dir else |_| {}
    // The start file first: builtin.zig's presence says the directory is
    // complete.
    if (start) {
        const start_path = try Io.Dir.path.join(gpa, &.{ dir, "glibc_start.zig" });
        defer gpa.free(start_path);
        var atomic = try cwd.createFileAtomic(io, start_path, .{ .make_path = true, .replace = true });
        defer atomic.deinit(io);
        try atomic.file.writeStreamingAll(io, glibcStart(opts.cpu.arch));
        try atomic.replace(io);
    }
    // Atomic, so concurrent builds never see a partial file.
    var atomic = try cwd.createFileAtomic(io, path, .{ .make_path = true, .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, source);
    try atomic.replace(io);
    return dir;
}
