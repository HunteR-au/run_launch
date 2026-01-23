const std = @import("std");
const vaxis = @import("vaxis");
const cmdevents = @import("cmdevents.zig");

pub const Cmd = @import("cmd.zig");
pub const HistoryWidget = @import("historywidget.zig").HistoryWidget;
pub const CmdBarWidget = @import("cmdbarwidget.zig").CmdBarWidget;
pub const HintWidget = @import("hintswidget.zig").HintsWidget;

const vxfw = vaxis.vxfw;

pub const CmdWidget = struct {
    alloc: std.mem.Allocator,
    cmd: *Cmd.Cmd,
    cmdbar_view: *CmdBarWidget,
    history_view: ?HistoryWidget = null,
    hinter_view: *HintWidget,
    //last_history_idx: ?usize = null,

    pub fn init(alloc: std.mem.Allocator, cmd: *Cmd.Cmd) std.mem.Allocator.Error!CmdWidget {
        return .{
            .alloc = alloc,
            .cmd = cmd,
            .cmdbar_view = try .init(alloc, cmd),
            .hinter_view = try .init(alloc),
        };
    }

    pub fn deinit(self: *CmdWidget) void {
        self.hinter_view.deinit();
        self.cmdbar_view.deinit();
    }

    pub fn widget(self: *CmdWidget) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = typeErasedEventHandler,
            .captureHandler = null,
            .drawFn = typeErasedDrawFn,
        };
    }

    pub fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        var self: *CmdWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    pub fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        var self: *CmdWidget = @ptrCast(@alignCast(ptr));
        return self.handleEvent(ctx, event);
    }

    fn typeErasedCaptureHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        var self: *CmdWidget = @ptrCast(@alignCast(ptr));
        return self.handleCapture(ctx, event);
    }

    fn createHistoryWidget(self: *CmdWidget) !void {
        const temp_slice = blk: {
            var array: std.ArrayList([]u8) = try .initCapacity(self.alloc, self.cmd.history.count());
            var iter = self.cmd.history.iterator();
            while (iter.next()) |i| {
                try array.append(self.alloc, i);
            }
            break :blk try array.toOwnedSlice(self.alloc);
        };

        self.history_view = try HistoryWidget.init(
            self.alloc,
            self.cmd,
            temp_slice,
            null,
        );
        self.alloc.free(temp_slice);
    }

    fn refreshHistoryWidget(self: *CmdWidget) !void {
        if (self.history_view != null) {
            self.history_view.?.deinit(self.alloc);
            self.history_view = null;
        }
        try self.createHistoryWidget();
    }

    pub fn handleEvent(self: *CmdWidget, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .key_press => |key| {
                if (key.matches(vaxis.Key.f2, .{})) {
                    if (self.history_view == null) {
                        // create a temp span to make history contiguous
                        try self.createHistoryWidget();
                    } else {
                        self.history_view.?.deinit(self.alloc);
                        self.history_view = null;
                    }
                    ctx.consumeAndRedraw();
                }
                if (key.mods.ctrl == true and self.history_view != null) {
                    // send the event to the history widget
                    try self.history_view.?.handleEvent(ctx, event);
                } else {
                    try self.cmdbar_view.eventHandler(ctx, event);
                }
            },
            .app => |appevent| {
                const cmdevent = cmdevents.getCmdEvent(appevent);
                if (cmdevent) |e| switch (e.*) {
                    .history_update => |h| {
                        if (h.cmd_str.len > 0) {
                            try self.cmd.addHistory(h.cmd_str);
                            try self.refreshHistoryWidget();
                        }
                    },
                    .select_history => |s| {
                        try self.cmdbar_view.setCmdViaHistoryIndex(ctx, s.history_idx);
                    },
                    .cmdbar_change => |evt| {
                        // This should be sent to the hinting system
                        const hints = try self.cmd.hinter.generateHints(self.hinter_view.alloc, evt.cmd_str);
                        try self.hinter_view.updateHints(hints);
                    },
                };
            },
            else => {
                try self.cmdbar_view.eventHandler(ctx, event);
                if (self.history_view) |*view| {
                    try view.handleEvent(ctx, event);
                }
            },
        }
    }

    pub fn draw(self: *CmdWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const max_size = ctx.max.size();

        const cmdbar_height_origin: i17 = max_size.height - 4;

        const cmdbar_child: vxfw.SubSurface = .{
            .origin = .{ .row = cmdbar_height_origin, .col = 0 },
            .surface = try self.cmdbar_view.draw(ctx),
        };

        const hinter_child: vxfw.SubSurface = .{
            .origin = .{ .row = max_size.height - 1, .col = 0 },
            .surface = try self.hinter_view.draw(ctx),
        };

        var children: []vxfw.SubSurface = undefined;
        if (self.history_view != null) {
            const height = self.history_view.?.getHeight();
            const history_child: vxfw.SubSurface = .{
                .origin = .{ .row = cmdbar_height_origin - @as(i17, @intCast(height)), .col = 0 },
                .surface = try self.history_view.?.draw(ctx),
            };

            children = try ctx.arena.alloc(vxfw.SubSurface, 3);
            children[0] = cmdbar_child;
            children[1] = history_child;
            children[2] = hinter_child;
        } else {
            children = try ctx.arena.alloc(vxfw.SubSurface, 2);
            children[0] = cmdbar_child;
            children[1] = hinter_child;
        }

        return .{
            .size = max_size,
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }
};
