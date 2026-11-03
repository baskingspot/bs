//! exit: 0
//! stdout: "add 3\nsize 4\nf 4\ng 3\nextra 1\nfields 2\nmarks 2\nedited\n"
//! rebuild-replace: "fn add(x: u64, y: u64) u64 {" "fn add(x: u64) u64 {"
//! rebuild-replace: "return x + y;" "return x;"
//! rebuild-replace: "add(1, 2)" "add(1)"
//! rebuild-replace: "b: [3]u8," "b: u8,"
//! rebuild-without: "    y: u8 = 1,\n"
//! rebuild-without: "pub const extra: u64 = 7;\n"
//! rebuild-without: "    t: type = u8,\n"
//! rebuild-without: "// EDITMARK\n"
//! rebuild-without: "    rt.print(\"edited\\n\");\n"
//! Edit builds that change a function's body and signature, a struct's
//! field type, a struct that gains a defaulted field and a comptime-only
//! one, a new declaration, and an embedded file (this one), each checked
//! against a full build, both ways.
const rt = @import("rt.zig");
pub const panic = rt.panic;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile ("call %[main:P]"
        :
        : [main] "X" (&main),
    );
}

fn add(x: u64, y: u64) u64 {
    return x + y;
}

const S = struct {
    a: u8,
    b: [3]u8,
};

fn size() u64 {
    return @sizeOf(S);
}

const F = struct {
    x: u16,
    y: u8 = 1,
};

var g: F = .{ .x = 3 };

pub const extra: u64 = 7;

const C = struct {
    n: u8 = 0,
    t: type = u8,
};

// EDITMARK
const self = @embedFile("edit.zig");

fn marks() u64 {
    const mark = "EDIT" ++ "MARK";
    comptime var n: u64 = 0;
    comptime {
        @setEvalBranchQuota(1000000);
        var i: usize = 0;
        while (i + mark.len <= self.len) : (i += 1) {
            if (eql(self[i..][0..mark.len], mark)) n += 1;
        }
    }
    return n;
}

fn eql(a: []const u8, b: []const u8) bool {
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

fn main() callconv(.c) noreturn {
    rt.print("add ");
    rt.printInt(add(1, 2));
    rt.print("size ");
    rt.printInt(size());
    rt.print("f ");
    rt.printInt(@sizeOf(F));
    rt.print("g ");
    rt.printInt(g.x);
    rt.print("extra ");
    rt.printInt(@intFromBool(@hasDecl(@This(), "extra")));
    rt.print("fields ");
    rt.printInt(comptime @typeInfo(C).@"struct".field_names.len);
    rt.print("marks ");
    rt.printInt(marks());
    rt.print("edited\n");
    rt.exit(0);
}
