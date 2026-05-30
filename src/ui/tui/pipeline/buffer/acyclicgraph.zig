const std = @import("std");
const ProcessBuffer = @import("../processbuffer.zig").ProcessBuffer;
//const VirtualProcessBuffer = @import("../virtualprocessbuffer.zig").VirtualProcessBuffer;

// const BufferType = union(enum) {
//     process: *ProcessBuffer,
//     virtual: *VirtualProcessBuffer,
// };

pub const AddChildError = error{ InvalidParent, InvalidChild, CycleDetected };

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

        pub fn init(alloc: std.mem.Allocator) !Self {
            return .{
                .alloc = alloc,
                .slots = try std.ArrayList(Slot).initCapacity(alloc, 8),
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
        }

        pub fn createNode(self: *Self, ptr: *NodeType) !Handle {
            const idx = self.slots.items.len;

            try self.slots.append(self.alloc, .{
                .generation = 1,
                .node = Node{
                    .ptr = ptr,
                    .parents = try std.ArrayList(Handle).initCapacity(self.alloc, 0),
                    .children = try std.ArrayList(Handle).initCapacity(self.alloc, 0),
                },
            });

            return Handle{ .index = @intCast(idx), .generation = 1 };
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
