//! glibc's dynamic symbols for one target version, read from the zig lib
//! directory's `libc/glibc/abilists`, the data upstream generates its glibc
//! stub libraries from. A dynamically linked executable's imports resolve
//! against it instead of against `libc.so` files (see "C interop" in
//! docs/architecture.md).
//!
//! The format and the choice of each symbol's version follow upstream's
//! `src/libs/glibc.zig` (`loadMetaData`, `buildSharedObjects`).
//! Copyright (c) Zig contributors. MIT licensed (see upstream/LICENSE).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Version = std.SemanticVersion;
const Glibc = @This();
const ElfObject = @import("ElfObject.zig");
const ElfDynamic = @import("ElfDynamic.zig");
const ElfShared = @import("ElfShared.zig");

pub const Lib = struct {
    name: []const u8,
    soname: []const u8,
    removed_in: ?Version = null,
};

/// abilists' libraries, in its order, which is upstream's link order: a
/// name defined by several resolves to the first.
pub const libs = [_]Lib{
    .{ .name = "m", .soname = "libm.so.6" },
    .{ .name = "c", .soname = "libc.so.6" },
    .{ .name = "ld", .soname = "ld-linux-x86-64.so.2" },
    .{ .name = "resolv", .soname = "libresolv.so.2" },
    .{ .name = "pthread", .soname = "libpthread.so.0", .removed_in = .{ .major = 2, .minor = 34, .patch = 0 } },
    .{ .name = "dl", .soname = "libdl.so.2", .removed_in = .{ .major = 2, .minor = 34, .patch = 0 } },
    .{ .name = "rt", .soname = "librt.so.1", .removed_in = .{ .major = 2, .minor = 34, .patch = 0 } },
    .{ .name = "util", .soname = "libutil.so.1", .removed_in = .{ .major = 2, .minor = 34, .patch = 0 } },
};

pub const lib_c: u8 = 1;
pub const lib_ld: u8 = 2;

pub const abilists_path = "libc/glibc/abilists";
pub const interp = "/lib64/ld-linux-x86-64.so.2";

/// The names glibc gives the data object `name` names, at one address, or
/// none. abilists does not say which names share one, so an executable
/// that copies one of them (R_X86_64_COPY) defines the others at its copy
/// too, as a link against the real libc.so.6 does, since glibc's own code
/// uses them.
pub fn dataAliases(name: []const u8) []const []const u8 {
    for (data_aliases) |group| {
        for (group) |n| if (std.mem.eql(u8, n, name)) return group;
    }
    return &.{};
}

const data_aliases = [_][]const []const u8{
    &.{ "environ", "_environ", "__environ" },
    &.{ "program_invocation_name", "__progname_full" },
    &.{ "program_invocation_short_name", "__progname" },
    &.{ "timezone", "__timezone" },
    &.{ "daylight", "__daylight" },
    &.{ "tzname", "__tzname" },
    &.{ "signgam", "__signgam" },
};

/// A symbol as a reference binds to it at link time: its library and its
/// default version at the target version (the newest one at or below it).
pub const Symbol = struct {
    lib: u8,
    /// Index into `versions`.
    version: u8,
    object: bool,
    /// Size in bytes, for objects.
    size: u16,
};

arena: std.heap.ArenaAllocator,
versions: []const Version,
symbols: std.StringHashMapUnmanaged(Symbol),

pub const Error = error{ OutOfMemory, InvalidAbilists, UnsupportedVersion };

/// The newest version abilists lists, which a newer target links against.
pub fn newest(g: *const Glibc) Version {
    return g.versions[g.versions.len - 1];
}

