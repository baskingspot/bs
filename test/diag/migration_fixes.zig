// Names removed since 0.13 whose replacement means the same: each gets a
// fix that compiles.
const std = @import("std");

fn rand() void {
    var prng = std.rand.DefaultPrng.init(1);
    _ = &prng;
}

fn randType(prng: *std.Random.DefaultPrng) void {
    const r: std.rand.Random = prng.random();
    _ = r;
}

fn tokenize() void {
    var it = std.mem.tokenize(u8, "a b", " ");
    _ = it.next();
}

fn split() void {
    var it = std.mem.split(u8, "a,b", ",");
    _ = it.next();
}

fn sort() void {
    var nums = [_]i32{ 2, 1 };
    std.sort.sort(i32, &nums, {}, std.sort.asc(i32));
}

fn int() type {
    return std.meta.Int(.unsigned, 8);
}

fn isInt(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .Int => true,
        else => false,
    };
}

fn fieldCount(comptime T: type) usize {
    return @typeInfo(T).Struct.field_names.len;
}

fn gpa() void {
    var debug_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    _ = debug_allocator.deinit();
}

fn exit() void {
    std.os.exit(0);
}

pub fn main() void {
    rand();
    var prng = std.Random.DefaultPrng.init(1);
    randType(&prng);
    tokenize();
    split();
    sort();
    gpa();
    exit();
    _ = isInt(u8);
    _ = fieldCount(struct { a: u8 });
    _ = int();
}

// error
// migration_fixes.zig:6:20: error[no-member]: root source file struct 'std' has no member named 'rand'
//   | var prng = std.rand.DefaultPrng.init(1);
//   note std/std.zig:1:1: struct declared here
//   hint: std.rand is now std.Random
//   fix migration_fixes.zig:6:20-6:24: "Random"
//   ref: main migration_fixes.zig:55:9 (+3 std frames)
// migration_fixes.zig:11:18: error[no-member]: root source file struct 'std' has no member named 'rand'
//   | const r: std.rand.Random = prng.random();
//   note std/std.zig:1:1: struct declared here
//   hint: std.rand is now std.Random
//   fix migration_fixes.zig:11:18-11:29: "Random"
//   ref: main migration_fixes.zig:57:13 (+3 std frames)
// migration_fixes.zig:16:21: error[no-member]: root source file struct 'mem' has no member named 'tokenize'
//   | var it = std.mem.tokenize(u8, "a b", " ");
//   note std/mem.zig:1:1: struct declared here
//   hint: std.mem.tokenize is now std.mem.tokenizeAny (split at any of the delimiter bytes), tokenizeSequence (at the whole delimiter) or tokenizeScalar (at one byte)
//   fix migration_fixes.zig:16:22-16:31: "tokenizeAny("
//   ref: main migration_fixes.zig:58:13 (+3 std frames)
// migration_fixes.zig:21:21: error[no-member]: root source file struct 'mem' has no member named 'split'
//   | var it = std.mem.split(u8, "a,b", ",");
//   note std/mem.zig:1:1: struct declared here
//   hint: std.mem.split is now std.mem.splitSequence (split at the whole delimiter), splitAny (at any of the delimiter bytes) or splitScalar (at one byte)
//   fix migration_fixes.zig:21:22-21:28: "splitSequence("
//   ref: main migration_fixes.zig:59:10 (+3 std frames)
// migration_fixes.zig:27:13: error[no-member]: root source file struct 'sort' has no member named 'sort'
//   | std.sort.sort(i32, &nums, {}, std.sort.asc(i32));
//   note std/sort.zig:1:1: struct declared here
//   hint: use `std.mem.sort(T, items, context, lessThan)`
//   fix migration_fixes.zig:27:5-27:18: "std.mem.sort"
//   ref: main migration_fixes.zig:60:9 (+3 std frames)
// migration_fixes.zig:31:20: error[no-member]: root source file struct 'meta' has no member named 'Int'
//   | return std.meta.Int(.unsigned, 8);
//   note std/meta.zig:1:1: struct declared here
//   hint: use the builtin `@Int(.unsigned, bits)`
//   fix migration_fixes.zig:31:12-31:24: "@Int"
//   call: migration_fixes.zig:65:12 comptime
// migration_fixes.zig:36:10: error[no-member]: enum '@typeInfo(lang.Type).@"union".tag_type.?' has no member named 'Int'
//   | .Int => true,
//   note std/lang.zig:640:18: enum declared here: pub const Type = union(enum) {
//   candidates: int
//   hint: @typeInfo's tags are lowercase: .int, .float, .pointer, .comptime_int, .@"struct", .@"enum", .@"union", .@"fn"
//   fix migration_fixes.zig:36:10-36:13: "int"
//   ref: main migration_fixes.zig:63:14 (+3 std frames)
// migration_fixes.zig:42:25: error[no-field]: no field named 'Struct' in union 'lang.Type'
//   | return @typeInfo(T).Struct.field_names.len;
//   note std/lang.zig:640:18: union declared here: pub const Type = union(enum) {
//   candidates: struct
//   hint: @typeInfo's fields are lowercase: .int, .pointer, .@"struct", .@"enum", .@"union", .@"fn"
//   fix migration_fixes.zig:42:25-42:31: "@\"struct\""
//   ref: main migration_fixes.zig:64:19 (+3 std frames)
// migration_fixes.zig:46:35: error[no-member]: root source file struct 'heap' has no member named 'GeneralPurposeAllocator'
//   | var debug_allocator = std.heap.GeneralPurposeAllocator(.{}){};
//   note std/heap.zig:1:1: struct declared here
//   hint: std.heap.GeneralPurposeAllocator is now std.heap.DebugAllocator(.{}); in main, init.gpa from std.process.Init is one already
//   fix migration_fixes.zig:46:36-46:59: "DebugAllocator"
//   ref: main migration_fixes.zig:61:8 (+3 std frames)
// migration_fixes.zig:51:11: error[no-member]: root source file struct 'os' has no member named 'exit'
//   | std.os.exit(0);
//   note std/os.zig:1:1: struct declared here
//   hint: use std.process.exit
//   fix migration_fixes.zig:51:5-51:16: "std.process.exit"
//   ref: main migration_fixes.zig:62:9 (+3 std frames)
// 10 errors
