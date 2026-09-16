const std = @import("std");
const ProcessBuffer = @import("../processbuffer.zig").ProcessBuffer;
//const VirtualProcessBuffer = @import("../virtualprocessbuffer.zig").VirtualProcessBuffer;

// const BufferType = union(enum) {
//     process: *ProcessBuffer,
//     virtual: *VirtualProcessBuffer,
// };

pub const AddChildError = error{ InvalidParent, InvalidChild, CycleDetected, SelfEdge };

pub const Handle = struct {
    index: u32,
    generation: u32,
};

pub fn AcyclicGraph(comptime NodeType: type) type {
    return struct {
        const Self = @This();

        const Slot = struct {
            generation: u32 = 0,
            node: ?Node = null,
        };

        pub const Node = struct {
            ptr: *anyopaque,
            parents: std.ArrayList(Handle),
            children: std.ArrayList(Handle),
        };

        alloc: std.mem.Allocator,
        slots: std.ArrayList(Slot),
        /// indices of slots whose node was removed; reused by `createNode`
        free_slots: std.ArrayList(u32),

        pub fn init(alloc: std.mem.Allocator) !Self {
            return .{
                .alloc = alloc,
                .slots = try std.ArrayList(Slot).initCapacity(alloc, 8),
                .free_slots = .empty,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.slots.items) |*slot| {
                if (slot.node) |*n| {
                    n.parents.deinit(self.alloc);
                    n.children.deinit(self.alloc);
                }
            }
            self.slots.deinit(self.alloc);
            self.free_slots.deinit(self.alloc);
        }

        pub fn createNode(self: *Self, ptr: *NodeType) !Handle {
            const node = Node{
                .ptr = ptr,
                .parents = try std.ArrayList(Handle).initCapacity(self.alloc, 0),
                .children = try std.ArrayList(Handle).initCapacity(self.alloc, 0),
            };

            if (self.free_slots.pop()) |idx| {
                // the generation was bumped when the slot was freed, so stale handles miss
                const slot = &self.slots.items[idx];
                slot.node = node;
                return Handle{ .index = idx, .generation = slot.generation };
            }

            const idx = self.slots.items.len;
            try self.slots.append(self.alloc, .{ .generation = 1, .node = node });
            return Handle{ .index = @intCast(idx), .generation = 1 };
        }

        /// Unlinks the node from every parent and child, frees its lists and bumps the slot's
        /// generation so existing handles resolve to null from now on.
        pub fn removeNode(self: *Self, h: Handle) void {
            const node = self.get(h) orelse return;

            for (node.parents.items) |ph| {
                if (self.get(ph)) |p| unlink(&p.children, h);
            }
            for (node.children.items) |ch| {
                if (self.get(ch)) |c| unlink(&c.parents, h);
            }
            node.parents.deinit(self.alloc);
            node.children.deinit(self.alloc);

            const slot = &self.slots.items[h.index];
            slot.node = null;
            slot.generation +%= 1;
            if (slot.generation == 0) slot.generation = 1;
            self.free_slots.append(self.alloc, h.index) catch {
                // the slot simply stays unused
            };
        }

        fn unlink(list: *std.ArrayList(Handle), h: Handle) void {
            var i: usize = 0;
            while (i < list.items.len) {
                if (list.items[i].index == h.index and list.items[i].generation == h.generation) {
                    _ = list.swapRemove(i);
                } else {
                    i += 1;
                }
            }
        }

        pub fn get(self: *Self, h: Handle) ?*Node {
            if (h.index >= self.slots.items.len) return null;

            const slot = &self.slots.items[h.index];
            if (slot.generation != h.generation) return null;

            return if (slot.node != null) &slot.node.? else null;
        }

        pub fn getObject(self: *Self, h: Handle) ?*NodeType {
            const node = self.get(h) orelse return null;
            return @ptrCast(@alignCast(node.ptr));
        }

        pub fn addChild(self: *Self, parent: Handle, child: Handle) !void {
            if (parent.index == child.index) return AddChildError.SelfEdge;
            const p = self.get(parent) orelse return AddChildError.InvalidParent;
            const c = self.get(child) orelse return AddChildError.InvalidChild;

            // Check if adding parent → child would create a cycle
            if (try self.reachable(child, parent)) {
                return AddChildError.CycleDetected;
            }

            try p.children.append(self.alloc, child);
            try c.parents.append(self.alloc, parent);
        }

        pub fn getValue(self: *Self, h: Handle) ?*NodeType {
            const node = self.get(h) orelse return null;
            return @ptrCast(@alignCast(node.ptr));
        }

        pub const ChildrenIterator = struct {
            graph: *Self,
            list: []const Handle,
            index: usize = 0,

            pub fn next(self: *ChildrenIterator) ?Handle {
                while (self.index < self.list.len) {
                    const h = self.list[self.index];
                    self.index += 1;

                    if (self.graph.get(h) != null) {
                        return h;
                    }
                }
                return null;
            }
        };

        pub fn children(self: *Self, h: Handle) ?ChildrenIterator {
            const node = self.get(h) orelse return null;
            return ChildrenIterator{
                .graph = self,
                .list = node.children.items,
            };
        }

        pub const ParentsIterator = struct {
            graph: *Self,
            list: []const Handle,
            index: usize = 0,

            pub fn next(self: *ParentsIterator) ?Handle {
                while (self.index < self.list.len) {
                    const h = self.list[self.index];
                    self.index += 1;

                    if (self.graph.get(h) != null) {
                        return h;
                    }
                }
                return null;
            }
        };

        pub fn parents(self: *Self, h: Handle) ?ParentsIterator {
            const node = self.get(h) orelse return null;
            return ParentsIterator{
                .graph = self,
                .list = node.parents.items,
            };
        }

        const VisitState = enum {
            Unvisited,
            Visiting,
            Visited,
        };

        fn reachable(self: *Self, start: Handle, target: Handle) !bool {
            if (start.index == target.index and start.generation == target.generation) return true;
            const visited = try self.alloc.alloc(bool, self.slots.items.len);
            defer self.alloc.free(visited);

            @memset(visited, false);

            return try self.reachableFrom(start.index, target, visited);
        }

        fn reachableFrom(
            self: *Self,
            index: usize,
            target: Handle,
            visited: []bool,
        ) !bool {
            if (visited[index]) return false;
            visited[index] = true;

            const slot = &self.slots.items[index];
            const node = slot.node orelse return false;

            // Check each child
            for (node.children.items) |child_handle| {
                // Skip stale handles
                if (self.get(child_handle) == null) continue;

                // If this child *is* the target → reachable
                if (child_handle.index == target.index and
                    child_handle.generation == target.generation)
                {
                    return true;
                }

                // Recurse
                if (try self.reachableFrom(child_handle.index, target, visited)) {
                    return true;
                }
            }

            return false;
        }
    };
}

