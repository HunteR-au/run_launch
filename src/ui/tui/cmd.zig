const std = @import("std");
const Output = @import("outputwidget.zig").Output;

pub const Handler = struct {
    listener: *anyopaque,
    handle: *const HandleFn,
    event_str: []const u8,
};

const HandlerRef = struct {
    handler: Handler,
    id: HandleId,
};

pub const HandleFn = fn (args: []const u8, listener: *anyopaque) std.mem.Allocator.Error!void;
pub const HandleId = usize;

pub const Cmd = struct {
    // what does this do
    // needs to process a command
    // --- pub/sub model
    // --- subscribe to events with an handler
    // --- --- publish an event

    arena: std.heap.ArenaAllocator,
    alloc: std.mem.Allocator,
    history: std.ArrayList([]u8),
    handlers: std.ArrayList(HandlerRef),
    lastHandleId: usize = 0,

    pub fn init(alloc: std.mem.Allocator) !Cmd {
        return .{
            .handlers = try std.ArrayList(HandlerRef).initCapacity(alloc, 10),
            .history = try std.ArrayList([]u8).initCapacity(alloc, 10),
            .arena = std.heap.ArenaAllocator.init(alloc),
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *Cmd) void {
        self.handlers.deinit(self.alloc);
        self.history.deinit(self.alloc);
        self.arena.deinit();
    }

    pub fn handleCmd(self: *const Cmd, buffer: []const u8) !void {
        const index = findFirstChar(buffer, ' ');

        if (index) |idx| {
            const key = buffer[0..idx];
            const args = buffer[idx + 1 ..];
            for (self.handlers.items) |*obj| {
                const h = obj.handler;
                if (std.mem.eql(u8, key, h.event_str)) {
                    try h.handle(args, h.listener);
                }
            }
        } else {
            // there must be no arguments
            const key = buffer;
            const args = "";
            for (self.handlers.items) |*obj| {
                const h = obj.handler;
                if (std.mem.eql(u8, key, h.event_str)) {
                    try h.handle(args, h.listener);
                }
            }
        }
    }

    pub fn addHandler(self: *Cmd, handler: Handler) !HandleId {
        self.lastHandleId = self.lastHandleId +| 1;
        try self.handlers.append(self.alloc, .{ .handler = handler, .id = self.lastHandleId });
        return self.lastHandleId;
    }

    pub fn removeHandler(self: *Cmd, id: HandleId) void {
        for (self.handlers.items, 0..) |*h, i| {
            if (h.id == id) {
                _ = self.handlers.swapRemove(i);
                break;
            }
        }
    }

    pub fn addHistory(self: *Cmd, buffer: []const u8) !void {
        const alloc = self.arena.allocator();
        try self.history.append(self.alloc, try alloc.dupe(u8, buffer));
    }

    pub fn getHistory(self: *Cmd, idx: usize) ?[]const u8 {
        //std.debug.print("history idx = {d}\n", .{idx});
        if (idx >= self.history.items.len) {
            return null;
        }
        const reverse_idx = self.history.items.len - 1 -| idx;
        //std.debug.print("history idx = {d}\n", .{reverse_idx});
        return self.history.items[reverse_idx];
    }

    fn findFirstChar(s: []const u8, token: u8) ?usize {
        for (s, 0..) |c, i| {
            if (c == token) return i;
        }
        return null;
    }
};
