// Adapted from zio's src/utils/simple_stack.zig and src/utils/simple_queue.zig
// (https://github.com/lalinsky/zio), MIT License, Copyright (c) 2025 Lukáš Lalinský.
const std = @import("std");

/// Generic simple LIFO stack.
/// T must be a struct type with `next` field of type ?*T.
/// In debug mode, the struct must also have an `in_list` field of type bool; void in release.
pub fn SimpleStack(comptime T: type) type {
    return struct {
        const Self = @This();

        head: ?*T = null,

        pub fn push(self: *Self, item: *T) void {
            if (std.debug.runtime_safety) {
                std.debug.assert(!item.in_list);
                item.in_list = true;
            }
            item.next = self.head;
            self.head = item;
        }

        pub fn pop(self: *Self) ?*T {
            const head = self.head orelse return null;
            if (std.debug.runtime_safety) {
                head.in_list = false;
            }
            self.head = head.next;
            head.next = null;
            return head;
        }

        /// Move all items from other stack to this stack (prepends).
        pub fn prependByMoving(self: *Self, other: *Self) void {
            const other_head = other.head orelse return;

            // Find tail of other stack
            var tail = other_head;
            while (tail.next) |next| {
                tail = next;
            }

            // Link tail to our current head
            tail.next = self.head;
            self.head = other_head;

            other.head = null;
        }
    };
}
/// Generic simple FIFO queue.
/// T must be a struct type with `next` and `prev` fields of type ?*T.
/// In debug mode, the struct must also have an `in_list` field of type bool; void in release.
pub fn SimpleQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        head: ?*T = null,
        tail: ?*T = null,

        /// Empty queue constant for convenient initialization
        pub const empty: Self = .{};

        /// Check if the queue is empty
        pub fn isEmpty(self: *const Self) bool {
            return self.head == null;
        }

        pub fn push(self: *Self, item: *T) void {
            if (std.debug.runtime_safety) {
                std.debug.assert(!item.in_list);
                item.in_list = true;
            }
            item.next = null;
            if (self.tail) |tail| {
                tail.next = item;
                item.prev = tail;
                self.tail = item;
            } else {
                item.prev = null;
                self.head = item;
                self.tail = item;
            }
        }

        pub fn pop(self: *Self) ?*T {
            const head = self.head orelse return null;
            if (std.debug.runtime_safety) {
                head.in_list = false;
            }
            self.head = head.next;
            if (self.head) |new_head| {
                new_head.prev = null;
            } else {
                self.tail = null;
            }
            head.next = null;
            head.prev = null;
            return head;
        }

        /// Remove and return all items from the queue.
        /// Returns a SimpleStack containing all items; the original queue becomes empty.
        /// This is useful for processing all items without repeated locking.
        ///
        /// The returned stack only uses `next` pointers for iteration. All nodes have
        /// their `prev` field set to null, which acts as a sentinel to prevent concurrent
        /// remove() operations from touching the nodes while they're being processed.
        pub fn popAll(self: *Self) SimpleStack(T) {
            const head = self.head;

            // Iterate through all nodes and set prev = null (sentinel)
            // This prevents concurrent remove() from manipulating these nodes
            var node = head;
            while (node) |n| {
                n.prev = null;
                node = n.next;
            }

            // Clear the queue
            self.* = .empty;

            // Return a SimpleStack (only uses next pointers)
            return .{ .head = head };
        }

        pub fn concatByMoving(self: *Self, other: *Self) void {
            if (other.head == null) return;

            if (self.tail) |tail| {
                tail.next = other.head;
                if (other.head) |other_head| {
                    other_head.prev = tail;
                }
                self.tail = other.tail;
            } else {
                self.head = other.head;
                self.tail = other.tail;
            }

            other.head = null;
            other.tail = null;
        }

        pub fn remove(self: *Self, item: *T) bool {
            // Handle empty list
            if (self.head == null) return false;

            // Validate membership (if no prev, must be head)
            if (item.prev == null and self.head != item) return false;
            // Validate membership (if no next, must be tail)
            if (item.next == null and self.tail != item) return false;

            // Mark as removed
            if (std.debug.runtime_safety) {
                item.in_list = false;
            }

            // Update prev node's next pointer (or head if removing first node)
            if (item.prev) |prev_node| {
                prev_node.next = item.next;
            } else {
                // No prev means this is the head
                self.head = item.next;
            }

            // Update next node's prev pointer (or tail if removing last node)
            if (item.next) |next_node| {
                next_node.prev = item.prev;
            } else {
                // No next means this is the tail
                self.tail = item.prev;
            }

            // Clear pointers
            item.next = null;
            item.prev = null;

            return true;
        }
    };
}

const Node = struct {
    next: ?*Node = null,
    prev: ?*Node = null,
    in_list: if (std.debug.runtime_safety) bool else void = if (std.debug.runtime_safety) false else {},
    data: i32,
};

test SimpleQueue {
    var nodes: [4]Node = undefined;
    for (&nodes, 0..) |*n, i| n.* = .{ .data = @intCast(i * 10) };

    var queue: SimpleQueue(Node) = .empty;
    try std.testing.expect(queue.isEmpty());
    for (&nodes) |*n| queue.push(n);
    try std.testing.expect(queue.remove(&nodes[2]));
    try std.testing.expect(!queue.remove(&nodes[2]));
    try std.testing.expectEqual(@as(i32, 0), queue.pop().?.data);

    var other: SimpleQueue(Node) = .empty;
    other.push(&nodes[0]);
    queue.concatByMoving(&other);
    try std.testing.expect(other.isEmpty());

    var stack = queue.popAll();
    try std.testing.expect(queue.isEmpty());
    var sum: i32 = 0;
    while (stack.pop()) |n| sum += n.data;
    try std.testing.expectEqual(@as(i32, 10 + 30 + 0), sum);
}

test SimpleStack {
    var a: Node = .{ .data = 1 };
    var b: Node = .{ .data = 2 };
    var c: Node = .{ .data = 3 };
    var s1: SimpleStack(Node) = .{};
    var s2: SimpleStack(Node) = .{};
    s1.push(&a);
    s2.push(&b);
    s2.push(&c);
    s1.prependByMoving(&s2);
    try std.testing.expect(s2.head == null);
    try std.testing.expectEqual(@as(i32, 3), s1.pop().?.data);
    try std.testing.expectEqual(@as(i32, 2), s1.pop().?.data);
    try std.testing.expectEqual(@as(i32, 1), s1.pop().?.data);
    try std.testing.expectEqual(@as(?*Node, null), s1.pop());
}
