const std = @import("std");

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const LineNumbersWidget = @import("linenumbers.zig").LineNumbersWidget;
const RowInfo = @import("linenumbers.zig").RowInfo;

pub const LinesAndTextWidget = struct {
    const LineToRow = struct {
        callback: *const fn (ptr: *anyopaque, row: usize) ?RowInfo,
        ptr: *anyopaque,
    };

    lines: ?*LineNumbersWidget,
    text: vxfw.Widget,
    gutter_width: usize,
    window_ofs: usize,
    line_to_row: LineToRow,

    pub fn widget(self: *LinesAndTextWidget) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = null,
            .captureHandler = null,
            .drawFn = LinesAndTextWidget.typeErasedDrawFn,
        };
    }

    pub fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        var self: *LinesAndTextWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    pub fn draw(self: *LinesAndTextWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        if (self.lines == null) return self.text.draw(ctx);

        const max_size = ctx.max.size();

        const height = ctx.max.height.?;
        // calculate the ctx for the text widget
        const text_ctx = ctx.withConstraints(
            ctx.min,
            .{
                .width = @as(?u16, @intCast(max_size.width -| self.gutter_width)),
                .height = max_size.height,
            },
        );

        // draw the text widget, this will popluate the style and rendered text position caches
        const text_child: vxfw.SubSurface = .{
            .origin = .{ .row = 0, .col = @as(i17, @intCast(self.gutter_width)) },
            .surface = try self.text.draw(text_ctx),
        };

        // Internally we track line numbers staring from 0 but we want to render them starting from 1
        const line_num_offset = 1;

        // populate the lines values for the lines widget
        self.lines.?.reset();
        for (0..height) |row| {
            if (self.line_to_row.callback(self.line_to_row.ptr, row)) |info| {
                try self.lines.?.addLine(row, info.line + line_num_offset, info.is_start);
            }
        }

        // draw the lines widget
        const lines_child: vxfw.SubSurface = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try self.lines.?.draw(ctx),
        };

        // return a surface with both widget's subsurfaces
        const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
        children[0] = lines_child;
        children[1] = text_child;

        return .{
            .size = max_size,
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }
};
