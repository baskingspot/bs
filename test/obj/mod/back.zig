// Imports the root module by its `-M` name, which is not "root" (`zig
// build` names a module after its build.zig name).
pub fn level() u32 {
    return @import("app").base + 1;
}
