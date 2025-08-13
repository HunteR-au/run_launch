const std = @import("std");
pub const vaxis = @import("vaxis");
pub const Cmd = @import("cmd.zig");

pub const vxfw = vaxis.vxfw;

pub const CmdWidget = struct {
    alloc: std.mem.Allocator,
    textBox: vxfw.TextField,
    cmd: Cmd.Cmd,
    last_history_idx: ?usize = null,

    pub fn init(alloc: std.mem.Allocator, unicode: *const vaxis.Unicode) std.mem.Allocator.Error!CmdWidget {
        return .{
            .alloc = alloc,
            .textBox = vxfw.TextField.init(alloc, unicode),
            .cmd = Cmd.Cmd.init(alloc),
        };
    }

    pub fn deinit(self: *CmdWidget) void {
        self.textBox.deinit();
        self.cmd.deinit();
    }

    pub fn runCmd(self: *CmdWidget) !void {
        const real_length = self.textBox.buf.realLength();
        try self.cmd.handleCmd(self.textBox.buf.buffer[0..real_length]);
        try self.cmd.addHistory(self.textBox.buf.buffer[0..real_length]);
        self.textBox.clearAndFree();
    }

    pub fn getShadow(self: *CmdWidget, prefix: []const u8) ?[]const u8 {
        _ = self;
        _ = prefix;
    }

    pub fn addToBuffer(self: *CmdWidget) !void {
        _ = self;
    }

    pub fn removeFromBuffer(self: *CmdWidget) !void {
        _ = self;
    }

    pub fn widget(self: *CmdWidget) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = typeErasedEventHandler,
            .drawFn = typeErasedDrawFn,
        };
    }

    pub fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        var self: *CmdWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    pub fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *CmdWidget = @ptrCast(@alignCast(ptr));
        return try self.eventHandler(ctx, event);
    }

    pub fn eventHandler(self: *CmdWidget, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .key_press => |key| {
                if (key.matches(vaxis.Key.enter, .{})) {
                    try self.runCmd();
                    try self.textBox.handleEvent(ctx, event);
                    return ctx.consumeAndRedraw();
                } else if (key.matches(vaxis.Key.up, .{})) {
                    const history_idx: usize = if (self.last_history_idx) |h| h +| 1 else 0;
                    const history_buffer = self.cmd.getHistory(history_idx);
                    if (history_buffer) |*buf| {
                        self.last_history_idx = history_idx;
                        self.textBox.clearAndFree();
                        try self.textBox.buf.insertSliceAtCursor(buf.*);
                    }
                } else if (key.matches(vaxis.Key.down, .{})) {
                    if (self.last_history_idx == null) {
                        // We haven't started searching up the history list
                        return;
                    } else if (self.last_history_idx == 0) {
                        // reset history searching
                        self.last_history_idx = null;
                        self.textBox.clearAndFree();
                    } else {
                        const history_idx = self.last_history_idx.? -| 1;
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

    pub fn draw(self: *CmdWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const max_size = ctx.max.size();

        const border: vxfw.Border = .{ .child = self.textBox.widget() };

        const border_child: vxfw.SubSurface = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try border.draw(ctx),
        };

        const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
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
