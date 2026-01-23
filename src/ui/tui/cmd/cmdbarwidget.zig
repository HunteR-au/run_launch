const std = @import("std");
const vaxis = @import("vaxis");
const Cmd = @import("cmd.zig");
const CmdWidget = @import("cmdwidget.zig").CmdWidget;
const HistoryWidget = @import("historywidget.zig").HistoryWidget;
const cmdevents = @import("cmdevents.zig");

pub const vxfw = vaxis.vxfw;

pub const CmdBarWidget = struct {
    alloc: std.mem.Allocator,
    textBox: vxfw.TextField,
    cmd: *Cmd.Cmd,
    //history_view: ?HistoryWidget = null,
    last_history_idx: ?usize = null,

    pub fn init(alloc: std.mem.Allocator, cmd: *Cmd.Cmd) std.mem.Allocator.Error!*CmdBarWidget {
        var self = try alloc.create(CmdBarWidget);
        self.* = .{
            .alloc = alloc,
            .textBox = vxfw.TextField.init(alloc),
            .cmd = cmd,
        };
        self.textBox.onChange = onChange;
        self.textBox.onSubmit = onSubmit;
        self.textBox.userdata = self;
        return self;
    }

    pub fn deinit(self: *CmdBarWidget) void {
        self.textBox.deinit();
        self.alloc.destroy(self);
        //if (self.history_view) |v| v.deinit(self.alloc);
    }

    pub fn runCmd(self: *CmdBarWidget, cmdstr: []u8) !void {
        try self.cmd.handleCmd(cmdstr);
        self.textBox.clearAndFree();
    }

    pub fn getShadow(self: *CmdBarWidget, prefix: []const u8) ?[]const u8 {
        _ = self;
        _ = prefix;
    }

    pub fn addToBuffer(self: *CmdBarWidget) !void {
        _ = self;
    }

    pub fn removeFromBuffer(self: *CmdBarWidget) !void {
        _ = self;
    }

    pub fn setCmdViaNextHistory(self: *CmdBarWidget) !void {
        const history_idx: usize = if (self.last_history_idx) |h| h -| 1 else self.cmd.history.count() - 1;
        const history_buffer = self.cmd.getHistory(history_idx);
        if (history_buffer) |*buf| {
            self.last_history_idx = history_idx;
            self.textBox.clearAndFree();
            try self.textBox.buf.insertSliceAtCursor(buf.*);
        }
    }

    pub fn setCmdViaPrevHistory(self: *CmdBarWidget) !void {
        if (self.last_history_idx == null) {
            // We haven't started searching up the history list
            return;
        } else if (self.last_history_idx == self.cmd.history.count() - 1) {
            // reset history searching
            self.last_history_idx = null;
            self.textBox.clearAndFree();
        } else {
            const history_idx = self.last_history_idx.? +| 1;
            const history_buffer = self.cmd.getHistory(history_idx);
            if (history_buffer) |*buf| {
                self.last_history_idx = history_idx;
                self.textBox.clearAndFree();
                try self.textBox.buf.insertSliceAtCursor(buf.*);
            } else {
                // Something unexpected happened decrementing the history list - reset
                self.last_history_idx = null;
                self.textBox.clearAndFree();
            }
        }
    }

    pub fn setCmdViaHistoryIndex(self: *CmdBarWidget, ctx: *vxfw.EventContext, index: u16) !void {
        const history_buffer = self.cmd.getHistory(@intCast(index));
        if (history_buffer) |*buf| {
            self.last_history_idx = index;
            self.textBox.clearAndFree();
            try self.textBox.buf.insertSliceAtCursor(buf.*);
            try self.checkChanged(ctx);
        }
    }

    fn checkChanged(self: *CmdBarWidget, ctx: *vxfw.EventContext) anyerror!void {
        ctx.consumeAndRedraw();
        const new = try self.textBox.buf.dupe();
        defer {
            self.textBox.buf.allocator.free(self.textBox.previous_val);
            self.textBox.previous_val = new;
        }
        if (std.mem.eql(u8, new, self.textBox.previous_val)) return;
        try onChange(self, ctx, new);
    }

    pub fn widget(self: *CmdBarWidget) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = typeErasedEventHandler,
            .drawFn = typeErasedDrawFn,
        };
    }

    pub fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        var self: *CmdBarWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    pub fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *CmdBarWidget = @ptrCast(@alignCast(ptr));
        return try self.eventHandler(ctx, event);
    }

    fn onChange(ptr: ?*anyopaque, ctx: *vxfw.EventContext, str: []const u8) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        try self.cmd.view.handleEvent(
            ctx,
            cmdevents.makeEvent(&cmdevents.CmdEvent{
                .cmdbar_change = .{
                    .cmd_str = str,
                },
            }),
        );
    }

    fn onSubmit(ptr: ?*anyopaque, ctx: *vxfw.EventContext, str: []const u8) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        _ = self;
        _ = ctx;
        _ = str;
    }

    pub fn eventHandler(self: *CmdBarWidget, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .key_press => |key| {
                if (key.matches(vaxis.Key.enter, .{})) {
                    const real_length = self.textBox.buf.realLength();
                    const cmdstr = try self.alloc.dupe(
                        u8,
                        self.textBox.buf.buffer[0..real_length],
                    );
                    try self.runCmd(cmdstr);
                    try self.cmd.view.handleEvent(
                        ctx,
                        cmdevents.makeEvent(&cmdevents.CmdEvent{
                            .history_update = .{
                                .cmd_str = cmdstr,
                                .success = true,
                            },
                        }),
                    );
                    self.alloc.free(cmdstr);
                    try self.checkChanged(ctx);
                    return ctx.consumeAndRedraw();
                } else if (key.matches(vaxis.Key.up, .{})) {
                    try self.setCmdViaNextHistory();
                    try self.checkChanged(ctx);
                } else if (key.matches(vaxis.Key.down, .{})) {
                    try self.setCmdViaPrevHistory();
                    try self.checkChanged(ctx);
                } else {
                    self.last_history_idx = null;
                    try self.textBox.handleEvent(ctx, event);
                }
            },
            else => {
                try self.textBox.handleEvent(ctx, event);
            },
        }
    }

    pub fn draw(self: *CmdBarWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const max_size = ctx.max.size();

        const border: vxfw.Border = .{ .child = self.textBox.widget() };

        const border_child: vxfw.SubSurface = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try border.draw(ctx),
        };

        var children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = border_child;

        return .{
            .size = max_size,
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }
};

// Features:
//  --> select a cmdwidget on pressing `/` (done)
//  --> will operate on the currently selected output
//  --> cmds are in the format cmd: args
//  --> remember history, nav history with up and down, (done)
//  --> maybe shadow prediction
//  --> maybe remember buffer for each output
//  --> on notify of buffer change, send an event

// POPUPS
// history list
// hints
//  - if no cmd match, list of commands based on entered input
//  - if cmd, arg format hint AND list of options if they exist

// SHADOW - when added
// list suggestions based on history
