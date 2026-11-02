//! Link throughput benchmark: `zig build bench-link` (ELF, x86_64 atoms) or
//! `zig build bench-link -- macho` (Mach-O, aarch64 atoms). Builds synthetic
//! sets of about 100k atoms shaped like a Debug build (mostly functions, each
//! calling others and referencing constants; some data and bss), links each
//! with `emit` several times, and compares against copying the same bytes
//! into a fresh buffer, which is the floor for a memcpy-dominated linker.
//!
//! The aarch64 atoms reference a constant with an adrp/add pair (two
//! relocations where x86_64 has one), call 64 libSystem imports with 1 in 32
//! of their calls, and their data's absolute addresses become chained
//! fixups. Mach-O output also includes hashing every page for the code
//! signature.
//!
//! Two relocation target distributions:
//! - random: every target uniformly random. Worst case for caches.
//! - mixed: an assumed Debug-build mix. Half the references go to 512 hot
//!   symbols with a skewed distribution (panic and safety-check handlers,
//!   memcpy, common std functions), a fifth to a few constants shared by
//!   neighboring functions (string literals), the rest uniformly random.
//!
//! Every function has debug info: one of 500 files, and a line row every
//! 8..40 bytes. Each emit is also timed stripped, to show its cost. Mach-O
//! does not emit debug info yet and ignores it.

const std = @import("std");
const Atom = @import("link/Atom.zig");
const Elf = @import("link/Elf.zig");
const MachO = @import("link/MachO.zig");

const n_text = 80_000;
const n_rodata = 15_000;
const n_data = 4_000;
const n_bss = 1_000;
const n_hot = 512;
const runs = 15;
const out_path = "/tmp/zap-bench-link.out";

const n_imports = 64;

const Mode = enum { random, mixed };
const Format = enum { elf, macho };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const format: Format = if (args.len > 1) std.meta.stringToEnum(Format, args[1]) orelse {
        std.debug.print("usage: bench-link [elf|macho]\n", .{});
        std.process.exit(1);
    } else .elf;
    switch (format) {
        inline else => |f| try bench(f, gpa, io, arena),
    }
}

