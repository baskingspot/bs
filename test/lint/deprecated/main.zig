//! Z011, deprecated calls, which Sema answers: ziglint's semantic-mode
//! tests of the rule, with std itself for their fake std, and calls
//! ziglint's resolver cannot follow. Only analyzed code is checked.

const std = @import("std");
const lib = @import("lib.zig");

const MyType = struct {
    value: u32 = 0,
    /// Deprecated: use newMethod instead
    pub fn oldMethod(self: *const MyType) void {
        _ = self;
    }
    /// Does something useful
    pub fn goodMethod(self: *const MyType) void {
        _ = self;
    }
};
const instance: MyType = .{};

/// Deprecated: use newFunc instead
pub fn oldFunc() void {}
pub const aliasFunc = oldFunc;

/// Deprecated: use NewList instead
pub fn OldList(comptime T: type) type {
    return struct { items: []T };
}
pub const DeprecatedAlias = OldList;

const find = std.mem.indexOfScalar;
const dir_path = std.Io.Dir.path;

const S = struct {
    field: OldList(u8),
};

fn typePositions(x: OldList(u8)) ?OldList(u8) {
    _ = x;
    const arr = [_]type{OldList(u8)};
    _ = arr;
    return null;
}

// Not analyzed, so not checked.
fn unreferenced() void {
    oldFunc();
}

// ziglint's resolver cannot follow a parameter; Sema can.
fn throughPointer(p: *const MyType) void {
    p.oldMethod();
}

export fn entry() void {
    instance.oldMethod();
    instance.goodMethod();
    oldFunc();
    aliasFunc();
    _ = OldList(u8);
    _ = DeprecatedAlias(u8);
    _ = std.ArrayListUnmanaged(u8);
    _ = std.fs.path.basename("a/b");
    // The same namespace, by a path that is not deprecated.
    // ziglint-ignore: Z035
    _ = std.Io.Dir.path.basename("a/b");
    // And through an alias of it: std's own alias of it to the deprecated
    // `std.fs.path` is not followed.
    _ = dir_path.basename("a/b");
    _ = find(u8, "ab", 'b');
    _ = lib.Color.get();
    _ = std.meta.fieldInfo(S, .field);
    _ = typePositions(.{ .items = &.{} });
    throughPointer(&instance);
}

test {
    entry();
}

// error
// main.zig:35:12: error[deprecated, Z011]: 'OldList' is deprecated: Deprecated: use NewList instead
//   | field: OldList(u8),
// main.zig:38:21: error[deprecated, Z011]: 'OldList' is deprecated: Deprecated: use NewList instead
//   | fn typePositions(x: OldList(u8)) ?OldList(u8) {
// main.zig:38:35: error[deprecated, Z011]: 'OldList' is deprecated: Deprecated: use NewList instead
//   | fn typePositions(x: OldList(u8)) ?OldList(u8) {
// main.zig:40:25: error[deprecated, Z011]: 'OldList' is deprecated: Deprecated: use NewList instead
//   | const arr = [_]type{OldList(u8)};
// main.zig:52:7: error[deprecated, Z011]: 'oldMethod' is deprecated: Deprecated: use newMethod instead
//   | p.oldMethod();
// main.zig:56:14: error[deprecated, Z011]: 'oldMethod' is deprecated: Deprecated: use newMethod instead
//   | instance.oldMethod();
// main.zig:58:5: error[deprecated, Z011]: 'oldFunc' is deprecated: Deprecated: use newFunc instead
//   | oldFunc();
// main.zig:59:5: error[deprecated, Z011]: 'aliasFunc' is deprecated: Deprecated: use newFunc instead
//   | aliasFunc();
// main.zig:60:9: error[deprecated, Z011]: 'OldList' is deprecated: Deprecated: use NewList instead
//   | _ = OldList(u8);
// main.zig:61:9: error[deprecated, Z011]: 'DeprecatedAlias' is deprecated: Deprecated: use NewList instead
//   | _ = DeprecatedAlias(u8);
// main.zig:62:13: error[deprecated, Z011]: 'ArrayListUnmanaged' is deprecated: Deprecated; use `ArrayList`.
//   | _ = std.ArrayListUnmanaged(u8);
// main.zig:63:21: error[deprecated, Z011]: 'std.fs.path' is deprecated: Deprecated, use `std.Io.Dir.path`.
//   | _ = std.fs.path.basename("a/b");
// main.zig:70:9: error[deprecated, Z011]: 'find' is deprecated: Deprecated in favor of `findScalar`.
//   | _ = find(u8, "ab", 'b');
// main.zig:71:19: error[deprecated, Z011]: 'get' is deprecated: Deprecated: use fromEnvironment instead
//   | _ = lib.Color.get();
// main.zig:72:18: error[deprecated, Z011]: 'fieldInfo' is deprecated: Deprecated in favor of `@typeInfo`.
//
// To be removed after 0.17.0 is tagged.
//   | _ = std.meta.fieldInfo(S, .field);
// 15 errors
