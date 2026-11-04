//! exit: 0
//! stdout: "16932\n47532\n48232\n78132\n1632\n327828\n16932\n22730\n7620\n78134\n2496\n2983\n"
//! A large load whose only user is a store, or a call, is copied straight
//! from its memory to the destination when nothing between them writes
//! memory, also across a bounds check, if the destination is the source or
//! does not overlap it. Each case writes the source or the destination
//! where it could change the result if the copy moved past the write, or
//! copies between overlapping memory, which upstream's ReleaseSafe build
//! copies with `memmove`. Each case prints what that build prints.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

fn out(v: u64) void {
    rt.printInt(v);
}

const C = struct { a: [17]u64 };

var arr: [8]C = undefined;
var g: C = undefined;

fn sum(c: C) u64 {
    var t: u64 = 0;
    for (c.a, 0..) |x, i| t +%= x *% (i + 1);
    return t;
}

fn fill(c: *C, base: u64) void {
    for (&c.a, 0..) |*x, i| x.* = base + i;
}

/// Copies through a pointer, with a bounds check between load and store.
noinline fn copyChecked(i: usize, j: usize) void {
    const c = arr[i];
    arr[j] = c;
}

/// Writes the source between the load and the store: the store must see
/// the old value.
noinline fn writeSourceBetween(i: usize, j: usize) void {
    const c = arr[i];
    arr[i].a[0] = 1000;
    arr[j] = c;
}

/// Writes the destination between the load and the store.
noinline fn writeDestBetween(i: usize, j: usize) void {
    const c = arr[i];
    arr[j].a[16] = 2000;
    arr[j] = c;
}

/// A copy onto itself.
noinline fn selfCopy(p: *C, q: *const C) void {
    p.* = q.*;
}

var words: [20]u64 = undefined;

/// Copies between overlapping memory, forward and backward.
noinline fn overlapCopy(d: usize, s: usize) void {
    const p: *C = @ptrCast(&words[d]);
    const q: *const C = @ptrCast(&words[s]);
    p.* = q.*;
}

fn wordSum() u64 {
    var t: u64 = 0;
    for (words, 0..) |x, i| t +%= x *% (i + 1);
    return t;
}

/// Swaps through a temporary.
noinline fn swap(a: *C, b: *C) void {
    const t = a.*;
    a.* = b.*;
    b.* = t;
}

/// The load is used after a call that writes its source.
noinline fn clobber(i: usize) void {
    arr[i].a[1] = 3000;
}
noinline fn callBetween(i: usize, j: usize) void {
    const c = arr[i];
    clobber(i);
    arr[j] = c;
}

/// A large value built by an inlined function and stored to a global.
inline fn make(x: u64) C {
    var c: C = undefined;
    fill(&c, x);
    c.a[3] = g.a[3];
    return c;
}
noinline fn setG(x: u64) void {
    g = make(x);
}

/// Passes a loaded value to a call across a bounds check.
noinline fn passChecked(i: usize) u64 {
    const c = arr[i];
    return sum(c) +% arr[(i + 1) % 8].a[2];
}

fn main() callconv(.c) noreturn {
    for (&arr, 0..) |*c, i| fill(c, 100 * i);
    fill(&g, 7);
    copyChecked(1, 2);
    out(sum(arr[2]));
    writeSourceBetween(3, 4);
    out(sum(arr[4]));
    out(sum(arr[3]));
    writeDestBetween(5, 6);
    out(sum(arr[6]));
    selfCopy(&arr[0], &arr[0]);
    out(sum(arr[0]));
    swap(&arr[0], &arr[7]);
    out(sum(arr[0]) *% 3 +% sum(arr[7]));
    callBetween(1, 5);
    out(sum(arr[5]));
    out(sum(arr[1]));
    setG(40);
    out(sum(g));
    out(passChecked(6));
    for (&words, 0..) |*x, i| x.* = i + 1;
    overlapCopy(2, 0);
    out(wordSum());
    overlapCopy(0, 3);
    out(wordSum());
    rt.exit(0);
}
