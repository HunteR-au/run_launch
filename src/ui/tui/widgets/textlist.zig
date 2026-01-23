const std = @import("std");
pub const vaxis = @import("vaxis");

pub const vxfw = vaxis.vxfw;

pub const TextListWidget = struct {
    items: []vxfw.Text,
    scroll: usize = 0,
    max_lines: usize = 15,
    last_drawn_top: ?usize = null,
    last_drawn_bottom: ?usize = null,

    pub fn init(items: []vxfw.Text) TextListWidget {
        return .{
            .items = items,
        };
    }

    pub fn widget(self: *TextListWidget) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = typeErasedEventHandler,
            .drawFn = typeErasedDrawFn,
        };
    }

    pub fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) !vxfw.Surface {
        var self: *TextListWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    pub fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        var self: *TextListWidget = @ptrCast(@alignCast(ptr));
        return try self.handleEvent(ctx, event);
    }

    pub fn draw(self: *TextListWidget, ctx: vxfw.DrawContext) !vxfw.Surface {
        const max_size = ctx.max.size();
        const size: vxfw.Size = .{
            .width = max_size.width,
            .height = @min(max_size.height, @min(self.items.len, self.max_lines)),
        };

        var surface = try vxfw.Surface.init(
            ctx.arena,
            self.widget(),
            size,
        );

        const total = self.items.len;
        if (total == 0) return surface;

        const visible_lines = size.height;
        const max_scroll =
            if (total > visible_lines) total - visible_lines else 0;

        if (self.scroll > max_scroll) self.scroll = max_scroll;

        const start = self.scroll;
        const end = @min(start + visible_lines, total);

        self.last_drawn_bottom = start;
        self.last_drawn_top = end;

        const children = try ctx.arena.alloc(vxfw.SubSurface, end - start);

        for (self.items[start..end], 0..) |*text, i| {
            children[i] = vxfw.SubSurface{
                .origin = .{
                    .row = @as(i17, @intCast(i)),
                    .col = 0,
                },
                .surface = try text.draw(ctx),
            };
        }
        surface.children = children;

        return surface;
    }

    pub fn handleEvent(self: *TextListWidget, ctx: *vxfw.EventContext, event: vxfw.Event) !void {
        switch (event) {
            .key_press => |key| {
                if (key.matches(vaxis.Key.up, .{})) {
                    self.scrollUp();
                    ctx.consumeAndRedraw();
                } else if (key.matches(vaxis.Key.down, .{})) {
                    self.scrollDown();
                    ctx.consumeAndRedraw();
                }
            },
            else => {},
        }
    }

    pub fn scrollDown(self: *TextListWidget) void {
        if (self.scroll > 0)
            self.scroll -= 1;
    }

    pub fn scrollUp(self: *TextListWidget) void {
        if (self.items.len == 0) return;

        const visible = self.max_lines;
        const max_scroll =
            if (self.items.len > visible) self.items.len - visible else 0;

        if (self.scroll < max_scroll)
            self.scroll += 1;
    }
};
