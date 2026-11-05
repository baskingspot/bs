//! The CPU bs generates code for (`-mcpu`): by default the host's,
//! clamped, for the native target and x86_64's baseline for an explicit
//! one, as upstream; or a CPU model and features up to x86-64-v2
//! (SSE4.2), plus features only inline assembly uses (AES-NI, PCLMULQDQ,
//! LZCNT, MOVBE, RDRAND and others).
//! AVX changes the vector ABI and is refused; the host's CPU is clamped
//! to the supported subset (docs/slop/architecture.md, "Where upstream
//! supports more").

const std = @import("std");
const Cpu = std.Target.Cpu;
const x86 = std.Target.x86;

/// x86_64's baseline CPU, the default for an explicit target.
pub const baseline: Cpu = x86.cpu.x86_64.toCpu(.x86_64);

/// The instruction set features bs accepts: x86-64-v2's, and for inline
/// assembly (`codegen/x86_64/asm_insn.zig`) aes, pclmul, clflushopt,
/// lzcnt, movbe, prfchw, rdpid, rdrnd and rdseed, which neither std nor
/// bs's code generation tests (std's `crypto.aes` and
/// `crypto.ghash_polyval` take their asm paths only with AVX too).
const isa = [_]x86.Feature{ .@"64bit", .aes, .clflushopt, .cmov, .crc32, .cx16, .cx8, .fxsr, .lzcnt, .mmx, .movbe, .nopl, .pclmul, .popcnt, .prfchw, .rdpid, .rdrnd, .rdseed, .sahf, .sse, .sse2, .sse3, .sse4_1, .sse4_2, .ssse3, .x87 };

/// Whether bs accepts instruction set feature `f` (`-mcpu`).
pub fn accepts(f: x86.Feature) bool {
    return std.mem.findScalar(x86.Feature, &isa, f) != null;
}

/// Whether feature `name` only tunes code generation (LLVM's tuning
/// features), which bs ignores and so accepts.
fn isTuning(name: []const u8) bool {
    const prefixes = [_][]const u8{
        "allow_light_256_bit", "branchfusion",     "bsf_bsr_0_clobbers_result", "ermsb",           "false_deps_",
        "fast_",               "faster_",          "fsrm",                      "idivl_to_divb",   "idivq_to_divl",
        "lea_sp",              "lea_uses_ag",      "macrofusion",               "no_bypass_delay", "pad_short_functions",
        "prefer_",             "sbb_dep_breaking", "slow_",                     "tuning_",         "use_",
        "vzeroupper",
    };
    for (prefixes) |p| if (std.mem.startsWith(u8, name, p)) return true;
    return false;
}

fn accepted(index: usize) bool {
    for (isa) |f| if (@backingInt(f) == index) return true;
    return isTuning(Cpu.Arch.x86_64.allFeaturesList()[index].name);
}

/// Whether feature `name` belongs to AVX or needs it.
fn isAvx(name: []const u8) bool {
    const prefixes = [_][]const u8{ "avx", "amx", "fma", "f16c", "xop", "vaes", "vpclmulqdq" };
    for (prefixes) |p| if (std.mem.startsWith(u8, name, p)) return true;
    return false;
}

pub const Resolved = struct {
    cpu: Cpu,
    /// Why the CPU is refused, if it is.
    refused: ?[]const u8 = null,
};

/// Resolves `-mcpu` value `text` (upstream's syntax: a model or
/// `baseline` or `native`, then `+feature` and `-feature`).
pub fn resolve(arena: std.mem.Allocator, io: std.Io, text: []const u8) Resolved {
    const query = std.Target.Query.parse(.{ .arch_os_abi = "x86_64-linux", .cpu_features = text }) catch |err|
        return .{ .cpu = baseline, .refused = arena.print("invalid CPU '{s}' ('-mcpu'): {t}", .{ text, err }) catch "out of memory" };
    const target = std.zig.system.resolveTargetQuery(io, query) catch |err|
        return .{ .cpu = baseline, .refused = arena.print("unable to resolve CPU '{s}' ('-mcpu'): {t}", .{ text, err }) catch "out of memory" };
    if (query.cpu_model == .native) return .{ .cpu = clamp(target.cpu) };
    var names: std.ArrayList(u8) = .empty;
    var avx = false;
    for (Cpu.Arch.x86_64.allFeaturesList(), 0..) |f, i| {
        if (!target.cpu.features.isEnabled(@intCast(i)) or accepted(i)) continue;
        avx = avx or isAvx(f.name);
        if (names.items.len != 0) names.appendSlice(arena, ", ") catch {}; // ziglint-ignore: Z026 -- out of memory only shortens the message
        names.appendSlice(arena, f.name) catch {}; // ziglint-ignore: Z026 -- out of memory only shortens the message
    }
    if (names.items.len == 0) return .{ .cpu = target.cpu };
    return .{ .cpu = baseline, .refused = arena.print("bs generates code for x86_64 CPUs up to x86-64-v2 (SSE4.2){s}; '-mcpu {s}' enables {s}", .{
        if (avx) " and does not support AVX" else "",
        text,
        names.items,
    }) catch "out of memory" };
}

