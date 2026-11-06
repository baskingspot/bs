//! exit: 0
//! stdout: "g 9 0 9 | e 7 12 | l 5 0 | n 6 | s 4 1 4 | c 10 | w 13 6 | p 9 16 8 15 | v 9 0 17 | o 9 0\n"

// Forwarding reads a load from inside nested blocks after they are left
// when it ran on every path out of them: before the first `br` leaving
// each, and not in a branch or a loop (`codegen/forward.zig`). An inline
// callee's copy of a by-value parameter is the caller's local, so its
// fields are the caller's. Each case below has a path on which the inner
// load does not run, and must not read it there; the guard and by-value
// cases read it where it did run.
const std = @import("std");

const P = struct { x: u32, y: u32 };

const Map = struct {
    meta: [*]const u32,
    n: u32,
    extra: u64 = 0,

    fn cap(self: *const Map) u32 {
        if (self.n == 0) return 0;
        return self.meta[0];
    }

    fn first(self: *const Map) u32 {
        if (self.n == 0) return 0;
        return self.meta[1];
    }
};

// The same with an optional pointer, as a hash map's `capacity` and
// `header` test `self.metadata` for null.
const OptMap = struct {
    meta: ?[*]const u32,
    n: u32,

    fn cap(self: *const OptMap) u32 {
        if (self.meta == null) return 0;
        return self.meta.?[0];
    }

    fn first(self: *const OptMap) u32 {
        if (self.meta == null) return 0;
        return self.meta.?[1];
    }
};

noinline fn guardOpt(m: *const OptMap, k: u32) u32 {
    if (k == 0) return 0;
    return m.cap() +% m.first();
}

// Too many fields to split, so an inline callee's by-value copy is a
// `const` cast of the caller's local, whose fields it then reads.
const Big = struct {
    meta: [*]const u32,
    n: u32,
    a: u64 = 0,
    b: u64 = 0,
    c: u64 = 0,
    d: u64 = 0,
    e: u64 = 0,
    f: u64 = 0,
    g: u64 = 0,
    h: u64 = 0,

    fn cap(self: Big) u32 {
        if (self.n == 0) return 0;
        return self.meta[0];
    }

    fn first(self: Big) u32 {
        if (self.n == 0) return 0;
        return self.meta[1];
    }
};

noinline fn byValue(m: Big, k: u32) u32 {
    if (k == 0) return 0;
    return m.cap() +% m.first();
}

// `cap`'s guard return: `self.n` and `self.meta` read before it are the
// values after it, also in the second inlined call.
noinline fn guard(m: *const Map, k: u32) u32 {
    if (k == 0) return 0;
    const a = m.cap();
    const b = m.first();
    return a +% b;
}

// The load runs after an early `br` out of the block, so it does not run
// when `skip` is set; the load after the block must load.
noinline fn early(s: *const P, skip: bool) u32 {
    var a: u32 = 7;
    blk: {
        if (skip) break :blk;
        a = s.x;
    }
    return a +% s.x;
}

// A load in a loop that runs zero times does not run at all.
noinline fn inLoop(s: *const P, n: usize, c: bool) u32 {
    var t: u32 = 0;
    blk: {
        for (0..n) |_| t +%= s.y;
        if (c) break :blk;
        t +%= 1;
    }
    return t +% s.y -% 3;
}

fn fail() noreturn {
    std.process.exit(3);
}

// A call to a function that does not return, before the first `br`: the
// load before it runs on every path out of the block.
noinline fn noReturn(s: *const P, bad: bool) u32 {
    var a: u32 = 0;
    blk: {
        a = s.x;
        if (bad) fail();
        if (a == 100) break :blk;
        a +%= 1;
    }
    return a +% s.x;
}

// The same in an inline callee: its load of `s.x`, before the call that
// does not return and the guard return, serves the caller after it.
fn checked(s: *const P) u32 {
    const x = s.x;
    if (x == 100) fail();
    if (x == 99) return 0;
    return x +% 1;
}

noinline fn noReturnInline(s: *const P) u32 {
    return checked(s) +% s.x;
}

// A load after a `switch` in an inner block, whose prongs leave the outer
// block or the inner one: not run on those paths.
noinline fn afterSwitch(s: *const P, k: u8) u32 {
    var a: u32 = 1;
    outer: {
        inner: {
            switch (k) {
                0 => break :outer,
                1 => break :inner,
                else => {},
            }
            a = s.y;
        }
        a +%= 0;
    }
    return a +% s.x -% 5;
}

// A load in a `switch` prong or an `if` before the first `br` runs on
// some paths only.
noinline fn inProng(s: *const P, k: u8, c: bool) u32 {
    var a: u32 = 1;
    blk: {
        switch (k) {
            0 => a = s.x,
            else => {},
        }
        if (c) break :blk;
        a +%= 1;
    }
    return a +% s.x;
}

noinline fn inIf(s: *const P, k: bool, c: bool) u32 {
    var a: u32 = 1;
    blk: {
        if (k) a = s.y;
        if (c) break :blk;
        a +%= 1;
    }
    return a +% s.y;
}

// Each block's own `br` comes first: the inner block is left before the
// load, which then does not run when `c` is set.
noinline fn innerFirst(s: *const P, c: bool) u32 {
    var a: u32 = 2;
    outer: {
        inner: {
            if (c) break :inner;
            a = s.x;
            break :outer;
        }
        a +%= 3;
    }
    return a +% s.x;
}

// A store between the guarded load and the later one.
noinline fn written(s: *P) u32 {
    var a: u32 = 0;
    blk: {
        a = s.x;
        if (a == 0) break :blk;
        s.x = 8;
    }
    return a +% s.x;
}

pub fn main() void {
    var buf: [160]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const meta = [_]u32{ 5, 4 };
    var s: P = .{ .x = 5, .y = 7 };
    var z: P = .{ .x = 0, .y = 7 };
    w.print("g {} {} {} | e {} {} | l {} {} | n {} | s {} {} {} | c {} | w {} {} | p {} {} {} {} | v {} {} {} | o {} {}\n", .{
        guard(&.{ .meta = &meta, .n = 1 }, 1),
        guard(&.{ .meta = &meta, .n = 0 }, 1),
        guard(&.{ .meta = &meta, .n = 2 }, 2),
        early(&s, true) -% 5,
        early(&s, false) +% 2,
        inLoop(&s, 0, true) +% 1,
        inLoop(&s, 0, false) -% 5,
        noReturn(&s, false) -% 5,
        afterSwitch(&s, 0) +% 3,
        afterSwitch(&s, 1),
        afterSwitch(&s, 2) -% 3,
        innerFirst(&s, true),
        written(&s),
        written(&z) +% 6,
        inProng(&s, 1, true),
        inProng(&s, 0, true),
        inIf(&s, false, true),
        inIf(&s, true, false),
        byValue(.{ .meta = &meta, .n = 1 }, 1),
        byValue(.{ .meta = &meta, .n = 0 }, 1),
        noReturnInline(&s),
        guardOpt(&.{ .meta = &meta, .n = 1 }, 1),
        guardOpt(&.{ .meta = null, .n = 1 }, 1),
    }) catch unreachable;
    std.Io.File.stdout().writeStreamingAll(std.Options.debug_io, w.buffered()) catch {};
}
