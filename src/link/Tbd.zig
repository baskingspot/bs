//! Reads a text-based dylib stub (TAPI v4 `.tbd`, as upstream's
//! lib/libc/darwin/libSystem.tbd) for the names it exports to arm64 macOS:
//! the `symbols`, `weak-symbols` and `thread-local-symbols` of each
//! `exports` and `reexports` entry whose targets include an arm64 macOS
//! one (Apple's stubs name arm64e, which arm64 code binds to, as upstream
//! links it), in every document of the file (libSystem's re-exported
//! libraries are documents of its stub).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Adds the names `text` exports, without Darwin's leading underscore, to
/// `out`. The names point into `text`.
pub fn exports(gpa: Allocator, text: []const u8, out: *std.StringHashMapUnmanaged(void)) Allocator.Error!void {
    // What the bracketed list being read holds, across lines.
    var list: enum { none, targets, names, skip } = .none;
    var in_exports = false;
    var arm64 = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var rest: []const u8 = line;
        if (list == .none) {
            if (std.mem.startsWith(u8, line, "---")) {
                in_exports = false;
                continue;
            }
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const key = std.mem.trim(u8, line[0..colon], " -");
            if (line.len != 0 and line[0] != ' ') {
                in_exports = std.mem.eql(u8, key, "exports") or std.mem.eql(u8, key, "reexports");
                continue;
            }
            if (!in_exports) continue;
            const open = std.mem.indexOfScalarPos(u8, line, colon, '[') orelse continue;
            list = if (std.mem.eql(u8, key, "targets"))
                .targets
            else if (arm64 and (std.mem.eql(u8, key, "symbols") or std.mem.eql(u8, key, "weak-symbols") or std.mem.eql(u8, key, "thread-local-symbols")))
                .names
            else
                .skip;
            if (list == .targets) arm64 = false;
            rest = line[open + 1 ..];
        }
        const close = std.mem.indexOfScalar(u8, rest, ']');
        var items = std.mem.tokenizeAny(u8, rest[0 .. close orelse rest.len], ", ");
        while (items.next()) |item| {
            const name = std.mem.trim(u8, item, "'");
            switch (list) {
                .targets => if (std.mem.startsWith(u8, name, "arm64") and std.mem.endsWith(u8, name, "-macos")) {
                    arm64 = true;
                },
                .names => if (name.len > 1 and name[0] == '_') try out.put(gpa, name[1..], {}),
                .skip, .none => {},
            }
        }
        if (close != null) list = .none;
    }
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
    const gpa = std.testing.allocator;
    var set: std.StringHashMapUnmanaged(void) = .empty;
    defer set.deinit(gpa);
    try exports(gpa, text, &set);
    for ([_][]const u8{ "memset", "memset_pattern4", "puts", "weak_one", "cos", "sin", "tls_one" }) |n| try std.testing.expect(set.contains(n));
    for ([_][]const u8{ "x86_only", "NSObject", "System", "R8289209$_write", "/usr/lib/system/libsystem_m.dylib" }) |n| try std.testing.expect(!set.contains(n));
    try std.testing.expectEqual(7, set.count());
}
