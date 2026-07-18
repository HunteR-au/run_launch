const std = @import("std");
const vaxis = @import("vaxis");
const TextListWidget = @import("../widgets/textlist.zig").TextListWidget;
const cmdevents = @import("../cmd/cmdevents.zig");
const Cmd = @import("cmd.zig").Cmd;

const vxfw = vaxis.vxfw;

const Key = struct {
    cp: u21,
    mod: vaxis.Key.Modifiers,
};

pub const Action = enum {
    SelectUp,
    SelectDown,
    SelectHistoryItem,
};

const Bindings = struct {
    const BindType = struct { action: Action, key: Key };
    const list = [_]BindType{
        .{ .action = Action.SelectUp, .key = Key{ .cp = vaxis.Key.up, .mod = .{ .ctrl = true } } },
        .{ .action = Action.SelectUp, .key = Key{ .cp = 'j', .mod = .{ .ctrl = true } } },
        .{ .action = Action.SelectDown, .key = Key{ .cp = vaxis.Key.down, .mod = .{ .ctrl = true } } },
        .{ .action = Action.SelectDown, .key = Key{ .cp = 'k', .mod = .{ .ctrl = true } } },
        .{ .action = Action.SelectHistoryItem, .key = Key{ .cp = vaxis.Key.enter, .mod = .{ .ctrl = true } } },
    };

    pub fn matches(key: vaxis.Key) ?Action {
        for (Bindings.list) |bind| {
            if (key.matches(bind.key.cp, bind.key.mod)) {
                return bind.action;
            }
        }

        return null;
    }
};

const nonselected = vaxis.Style{ .bg = .default, .fg = .default };
const selected = vaxis.Style{ .bg = .{ .rgb = .{ 100, 100, 100 } }, .fg = .default };

pub const HistoryWidget = struct {
    line_selected: ?u16 = null,
    history: TextListWidget,
    cmd: *Cmd,

    const max_height = 15;

    pub fn init(alloc: std.mem.Allocator, cmd: *Cmd, history_strs: [][]u8, selected_line: ?u16) std.mem.Allocator.Error!HistoryWidget {
        var texts: std.ArrayList(vxfw.Text) = try .initCapacity(alloc, history_strs.len);
        for (history_strs, 0..) |str, i| {
            var style: vaxis.Style = undefined;
            if (selected_line) |line| {
                style = if (i == line) selected else nonselected;
            } else style = nonselected;

            try texts.append(alloc, vxfw.Text{
                .text = try alloc.dupe(u8, str),
                .overflow = .ellipsis,
                .text_align = .left,
                .softwrap = false,
                .style = style,
            });
        }

        return .{
            .line_selected = selected_line,
            .history = .init(try texts.toOwnedSlice(alloc)),
            .cmd = cmd,
        };
    }

    pub fn deinit(self: *HistoryWidget, alloc: std.mem.Allocator) void {
        alloc.free(self.history.items);
    }

    pub fn widget(self: *HistoryWidget) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = typeErasedEventHandler,
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *HistoryWidget = @ptrCast(@alignCast(ptr));
        return self.handleEvent(ctx, event);
    }

    pub fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        var self: *HistoryWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    pub fn draw(self: *HistoryWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const max_size = ctx.max.size();

        const border: vxfw.Border = .{ .child = self.history.widget() };

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

    pub fn selectDown(self: *HistoryWidget) void {
        if (self.line_selected == null) {
            self.initalizeSelect(0) catch {};
            return;
        }

        if (self.line_selected.? > 0) {
            self.history.items[self.line_selected.?].style = nonselected;
            self.line_selected.? -= 1;
            self.history.items[self.line_selected.?].style = selected;

            if (self.history.last_drawn_bottom) |rendered_bottom| {
                if (rendered_bottom > self.line_selected.?) self.history.scrollDown();
            }
        }
    }

    pub fn selectUp(self: *HistoryWidget) void {
        if (self.history.items.len == 0) return;

        if (self.line_selected == null) {
            self.initalizeSelect(0) catch {};
            return;
        }

        if (self.line_selected.? < self.history.items.len - 1) {
            self.history.items[self.line_selected.?].style = nonselected;
            self.line_selected.? += 1;
            self.history.items[self.line_selected.?].style = selected;

            if (self.history.last_drawn_top) |rendered_top| {
                if (rendered_top <= self.line_selected.?) self.history.scrollUp();
            }
        }
    }

    fn initalizeSelect(self: *HistoryWidget, pos: u16) !void {
        if (pos >= self.history.items.len) return error.OutOfBounds;
        if (self.line_selected) |line| self.history.items[line].style = nonselected;

        const line_from_bottom: usize = (self.history.items.len - 1) - pos;

        self.line_selected = @intCast(line_from_bottom);
        self.history.items[line_from_bottom].style = selected;
    }

    pub fn getHeight(self: *HistoryWidget) usize {
        const boarder_height = 2;
        const text_height: usize = @min(max_height, self.history.items.len);
        return text_height + boarder_height;
    }

    pub fn handleEvent(self: *HistoryWidget, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .key_press => |key| {
                const opt_result = Bindings.matches(key);
                if (opt_result) |result| switch (result) {
                    .SelectUp => {
                        self.selectUp();
                        ctx.consumeAndRedraw();
                    },
                    .SelectDown => {
                        self.selectDown();
                        ctx.consumeAndRedraw();
                    },
                    .SelectHistoryItem => {
                        if (self.line_selected) |line| {
                            if (line >= self.history.items.len)
                                std.debug.panic("HistoryWidget: OOB on selected history line: historylen = {d} selected_line = {d}", .{ self.history.items.len, line });

                            try self.cmd.view.handleEvent(
                                ctx,
                                cmdevents.makeEvent(&cmdevents.CmdEvent{
                                    .select_history = .{
                                        .cmd_str = self.history.items[line].text,
                                        .history_idx = line,
                                    },
                                }),
                            );
                        }
                    },
                };
                // if (key.matches(vaxis.Key.up, .{ .ctrl = true }) or
                //     key.matches('j', .{ .ctrl = true }))
                // {
                //     self.selectUp();
                //     ctx.consumeAndRedraw();
                // } else if (key.matches(vaxis.Key.down, .{ .ctrl = true }) or
                //     key.matches('k', .{ .ctrl = true }))
                // {
                //     self.selectDown();
                //     ctx.consumeAndRedraw();
                // } else if (key.matches(vaxis.Key.enter, .{ .ctrl = true })) {
                //     if (self.line_selected) |line| {
                //         if (line >= self.history.items.len)
                //             std.debug.panic("HistoryWidget: OOB on selected history line: historylen = {d} selected_line = {d}", .{ self.history.items.len, line });

                //         try self.cmd.view.handleEvent(
                //             ctx,
                //             cmdevents.makeEvent(&cmdevents.CmdEvent{
                //                 .select_history = .{
                //                     .cmd_str = self.history.items[line].text,
                //                     .history_idx = line,
                //                 },
                //             }),
                //         );
                //     }
                // }
            },
            else => {},
        }
    }
};
