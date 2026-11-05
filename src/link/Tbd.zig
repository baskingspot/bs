//! Reads a text-based dylib stub (TAPI v4 `.tbd`, as the macOS SDK's and
//! upstream's lib/libc/darwin/libSystem.tbd) for what it says about arm64
//! macOS: the library's install name and versions, the libraries it
//! re-exports, and the names it exports — the `symbols`, `weak-symbols`
//! and `thread-local-symbols` of each `exports` and `reexports` entry
//! whose targets include an arm64 macOS one (Apple's stubs name arm64e,
//! which arm64 code binds to, as upstream links it), and the symbols of
//! its `objc-classes`, `objc-eh-types` and `objc-ivars` — in every
//! document of the file (libSystem's re-exported libraries are documents
//! of its stub).

const std = @import("std");
const Allocator = std.mem.Allocator;
const MachODylib = @import("MachODylib.zig");

/// Adds the names `text` exports, without Darwin's leading underscore, to
/// `out`. The names point into `text`.
pub fn exports(gpa: Allocator, text: []const u8, out: *std.StringHashMapUnmanaged(void)) Allocator.Error!void {
    _ = try scan(gpa, text, void, out);
}

pub const Error = error{ OutOfMemory, InvalidTbd };

/// The library a stub describes, as a dylib file would (`MachODylib`),
/// with the install names of the libraries it re-exports that are not
/// documents of the stub itself: their exports are its too, from their own
/// stubs. Names point into `text` or `arena`.
pub fn dylib(arena: Allocator, path: []const u8, text: []const u8) Error!struct { MachODylib, []const []const u8 } {
    var d: MachODylib = .{ .path = path, .install_name = "", .current_version = 0x10000, .compatibility_version = 0x10000 };
    const info = try scan(arena, text, MachODylib.Export, &d.exports);
    d.install_name = info.install_name orelse return error.InvalidTbd;
    d.current_version = info.current_version;
    d.compatibility_version = info.compatibility_version;
    var external: std.ArrayList([]const u8) = .empty;
    for (info.reexports.items) |lib| {
        for (info.documents.items) |doc| {
            if (std.mem.eql(u8, doc, lib)) break;
        } else try external.append(arena, lib);
    }
    return .{ d, external.items };
}

const Info = struct {
    install_name: ?[]const u8 = null,
    current_version: u32 = 0x10000,
    compatibility_version: u32 = 0x10000,
    /// Every document's install name.
    documents: std.ArrayList([]const u8) = .empty,
    reexports: std.ArrayList([]const u8) = .empty,
};

