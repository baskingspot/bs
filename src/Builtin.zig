//! The generated `builtin` module: `@import("builtin")`.
//!
//! The text follows upstream Zig 0.17.0's `src/Builtin.zig` output for zap's
//! one Linux configuration: x86_64-linux-none, Debug, the self-hosted x86_64
//! backend, static linking.
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
    /// `-fPIC` and `-fPIE` on objects and libraries (see
    /// "Position-independent code" in docs/architecture.md).
    pic: bool = false,
    pie: bool = false,
};

pub fn generate(gpa: Allocator, opts: Options) Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa,
    \\const std = @import("std");
    \\pub const zig_version = std.SemanticVersion.parse(zig_version_string) catch unreachable;
    \\pub const zig_version_string = "0.17.0";
    \\pub const zig_backend = std.lang.CompilerBackend.stage2_x86_64;
    \\
    \\pub const output_mode: std.lang.OutputMode = .{s};
    \\pub const link_mode: std.lang.LinkMode = .static;
    \\pub const unwind_tables: std.lang.UnwindTables = .{s};
    \\pub const is_test = {s};
    \\pub const single_threaded = {s};
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
    \\pub const fuzz = {s};
    \\pub const position_independent_code = {s};
    \\pub const position_independent_executable = {s};
    \\pub const strip_debug_info = false;
    \\pub const code_model: std.lang.CodeModel = .default;
    \\pub const omit_frame_pointer = false;
    \\pub var test_functions: []const std.lang.TestFn = &.{{}}; // overwritten later
    \\
    , .{ @tagName(opts.output_mode), @tagName(opts.unwind_tables), if (opts.is_test) "true" else "false", if (opts.single_threaded) "true" else "false", if (opts.fuzz) "true" else "false", if (opts.pic) "true" else "false", if (opts.pie) "true" else "false" });
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
