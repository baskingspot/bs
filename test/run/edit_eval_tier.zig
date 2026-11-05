//! exit: 0
//! stdout: "thirty\n"
//! rebuild-without: "const d: Model = .{ .name = 1, .features = make(&.{.t}) };\n"
//! rebuild-without: "    sum += d.features.ints[0];\n"
//! A comptime call is evaluated by the walker for its first few runs and
//! by the evaluator after: without `d`, `g`'s call of `make` is the
//! fourth and the walker runs it; with it, the fifth, and the evaluator
//! does. The walker keeps `x` as a comptime variable, which reads no
//! layout; the evaluator's lowered code makes, loads and returns it as a
//! runtime local, whose reads of `S`'s layout must be conditional, or `g`
//! depends on `S`'s layout only in the second build, and the edit build,
//! which keeps `g` from the first, would lack the edge.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

// `g` itself reads only `Model`'s layout, not `S`'s.
const S = struct {
    ints: [2]u64,
    const empty: S = .{ .ints = .{ 0, 0 } };
    fn add(s: *S, i: u6) void {
        s.ints[0] |= @as(u64, 1) << i;
    }
};

fn Fns(comptime F: type) type {
    return struct {
        fn make(list: []const F) S {
            var x = S.empty;
            for (list) |i| x.add(@backingInt(i));
            return x;
        }
    };
}
const Model = struct { name: u8, features: S };
const E = enum(u6) { p, q, r, s, t };
const make = Fns(E).make;

const a: Model = .{ .name = 1, .features = make(&.{.q}) };
const b: Model = .{ .name = 1, .features = make(&.{.r}) };
const c: Model = .{ .name = 1, .features = make(&.{.s}) };
const d: Model = .{ .name = 1, .features = make(&.{.t}) };
const g: Model = .{ .name = 1, .features = make(&[_]E{}) };

fn main() callconv(.c) noreturn {
    var sum = a.features.ints[0] + b.features.ints[0] + c.features.ints[0];
    sum += d.features.ints[0];
    sum += g.features.ints[0];
    if (sum == 30) rt.print("thirty\n");
    rt.exit(0);
}
