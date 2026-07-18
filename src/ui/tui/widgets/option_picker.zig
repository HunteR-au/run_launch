const std = @import("std");
const vaxis = @import("vaxis");

const OptionPicker = @This();

// view picker
// border
//  \-> list of items
// items can be selected/deselected
// can quit picker with esc
// enter will product a string in cmd

// TODO: up and down syntax is all mixed up :(

const vxfw = vaxis.vxfw;
const Allocator = std.mem.Allocator;

const Nonselected = vaxis.Style{ .bg = .default, .fg = .default };
const Selected = vaxis.Style{ .bg = .{ .rgb = .{ 100, 100, 100 } }, .fg = .default };

const Items = struct {
    text: vxfw.Text,
    is_selected: bool = false,
};

const Key = struct {
    cp: u21,
    mod: vaxis.Key.Modifiers,
};

pub const Action = enum {
    CursorDown,
    CursorUp,
    SelectItem,
    Exit,
    ChooseAndExit,
};

const Bindings = struct {
    const BindType = struct { action: Action, key: Key };
    const list = [_]BindType{
        .{ .action = Action.CursorDown, .key = Key{ .cp = vaxis.Key.down, .mod = .{} } },
        .{ .action = Action.CursorDown, .key = Key{ .cp = 'j', .mod = .{} } },
        .{ .action = Action.CursorUp, .key = Key{ .cp = vaxis.Key.up, .mod = .{} } },
        .{ .action = Action.CursorUp, .key = Key{ .cp = 'k', .mod = .{} } },
        .{ .action = Action.SelectItem, .key = Key{ .cp = vaxis.Key.space, .mod = .{} } },
        .{ .action = Action.Exit, .key = Key{ .cp = vaxis.Key.escape, .mod = .{} } },
        .{ .action = Action.ChooseAndExit, .key = Key{ .cp = vaxis.Key.enter, .mod = .{} } },
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

title: []const u8,
items: []Items,
selected_item: usize = 0,
can_select_items: bool = true,
widget_body: TextBodyWidget,

pub fn init(alloc: Allocator, title: []const u8, text_list: []const []const u8) Allocator.Error!*@This() {
    const self = try alloc.create(@This());

    const items = try alloc.alloc(Items, text_list.len);
    for (items, 0..) |*item, i| {
        item.text = .{ .text = text_list[i], .style = Nonselected };
    }

    self.* = .{
        .title = title,
        .items = items,
        .widget_body = .{
            .parent = self,
        },
    };
    return self;
}

pub fn deinit(self: *@This(), alloc: Allocator) void {
    alloc.free(self.items);
    alloc.destroy(self);
}

pub fn widget(self: *@This()) vxfw.Widget {
    return .{
        .userdata = self,
        .eventHandler = typeErasedEventHandler,
        .drawFn = typeErasedDrawFn,
    };
}

pub fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    const self: *@This() = @ptrCast(@alignCast(ptr));
    return self.handleEvent(ctx, event);
}

pub fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    var self: *@This() = @ptrCast(@alignCast(ptr));
    return self.draw(ctx);
}