const testing = std.testing;

test "graph: self edges and cycles are rejected, removed nodes resolve to null" {
    const alloc = testing.allocator;
    var g = try AcyclicGraph(u32).init(alloc);
    defer g.deinit();

    var a: u32 = 1;
    var b: u32 = 2;
    var c: u32 = 3;
    const ha = try g.createNode(&a);
    const hb = try g.createNode(&b);
    const hc = try g.createNode(&c);

    try testing.expectError(error.SelfEdge, g.addChild(ha, ha));
    try g.addChild(ha, hb);
    try g.addChild(hb, hc);
    try testing.expectError(error.CycleDetected, g.addChild(hc, ha));

    g.removeNode(hb);
    try testing.expectEqual(null, g.get(hb));
    // a no longer lists b as a child, c no longer lists b as a parent
    try testing.expectEqual(0, g.get(ha).?.children.items.len);
    try testing.expectEqual(0, g.get(hc).?.parents.items.len);

    // the freed slot is reused with a new generation, so the stale handle still misses
    var d: u32 = 4;
    const hd = try g.createNode(&d);
    try testing.expectEqual(hb.index, hd.index);
    try testing.expect(hd.generation != hb.generation);
    try testing.expectEqual(null, g.get(hb));
    try testing.expectEqual(@as(u32, 4), g.getObject(hd).?.*);
}