/// What `text` says about arm64 macOS; its exported names go to `out`,
/// with their `MachODylib.Export` flags when `V` is that.
fn scan(gpa: Allocator, text: []const u8, comptime V: type, out: *std.StringHashMapUnmanaged(V)) Allocator.Error!Info {
    var info: Info = .{};
    // What the bracketed list being read holds, across lines.
    var list: enum { none, targets, symbols, weak, tls, objc_classes, objc_eh_types, objc_ivars, libraries, skip } = .none;
    var section: enum { other, exports, reexported_libraries } = .other;
    var arm64 = false;
    var first_doc = true;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var rest: []const u8 = line;
        if (list == .none) {
            if (std.mem.startsWith(u8, line, "---")) {
                section = .other;
                continue;
            }
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const key = std.mem.trim(u8, line[0..colon], " -");
            if (line.len != 0 and line[0] != ' ') {
                section = if (std.mem.eql(u8, key, "exports") or std.mem.eql(u8, key, "reexports"))
                    .exports
                else if (std.mem.eql(u8, key, "reexported-libraries"))
                    .reexported_libraries
                else
                    .other;
                const value = std.mem.trim(u8, line[colon + 1 ..], " '\r");
                if (std.mem.eql(u8, key, "install-name")) {
                    try info.documents.append(gpa, value);
                    if (first_doc) info.install_name = value;
                    first_doc = false;
                } else if (info.documents.items.len == 1 and std.mem.eql(u8, key, "current-version")) {
                    info.current_version = version(value);
                } else if (info.documents.items.len == 1 and std.mem.eql(u8, key, "compatibility-version")) {
                    info.compatibility_version = version(value);
                }
                continue;
            }
            if (section == .other) continue;
            const open = std.mem.indexOfScalarPos(u8, line, colon, '[') orelse continue;
            const eql = std.mem.eql;
            list = if (eql(u8, key, "targets"))
                .targets
            else if (!arm64)
                .skip
            else if (section == .reexported_libraries)
                (if (eql(u8, key, "libraries")) .libraries else .skip)
            else if (eql(u8, key, "symbols"))
                .symbols
            else if (eql(u8, key, "weak-symbols"))
                .weak
            else if (eql(u8, key, "thread-local-symbols"))
                .tls
            else if (eql(u8, key, "objc-classes"))
                .objc_classes
            else if (eql(u8, key, "objc-eh-types"))
                .objc_eh_types
            else if (eql(u8, key, "objc-ivars"))
                .objc_ivars
            else
                .skip;
            if (list == .targets) arm64 = false;
            rest = line[open + 1 ..];
        }
        const close = std.mem.indexOfScalar(u8, rest, ']');
        var items = std.mem.tokenizeAny(u8, rest[0 .. close orelse rest.len], ", \r");
        while (items.next()) |item| {
            const name = std.mem.trim(u8, item, "'");
            switch (list) {
                .targets => if (std.mem.startsWith(u8, name, "arm64") and std.mem.endsWith(u8, name, "-macos")) {
                    arm64 = true;
                },
                .symbols, .weak, .tls => if (name.len > 1 and name[0] == '_') {
                    try put(gpa, V, out, name[1..], .{ .weak = list == .weak, .tls = list == .tls });
                },
                // Their symbols, without the leading underscore, as ld64
                // makes them for an objc2 stub.
                .objc_classes => {
                    try put(gpa, V, out, try std.fmt.allocPrint(gpa, "OBJC_CLASS_$_{s}", .{name}), .{ .weak = false, .tls = false });
                    try put(gpa, V, out, try std.fmt.allocPrint(gpa, "OBJC_METACLASS_$_{s}", .{name}), .{ .weak = false, .tls = false });
                },
                .objc_eh_types => try put(gpa, V, out, try std.fmt.allocPrint(gpa, "OBJC_EHTYPE_$_{s}", .{name}), .{ .weak = false, .tls = false }),
                .objc_ivars => try put(gpa, V, out, try std.fmt.allocPrint(gpa, "OBJC_IVAR_$_{s}", .{name}), .{ .weak = false, .tls = false }),
                .libraries => try info.reexports.append(gpa, name),
                .skip, .none => {},
            }
        }
        if (close != null) list = .none;
    }
    return info;
}

fn put(gpa: Allocator, comptime V: type, out: *std.StringHashMapUnmanaged(V), name: []const u8, flags: MachODylib.Export) Allocator.Error!void {
    try out.put(gpa, name, if (V == void) {} else flags);
}

/// A version as LC_ID_DYLIB packs it: `X[.Y[.Z]]` as X.Y.Z in 16, 8 and
/// 8 bits.
fn version(text: []const u8) u32 {
    var v: u32 = 0;
    var it = std.mem.splitScalar(u8, text, '.');
    for ([_]u5{ 16, 8, 0 }, [_]u32{ 0xffff, 0xff, 0xff }) |shift, max| {
        const part = it.next() orelse break;
        v |= @min(std.fmt.parseInt(u32, part, 10) catch 0, max) << shift;
    }
    return v;
}