/// The supported part of host CPU `host`: x86-64-v2 if it has all of
/// v2's instructions, else the baseline, plus the host's other accepted
/// instruction set features.
pub fn clamp(host: Cpu) Cpu {
    if (host.arch != .x86_64) return baseline;
    const v2 = x86.cpu.x86_64_v2.toCpu(.x86_64);
    var has_v2 = true;
    for (isa) |f| {
        if (v2.has(.x86, f) and !host.has(.x86, f)) has_v2 = false;
    }
    var cpu = if (has_v2) v2 else baseline;
    for (isa) |f| if (host.has(.x86, f)) cpu.features.addFeature(@backingInt(f));
    return cpu;
}

/// The CPU as cache keys name it: empty for the target's default CPU
/// (`default`), else its model and features.
pub fn cacheName(arena: std.mem.Allocator, cpu: Cpu, default: Cpu) ![]const u8 {
    if (cpu.model == default.model and cpu.features.eql(default.features)) return "";
    var s: std.ArrayList(u8) = .empty;
    try s.print(arena, "@{s}", .{cpu.model.name});
    for (cpu.features.ints) |w| try s.print(arena, ":{x}", .{w});
    return s.items;
}

// ---------------------------------------------------------------------------
// aarch64: by default the host's CPU, clamped, for the native target, and
// Apple's M1 (aarch64-macos) or the generic ARMv8.0 core (aarch64-linux)
// for an explicit one, as upstream; or a CPU model and features without
// SVE and SME, which bs's backend and assembler do not handle (with them
// std takes 256-bit vectors, `std.simd.suggestVectorLength`, and its Linux
// syscalls clobber the z and p registers).

const aarch64 = std.Target.aarch64;

/// The default CPU of an explicit target for `arch` (aarch64-macos's when
/// `macos`), as upstream's.
pub fn targetDefault(arch: std.Target.Cpu.Arch, macos: bool) Cpu {
    if (arch == .x86_64) return baseline;
    if (!macos) return aarch64.cpu.generic.toCpu(.aarch64);
    // Without fuse_aes, as `resolveTargetQuery` gives every Apple model.
    var cpu = aarch64.cpu.apple_m1.toCpu(.aarch64);
    cpu.features.removeFeature(@backingInt(aarch64.Feature.fuse_aes));
    return cpu;
}

/// Whether aarch64 feature `name` belongs to SVE or SME.
fn isScalable(name: []const u8) bool {
    const prefixes = [_][]const u8{ "sve", "sme", "ssve" };
    for (prefixes) |p| if (std.mem.startsWith(u8, name, p)) return true;
    return false;
}

/// aarch64 CPU `host` without SVE and SME.
pub fn clampAarch64(host: Cpu) Cpu {
    var cpu = host;
    for (Cpu.Arch.aarch64.allFeaturesList(), 0..) |f, i| {
        if (isScalable(f.name)) cpu.features.removeFeature(@intCast(i));
    }
    return cpu;
}

/// The host's CPU, clamped, when the host is aarch64.
pub fn nativeAarch64(io: std.Io) ?Cpu {
    if (@import("builtin").cpu.arch != .aarch64) return null;
    const host = std.zig.system.resolveTargetQuery(io, .{}) catch return null;
    return clampAarch64(host.cpu);
}

/// Resolves aarch64 `-mcpu` value `text` (upstream's syntax) for
/// aarch64-macos (`macos`) or aarch64-linux: `native` is the host's CPU,
/// clamped, or the target's default on a host of another architecture
/// (whose CPU upstream would put in an aarch64 builtin); a model or
/// features that enable SVE or SME are refused.
pub fn resolveAarch64(arena: std.mem.Allocator, io: std.Io, text: []const u8, macos: bool) Resolved {
    const default = targetDefault(.aarch64, macos);
    if (std.mem.eql(u8, text, "native")) return .{ .cpu = nativeAarch64(io) orelse default };
    const query = std.Target.Query.parse(.{ .arch_os_abi = if (macos) "aarch64-macos" else "aarch64-linux", .cpu_features = text }) catch |err|
        return .{ .cpu = default, .refused = std.fmt.allocPrint(arena, "invalid CPU '{s}' ('-mcpu'): {t}", .{ text, err }) catch "out of memory" };
    const target = std.zig.system.resolveTargetQuery(io, query) catch |err|
        return .{ .cpu = default, .refused = std.fmt.allocPrint(arena, "unable to resolve CPU '{s}' ('-mcpu'): {t}", .{ text, err }) catch "out of memory" };
    var names: std.ArrayList(u8) = .empty;
    for (Cpu.Arch.aarch64.allFeaturesList(), 0..) |f, i| {
        if (!target.cpu.features.isEnabled(@intCast(i)) or !isScalable(f.name)) continue;
        if (names.items.len != 0) names.appendSlice(arena, ", ") catch {};
        names.appendSlice(arena, f.name) catch {};
    }
    if (names.items.len == 0) return .{ .cpu = target.cpu };
    return .{ .cpu = default, .refused = std.fmt.allocPrint(arena, "bs does not generate SVE or SME code for aarch64; '-mcpu {s}' enables {s}", .{ text, names.items }) catch "out of memory" };
}