fn bench(comptime format: Format, gpa: std.mem.Allocator, io: std.Io, arena: std.mem.Allocator) !void {
    const L = switch (format) {
        .elf => Elf,
        .macho => MachO,
    };
    const keys = try arena.alloc(Atom.SymbolKey, n_text + n_rodata + n_data + n_bss);
    const names = try arena.alloc([]const u8, keys.len);
    for (keys, names, 0..) |*k, *n, i| {
        n.* = try std.fmt.allocPrint(arena, "bench:file{d}.zig:decl{d}", .{ i % 500, i });
        k.* = .fromName(n.*);
    }

    var imports: [n_imports]MachO.Import = undefined;
    for (&imports, 0..) |*imp, i| {
        imp.name = try std.fmt.allocPrint(arena, "_imp{d}", .{i});
        imp.key = .fromName(imp.name);
    }

    const cpus = std.Thread.getCpuCount() catch 1;
    for ([_]Mode{ .random, .mixed }) |mode| {
        var prng: std.Random.DefaultPrng = .init(0x5eed);
        const atoms = try generate(arena, prng.random(), keys, names, mode, format, &imports);
        var content_bytes: usize = 0;
        var n_relocs: usize = 0;
        var n_targets: usize = 0;
        for (atoms) |a| {
            content_bytes += a.bytes.len;
            n_relocs += a.relocs.len;
            n_targets += a.targets.len;
        }
        var debug_bytes: usize = 0;
        for (atoms) |a| if (a.debug) |d| {
            debug_bytes += d.lines.len;
        };
        var single: L.Options = .{ .entry = keys[0], .threads = 1 };
        switch (format) {
            .elf => single.comp_dir = "/bench",
            .macho => {
                single.imports = &imports;
                // As `link` names it, so the file and `emit` match.
                single.identifier = std.fs.path.basename(out_path);
            },
        }
        var parallel = single;
        parallel.threads = null;
        // Mach-O has no debug info yet, so stripping changes nothing.
        var single_strip = single;
        var parallel_strip = parallel;
        if (format == .elf) {
            single_strip.strip = true;
            parallel_strip.strip = true;
        }

        // Threads must not change the output.
        const out1 = try L.emit(gpa, io, atoms, single);
        defer gpa.free(out1);
        const out_n = try L.emit(gpa, io, atoms, parallel);
        defer gpa.free(out_n);
        if (!std.mem.eql(u8, out1, out_n)) @panic("output depends on the thread count");
        const stripped = try L.emit(gpa, io, atoms, parallel_strip);
        defer gpa.free(stripped);

        var best_single: u64 = std.math.maxInt(u64);
        var best_parallel: u64 = std.math.maxInt(u64);
        var best_copy: u64 = std.math.maxInt(u64);
        var best_copy_n: u64 = std.math.maxInt(u64);
        var best_single_strip: u64 = std.math.maxInt(u64);
        var best_parallel_strip: u64 = std.math.maxInt(u64);
        for (0..runs) |_| {
            best_single = @min(best_single, try timeEmit(L, gpa, io, atoms, single));
            best_parallel = @min(best_parallel, try timeEmit(L, gpa, io, atoms, parallel));
            best_single_strip = @min(best_single_strip, try timeEmit(L, gpa, io, atoms, single_strip));
            best_parallel_strip = @min(best_parallel_strip, try timeEmit(L, gpa, io, atoms, parallel_strip));
            best_copy_n = @min(best_copy_n, try floor(gpa, io, atoms, cpus));
            best_copy = @min(best_copy, try floor(gpa, io, atoms, 1));
        }

        var with_write: u64 = std.math.maxInt(u64);
        for (0..runs) |_| {
            const t = std.Io.Timestamp.now(io, .awake);
            try L.link(gpa, io, std.Io.Dir.cwd(), out_path, atoms, parallel);
            with_write = @min(with_write, elapsed(io, t));
        }
        const file = try std.Io.Dir.cwd().readFileAlloc(io, out_path, gpa, .unlimited);
        defer gpa.free(file);
        if (!std.mem.eql(u8, file, out_n)) @panic("link wrote different bytes than emit returned");

        std.debug.print(
            \\{t} {t} targets: {d} atoms ({d} after dedup), {d} relocations to {d} per-atom targets, atom bytes {d:.1} MiB, line programs {d:.1} MiB, output {d:.1} MiB ({d:.1} MiB stripped)
            \\  memcpy floor, 1 thread:    {d:.2} ms
            \\  memcpy floor, {d} threads:   {d:.2} ms
            \\  emit, 1 thread:            {d:.2} ms  {d:.2}x the 1-thread floor  ({d:.0} atoms/s); stripped {d:.2} ms
            \\  emit, {d} threads:           {d:.2} ms  {d:.2}x the 1-thread floor, {d:.2}x the {d}-thread floor  ({d:.0} atoms/s); stripped {d:.2} ms
            \\  link to a file, {d} threads: {d:.2} ms
            \\
        , .{
            format,                              mode,
            atoms.len,                           keys.len,
            n_relocs,                            n_targets,
            mib(content_bytes),                  mib(debug_bytes),
            mib(out1.len),                       mib(stripped.len),
            ms(best_copy),                       cpus,
            ms(best_copy_n),                     ms(best_single),
            ms(best_single) / ms(best_copy),     rate(atoms.len, best_single),
            ms(best_single_strip),               cpus,
            ms(best_parallel),                   ms(best_parallel) / ms(best_copy),
            ms(best_parallel) / ms(best_copy_n), cpus,
            rate(atoms.len, best_parallel),      ms(best_parallel_strip),
            cpus,                                ms(with_write),
        });
    }
    std.debug.print("(best of {d} runs each)\n", .{runs});
}

