//! exit: 0
//! stdout: "//! exit: 0\n1\n1\n1\n"
//! @embedFile of a file next to this one, and comptime @errorName, both
//! string literals.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

const self = @embedFile("embed.zig");
const also = @embedFile("./../" ++ "run/embed.zig");
const name = @errorName(error.TestErrorCode);

fn main() callconv(.c) noreturn {
    rt.print(self[0..11]);
    rt.print("\n");
    rt.printInt(@intFromBool(@TypeOf(self) == *const [self.len:0]u8));
    rt.printInt(@intFromBool(self.ptr == also.ptr or self.len == also.len));
    rt.printInt(@intFromBool(@TypeOf(name) == *const [13:0]u8));
    rt.exit(0);
}
