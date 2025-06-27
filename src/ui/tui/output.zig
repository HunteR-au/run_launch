const std = @import("std");
//const MultiStyleText = @import("multistyletext.zig").MultiStyleText;

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Border = vxfw.Border;
//const grapheme = vaxis.grapheme;
const ScrollBar = vxfw.ScrollBars;
const ScrollView = vxfw.ScrollView;
//const Text = vxfw.Text;
const graphemedata = vaxis.grapheme.GraphemeData;
const Unicode = vaxis.Unicode;
const MultiStyleText = @import("multistyletext.zig").MultiStyleText;

// This widget should be the interface for a box that renders text for text input stream
// It contains a multistyletext - which should be an interface to render text in a container
//      - with multiple styles for different ranges
// It should manage text selection, scolling and the interface to manage the buffer

// Steps
// 1) - draw a border
// 2) - draw text in border
// 3) - set up scrolling
// 4) - set up text selection and copy
// 5) - output should create a bufferwriter that calls the multistyletext bufferwriter
//          - this bufferwriter should inject style into the data AND add other meta data
//          - that the output should track (ie timestamps)

pub const Output = struct {
    alloc: std.mem.Allocator,
    text: *MultiStyleText,
    scroll_bars: ScrollBar,
    border: Border,
    process_name: []const u8,
    temp: vxfw.Text = undefined,

    pub fn init(alloc: std.mem.Allocator, processname: []const u8) !*Output {
        const multistyletext = try alloc.create(MultiStyleText);
        errdefer alloc.destroy(multistyletext);
        multistyletext.* = .{};
        const pname = try alloc.dupe(u8, processname);
        errdefer alloc.free(pname);
        var output = try alloc.create(Output);
        errdefer alloc.destroy(output);
        output.* = .{
            .alloc = alloc,
            .text = multistyletext,
            .process_name = pname,
            .scroll_bars = undefined,
            .border = undefined,
        };
        output.text.softwrap = false;
        output.scroll_bars = .{
            .scroll_view = .{
                .wheel_scroll = 1,
                .children = .{
                    .builder = .{
                        .userdata = output,
                        .buildFn = Output.getScrollItems,
                    },
                },
            },
            .estimated_content_height = 20,
            .estimated_content_width = 30,
        };

        output.border = .{ .child = output.scroll_bars.widget() };

        const unicode = try vaxis.Unicode.init(alloc);
        const grapheme = try graphemedata.init(alloc);
        output.text.style_base = .{ .fg = .{ .rgb = [3]u8{ 100, 50, 50 } } };
        try output.text.append(alloc, .{
            .bytes = "A string to be render in the output widget...\n",
            .gd = &grapheme,
            .unicode = &unicode,
        });
        try output.text.append(alloc, .{
            .bytes = "A somewhat different string to be render in the output widget...\n",
            .gd = &grapheme,
            .unicode = &unicode,
        });

        return output;
    }

    pub fn deinit(self: *Output) void {
        self.text.deinit(self.alloc);
        self.alloc.destroy(self.text);
        self.alloc.destroy(self);
    }

    fn getScrollItems(ptr: *const anyopaque, idx: usize, _: usize) ?vxfw.Widget {
        const self: *Output = @constCast(@ptrCast(@alignCast(ptr)));
        if (idx == 0) {
            self.temp = .{
                .text = self.text.content.items,
            };
            return self.temp.widget();
        } else return null;
        //if (idx == 0) {
        //    var multistyletext = self.text;
        //    return multistyletext.widget();
        //} else return null;
    }

    pub fn widget(self: *Output) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = Output.typeErasedEventHandler,
            .captureHandler = Output.typeErasedCaptureHandler,
            .drawFn = Output.typeErasedDrawFn,
        };
    }

    pub fn typeErasedCaptureHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        _ = ptr;
        _ = ctx;
        _ = event;
    }

    pub fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        var self: *Output = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    pub fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Output = @ptrCast(@alignCast(ptr));
        return try self.handleEvent(ctx, event);
    }

    pub fn handleEvent(self: *Output, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .tick => {
                ctx.redraw = true;
            },
            .mouse_enter => {
                std.debug.print("mouse enter output\n", .{});
                try self.scroll_bars.handleEvent(ctx, event);
                try self.scroll_bars.scroll_view.handleEvent(ctx, event);
            },
            .mouse_leave => {
                std.debug.print("mouse leave output\n", .{});
                try self.scroll_bars.handleEvent(ctx, event);
                try self.scroll_bars.scroll_view.handleEvent(ctx, event);
            },
            .mouse => |mouse| {
                std.debug.print("output: mouse type {?}\n", .{mouse.type});
                try self.scroll_bars.handleEvent(ctx, event);
                try self.scroll_bars.scroll_view.handleEvent(ctx, event);
            },
            .key_press => {
                std.debug.print("key press\n", .{});
                try self.scroll_bars.handleEvent(ctx, event);
                try self.scroll_bars.scroll_view.handleEvent(ctx, event);
            },
            else => {},
        }
    }

    pub fn draw(self: *Output, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const max_size = ctx.max.size();

        //self.border = .{ .child = self.scroll_bars.widget() };
        const border_child: vxfw.SubSurface = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try self.border.draw(ctx),
        };

        const title: vxfw.Text = .{ .text = self.process_name };
        const title_child: vxfw.SubSurface = .{
            .z_index = 1,
            .origin = .{ .row = 0, .col = 2 },
            .surface = try title.draw(ctx),
        };

        const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
        children[0] = border_child;
        children[1] = title_child;

        return .{
            .size = max_size,
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }
};

test "Add a buffer to an Output" {
    // const alloc = std.testing.allocator;
    // const output_widget: Output = .{};
    // defer output_widget.deinit();

    // const gd = grapheme.GraphemeData.init(alloc);
    // defer gd.deinit();
    // const unicode = Unicode.init(alloc);
    // defer unicode.deinit();

    // output_widget.buffer.append(alloc, .{
    //     .bytes = "123456",
    //     .gd = &gd,
    //     .unicode = &unicode,
    // });
}
