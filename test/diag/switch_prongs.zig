const E = enum { a, b, c };
const U = union(enum) { a: u8, b: void, @"c d": u8 };
const Err = error{ X, Y };
fn lines(e: E) u8 {
    return switch (e) {
        .a => 1,
    };
}
fn oneLine(e: E) u8 {
    return switch (e) { .a => 1 };
}
fn tagged(x: U) u8 {
    return switch (x) {
        .a => |v| v,
    };
}
fn errors(x: Err!u8) u8 {
    return x catch |err| switch (err) {
        error.X => 1,
    };
}
fn anyErr(x: anyerror) u8 {
    return switch (x) {
        error.X => 1,
    };
}
pub fn main() void {
    _ = lines(.a);
    _ = oneLine(.a);
    _ = tagged(.{ .a = 1 });
    _ = errors(1);
    _ = anyErr(error.X);
}

// error
// switch_prongs.zig:5:12: error[switch-incomplete]: switch must handle all possibilities
//   | return switch (e) {
//   note switch_prongs.zig:1:21: unhandled enumeration value: 'b'
//   note switch_prongs.zig:1:24: unhandled enumeration value: 'c'
//   note switch_prongs.zig:1:11: enum 'switch_prongs.E' declared here: const E = enum { a, b, c };
//   ref: main switch_prongs.zig:28:14 (+3 std frames)
// switch_prongs.zig:10:12: error[switch-incomplete]: switch must handle all possibilities
//   | return switch (e) { .a => 1 };
//   note switch_prongs.zig:1:21: unhandled enumeration value: 'b'
//   note switch_prongs.zig:1:24: unhandled enumeration value: 'c'
//   note switch_prongs.zig:1:11: enum 'switch_prongs.E' declared here: const E = enum { a, b, c };
//   ref: main switch_prongs.zig:29:16 (+3 std frames)
// switch_prongs.zig:13:12: error[switch-incomplete]: switch must handle all possibilities
//   | return switch (x) {
//   note switch_prongs.zig:2:32: unhandled enumeration value: 'b'
//   note switch_prongs.zig:2:41: unhandled enumeration value: 'c d'
//   note switch_prongs.zig:2:11: enum '@typeInfo(switch_prongs.U).@"union".tag_type.?' declared here: const U = union(enum) { a: u8, b: void, @"c d": u8 };
//   ref: main switch_prongs.zig:30:15 (+3 std frames)
// switch_prongs.zig:18:26: error[switch-incomplete]: switch must handle all possibilities
//   | return x catch |err| switch (err) {
//   note switch_prongs.zig:18:26: unhandled error value: 'error.Y'
//   ref: main switch_prongs.zig:31:15 (+3 std frames)
// switch_prongs.zig:23:12: error[switch-incomplete]: else prong required when switching on type 'anyerror'
//   | return switch (x) {
//   ref: main switch_prongs.zig:32:15 (+3 std frames)
// 5 errors
