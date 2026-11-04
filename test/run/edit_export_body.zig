//! exit: 0
//! stdout: "7\n"
//! rebuild-replace: "return 7;" "return 8;"
//! Edit builds that generate a function again which an `@export` names,
//! while the unit that exports it stays green: the function's atom keeps
//! the export's name, as a full build names it (BS_CACHE_VERIFY).
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

fn answer() callconv(.c) u32 {
    return 7;
}

comptime {
    @export(&answer, .{ .name = "edit_export_answer" });
}

extern fn edit_export_answer() u32;

fn main() callconv(.c) noreturn {
    rt.printInt(edit_export_answer());
    rt.exit(0);
}
