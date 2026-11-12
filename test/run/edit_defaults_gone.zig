//! exit: 0
//! stderr: "save 0\n"
//! rebuild-replace: "title: []const u8,\n" "title: []const u8 = \"\",\n"
//! rebuild-replace: "n: u32,\n" "n: u32 = 0,\n"
//! rebuild-replace: ".{ .kind = kind, .title = \"\", .n = 0 }" ".{ .kind = kind }"

// An edit that removes the root struct's last field defaults. A struct
// whose fields all lose their defaults maps none of its declarations to
// the old ZIR (as upstream's), so `Kind` is made again, and the edit
// reaches `stringToEnum`'s map type's defaults but not its layout. The
// lazy edit build loads `stringToEnum` without the layout, a dependency
// no edit reached, and must still resolve the layout before it brings
// the defaults up to date.
const std = @import("std");
const S = @This();

pub const Kind = enum { open, save, pick };

kind: Kind,
title: []const u8,
n: u32,

fn create(kind: Kind) S {
    return .{ .kind = kind, .title = "", .n = 0 };
}

fn parse(s: []const u8) ?Kind {
    return std.meta.stringToEnum(Kind, s);
}

pub fn main() void {
    const s = create(parse("save").?);
    std.debug.print("{t} {d}\n", .{ s.kind, s.n });
}
