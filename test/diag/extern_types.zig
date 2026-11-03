const Mode = enum { read, write };
const Header = extern struct { len: u32, mode: Mode };

export fn sum(values: []const u32) u32 {
    var total: u32 = 0;
    for (values) |v| total += v;
    return total;
}

export fn headerLen(h: *const Header) u32 {
    return h.len;
}

pub fn main() void {}

// error
// extern_types.zig:2:48: error[bad-type]: extern structs cannot contain fields of type 'extern_types.Mode'
//   | const Header = extern struct { len: u32, mode: Mode };
//   note extern_types.zig:1:14: integer tag type of enum is inferred
//   note extern_types.zig:1:14: consider explicitly specifying the integer tag type
//   note extern_types.zig:1:14: enum declared here: const Mode = enum { read, write };
//   ref: headerLen extern_types.zig:11:13
// extern_types.zig:4:15: error[bad-fn-type]: parameter of type '[]const u32' not allowed in function with calling convention 'x86_64_sysv'
//   | export fn sum(values: []const u32) u32 {
//   note extern_types.zig:4:15: slices have no guaranteed in-memory representation
// 2 errors