test resolve {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    try std.testing.expect(resolve(arena, io, "baseline").cpu.model == baseline.model);
    // Models and features up to x86-64-v2, with their tuning features.
    for ([_][]const u8{ "x86_64_v2", "nehalem", "penryn", "baseline+sse4_1", "x86_64+popcnt-sse3", "westmere", "x86_64_v2+aes+pclmul", "x86_64_v2+lzcnt+movbe+prfchw+rdrnd+rdseed+clflushopt+rdpid" }) |ok| {
        try std.testing.expectEqual(null, resolve(arena, io, ok).refused);
    }
    try std.testing.expect(resolve(arena, io, "nehalem").cpu.has(.x86, .sse4_2));
    // AVX, explicitly or through a model, and other features beyond v2.
    try std.testing.expectEqualStrings("bs generates code for x86_64 CPUs up to x86-64-v2 (SSE4.2) and does not support AVX; '-mcpu x86_64_v2+avx' enables avx", resolve(arena, io, "x86_64_v2+avx").refused.?);
    try std.testing.expect(std.mem.find(u8, resolve(arena, io, "haswell").refused.?, "does not support AVX") != null);
    try std.testing.expectEqualStrings("bs generates code for x86_64 CPUs up to x86-64-v2 (SSE4.2); '-mcpu x86_64_v2+sha' enables sha", resolve(arena, io, "x86_64_v2+sha").refused.?);
    try std.testing.expect(resolve(arena, io, "nosuchcpu").refused != null);
}

test clamp {
    // A Haswell host, whose cpuid reports AES-NI (the model leaves it out).
    var host = x86.cpu.haswell.toCpu(.x86_64);
    host.features.addFeature(@backingInt(x86.Feature.aes));
    const haswell = clamp(host);
    try std.testing.expect(haswell.model == &x86.cpu.x86_64_v2);
    try std.testing.expect(haswell.has(.x86, .sse4_2) and !haswell.has(.x86, .avx) and haswell.has(.x86, .aes) and haswell.has(.x86, .pclmul));
    const core2 = clamp(x86.cpu.core2.toCpu(.x86_64));
    try std.testing.expect(core2.model == baseline.model and core2.has(.x86, .ssse3) and !core2.has(.x86, .sse4_1));
}

test resolveAarch64 {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    // The targets' defaults, models without SVE, and features.
    // `-mcpu baseline`, which `zig build` passes, is the default exactly
    // (so its cache name is the target's alone).
    for ([_]bool{ true, false }) |macos| {
        const def = targetDefault(.aarch64, macos);
        const r = resolveAarch64(arena, io, "baseline", macos);
        try std.testing.expect(r.cpu.model == def.model and r.cpu.features.eql(def.features));
        try std.testing.expectEqualStrings("", try cacheName(arena, r.cpu, def));
    }
    try std.testing.expect(targetDefault(.aarch64, true).model == &aarch64.cpu.apple_m1);
    const n1 = resolveAarch64(arena, io, "neoverse_n1", false);
    try std.testing.expectEqual(null, n1.refused);
    try std.testing.expect(n1.cpu.has(.aarch64, .lse) and n1.cpu.has(.aarch64, .aes) and n1.cpu.has(.aarch64, .sha2));
    try std.testing.expect(resolveAarch64(arena, io, "generic+lse+crc", false).cpu.has(.aarch64, .crc));
    // SVE, through a model, a feature, or a feature that needs it.
    try std.testing.expect(std.mem.find(u8, resolveAarch64(arena, io, "a64fx", false).refused.?, "enables sve") != null);
    try std.testing.expect(resolveAarch64(arena, io, "generic+sve2", false).refused != null);
}

test clampAarch64 {
    // A Neoverse V1 host (SVE) keeps its model, AES, SHA-256 and LSE.
    const v1 = clampAarch64(aarch64.cpu.neoverse_v1.toCpu(.aarch64));
    try std.testing.expect(v1.model == &aarch64.cpu.neoverse_v1);
    try std.testing.expect(!v1.has(.aarch64, .sve) and v1.has(.aarch64, .aes) and v1.has(.aarch64, .sha2) and v1.has(.aarch64, .lse));
    const m4 = clampAarch64(aarch64.cpu.apple_m4.toCpu(.aarch64));
    try std.testing.expect(!m4.has(.aarch64, .sme) and m4.has(.aarch64, .fullfp16));
}
