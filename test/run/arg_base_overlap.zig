//! exit: 0
//! stderr: "1 5 1 5 5 8\n"
//! A by-value argument read through a pointer that lives in one of the
//! registers the argument is passed in: `local` arrives in rsi and stays
//! there up to the first call, whose callee returns through rdi and takes
//! `self` in rsi (and rdx). The register the address is based on must be
//! written last (`loadPair`), or the address moved to r11 first
//! (`loadBytes`, for the 7- and 15-byte maps). The slice map is zwasm's
//! frame_chain.zig, which read the slice's length from its pointer plus 8.
const std = @import("std");
fn CodeMap(comptime T: type) type {
    return struct {
        data: T,
        const Self = @This();
        const Lookup = union(enum) { inside: [2]usize, outside };
        noinline fn lookup(self: Self, addr: usize) Lookup {
            const entries: []const u64 = switch (T) {
                []const u64 => self.data,
                else => &.{ self.data[0], self.data[self.data.len - 1] },
            };
            for (entries, 0..) |e, i| if (e == addr) return .{ .inside = .{ i, e } };
            return .outside;
        }
        inline fn isCodeUnion(local: ?*const Self, is_code: *const fn (usize) bool, addr: usize) bool {
            if (local) |cm| switch (cm.lookup(addr)) {
                .inside => return true,
                .outside => {},
            };
            return is_code(addr);
        }
        noinline fn sniff(fp: usize, local: ?*const Self, is_code: *const fn (usize) bool) ?Link {
            if (fp == 0) return null;
            const slots: [*]const usize = @ptrFromInt(fp);
            if (isCodeUnion(local, is_code, slots[1])) return .{ .fp = slots[0], .rip = slots[1] };
            if (isCodeUnion(local, is_code, slots[2])) return .{ .fp = slots[1], .rip = slots[2] };
            return .{ .fp = 0, .rip = 0 };
        }
    };
}
const Link = struct { fp: usize, rip: usize };
fn isCode(a: usize) bool {
    return a == 99;
}
pub fn main() void {
    var frame = [_]usize{ 1, 5, 8 };
    const sl: CodeMap([]const u64) = .{ .data = &.{ 5, 0 } };
    const a = CodeMap([]const u64).sniff(@intFromPtr(&frame), &sl, isCode).?;
    const b7: CodeMap([7]u8) = .{ .data = .{ 9, 0, 0, 0, 0, 0, 5 } };
    const b = CodeMap([7]u8).sniff(@intFromPtr(&frame), &b7, isCode).?;
    const b15: CodeMap([15]u8) = .{ .data = .{ 9, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 8 } };
    const c = CodeMap([15]u8).sniff(@intFromPtr(&frame), &b15, isCode).?;
    std.debug.print("{d} {d} {d} {d} {d} {d}\n", .{ a.fp, a.rip, b.fp, b.rip, c.fp, c.rip });
}