/// The floor for `threads` threads: copy every atom's bytes once into a
/// fresh buffer, faulted in the way `emit` faults in its output, each thread
/// a contiguous run of atoms.
fn floor(gpa: std.mem.Allocator, io: std.Io, atoms: []const Atom, threads: usize) !u64 {
    const t = std.Io.Timestamp.now(io, .awake);
    var starts: [64]usize = undefined;
    const n = @min(threads, starts.len - 1);
    var at: usize = 0;
    for (0..n) |i| {
        starts[i] = at;
        for (atoms[i * atoms.len / n .. (i + 1) * atoms.len / n]) |a| at += a.bytes.len;
    }
    starts[n] = at;
    const out = try gpa.alloc(u8, at);
    Elf.adviseHugePages(out);
    const Worker = struct {
        fn work(dst: []u8, part: []const Atom) void {
            Elf.populate(dst);
            var off: usize = 0;
            for (part) |a| {
                @memcpy(dst[off..][0..a.bytes.len], a.bytes);
                off += a.bytes.len;
            }
        }
    };
    var group: std.Io.Group = .init;
    for (1..n) |i| group.async(io, Worker.work, .{ out[starts[i]..starts[i + 1]], atoms[i * atoms.len / n .. (i + 1) * atoms.len / n] });
    Worker.work(out[0..starts[1]], atoms[0 .. atoms.len / n]);
    try group.await(io);
    std.mem.doNotOptimizeAway(out.ptr);
    const ns = elapsed(io, t);
    gpa.free(out);
    return ns;
}

fn timeEmit(comptime L: type, gpa: std.mem.Allocator, io: std.Io, atoms: []const Atom, options: L.Options) !u64 {
    const t = std.Io.Timestamp.now(io, .awake);
    const out = try L.emit(gpa, io, atoms, options);
    const ns = elapsed(io, t);
    gpa.free(out);
    return ns;
}

fn rate(n: usize, ns: u64) f64 {
    return @as(f64, @floatFromInt(n)) / (@as(f64, @floatFromInt(ns)) / 1e9);
}

