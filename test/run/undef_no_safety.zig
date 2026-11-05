//! exit: 0
//! stdout: "1\n1\n1\n1\n7\n6\n"
//! Without runtime safety, `@memset` of `undefined` and a store of
//! `undefined` write nothing, as upstream's `memset` and `store` (not
//! their `_safe` forms): memory fresh from mmap stays zero, which code
//! such as Ghostty's page allocation relies on in ReleaseFast. With
//! safety, both fill 0xaa.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

/// A fresh anonymous private mapping: zeroed by the kernel.
fn mapPage() *align(4096) [4096]u8 {
    const addr = asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [nr] "{rax}" (9),
          [addr] "{rdi}" (0),
          [len] "{rsi}" (4096),
          [prot] "{rdx}" (3), // PROT_READ | PROT_WRITE
          [flags] "{r10}" (0x22), // MAP_PRIVATE | MAP_ANONYMOUS
          [fd] "{r8}" (@as(usize, @bitCast(@as(isize, -1)))),
          [off] "{r9}" (0),
        : .{ .rcx = true, .r11 = true, .memory = true });
    return @ptrFromInt(addr);
}

fn all(bytes: []const volatile u8, b: u8) bool {
    for (bytes) |x| if (x != b) return false;
    return true;
}

const S = extern struct { a: u32, b: [60]u8, c: u64 };

fn memsetUnsafe(p: []u8) void {
    @setRuntimeSafety(false);
    @memset(p, undefined);
}

fn storeUnsafe(p: *S, q: *[3000]u8, r: *u16) void {
    @setRuntimeSafety(false);
    p.* = undefined;
    q.* = undefined;
    r.* = undefined;
}

fn memsetSafe(p: []u8) void {
    @memset(p, undefined);
}

fn storeSafe(p: *S) void {
    p.* = undefined;
}

var yes = true;
var no = false;

/// A local left undefined, then written on the taken path: promoted to a
/// register with no store before the first write.
fn promoted() u32 {
    @setRuntimeSafety(false);
    var x: u32 = undefined;
    if (no) x = 5;
    if (yes) x = 7;
    return x;
}

fn loopFilled() u32 {
    @setRuntimeSafety(false);
    var a: [4]u8 = undefined;
    for (0..4) |k| a[k] = @intCast(k);
    return a[0] + a[1] + a[2] + a[3];
}

fn main() callconv(.c) noreturn {
    const page = mapPage();
    memsetUnsafe(page[0..1000]);
    storeUnsafe(@ptrCast(page[1000..]), page[1072..4072], @ptrCast(page[4080..]));
    rt.printInt(@intFromBool(all(page, 0)));

    const safe_page = mapPage();
    memsetSafe(safe_page[0..1000]);
    rt.printInt(@intFromBool(all(safe_page[0..1000], 0xaa)));
    rt.printInt(@intFromBool(all(safe_page[1000..], 0)));
    storeSafe(@ptrCast(safe_page[1000..]));
    rt.printInt(@intFromBool(all(safe_page[1000 .. 1000 + @sizeOf(S)], 0xaa)));

    rt.printInt(promoted());
    rt.printInt(loopFilled());
    rt.exit(0);
}
