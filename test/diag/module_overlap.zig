// A file belongs to one module, as upstream: module_overlap/other.zig is
// in 'root' through this import and in 'foo' through foo.zig's.
pub fn main() void {
    _ = @import("foo");
    _ = @import("module_overlap/other.zig");
}

// error
// args: --dep foo -Mroot=module_overlap.zig -Mfoo=module_overlap/foo.zig
// module_overlap/other.zig:1:1: error[bad-import]: file exists in modules 'root' and 'foo'
//   note module_overlap/other.zig:1:1: files must belong to only one module
//   note module_overlap.zig:5:17: file is imported here by the root of module 'root'
//   note module_overlap/foo.zig:2:17: file is imported here by the root of module 'foo'
// 1 error
