//! The CPU bs compiles for (`-mcpu`), which `builtin.cpu` reports: by
//! default the host's, clamped, for the native target and x86_64's
//! baseline for an explicit one, as upstream; or an explicit CPU model
//! and features, as upstream resolves them. bs's own code uses
//! instructions up to x86-64-v2 (SSE4.2) on any of them; inline assembly
//! may use what the assembler encodes (docs/slop/architecture.md, "Where
//! upstream supports more").

const std = @import("std");
const builtin = @import("builtin");
const Cpu = std.Target.Cpu;
const x86 = std.Target.x86;

/// x86_64's baseline CPU, the default for an explicit target.
pub const baseline: Cpu = x86.cpu.x86_64.toCpu(.x86_64);

/// The instruction set features bs's code generation and inline
/// assembler know: x86-64-v2's, and for inline assembly
/// (`codegen/x86_64/asm_insn.zig`) aes, pclmul, clflushopt, lzcnt, movbe,
/// prfchw, rdpid, rdrnd and rdseed. The host's CPU is clamped to them.
const isa = [_]x86.Feature{ .@"64bit", .aes, .clflushopt, .cmov, .crc32, .cx16, .cx8, .fxsr, .lzcnt, .mmx, .movbe, .nopl, .pclmul, .popcnt, .prfchw, .rdpid, .rdrnd, .rdseed, .sahf, .sse, .sse2, .sse3, .sse4_1, .sse4_2, .ssse3, .x87 };

/// Whether the host's CPU keeps feature `f` when clamped (`isa`).
pub fn accepts(f: x86.Feature) bool {
    return std.mem.findScalar(x86.Feature, &isa, f) != null;
}

pub const Resolved = struct {
    cpu: Cpu,
    /// Why the CPU is refused, if it is.
    refused: ?[]const u8 = null,
};

/// Resolves `-mcpu` value `text` (upstream's syntax: a model or
/// `baseline` or `native`, then `+feature` and `-feature`). An explicit
/// CPU is upstream's, whatever its instruction sets: `builtin.cpu` and
/// the program's comptime choices are the ones upstream makes (a kernel
/// object built for `x86_64_v3` sees AVX2), while bs's own code uses
/// only the instructions `isa` lists, which every such CPU has.
/// `native` is the host's CPU, clamped (`clamp`). Features no CPU model
/// has are refused.
pub fn resolve(arena: std.mem.Allocator, io: std.Io, text: []const u8) Resolved {
    const query = std.Target.Query.parse(.{ .arch_os_abi = "x86_64-linux", .cpu_features = text }) catch |err|
        return .{ .cpu = baseline, .refused = arena.print("invalid CPU '{s}' ('-mcpu'): {t}", .{ text, err }) catch "out of memory" };
    const target = std.zig.system.resolveTargetQuery(io, query) catch |err|
        return .{ .cpu = baseline, .refused = arena.print("unable to resolve CPU '{s}' ('-mcpu'): {t}", .{ text, err }) catch "out of memory" };
    if (query.cpu_model == .native) return .{ .cpu = clamp(target.cpu) };
    // Every feature some CPU model has: instruction set extensions and
    // tuning. The others (`retpoline`, `lvi_cfi`, ...) change how code is
    // generated, not which instructions exist, and so does `soft_float`
    // (floats in GPRs), which only the 32-bit Lakemont has.
    var known: Cpu.Feature.Set = .empty;
    for (Cpu.Arch.x86_64.allCpuModels()) |m| known.addFeatureSet(m.features);
    known.populateDependencies(Cpu.Arch.x86_64.allFeaturesList());
    known.removeFeature(@backingInt(x86.Feature.soft_float));
    var names: std.ArrayList(u8) = .empty;
    for (Cpu.Arch.x86_64.allFeaturesList(), 0..) |f, i| {
        if (!target.cpu.features.isEnabled(@intCast(i)) or known.isEnabled(@intCast(i))) continue;
        if (names.items.len != 0) names.appendSlice(arena, ", ") catch {}; // ziglint-ignore: Z026 -- out of memory only shortens the message
        names.appendSlice(arena, f.name) catch {}; // ziglint-ignore: Z026 -- out of memory only shortens the message
    }
    if (names.items.len == 0) return .{ .cpu = target.cpu };
    return .{ .cpu = baseline, .refused = arena.print("bs does not generate code with x86_64 CPU features that change code generation rather than add instructions; '-mcpu {s}' enables {s}; build this step with upstream zig", .{
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
pub fn targetDefault(arch: Cpu.Arch, macos: bool) Cpu {
    if (arch == .x86_64) return baseline;
    if (!macos) return aarch64.cpu.generic.toCpu(.aarch64);
    // Without fuse_aes, as `resolveTargetQuery` gives every Apple model.
    var cpu = aarch64.cpu.apple_m1.toCpu(.aarch64);
    cpu.features.removeFeature(@backingInt(aarch64.Feature.fuse_aes));
    return cpu;
}

/// Whether aarch64 feature `name` belongs to SVE or SME.
pub fn isScalable(name: []const u8) bool {
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
    if (builtin.cpu.arch != .aarch64) return null;
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
        return .{ .cpu = default, .refused = arena.print("invalid CPU '{s}' ('-mcpu'): {t}", .{ text, err }) catch "out of memory" };
    const target = std.zig.system.resolveTargetQuery(io, query) catch |err|
        return .{ .cpu = default, .refused = arena.print("unable to resolve CPU '{s}' ('-mcpu'): {t}", .{ text, err }) catch "out of memory" };
    var names: std.ArrayList(u8) = .empty;
    for (Cpu.Arch.aarch64.allFeaturesList(), 0..) |f, i| {
        if (!target.cpu.features.isEnabled(@intCast(i)) or !isScalable(f.name)) continue;
        if (names.items.len != 0) names.appendSlice(arena, ", ") catch {}; // ziglint-ignore: Z026 -- out of memory only shortens the message
        names.appendSlice(arena, f.name) catch {}; // ziglint-ignore: Z026 -- out of memory only shortens the message
    }
    if (names.items.len == 0) return .{ .cpu = target.cpu };
    return .{ .cpu = default, .refused = arena.print("bs does not generate SVE or SME code for aarch64; '-mcpu {s}' enables {s}", .{ text, names.items }) catch "out of memory" };
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
    // Models and features past v2 are upstream's CPU: a kernel object
    // built for x86_64_v3 sees AVX2 in `builtin.cpu`.
    for ([_][]const u8{ "x86_64_v3", "x86_64_v4", "haswell", "sapphirerapids", "znver5", "x86_64_v2+avx", "x86_64_v2+sha" }) |ok| {
        try std.testing.expectEqual(null, resolve(arena, io, ok).refused);
    }
    const v3 = resolve(arena, io, "x86_64_v3").cpu;
    try std.testing.expect(v3.model == &x86.cpu.x86_64_v3 and v3.has(.x86, .avx2) and v3.has(.x86, .fma) and !v3.has(.x86, .avx512f));
    try std.testing.expect(resolve(arena, io, "znver4").cpu.has(.x86, .avx512bw));
    // Features that change code generation, which no CPU model has.
    try std.testing.expectEqualStrings("bs does not generate code with x86_64 CPU features that change code generation rather than add instructions; '-mcpu x86_64_v3+soft_float' enables soft_float; build this step with upstream zig", resolve(arena, io, "x86_64_v3+soft_float").refused.?);
    try std.testing.expect(std.mem.find(u8, resolve(arena, io, "x86_64+seses").refused.?, "lvi_cfi, seses") != null);
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
