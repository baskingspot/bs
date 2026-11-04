// List adapted from cache.zig's src/list.zig
// (https://github.com/karlseguin/cache.zig), MIT License, Copyright (c) 2024 Karl Seguin.
const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn List(comptime T: type) type {
    return struct {
        head: ?*Node,
        tail: ?*Node,
        mutex: Io.Mutex,

        pub const Node = struct {
            value: T,
            prev: ?*Node = null,
            next: ?*Node = null,
        };

        const Self = @This();

        pub fn init() Self {
            return .{
                .head = null,
                .tail = null,
                .mutex = .init,
            };
        }

        pub fn insert(self: *Self, io: Io, node: *Node) void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            self.moveToFrontLocked(node);
        }

        pub fn moveToFront(self: *Self, io: Io, node: *Node) void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            self.removeLocked(node);
            self.moveToFrontLocked(node);
        }

        pub fn moveToTail(self: *Self, io: Io, node: *Node) void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            self.removeLocked(node);
            self.moveToTailLocked(node);
        }

        pub fn remove(self: *Self, io: Io, node: *Node) void {
            self.mutex.lockUncancelable(io);
            self.removeLocked(node);
            self.mutex.unlock(io);
            node.next = null;
            node.prev = null;
        }

        pub fn removeTail(self: *Self) ?*Node {
            if (self.tail) |node| {
                if (node.prev) |prev| {
                    self.tail = prev;
                    prev.next = null;
                } else {
                    self.tail = null;
                    self.head = null;
                }
                node.next = null;
                node.prev = null;
                return node;
            } else {
                return null;
            }
        }

        fn moveToFrontLocked(self: *Self, node: *Node) void {
            if (self.head) |head| {
                head.prev = node;
                node.next = head;
                self.head = node;
            } else {
                self.head = node;
                self.tail = node;
            }
            node.prev = null;
        }

        fn moveToTailLocked(self: *Self, node: *Node) void {
            if (self.tail) |tail| {
                tail.next = node;
                node.prev = tail;
                self.tail = node;
            } else {
                self.head = node;
                self.tail = node;
            }
            node.next = null;
        }

        fn removeLocked(self: *Self, node: *Node) void {
            if (node.prev) |prev| {
                prev.next = node.next;
            } else {
                self.head = node.next;
            }

            if (node.next) |next| {
                next.prev = node.prev;
            } else {
                self.tail = node.prev;
            }
        }
    };
}

/// A least-recently-used cache of at most `capacity` entries.
const Lru = struct {
    list: List(Entry),
    map: std.StringHashMapUnmanaged(*List(Entry).Node),
    capacity: usize,

    const Entry = struct { key: []const u8, value: u32 };

    fn init(capacity: usize) Lru {
        return .{ .list = .init(), .map = .empty, .capacity = capacity };
    }

    fn deinit(self: *Lru, gpa: Allocator) void {
        var it = self.map.valueIterator();
        while (it.next()) |node| gpa.destroy(node.*);
        self.map.deinit(gpa);
    }

    fn put(self: *Lru, gpa: Allocator, io: Io, key: []const u8, value: u32) !void {
        if (self.map.get(key)) |node| {
            node.value.value = value;
            self.list.moveToFront(io, node);
            return;
        }
        if (self.map.count() == self.capacity) {
            const old = self.list.removeTail().?;
            _ = self.map.remove(old.value.key);
            gpa.destroy(old);
        }
        const node = try gpa.create(List(Entry).Node);
        node.* = .{ .value = .{ .key = key, .value = value } };
        try self.map.put(gpa, key, node);
        self.list.insert(io, node);
    }

    fn get(self: *Lru, io: Io, key: []const u8) ?u32 {
        const node = self.map.get(key) orelse return null;
        self.list.moveToFront(io, node);
        return node.value.value;
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var lru = Lru.init(2);
    defer lru.deinit(gpa);
    try lru.put(gpa, io, "a", 1);
    try lru.put(gpa, io, "b", 2);
    _ = lru.get(io, "a");
    try lru.put(gpa, io, "c", 3);
    const b = lru.get(io, "b") orelse 0;
    std.debug.print("a={d} b={d} c={d}\n", .{ lru.get(io, "a").?, b, lru.get(io, "c").? });
}
