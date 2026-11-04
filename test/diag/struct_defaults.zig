// A struct's field defaults are analyzed once its layout is, whether or
// not anything reads them (upstream's exported_function_uses_invalid_type
// and accessing_runtime_paramter_outside_function_scope). The edit build
// must find them from the layouts it keeps.
export fn foo() void {
    const S = struct { x: u32 = "bad default" };
    const s: S = undefined;
    _ = s;
}

export fn entry(y: u8) void {
    const Thing = struct {
        y: u8 = y,
    };
    _ = Thing{ .y = 1 };
}

// Only the default's dependency changes in the edit, not the layout: the
// edit build reaches the defaults from the layout it keeps.
const default_z = "bad default";
const Z = struct { z: u32 = default_z };

export fn bar() void {
    const z: Z = undefined;
    _ = z;
}

pub fn main() void {}

// error
// edit-from: "\"bad default\"" "5"
// edit-from: "y: u8 = y" "y: u8 = @sizeOf(@TypeOf(y))"
// edit-from: "default_z = \"bad default\"" "default_z = 7"
// struct_defaults.zig:6:33: error[type-mismatch]: expected type 'u32', found '*const [11:0]u8'
//   | const S = struct { x: u32 = "bad default" };
//   ref: struct_defaults.foo.S struct_defaults.zig:6:15 <- foo struct_defaults.zig:7:18
// struct_defaults.zig:13:17: error[not-accessible]: 'y' not accessible outside function scope
//   | y: u8 = y,
//   ref: struct_defaults.entry.Thing struct_defaults.zig:12:19 <- entry struct_defaults.zig:15:17
// struct_defaults.zig:21:29: error[type-mismatch]: expected type 'u32', found '*const [11:0]u8'
//   | const Z = struct { z: u32 = default_z };
//   ref: struct_defaults.Z struct_defaults.zig:21:11 <- bar struct_defaults.zig:24:18
// 3 errors
