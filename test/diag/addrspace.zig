const S = struct { x: u32 };

fn coerce(p: *addrspace(.gs) u32) *u32 {
    return p;
}

fn cast(p: *addrspace(.gs) u32) *u32 {
    return @ptrCast(p);
}

fn derived(p: *addrspace(.gs) S) *u32 {
    return &p.x;
}

fn load(p: *addrspace(.fs) u32) u32 {
    return p.*;
}

pub fn main() void {
    _ = &coerce;
    _ = &cast;
    _ = &derived;
    _ = &load;
}

// error
// addrspace.zig:4:12: error[type-mismatch]: expected type '*u32', found '*addrspace(.gs) u32'
//   | return p;
//   note addrspace.zig:4:12: address space 'gs' cannot cast into address space 'generic'
//   note addrspace.zig:3:35: function return type declared here: fn coerce(p: *addrspace(.gs) u32) *u32 {
//   ref: main addrspace.zig:20:10 (+3 std frames)
// addrspace.zig:8:12: error[bad-cast]: @ptrCast changes pointer address space
//   | return @ptrCast(p);
//   note addrspace.zig:8:21: '*addrspace(.gs) u32' has address space 'gs'
//   note addrspace.zig:8:12: '*u32' has address space 'generic'
//   note addrspace.zig:8:12: use @addrSpaceCast to cast pointer address space
//   ref: main addrspace.zig:21:10 (+3 std frames)
// addrspace.zig:12:12: error[type-mismatch]: expected type '*u32', found '*addrspace(.gs) u32'
//   | return &p.x;
//   note addrspace.zig:12:12: address space 'gs' cannot cast into address space 'generic'
//   note addrspace.zig:11:34: function return type declared here: fn derived(p: *addrspace(.gs) S) *u32 {
//   ref: main addrspace.zig:22:10 (+3 std frames)
// addrspace.zig:16:13: error[unsupported]: zap does not support memory accesses through pointers in address space 'fs' yet
//   | return p.*;
//   ref: main addrspace.zig:23:10 (+3 std frames)
// 4 errors