/// Reads `contents` (abilists) for x86_64-linux-gnu at glibc `target`.
pub fn load(gpa: Allocator, contents: []const u8, target: Version) Error!Glibc {
    var g: Glibc = .{ .arena = .init(gpa), .versions = &.{}, .symbols = .empty };
    errdefer g.arena.deinit();
    const arena = g.arena.allocator();
    var r: Reader = .{ .bytes = contents };

    const n_libs = try r.byte();
    for (0..n_libs) |i| {
        const name = try r.string();
        if (i >= libs.len or !std.mem.eql(u8, libs[i].name, name)) return error.InvalidAbilists;
    }
    const versions = try arena.alloc(Version, try r.byte());
    for (versions) |*v| v.* = .{ .major = try r.byte(), .minor = try r.byte(), .patch = try r.byte() };
    g.versions = versions;
    // A target newer than the newest version abilists lists links against
    // that one, as upstream (which warns; `newest` lets the caller).
    if (versions.len == 0) return error.InvalidAbilists;
    const target_ver: u8 = for (versions, 0..) |v, i| {
        switch (v.order(target)) {
            .eq => break @intCast(i),
            .lt => continue,
            .gt => return error.UnsupportedVersion,
        }
    } else @intCast(versions.len - 1);
    const n_targets = try r.byte();
    var target_index: ?u6 = null;
    for (0..n_targets) |i| {
        if (std.mem.eql(u8, try r.string(), "x86_64-linux-gnu")) target_index = @intCast(i);
    }
    const ti = target_index orelse return error.InvalidAbilists;

    // Functions, then objects. A name's inclusions are consecutive; the
    // last has the terminal bit. A library removed at or before the target
    // version provides nothing.
    var lib_ok: [libs.len]bool = undefined;
    for (&lib_ok, libs) |*ok, lib| ok.* = if (lib.removed_in) |rem| target.order(rem) == .lt else true;
    for ([_]bool{ false, true }) |object| {
        const n = try r.int(u16);
        var best: ?Symbol = null;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const name = try r.string();
            while (true) {
                const targets = try r.leb(u64);
                const size: u16 = if (object) std.math.cast(u16, try r.leb(u64)) orelse return error.InvalidAbilists else 0;
                var lib = try r.byte();
                const terminal = lib & 0x80 != 0;
                lib &= 0x7f;
                if (lib >= libs.len) return error.InvalidAbilists;
                const applies = lib_ok[lib] and targets & (@as(u64, 1) << ti) != 0;
                while (true) {
                    const b = try r.byte();
                    const ver: u8 = b & 0x7f;
                    // The earliest library in link order, then its newest
                    // version not past the target.
                    if (applies and ver <= target_ver) {
                        if (best == null or lib < best.?.lib or (lib == best.?.lib and ver > best.?.version))
                            best = .{ .lib = lib, .version = ver, .object = object, .size = size };
                    }
                    if (b & 0x80 != 0) break;
                }
                if (terminal) break;
                i += 1;
                if (i >= n) return error.InvalidAbilists;
            }
            if (best) |b| try g.symbols.put(arena, try arena.dupe(u8, name), b);
            best = null;
        }
    }
    return g;
}

pub fn deinit(g: *Glibc) void {
    g.arena.deinit();
}

/// The dynamic tables of an executable that imports `imports` from glibc
/// (`Emit.link`, and `Incremental` relinking from the cache): sorts them by
/// name, so the tables do not depend on the order code requested them, and
/// gives each its library and version. DT_NEEDED lists libc.so.6 always,
/// as upstream, and the other libraries used, in upstream's link order.
/// `copies` are the imports the executable copies instead (`Emit.copies`),
/// which become its exports, each with its aliases that nothing imports.
/// A name one of the `shared` libraries defines comes from the first
/// such library, before glibc. Strings are allocated in `arena`.
pub fn dynamicOptions(g: *const Glibc, arena: Allocator, imports: []ElfObject.Import, copies: []const ElfObject.Import, shared: []const ElfShared) error{ OutOfMemory, NotInGlibc }!ElfDynamic.Options {
    return g.options(arena, imports, copies, shared, true);
}

/// The dynamic tables of a shared object that links glibc, as
/// `dynamicOptions`' for an executable, except that it copies nothing,
/// has no interpreter, and imports a name neither the `shared` libraries
/// nor glibc define unversioned, for the program that loads it to define.
/// The caller adds the exports and the soname.
pub fn sharedObjectOptions(g: *const Glibc, arena: Allocator, imports: []ElfObject.Import, shared: []const ElfShared) Allocator.Error!ElfDynamic.Options {
    return g.options(arena, imports, &.{}, shared, false) catch |err| switch (err) {
        error.OutOfMemory => |e| e,
        error.NotInGlibc => unreachable,
    };
}

