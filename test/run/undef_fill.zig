//! exit: 0
//! stdout: "1\n1\n1\n1\n1\n1\n1\n1\n1\n1\n1\n1\n1\n1\n1\n1\n1\n"
//! Debug fills undefined memory with 0xaa, as upstream: small values with
//! stores, large ones (here, past 128 bytes) with `rep stosb`, both for
//! an undefined local and for `undefined` stored through a pointer. A
//! fill goes only when nothing can read it (`Ssa.deadFills`): the rest
//! read bytes of a local that some path leaves filled.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

fn allAa(bytes: []const volatile u8) bool {
    for (bytes) |b| if (b != 0xaa) return false;
    return true;
}

fn local(comptime n: usize) bool {
    var buf: [n]u8 = undefined;
    return allAa(&buf);
}

const Odd = extern struct { a: [125]u8, b: u32 };

fn stored(p: *volatile [3000]u8) bool {
    @memset(p, 0);
    p.* = undefined;
    return allAa(p);
}

var yes = true;
var no = false;
var three: usize = 3;

/// Only some elements written before one that was not is read.
fn partial() bool {
    var a: [8]u8 = undefined;
    a[0] = 1;
    a[1] = 2;
    return a[5] == 0xaa and a[0] == 1;
}

/// Read at a runtime index.
fn runtimeIndex() bool {
    var a: [4]u16 = undefined;
    a[0] = 7;
    return a[three] == 0xaaaa;
}

/// Written on one path only.
fn onePath() bool {
    var a: [2]u32 = undefined;
    if (no) a[0] = 1;
    a[1] = 2;
    return a[0] == 0xaaaa_aaaa;
}

/// Read in a loop before the iteration that writes it.
fn loopReadFirst() bool {
    var a: [6]u8 = undefined;
    var ok = true;
    for (0..6) |k| {
        if (k == three) ok = ok and a[k + 1] == 0xaa;
        a[k] = @intCast(k);
    }
    return ok and a[5] == 5;
}

/// A promoted variable left undefined on one path.
fn promoted() bool {
    var x: u32 = undefined;
    if (no) x = 5;
    return x == 0xaaaa_aaaa;
}

/// One field written, the whole struct read as bytes.
fn structBytes() bool {
    const S = extern struct { a: u16, b: u16 };
    var s: S = undefined;
    s.a = 0x0101;
    const bytes: *const [4]u8 = @ptrCast(&s);
    return bytes[2] == 0xaa and bytes[3] == 0xaa;
}

/// Every byte written before the read: the fill is dead, and the values
/// are those written.
fn whole() bool {
    var a: [3]u16 = undefined;
    a[2] = 3;
    if (yes) a[0] = 1 else a[0] = 9;
    a[1] = 2;
    return a[0] == 1 and a[1] == 2 and a[2] == 3;
}

/// `for` loops that write all but one element before it is read: one
/// short, one that skips an iteration, one that leaves early, and an inner
/// loop one element short.
fn loopShort() bool {
    var a: [4]u8 = undefined;
    for (0..3) |k| a[k] = @intCast(k);
    return a[3] == 0xaa;
}

fn loopContinue() bool {
    var a: [4]u8 = undefined;
    for (0..4) |k| {
        if (k == three - 2) continue;
        a[k] = @intCast(k);
    }
    return a[1] == 0xaa and a[3] == 3;
}

fn loopBreak() bool {
    var a: [4]u8 = undefined;
    for (0..4) |k| {
        if (k == three - 1) break;
        a[k] = @intCast(k);
    }
    return a[2] == 0xaa;
}

fn loopInnerShort() bool {
    var a: [2][4]u8 = undefined;
    for (0..2) |i| {
        for (0..3) |j| a[i][j] = @intCast(j);
    }
    return a[1][3] == 0xaa and a[1][2] == 2;
}

/// Loops that write every element: the fill is dead.
fn loopWhole() bool {
    var a: [2][4]u8 = undefined;
    for (0..2) |i| {
        for (0..4) |j| a[i][j] = @intCast(i * 4 + j);
    }
    return a[0][0] == 0 and a[1][3] == 7;
}

fn main() callconv(.c) noreturn {
    rt.printInt(@intFromBool(loopShort()));
    rt.printInt(@intFromBool(loopContinue()));
    rt.printInt(@intFromBool(loopBreak()));
    rt.printInt(@intFromBool(loopInnerShort()));
    rt.printInt(@intFromBool(loopWhole()));
    rt.printInt(@intFromBool(partial()));
    rt.printInt(@intFromBool(runtimeIndex()));
    rt.printInt(@intFromBool(onePath()));
    rt.printInt(@intFromBool(loopReadFirst()));
    rt.printInt(@intFromBool(promoted()));
    rt.printInt(@intFromBool(structBytes()));
    rt.printInt(@intFromBool(whole()));
    rt.printInt(@intFromBool(local(128)));
    rt.printInt(@intFromBool(local(129)));
    rt.printInt(@intFromBool(local(64 * 1024)));
    var odd: Odd = undefined;
    rt.printInt(@intFromBool(allAa(@as(*const volatile [@sizeOf(Odd)]u8, @ptrCast(&odd)))));
    var big: [3000]u8 = undefined;
    rt.printInt(@intFromBool(stored(&big)));
    rt.exit(0);
}
