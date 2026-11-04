// Adapted from zul's src/command_line_args.zig
// (https://github.com/karlseguin/zul), MIT License, Copyright (c) Karl Seguin.
const std = @import("std");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

pub const CommandLineArgs = struct {
    _arena: *ArenaAllocator,
    _lookup: std.StringHashMapUnmanaged([]const u8),

    exe: []const u8,
    tail: [][]const u8,
    list: [][]const u8,

    // Done this way, with our anytype iterator so that we can write unit tests
    pub fn parseFromIterator(arena: *ArenaAllocator, it: anytype) !CommandLineArgs {
        const allocator = arena.allocator();
        var list: std.ArrayList([]const u8) = .empty;
        var lookup: std.StringHashMapUnmanaged([]const u8) = .{};

        const exe = blk: {
            const first = it.next() orelse return .{
                .exe = "",
                .tail = &[_][]const u8{},
                .list = &[_][]const u8{},
                ._arena = arena,
                ._lookup = lookup,
            };
            const exe = try allocator.dupe(u8, first);
            try list.append(allocator, exe);
            break :blk exe;
        };

        // first thing we do is collect them all into our list. This will let us
        // move forwards and backwards when we do our simple parsing
        while (it.next()) |arg| {
            try list.append(allocator, try allocator.dupe(u8, arg));
        }

        // 1, skip the exe
        var i: usize = 1;
        var tail_start: usize = 1;

        const items = list.items;
        while (i < items.len) {
            const arg = items[i];
            if (arg.len == 1 or arg[0] != '-') {
                // can't be a valid parameter, so it must be the start of our tail
                break;
            }

            if (arg[1] == '-') {
                const kv = KeyValue.from(arg[2..], items, &i);
                try lookup.put(allocator, kv.key, kv.value);
            } else {
                const kv = KeyValue.from(arg[1..], items, &i);
                const key = kv.key;

                // -xvf file.tar.gz
                // parses into x=>"", v=>"", f=>"file.tar.gz"
                for (0..key.len - 1) |j| {
                    try lookup.put(allocator, key[j .. j + 1], "");
                }
                try lookup.put(allocator, key[key.len - 1 ..], kv.value);
            }
            tail_start = i;
        }

        return .{
            .exe = exe,
            // safe to do since all the memory is managed by our arena
            .tail = list.items[tail_start..],
            .list = list.items,
            ._arena = arena,
            ._lookup = lookup,
        };
    }

    pub fn deinit(self: CommandLineArgs) void {
        const arena = self._arena;
        const allocator = arena.child_allocator;
        arena.deinit();
        allocator.destroy(arena);
    }

    pub fn contains(self: *const CommandLineArgs, name: []const u8) bool {
        return self._lookup.contains(name);
    }

    pub fn get(self: *const CommandLineArgs, name: []const u8) ?[]const u8 {
        return self._lookup.get(name);
    }

    pub fn count(self: *const CommandLineArgs) u32 {
        return self._lookup.count();
    }
};

const KeyValue = struct {
    key: []const u8,
    value: []const u8,

    fn from(key: []const u8, items: [][]const u8, i: *usize) KeyValue {
        const item_index = i.*;
        if (std.mem.indexOfScalarPos(u8, key, 0, '=')) |pos| {
            // this parameter is in the form of --key=value, or -k=value
            // we just skip the key
            i.* = item_index + 1;

            return .{
                .key = key[0..pos],
                .value = key[pos + 1 ..],
            };
        }

        if (item_index == items.len - 1 or items[item_index + 1][0] == '-') {
            // our key is at the end of the arguments OR
            // the next argument starts with a '-'. This means this key has no value

            // we just skip the key
            i.* = item_index + 1;

            return .{
                .key = key,
                .value = "",
            };
        }

        // skip the current key, and the next arg (which is our value)
        i.* = item_index + 2;
        return .{
            .key = key,
            .value = items[item_index + 1],
        };
    }
};

const SliceIterator = struct {
    args: []const []const u8,
    index: usize = 0,

    fn next(self: *SliceIterator) ?[]const u8 {
        if (self.index == self.args.len) return null;
        defer self.index += 1;
        return self.args[self.index];
    }
};

pub fn main(init: std.process.Init) !void {
    const arena = try init.gpa.create(ArenaAllocator);
    arena.* = ArenaAllocator.init(init.gpa);
    var it: SliceIterator = .{ .args = &.{ "/bin/app", "--port=8080", "-xvf", "out.tar", "rest" } };
    const args = try CommandLineArgs.parseFromIterator(arena, &it);
    defer args.deinit();
    const port = try std.fmt.parseInt(u16, args.get("port") orelse "80", 10);
    std.debug.print("{s} port={d} x={} f={s} tail={d}\n", .{ args.exe, port, args.contains("x"), args.get("f").?, args.tail.len });
}
