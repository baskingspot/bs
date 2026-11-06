//! exit: 0
//! stdout: "1\n2\n"
//! rebuild-replace: "member: u32," "member: Word,"
//! rebuild-without: " extra: u8,"
//! A union's generated tag type is no unit's: the union's layout makes it
//! whole, and its source is the union's. An edit to the union changes the
//! tag's source hash (`A`, whose field names stay), and a field its result
//! (`B`), without the tag being analyzed again; the edit build must record
//! both as a full build does (`Incremental.recordDelta`; the edit hunter,
//! seed 5203).
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

const Word = u32;
const A = union(enum) { ignored, member: u32, pair: [2]Word };
const B = union(enum) { none, one: u8, extra: u8, two: u16 };
var a: A = .ignored;
var b: B = .none;

fn main() callconv(.c) noreturn {
    a = .{ .member = 3 };
    b = .{ .two = 4 };
    rt.printInt(@intFromEnum(a));
    rt.printInt(@intFromEnum(b) - @as(u8, if (@hasField(B, "extra")) 1 else 0));
    rt.exit(0);
}
