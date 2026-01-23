const std = @import("std");
const utils = @import("utils");
const Output = @import("../outputwidget.zig").Output;
const CmdWidget = @import("../cmd//cmdwidget.zig").CmdWidget;
const CmdHinter = @import("cmdhints.zig").CommandHinter;

const StaticRingBuffer = utils.ringbuffers.StaticRingBuffer;

pub const Handler = struct {
    listener: *anyopaque,
    handle: *const HandleFn,
    event_str: []const u8,
    arg_description: ?[]const u8 = null,
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
    const max_history: comptime_int = 20;

    alloc: std.mem.Allocator,
    handlers: std.ArrayList(HandlerRef),
    lastHandleId: usize = 0,
    history: StaticRingBuffer([]u8, max_history),
    hinter: CmdHinter,

    view: CmdWidget,

    pub fn init(alloc: std.mem.Allocator) !*Cmd {
        const self = try alloc.create(Cmd);
        self.* = .{
            .handlers = try .initCapacity(alloc, 10),
            .history = .init(),
            .alloc = alloc,
            .view = try .init(alloc, self),
            .hinter = try .init(alloc),
        };
        return self;
    }

    pub fn deinit(self: *Cmd) void {
        self.hinter.deinit();
        self.handlers.deinit(self.alloc);
        var iter = self.history.iterator();
        while (iter.next()) |i| self.alloc.free(i);
        self.alloc.destroy(self);
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
        try self.hinter.addCommandInfo(.{
            .commandName = handler.event_str,
            .argumentDescription = handler.arg_description,
        });
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
        try self.history.push(try self.alloc.dupe(u8, buffer), true);
    }

    pub fn getHistory(self: *Cmd, idx: usize) ?[]const u8 {
        const history_count = self.history.count();
        if (idx >= history_count) {
            return null;
        }

        return self.history.get(idx) catch {
            std.debug.panic(
                "getHistory OOB error - index: {d} capacity: {d} ",
                .{ idx, history_count },
            );
        };

        //const reverse_idx = history_count - 1 -| idx;
        //return self.history.get(reverse_idx) catch {
        //    std.debug.panic(
        //        "getHistory OOB error - index: {d} capacity: {d} ",
        //        .{ reverse_idx, history_count },
        //    );
        //};
    }

    fn findFirstChar(s: []const u8, token: u8) ?usize {
        for (s, 0..) |c, i| {
            if (c == token) return i;
        }
        return null;
    }
};