fn options(g: *const Glibc, arena: Allocator, imports: []ElfObject.Import, copies: []const ElfObject.Import, shared: []const ElfShared, executable: bool) error{ OutOfMemory, NotInGlibc }!ElfDynamic.Options {
    std.mem.sortUnstable(ElfObject.Import, imports, {}, struct {
        fn lt(_: void, a: ElfObject.Import, b: ElfObject.Import) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
    // The shared libraries come first, each needed whether used or not, as
    // upstream links them; then glibc's.
    var needed: std.ArrayList([]const u8) = .empty;
    for (shared) |lib| try needed.append(arena, lib.soname);
    var used: [libs.len]bool = @splat(false);
    used[lib_c] = true;
    for ([_][]const ElfObject.Import{ imports, copies }) |list| for (list) |imp| {
        if (sharedSymbol(shared, imp.name) == null) used[
            (g.get(imp.name) orelse if (executable) return error.NotInGlibc else continue).lib
        ] = true;
    };
    var lib_index: [libs.len]u32 = undefined;
    for (libs, used, &lib_index) |lib, u, *index| if (u) {
        index.* = @intCast(needed.items.len);
        try needed.append(arena, lib.soname);
    };
    const Place = struct { version: ?[]const u8, library: u32 };
    const place = struct {
        fn f(gl: *const Glibc, a: Allocator, sh: []const ElfShared, li: *const [libs.len]u32, name: []const u8) !?Place {
            if (sharedSymbol(sh, name)) |s| return .{ .version = s.sym.version, .library = s.lib };
            const sym = gl.get(name) orelse return null;
            return .{ .version = try gl.versionName(a, sym.version), .library = li[sym.lib] };
        }
    }.f;
    for (imports) |*imp| {
        const p = try place(g, arena, shared, &lib_index, imp.name) orelse continue;
        imp.version = p.version;
        imp.library = p.library;
    }
    // Each copy, then the other names its library gives the same object,
    // which the library's own code may use instead.
    var exports: std.ArrayList(ElfDynamic.Export) = .empty;
    for (copies) |c| {
        const name = c.name;
        const aliases = if (sharedSymbol(shared, name)) |s| try shared[s.lib].aliases(arena, s.sym.value) else dataAliases(name);
        // The copy itself first: its relocation names it.
        for ([_][]const []const u8{ &.{name}, aliases }, [_]bool{ false, true }) |list, alias| for (list) |n| {
            if (alias and (std.mem.eql(u8, n, name) or for (imports) |imp| {
                if (std.mem.eql(u8, imp.name, n)) break true;
            } else false)) continue;
            const p = try place(g, arena, shared, &lib_index, n) orelse continue;
            try exports.append(arena, .{ .key = c.key, .name = n, .copy = .{ .version = p.version, .library = p.library, .alias = alias } });
        };
    }
    return .{ .exports = exports.items, .imports = imports, .interp = if (executable) interp else null, .needed = needed.items };
}

/// The first of `shared` that defines `name`, as the link resolves it.
pub fn sharedSymbol(shared: []const ElfShared, name: []const u8) ?struct { lib: u32, sym: ElfShared.Symbol } {
    for (shared, 0..) |lib, i| if (lib.symbols.get(name)) |sym| return .{ .lib = @intCast(i), .sym = sym };
    return null;
}

pub fn get(g: *const Glibc, name: []const u8) ?Symbol {
    return g.symbols.get(name);
}

/// `GLIBC_2.2.5`, `GLIBC_2.34`.
pub fn versionName(g: *const Glibc, arena: Allocator, index: u8) Allocator.Error![]const u8 {
    const v = g.versions[index];
    return if (v.patch == 0)
        std.fmt.allocPrint(arena, "GLIBC_{d}.{d}", .{ v.major, v.minor })
    else
        std.fmt.allocPrint(arena, "GLIBC_{d}.{d}.{d}", .{ v.major, v.minor, v.patch });
}

const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn byte(r: *Reader) Error!u8 {
        if (r.pos >= r.bytes.len) return error.InvalidAbilists;
        r.pos += 1;
        return r.bytes[r.pos - 1];
    }

    fn int(r: *Reader, comptime T: type) Error!T {
        if (r.pos + @sizeOf(T) > r.bytes.len) return error.InvalidAbilists;
        defer r.pos += @sizeOf(T);
        return std.mem.readInt(T, r.bytes[r.pos..][0..@sizeOf(T)], .little);
    }

    fn string(r: *Reader) Error![]const u8 {
        const end = std.mem.indexOfScalarPos(u8, r.bytes, r.pos, 0) orelse return error.InvalidAbilists;
        defer r.pos = end + 1;
        return r.bytes[r.pos..end];
    }

    fn leb(r: *Reader, comptime T: type) Error!T {
        var result: T = 0;
        var shift: u7 = 0;
        while (true) {
            const b = try r.byte();
            if (shift >= @bitSizeOf(T)) return error.InvalidAbilists;
            result |= @as(T, b & 0x7f) << @intCast(shift);
            if (b & 0x80 == 0) return result;
            shift += 7;
        }
    }
};

test load {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const build_options = @import("build_options");
    const path = try std.fs.path.join(gpa, &.{ build_options.zig_lib_dir, abilists_path });
    defer gpa.free(path);
    const contents = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
    defer gpa.free(contents);

    // As upstream's stubs bind them (readelf -V of `zig build-exe -lc
    // -target x86_64-linux-gnu.<v>`).
    var g231 = try load(gpa, contents, .{ .major = 2, .minor = 31, .patch = 0 });
    defer g231.deinit();
    var g236 = try load(gpa, contents, .{ .major = 2, .minor = 36, .patch = 0 });
    defer g236.deinit();
    var buf: [1024]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const expect = struct {
        fn f(g: *const Glibc, a: Allocator, name: []const u8, lib: []const u8, version: []const u8) !void {
            const s = g.get(name) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings(lib, libs[s.lib].soname);
            try std.testing.expectEqualStrings(version, try g.versionName(a, s.version));
        }
    }.f;
    // memcpy has 2.2.5 and 2.14; the default is the newest.
    try expect(&g231, fba.allocator(), "memcpy", "libc.so.6", "GLIBC_2.14");
    // __libc_start_main gained 2.34, which a 2.31 target must not take.
    try expect(&g231, fba.allocator(), "__libc_start_main", "libc.so.6", "GLIBC_2.2.5");
    try expect(&g236, fba.allocator(), "__libc_start_main", "libc.so.6", "GLIBC_2.34");
    // In libpthread before 2.34, in libc after.
    try expect(&g231, fba.allocator(), "pthread_key_create", "libpthread.so.0", "GLIBC_2.2.5");
    try expect(&g236, fba.allocator(), "pthread_key_create", "libc.so.6", "GLIBC_2.34");
    try expect(&g236, fba.allocator(), "__tls_get_addr", "ld-linux-x86-64.so.2", "GLIBC_2.3");
    try expect(&g236, fba.allocator(), "sin", "libm.so.6", "GLIBC_2.2.5");
    const environ = g236.get("environ").?;
    try std.testing.expect(environ.object and environ.size == 8);
    try std.testing.expectEqual(null, g236.get("not_a_glibc_symbol"));
    // Added in 2.32.
    try std.testing.expect(g231.get("pthread_attr_setsigmask_np") == null);
    try std.testing.expect(g236.get("pthread_attr_setsigmask_np") != null);
    // Newer than abilists' newest: that one, as upstream.
    var g99 = try load(gpa, contents, .{ .major = 2, .minor = 99, .patch = 0 });
    defer g99.deinit();
    try std.testing.expect(g99.newest().order(.{ .major = 2, .minor = 99, .patch = 0 }) == .lt);
    try expect(&g99, fba.allocator(), "__libc_start_main", "libc.so.6", "GLIBC_2.34");
    try std.testing.expectError(error.UnsupportedVersion, load(gpa, contents, .{ .major = 2, .minor = 0, .patch = 5 }));
}
