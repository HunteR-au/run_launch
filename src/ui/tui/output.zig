const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const grapheme = vaxis.grapheme;
const DisplayWidth = @import("DisplayWidth");
const ScrollBar = vxfw.ScrollBars;
const ScrollView = vxfw.ScrollView;
const Text = vxfw.Text;

const Output = struct {
    alloc: std.mem.Allocator,
    buffer: Output.Buffer = .{},
    scroll_view: ScrollView = .{},
    scroll_bar: ScrollBar = .{},

    pub fn init(alloc: std.mem.Allocator) !Output {
        // TODO: buffer needs a widget which will be a Text
        //

        const output: Output = .{
            .alloc = alloc,
            .scroll_view = .{
                .wheel_scroll = 1,
                .children = .{},
            },
            .scroll_bar = .{},
        };
        output.scroll_view.children = .{ .slice = &.{output.buffer} };
        output.scroll_bar.scroll_view = output.scroll_view;
        return output;
    }

    pub fn deinit(self: *Output) void {
        self.buffer.deinit(self.alloc);
    }

    pub fn widget(self: *Output) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = Output.typeErasedEventHandler,
            .drawFn = Output.typeErasedDrawFn,
        };
    }

    pub fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Output = @ptrCast(@alignCast(ptr));
        return try self.draw(ctx);
    }

    pub fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Output = @ptrCast(@alignCast(ptr));
        return try self.handleEvent(ctx, event);
    }

    pub fn handleEvent(self: *Output, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        _ = self;
        _ = ctx;
        _ = event;
    }

    pub fn draw(self: *Output, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        _ = self;
        _ = ctx;
    }
};

test "Add a buffer to an Output" {
    const alloc = std.testing.allocator;
    const output_widget: Output = .{};
    defer output_widget.deinit();

    const gd = grapheme.GraphemeData.init(alloc);
    defer gd.deinit();
    const wd = DisplayWidth.DisplayWidthData.init(alloc);
    defer wd.deinit();

    output_widget.buffer.append(alloc, .{
        .bytes = "123456",
        .gd = gd,
        .wd = wd,
    });
}
