//! The CPU a Zig 0.16 compilation's builtin module names: model and
//! features from 0.16's tables (`cpu_tables_0_16.zig`), resolved as
//! upstream 0.16.0 resolves the same `-target` and `-mcpu`. 0.17 renamed,
//! added and dropped features and models (`max_interleave_factor_4`,
//! `apple_a14`), so the CPU bs resolves with its own std (`cpu.zig`),
//! which code generation uses, cannot be written into a 0.16 builtin.
//!
//! bs's own limits apply in 0.16's terms too: a native x86_64 CPU is
//! clamped (`cpu.clamp`) to the same model and features, and an aarch64
//! one loses SVE and SME (`cpu.clampAarch64`).

const std = @import("std");
const builtin = @import("builtin");
const tables = @import("cpu_tables_0_16.zig");
const cpu_mod = @import("cpu.zig");

/// A CPU in 0.16's names.
pub const Names = struct {
    model: []const u8,
    /// Every enabled feature, in 0.16's order.
    features: []const []const u8,
};

/// The 0.16 CPU for `arch` (aarch64-macos's when `macos`), `-mcpu` value
/// `mcpu` and whether the target is native, as `main.resolveCpu` resolves
/// it in 0.17 to `cpu17`. Exits with an error for a CPU 0.16 does not
/// know.
pub fn resolve(arena: std.mem.Allocator, arch: std.Target.Cpu.Arch, macos: bool, mcpu: ?[]const u8, native: bool, cpu17: std.Target.Cpu) !Names {
    const t = if (arch == .x86_64) tables.x86 else tables.aarch64;
    const set = try arena.alloc(bool, t.features.len);
    @memset(set, false);
    const text = mcpu orelse if (native) "native" else "baseline";
    const split = std.mem.findAny(u8, text, "+-") orelse text.len;
    const model_name = text[0..split];
    var model: []const u8 = undefined;
    if (!std.mem.eql(u8, model_name, "native")) {
        model = if (!std.mem.eql(u8, model_name, "baseline")) model_name else if (arch == .x86_64) "x86_64" else baseline(macos);
    } else if (arch == .aarch64 and builtin.cpu.arch != .aarch64) {
        // A host of another architecture: the target's default, as bs's.
        model = baseline(macos);
    } else if (builtin.os.tag == .macos and arch == .aarch64) {
        model = macosModel() orelse baseline(macos);
    } else {
        // The clamped x86_64 host CPU, whose model and features both
        // releases have, and aarch64-linux's host CPU: 0.17's by name.
        model = cpu17.model.name;
        for (cpu17.arch.allFeaturesList(), 0..) |f, i| {
            if (cpu17.features.isEnabled(@intCast(i))) if (index(t, f.name)) |j| {
                set[j] = true;
            };
        }
    }
    // `Model.toCpu`.
    const m = for (t.models) |m| {
        if (std.mem.eql(u8, m.name, model)) break m;
    } else std.process.fatal("CPU model '{s}' ('-mcpu {s}') is not in Zig 0.16", .{ model, text });
    for (m.features) |f| set[f] = true;
    populate(t, set);
    // `updateCpuFeatures`: the modifiers, with the added features'
    // dependencies.
    const sub = try arena.alloc(bool, t.features.len);
    @memset(sub, false);
    var i = split;
    while (i < text.len) {
        const end = std.mem.findAnyPos(u8, text, i + 1, "+-") orelse text.len;
        const name = text[i + 1 .. end];
        const j = index(t, name) orelse
            std.process.fatal("CPU feature '{s}' ('-mcpu {s}') is not in Zig 0.16", .{ name, text });
        if (text[i] == '+') set[j] = true else sub[j] = true;
        i = end;
    }
    for (set, sub) |*s, x| if (x) {
        s.* = false;
    };
    populate(t, set);
    for (set, sub, t.features) |*s, x, f| if (x or (arch == .aarch64 and cpu_mod.isScalable(f.name))) {
        s.* = false;
    };
    var names: std.ArrayList([]const u8) = .empty;
    for (t.features, set) |f, on| if (on) try names.append(arena, f.name);
    return .{ .model = m.name, .features = names.items };
}

