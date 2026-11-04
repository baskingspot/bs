//! exit: 0
//! stdout: "42\n"
//! rebuild-without: "    var y: u32 = 7;\n    _ = &y;\n"
//! An edit above an anonymous struct renames it (`main__struct_<n>`
//! numbers its instruction), and so the type its generic instance makes,
//! which captures nothing and so stays the same type: the edit build
//! loads that type's functions, whose symbols must take the new name
//! without the build being redone (docs/architecture.md, "Type names").
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

fn main() callconv(.c) noreturn {
    const x: u32 = 1;
    var y: u32 = 7;
    _ = &y;
    const g: Gen(struct {
        pub fn get(_: @This()) u32 {
            return 40;
        }
    }) = .{};
    rt.printInt(g.run() + x);
    rt.exit(0);
}

fn Gen(comptime C: type) type {
    return struct {
        const Self = @This();
        const Inner = Wrap(struct {
            pub fn one() u32 {
                return 1;
            }
        });
        ctx: C = undefined,
        fn run(self: *const Self) u32 {
            return self.ctx.get() + Inner.call();
        }
    };
}

fn Wrap(comptime H: type) type {
    return struct {
        fn call() u32 {
            return H.one();
        }
    };
}
