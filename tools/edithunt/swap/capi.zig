//! The edit hunter's `swap` project: `@import("revo")` names root.zig's
//! module, whose name differs between the two programs.
const revo = @import("revo");

pub fn scaled(x: u32) u32 {
    return revo.baselib.scale(x);
}

pub fn libName() []const u8 {
    return revo.baselib.name;
}

export fn revo_version() u32 { // ziglint-ignore: Z001 -- the exported C symbol keeps C naming
    return revo.baselib.version;
}
