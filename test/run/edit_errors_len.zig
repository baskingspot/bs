//! exit: 0
//! stdout: "1\n1\n"
//! rebuild-replace: "error.Added" "error.Known"
//! An error code is checked against the number of error codes, a
//! link-time value: an edit build that adds an error (`error.Added`, the
//! compilation's last code) relinks with the new count, so converting
//! that code back to an error does not fail the check.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

fn fromInt(code: u16) anyerror {
    return @errorFromInt(code);
}

fn main() callconv(.c) noreturn {
    var known: u16 = @intFromError(error.Known);
    _ = &known;
    rt.printInt(@intFromBool(fromInt(known) == error.Known));
    var last: u16 = @intFromError(error.Added);
    _ = &last;
    rt.printInt(@intFromBool(@intFromError(fromInt(last)) == last));
    rt.exit(0);
}