/// 0.16's `Cpu.baseline` for aarch64 (`Model.baseline`).
fn baseline(macos: bool) []const u8 {
    return if (macos) "apple_m1" else "generic";
}

fn index(t: tables.Arch, name: []const u8) ?usize {
    for (t.features, 0..) |f, i| if (std.mem.eql(u8, f.name, name)) return i;
    return null;
}

/// `Feature.Set.populateDependencies`.
fn populate(t: tables.Arch, set: []bool) void {
    var changed = true;
    while (changed) {
        changed = false;
        for (t.features, 0..) |f, i| {
            if (!set[i]) continue;
            for (f.deps) |d| if (!set[d]) {
                set[d] = true;
                changed = true;
            };
        }
    }
}

/// The model 0.16 detects on this Mac (upstream 0.16.0's
/// std/zig/system/darwin/macos.zig, `detectNativeCpuAndFeatures`), or
/// null where it detects none and falls back to the baseline.
fn macosModel() ?[]const u8 {
    if (builtin.os.tag != .macos) @compileError("macOS only");
    var family: std.c.CPUFAMILY = undefined;
    var len: usize = @sizeOf(std.c.CPUFAMILY);
    if (std.c.sysctlbyname("hw.cpufamily", &family, &len, null, 0) != 0) return null;
    return switch (family) {
        .ARM_CYCLONE => "apple_a7",
        .ARM_TYPHOON => "apple_a8",
        .ARM_TWISTER => "apple_a9",
        .ARM_HURRICANE => "apple_a10",
        .ARM_MONSOON_MISTRAL => "apple_a11",
        .ARM_VORTEX_TEMPEST => "apple_a12",
        .ARM_LIGHTNING_THUNDER => "apple_a13",
        .ARM_FIRESTORM_ICESTORM => "apple_m1",
        .ARM_BLIZZARD_AVALANCHE => "apple_m2",
        .ARM_EVEREST_SAWTOOTH, .ARM_IBIZA, .ARM_PALMA, .ARM_LOBOS => "apple_m3",
        .ARM_COLL => "apple_a17",
        .ARM_DONAN, .ARM_BRAVA, .ARM_TAHITI, .ARM_TUPAI => "apple_m4",
        else => null,
    };
}

test resolve {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // As upstream 0.16.0's `--show-builtin`: aarch64-macos's default is
    // Apple's M1 with fuse_aes, which 0.17 drops, in 65 features.
    const m1 = try resolve(arena, .aarch64, true, null, false, cpu_mod.targetDefault(.aarch64, true));
    try std.testing.expectEqualStrings("apple_m1", m1.model);
    try std.testing.expectEqual(65, m1.features.len);
    for (m1.features) |f| {
        if (std.mem.eql(u8, f, "fuse_aes")) break;
    } else return error.TestUnexpectedResult;
    // `-mcpu x86_64_v3`, with its dependencies.
    const v3 = try resolve(arena, .x86_64, false, "x86_64_v3", false, cpu_mod.baseline);
    try std.testing.expectEqualStrings("x86_64_v3", v3.model);
    const joined = try std.mem.join(arena, " ", v3.features);
    try std.testing.expectEqualStrings("64bit allow_light_256_bit avx avx2 bmi bmi2 cmov crc32 cx16 cx8 f16c false_deps_lzcnt_tzcnt false_deps_popcnt fast_15bytenop fast_scalar_fsqrt fast_shld_rotate fast_variable_crosslane_shuffle fast_variable_perlane_shuffle fma fxsr idivq_to_divl lzcnt macrofusion mmx movbe nopl popcnt sahf slow_3ops_lea sse sse2 sse3 sse4_1 sse4_2 ssse3 vzeroupper x87 xsave", joined);
}
