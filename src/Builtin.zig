//! The generated `builtin` module: `@import("builtin")`.
//!
//! The text follows upstream Zig 0.17.0's `src/Builtin.zig` output for
//! zap's two configurations, both Debug: x86_64-linux-none with the
//! self-hosted x86_64 backend, linked statically, and aarch64-macos (CPU
//! `apple_m1`, macOS 15.0 to 27.0, as `-target aarch64-macos` gives) with
//! LLVM, linked against libSystem. `zig_backend` is upstream's Debug default
//! for the target, so std takes the code paths it takes with upstream.
//! Copyright (c) Zig contributors. MIT licensed (see upstream/LICENSE).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const InternPool = @import("InternPool.zig");

pub const OutputMode = enum { Exe, Obj };

pub const Options = struct {
    output_mode: OutputMode,
    is_test: bool,
    target: InternPool.Target = .x86_64_linux,
};

pub fn generate(gpa: Allocator, opts: Options) Allocator.Error![]u8 {
    const args = .{ @tagName(opts.output_mode), if (opts.is_test) "true" else "false" };
    if (opts.target == .aarch64_macos) return std.fmt.allocPrint(gpa,
    \\const std = @import("std");
    \\pub const zig_version = std.SemanticVersion.parse(zig_version_string) catch unreachable;
    \\pub const zig_version_string = "0.17.0";
    \\pub const zig_backend = std.lang.CompilerBackend.stage2_llvm;
    \\
    \\pub const output_mode: std.lang.OutputMode = .{s};
    \\pub const link_mode: std.lang.LinkMode = .dynamic;
    \\pub const unwind_tables: std.lang.UnwindTables = .async;
    \\pub const is_test = {s};
    \\pub const single_threaded = false;
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
    \\        .fuse_aes,
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
    \\            .major = 15,
    \\            .minor = 0,
    \\            .patch = 0,
    \\        }},
    \\        .max = .{{
    \\            .major = 27,
    \\            .minor = 0,
    \\            .patch = 0,
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
    \\pub const optimize: std.lang.Optimize = .debug;
    \\pub const link_libc = true;
    \\pub const link_libcpp = false;
    \\pub const have_error_return_tracing = true;
    \\pub const valgrind_support = false;
    \\pub const sanitize_thread = false;
    \\pub const fuzz = false;
    \\pub const position_independent_code = true;
    \\pub const position_independent_executable = true;
    \\pub const strip_debug_info = false;
    \\pub const code_model: std.lang.CodeModel = .default;
    \\pub const omit_frame_pointer = false;
    \\pub var test_functions: []const std.lang.TestFn = &.{{}}; // overwritten later
    \\
    , args);
    return std.fmt.allocPrint(gpa,
    \\const std = @import("std");
    \\pub const zig_version = std.SemanticVersion.parse(zig_version_string) catch unreachable;
    \\pub const zig_version_string = "0.17.0";
    \\pub const zig_backend = std.lang.CompilerBackend.stage2_x86_64;
    \\
    \\pub const output_mode: std.lang.OutputMode = .{s};
    \\pub const link_mode: std.lang.LinkMode = .static;
    \\pub const unwind_tables: std.lang.UnwindTables = .async;
    \\pub const is_test = {s};
    \\pub const single_threaded = false;
    \\/// Deprecated; to be removed in 0.18.0. Use `target.abi` instead.
    \\pub const abi: std.Target.Abi = .none;
    \\/// Deprecated; to be removed in 0.18.0. Use `target.cpu` instead.
    \\pub const cpu: std.Target.Cpu = .{{
    \\    .arch = .x86_64,
    \\    .model = &std.Target.x86.cpu.x86_64,
    \\    .features = std.Target.x86.featureSet(&.{{
    \\        .@"64bit",
    \\        .cmov,
    \\        .cx8,
    \\        .fxsr,
    \\        .idivq_to_divl,
    \\        .macrofusion,
    \\        .mmx,
    \\        .nopl,
    \\        .slow_3ops_lea,
    \\        .slow_incdec,
    \\        .sse,
    \\        .sse2,
    \\        .vzeroupper,
    \\        .x87,
    \\    }}),
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
    \\            .major = 2,
    \\            .minor = 31,
    \\            .patch = 0,
    \\        }},
    \\        .android = 29,
    \\    }}}},
    \\}};
    \\pub const target: std.Target = .{{
    \\    .cpu = cpu,
    \\    .os = os,
    \\    .abi = abi,
    \\    .ofmt = object_format,
    \\    .dynamic_linker = .none,
    \\}};
    \\/// Deprecated; to be removed in 0.18.0. Use `target.ofmt` instead.
    \\pub const object_format: std.Target.ObjectFormat = .elf;
    \\/// Deprecated, to be removed after 0.18.0
    \\pub const mode = optimize;
    \\pub const optimize: std.lang.Optimize = .debug;
    \\pub const link_libc = false;
    \\pub const link_libcpp = false;
    \\pub const have_error_return_tracing = true;
    \\pub const valgrind_support = true;
    \\pub const sanitize_thread = false;
    \\pub const fuzz = false;
    \\pub const position_independent_code = false;
    \\pub const position_independent_executable = false;
    \\pub const strip_debug_info = false;
    \\pub const code_model: std.lang.CodeModel = .default;
    \\pub const omit_frame_pointer = false;
    \\pub var test_functions: []const std.lang.TestFn = &.{{}}; // overwritten later
    \\
    , args);
}

/// Writes the generated source to `<cache_dir>/builtin/<content hash>/builtin.zig`
/// unless it is already there, and returns that directory.
pub fn writeToCache(gpa: Allocator, io: Io, cache_dir: []const u8, opts: Options) ![]u8 {
    const source = try generate(gpa, opts);
    defer gpa.free(source);
    var hash: [16]u8 = undefined;
    std.crypto.hash.Blake3.hash(source, &hash, .{});
    const dir = try std.fmt.allocPrint(gpa, "{s}/builtin/{x}", .{ cache_dir, &hash });
    errdefer gpa.free(dir);
    const path = try std.fs.path.join(gpa, &.{ dir, "builtin.zig" });
    defer gpa.free(path);
    const cwd = Io.Dir.cwd();
    if (cwd.access(io, path, .{})) |_| return dir else |_| {}
    // Atomic, so concurrent builds never see a partial file.
    var atomic = try cwd.createFileAtomic(io, path, .{ .make_path = true, .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, source);
    try atomic.replace(io);
    return dir;
}