fn generate(arena: std.mem.Allocator, rand: std.Random, keys: []const Atom.SymbolKey, names: []const []const u8, mode: Mode, format: Format, imports: []const MachO.Import) ![]Atom {
    var atoms: std.ArrayList(Atom) = .empty;
    var targets: std.AutoArrayHashMapUnmanaged(Atom.SymbolKey, void) = .empty;
    // Each atom's name, bytes, relocations, and targets are allocated
    // together, as CodeGen's arena or a cache entry would hold them, and the
    // copy floor reads the same real memory.
    var files: [500][]const u8 = undefined;
    for (&files, 0..) |*f, j| f.* = try std.fmt.allocPrint(arena, "src/dir{d}/file{d}.zig", .{ j % 20, j });
    // Functions: 32..512 bytes, one call or constant reference per 32 bytes.
    for (0..n_text) |i| {
        const name = try arena.dupe(u8, names[i]);
        const len = rand.intRangeAtMost(u32, 32, 512);
        const bytes = try arena.alloc(u8, len);
        rand.bytes(bytes);
        var relocs: std.ArrayList(Atom.Reloc) = .empty;
        targets.clearRetainingCapacity();
        for (0..len / 32) |j| {
            const call = rand.boolean();
            const target = switch (mode) {
                .random => if (call) rand.uintLessThan(usize, n_text) else n_text + rand.uintLessThan(usize, n_rodata),
                .mixed => switch (rand.uintLessThan(u8, 10)) {
                    0...4 => blk: {
                        const u = rand.float(f64);
                        break :blk @as(usize, @intFromFloat(u * u * u * n_hot));
                    },
                    5, 6 => n_text + i * n_rodata / n_text + rand.uintLessThan(usize, 2),
                    else => if (call) rand.uintLessThan(usize, n_text) else n_text + rand.uintLessThan(usize, n_rodata),
                },
            };
            switch (format) {
                .elf => {
                    const gop = try targets.getOrPut(arena, keys[target]);
                    try relocs.append(arena, .init(@intCast(j * 32 + 1), .x86_64_pc32, @intCast(gop.index), -4));
                },
                .macho => {
                    // The patched instructions must be real: the linker
                    // reads the access size from adrp's partner.
                    const off: u32 = @intCast(j * 32);
                    if (target < n_text) {
                        const key = if (rand.uintLessThan(u8, 32) == 0) imports[rand.uintLessThan(usize, imports.len)].key else keys[target];
                        const gop = try targets.getOrPut(arena, key);
                        std.mem.writeInt(u32, bytes[off..][0..4], 0x94000000, .little); // bl
                        try relocs.append(arena, .init(off, .aarch64_branch26, @intCast(gop.index), 0));
                    } else {
                        const gop = try targets.getOrPut(arena, keys[target]);
                        std.mem.writeInt(u32, bytes[off..][0..4], 0x90000000, .little); // adrp x0
                        std.mem.writeInt(u32, bytes[off + 4 ..][0..4], 0x91000000, .little); // add x0, x0
                        try relocs.append(arena, .init(off, .aarch64_page21, @intCast(gop.index), 0));
                        try relocs.append(arena, .init(off + 4, .aarch64_pageoff12, @intCast(gop.index), 0));
                    }
                },
            }
        }
        var lines: Atom.LineProgram = .{};
        var offset: u32 = 0;
        var line: u32 = 0;
        while (offset < len) : (offset += rand.intRangeAtMost(u32, 8, 40)) {
            try lines.addRow(arena, offset, line, rand.intRangeAtMost(u32, 4, 40));
            line += rand.intRangeAtMost(u32, 1, 3);
        }
        const debug: Atom.Debug = .{ .file = files[i % files.len], .name = name[std.mem.lastIndexOfScalar(u8, name, ':').? + 1 ..], .base_line = rand.uintLessThan(u32, 5000), .lines = lines.bytes.items };
        try atoms.append(arena, .{ .key = keys[i], .name = name, .section = .text, .alignment = .@"16", .bytes = bytes, .targets = try arena.dupe(Atom.SymbolKey, targets.keys()), .relocs = relocs.items, .debug = debug });
    }
    // Constants: 8..128 bytes; every fourth one is emitted twice, as two
    // functions producing the same content-addressed constant would.
    for (0..n_rodata) |i| {
        const name = try arena.dupe(u8, names[n_text + i]);
        const bytes = try arena.alloc(u8, rand.intRangeAtMost(u32, 8, 128));
        rand.bytes(bytes);
        const a: Atom = .{ .key = keys[n_text + i], .name = name, .section = .rodata, .alignment = .@"8", .bytes = bytes };
        try atoms.append(arena, a);
        if (i % 4 == 0) try atoms.append(arena, a);
    }
    for (0..n_data) |i| {
        const name = try arena.dupe(u8, names[n_text + n_rodata + i]);
        const bytes = try arena.alloc(u8, 32);
        rand.bytes(bytes);
        const t = try arena.alloc(Atom.SymbolKey, 2);
        for (t) |*k| k.* = keys[rand.uintLessThan(usize, keys.len - n_bss)];
        if (t[0] == t[1]) t[1] = keys[0];
        const abs64: Atom.Reloc.Kind = if (format == .elf) .x86_64_abs64 else .aarch64_abs64;
        const relocs = try arena.dupe(Atom.Reloc, &.{ .init(0, abs64, 0, 0), .init(8, abs64, 1, 0) });
        const k = n_text + n_rodata + i;
        try atoms.append(arena, .{ .key = keys[k], .name = name, .section = .data, .alignment = .@"8", .bytes = bytes, .targets = t, .relocs = relocs });
    }
    for (0..n_bss) |i| {
        const k = n_text + n_rodata + n_data + i;
        try atoms.append(arena, .{ .key = keys[k], .name = names[k], .section = .bss, .alignment = .@"8", .zero_fill = 64 });
    }
    // Shuffle so that sections are interleaved in the input, as they are when
    // parallel CodeGen workers finish in arbitrary order.
    rand.shuffle(Atom, atoms.items);
    return atoms.items;
}

fn elapsed(io: std.Io, start: std.Io.Timestamp) u64 {
    return @intCast(start.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds);
}

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

fn mib(n: usize) f64 {
    return @as(f64, @floatFromInt(n)) / (1 << 20);
}
