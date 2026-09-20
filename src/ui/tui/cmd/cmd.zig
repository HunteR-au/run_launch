const std = @import("std");
const Io = std.Io;
const utils = @import("utils");
const Output = @import("../outputwidget.zig").Output;
const CmdWidget = @import("../cmd//cmdwidget.zig").CmdWidget;
const CmdHinter = @import("cmdhints.zig").CommandHinter;
const CmdAutomation = @import("cmd_automation.zig");

const vxfw = @import("vaxis").vxfw;

const StaticRingBuffer = utils.ringbuffers.StaticRingBuffer;

pub const Handler = struct {
    listener: *anyopaque,
    handle: HandleFn,
    event_str: []const u8,
    arg_description: ?[]const u8 = null,
};

const HandlerRef = struct {
    handler: Handler,
    id: HandleId,
};

pub const HandleEventFn = fn (ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void;
pub const HandleRawFn = fn (io: Io, args: []const u8, listener: *anyopaque) std.mem.Allocator.Error!void;
pub const HandleId = usize;

pub const HandleFn = union(enum) {
    regular_fn: *const HandleRawFn,
    event_fn: *const HandleEventFn,
};

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
        self.view.deinit();
        self.hinter.deinit();
        self.handlers.deinit(self.alloc);
        var iter = self.history.iterator();
        while (iter.next()) |i| self.alloc.free(i);
        self.alloc.destroy(self);
    }

    pub fn run_script(self: *const Cmd, io: Io, script: []const u8, ctx: *vxfw.EventContext, event: vxfw.Event) !void {
        const autos = try CmdAutomation.parse_script(self.alloc, script);
        defer {
            for (autos) |a| a.deinit(self.alloc);
        }

        for (autos) |step| {
            switch (step.select) {
                .str => |select_cmd| {
                    // select the output
                    try self.handleCmd(io, select_cmd, ctx, event);

                    // run the cmd
                    try self.handleCmd(io, step.cmd, ctx, event);
                },
                .skip => {
                    // no select action, run cmd
                    try self.handleCmd(io, step.cmd, ctx, event);
                },
                .all => {
                    // run the cmd on ALL outputs
                    // TODO: maybe need a flag to signal I want to force is not in view

                    // run the cmd
                    try self.handleCmd(io, step.cmd, ctx, event);
                },
            }
        }
    }

    pub fn handleCmd(self: *const Cmd, io: Io, buffer: []const u8, ctx: *vxfw.EventContext, event: vxfw.Event) !void {
        const index = findFirstChar(buffer, ' ');

        // parse the key/args
        var key: []const u8 = undefined;
        var args: []const u8 = undefined;
        if (index) |idx| {
            key = buffer[0..idx];
            args = buffer[idx + 1 ..];
        } else {
            key = buffer;
            args = "";
        }

        // find all matching handlers
        var matches: std.ArrayList(HandlerRef) = try .initCapacity(self.alloc, 10);
        defer matches.deinit(self.alloc);
        for (self.handlers.items) |obj| {
            if (std.mem.eql(u8, key, obj.handler.event_str)) {
                try matches.append(self.alloc, obj);
            }
        }

        // run matched handlers
        for (matches.items) |*match| {
            const h = match.handler;
            switch (h.handle) {
                .regular_fn => |func| try func(io, args, h.listener),
                .event_fn => |func| try func(h.listener, ctx, event),
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
        // the ring overwrites the oldest entry when full; free it first
        if (self.history.isFull()) self.alloc.free(try self.history.pop());
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
    }

    fn findFirstChar(s: []const u8, token: u8) ?usize {
        for (s, 0..) |c, i| {
            if (c == token) return i;
        }
        return null;
    }
};