pub fn draw(self: *@This(), ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const max_size = ctx.max.size();

    const border: vxfw.Border = .{
        .child = self.widget_body.widget(),
        .labels = &.{
            .{ .text = self.title, .alignment = .top_center },
        },
    };

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

pub fn handleEvent(self: *@This(), ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    switch (event) {
        .key_press => |key| {
            const opt_result = Bindings.matches(key);
            if (opt_result) |result| switch (result) {
                .CursorDown => {
                    //self.selected_item = self.selected_item -| 1;
                    self.widget_body.cursor_down();
                    return ctx.consumeAndRedraw();
                },
                .CursorUp => {
                    // const temp = self.selected_item + 1;
                    // if (temp < self.items.len) {
                    //     self.selected_item = temp;
                    //     return ctx.consumeAndRedraw();
                    // } else return;
                    self.widget_body.cursor_up();
                    return ctx.consumeAndRedraw();
                },
                .SelectItem => {
                    if (!self.can_select_items) return;

                    // flip the boolean
                    self.items[self.selected_item].is_selected ^= true;
                    if (self.items[self.selected_item].is_selected) {
                        self.items[self.selected_item].text.style = Selected;
                    } else {
                        self.items[self.selected_item].text.style = Nonselected;
                    }
                    return ctx.consumeAndRedraw();
                },
                .Exit => {
                    // TODO
                },
                .ChooseAndExit => {
                    // TODO
                },
            };
        },
        else => {},
    }
}

const TextBodyWidget = struct {
    parent: *OptionPicker,
    scroll: usize = 0,
    //max_lines: usize = 15,
    visible_items: ?usize = null,
    last_drawn_top: ?usize = null,
    last_drawn_bottom: ?usize = null,

    pub fn widget(self: *@This()) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = null,
            .drawFn = @This().typeErasedDrawFn,
        };
    }

    pub fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        var self: *@This() = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    pub fn draw(self: *@This(), ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const max_size = ctx.max.size();
        const size: vxfw.Size = .{
            .width = max_size.width,
            .height = @min(max_size.height, self.parent.items.len),
        };

        var surface = try vxfw.Surface.init(
            ctx.arena,
            self.widget(),
            size,
        );

        const selection_caret = vxfw.Text{ .text = ">", .style = Nonselected };

        const total = self.parent.items.len;
        if (total == 0) return surface;

        const visible_lines = size.height;
        const max_scroll = if (total > visible_lines) total - visible_lines else 0;

        if (self.scroll > max_scroll) self.scroll = max_scroll;

        const start = self.scroll;
        const end = @min(start + visible_lines, total);

        self.last_drawn_bottom = start;
        self.last_drawn_top = end;
        self.visible_items = end - start;

        const children = try ctx.arena.alloc(vxfw.SubSurface, end - start + 1);

        var is_rendering_carrot = false;
        for (self.parent.items[start..end], 0..) |*item, i| {
            if (self.parent.selected_item == start + i) {
                is_rendering_carrot = true;
                // draw the caret for the selected item

                children[children.len - 1] = vxfw.SubSurface{
                    .origin = .{
                        .row = @as(i17, @intCast(i)),
                        .col = 0,
                    },
                    .surface = try selection_caret.draw(ctx),
                };
            }
            children[i] = vxfw.SubSurface{
                .origin = .{
                    .row = @as(i17, @intCast(i)),
                    .col = 1,
                },
                .surface = try item.text.draw(ctx),
            };
        }

        if (is_rendering_carrot) {
            surface.children = children;
        } else {
            surface.children = children[0 .. children.len - 1];
        }

        return surface;
    }

    pub fn cursor_up(self: *TextBodyWidget) void {
        if (self.parent.selected_item > 0) {
            self.parent.selected_item -= 1;

            if (self.last_drawn_bottom) |rendered_bottom| {
                if (rendered_bottom > self.parent.selected_item) self.scroll_event(.down);
            }
        }
    }

    pub fn cursor_down(self: *TextBodyWidget) void {
        if (self.parent.items.len == 0) return;

        if (self.parent.selected_item + 1 < self.parent.items.len) {
            self.parent.selected_item += 1;

            if (self.last_drawn_top) |rendered_top| {
                if (rendered_top <= self.parent.selected_item) self.scroll_event(.up);
            }
        }
    }

    const ScrollDirection = enum { up, down };
    pub fn scroll_event(self: *TextBodyWidget, direction: ScrollDirection) void {
        switch (direction) {
            .down => {
                if (self.scroll > 0) self.scroll -= 1;
            },
            .up => {
                if (self.parent.items.len == 0) return;

                //const visible = self.max_lines;
                const visible = if (self.visible_items) |num_vis| num_vis else self.parent.items.len;
                const max_scroll =
                    if (self.parent.items.len > visible) self.parent.items.len - visible else 0;

                if (self.scroll < max_scroll)
                    self.scroll += 1;
            },
        }
    }
};