test exports {
    const text =
        \\--- !tapi-tbd
        \\tbd-version:     4
        \\targets:         [ x86_64-macos, arm64e-macos ]
        \\install-name:    '/usr/lib/libSystem.B.dylib'
        \\reexported-libraries:
        \\  - targets:         [ x86_64-macos, arm64e-macos ]
        \\    libraries:       [ '/usr/lib/system/libsystem_m.dylib' ]
        \\exports:
        \\  - targets:         [ x86_64-macos ]
        \\    symbols:         [ _x86_only ]
        \\  - targets:         [ x86_64-macos, x86_64-maccatalyst, arm64e-macos,
        \\                       arm64e.x1-macos ]
        \\    symbols:         [ _memset, _memset_pattern4,
        \\                       'R8289209$_write', _puts ]
        \\    objc-classes:    [ NSObject ]
        \\    weak-symbols:    [ _weak_one ]
        \\--- !tapi-tbd
        \\tbd-version:     4
        \\targets:         [ arm64e-macos ]
        \\install-name:    '/usr/lib/system/libsystem_m.dylib'
        \\parent-umbrella:
        \\  - targets:         [ arm64e-macos ]
        \\    umbrella:        System
        \\exports:
        \\  - targets:         [ arm64e-macos ]
        \\    symbols:         [ _cos, _sin ]
        \\    thread-local-symbols: [ _tls_one ]
        \\...
    ;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var set: std.StringHashMapUnmanaged(void) = .empty;
    try exports(arena, text, &set);
    for ([_][]const u8{ "memset", "memset_pattern4", "puts", "weak_one", "cos", "sin", "tls_one", "OBJC_CLASS_$_NSObject", "OBJC_METACLASS_$_NSObject" }) |n| try std.testing.expect(set.contains(n));
    for ([_][]const u8{ "x86_only", "NSObject", "System", "R8289209$_write", "/usr/lib/system/libsystem_m.dylib" }) |n| try std.testing.expect(!set.contains(n));
    try std.testing.expectEqual(9, set.count());

    // As a library: libsystem_m is a document of the stub, so nothing is
    // left to read elsewhere.
    const lib, const external = try dylib(arena, "libSystem.tbd", text);
    try std.testing.expectEqualStrings("/usr/lib/libSystem.B.dylib", lib.install_name);
    try std.testing.expectEqual(0, external.len);
    try std.testing.expectEqual(MachODylib.Export{ .weak = true, .tls = false }, lib.exports.get("weak_one").?);
    try std.testing.expectEqual(MachODylib.Export{ .weak = false, .tls = true }, lib.exports.get("tls_one").?);
    try std.testing.expectEqual(MachODylib.Export{ .weak = false, .tls = false }, lib.exports.get("sin").?);
}

test dylib {
    // The SDK's Cocoa stub: versions, and re-exported frameworks whose
    // exports are in their own stubs.
    const text =
        \\--- !tapi-tbd
        \\tbd-version:     4
        \\targets:         [ x86_64-macos, arm64e-macos, arm64e.x1-macos ]
        \\install-name:    '/System/Library/Frameworks/Cocoa.framework/Versions/A/Cocoa'
        \\current-version: 24
        \\compatibility-version: 1.2.12
        \\reexported-libraries:
        \\  - targets:         [ x86_64-macos ]
        \\    libraries:       [ '/x86_64/Only' ]
        \\  - targets:         [ x86_64-macos, arm64e-macos, arm64e.x1-macos ]
        \\    libraries:       [ '/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit', 
        \\                       '/System/Library/Frameworks/CoreData.framework/Versions/A/CoreData' ]
        \\exports:
        \\  - targets:         [ x86_64-macos, arm64e-macos, arm64e.x1-macos ]
        \\    symbols:         [ _CocoaVersionNumber, _CocoaVersionString ]
        \\    objc-eh-types:   [ NSException ]
        \\    objc-ivars:      [ NSObject.isa ]
        \\...
        \\
    ;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lib, const external = try dylib(arena, "Cocoa.tbd", text);
    try std.testing.expectEqualStrings("/System/Library/Frameworks/Cocoa.framework/Versions/A/Cocoa", lib.install_name);
    try std.testing.expectEqual(24 << 16, lib.current_version);
    try std.testing.expectEqual((1 << 16) | (2 << 8) | 12, lib.compatibility_version);
    try std.testing.expectEqual(2, external.len);
    try std.testing.expectEqualStrings("/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit", external[0]);
    try std.testing.expectEqualStrings("/System/Library/Frameworks/CoreData.framework/Versions/A/CoreData", external[1]);
    for ([_][]const u8{ "CocoaVersionNumber", "CocoaVersionString", "OBJC_EHTYPE_$_NSException", "OBJC_IVAR_$_NSObject.isa" }) |n| try std.testing.expect(lib.exports.contains(n));
    try std.testing.expectEqual(4, lib.exports.count());
}
