//! exit: 0
//! stdout: "1001 2 3003 5088 103004 6006 99 77 99\n"

// A by-value receiver read from a `const` local that is read again after
// the call is passed as the local's memory, without a copy, when nothing
// can write the local during the call. A callee writing the copy's
// source, through another argument or a global, sees its parameter and
// leaves the local unchanged; so does one passed a `var` and a pointer to
// it, or a `const` and its address. A by-value parameter's receiver is
// the caller's argument memory, which the callee writing the caller's
// source leaves unchanged too.
const std = @import("std");

const Big = struct {
    a: [5]u64,

    noinline fn readAfterWrite(x: Big, src: *Big) u64 {
        src.a[0] = 99;
        return x.a[0];
    }

    noinline fn readAfterGlobal(x: Big) u64 {
        global.a[0] = 77;
        return x.a[0];
    }

    noinline fn readAfterVar(x: Big, v: *Big) u64 {
        v.a[1] = 88;
        return x.a[1];
    }

    noinline fn sum(x: Big, y: *const Big) u64 {
        return x.a[3] + y.a[0];
    }
};

var global: *Big = undefined;

noinline fn copyThenCall(src: *Big) u64 {
    const c = src.*;
    const r = c.readAfterWrite(src);
    return r * 1000 + c.a[0];
}

noinline fn sourceThenCall(src: *Big) u64 {
    return src.*.readAfterWrite(src);
}

noinline fn copyThenGlobal(src: *Big) u64 {
    const c = src.*;
    global = src;
    const r = c.readAfterGlobal();
    return r * 1000 + c.a[0];
}

noinline fn viaParam(b: Big, src: *Big) u64 {
    const r = b.readAfterWrite(src);
    return r * 1000 + b.a[0];
}

noinline fn paramThenCall(src: *Big) u64 {
    return viaParam(src.*, src);
}

noinline fn varThenCall(src: *const Big) u64 {
    var v = src.*;
    const r = v.readAfterVar(&v);
    return r * 1000 + v.a[1];
}

noinline fn addressToo(src: *const Big) u64 {
    const c = src.*;
    const r = c.sum(&c);
    return r * 1000 + c.a[3];
}

pub fn main() void {
    var b: Big = .{ .a = .{ 1, 2, 3, 4, 5 } };
    var c: Big = .{ .a = .{ 2, 0, 0, 0, 0 } };
    var d: Big = .{ .a = .{ 3, 0, 0, 0, 0 } };
    var e: Big = .{ .a = .{ 4, 5, 0, 0, 0 } };
    const r1 = copyThenCall(&b);
    const r2 = sourceThenCall(&c);
    const r3 = copyThenGlobal(&d);
    const r4 = varThenCall(&e);
    const r5 = addressToo(&b);
    var f: Big = .{ .a = .{ 6, 0, 0, 0, 0 } };
    const r6 = paramThenCall(&f);
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print("{} {} {} {} {} {} {} {} {}\n", .{ r1, r2, r3, r4, r5, r6, b.a[0], d.a[0], f.a[0] }) catch unreachable;
    std.Io.File.stdout().writeStreamingAll(std.Options.debug_io, w.buffered()) catch {};
}
