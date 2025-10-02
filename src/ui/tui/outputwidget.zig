const std = @import("std");
const utils = @import("utils");
//const MultiStyleText = @import("multistyletext.zig").MultiStyleText;

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Border = vxfw.Border;
//const grapheme = vaxis.grapheme;
const ScrollBar = vxfw.ScrollBars;
const ScrollView = vxfw.ScrollView;
//const Text = vxfw.Text;
const graphemedata = vaxis.Graphemes;
const Unicode = vaxis.Unicode;
//const MultiStyleText = @import("multistyletext.zig").MultiStyleText;

pub const UiConfig = @import("uiconfig").UiConfig;
pub const Output = @import("output.zig");
pub const ProcessBuffer = @import("pipeline/processbuffer.zig").ProcessBuffer;
const MultiStyleText = @import("widgets/mutistyletext.zig").MultiStyleText(
    Output.StyleMap,
    Output.StyleList,
);

//const x = MultiStyleText{.style_cache = .init(map: *StyleMap, list: *StyleList), .text = "ddd"};

// need to be able to add handler for the fold cmd
//      this handler will need to create a fold filter

// Steps
// 1) - draw a border
// 2) - draw text in border
// 3) - set up scrolling
// 4) - set up text selection and copy
// 5) - output should create a bufferwriter that calls the multistyletext bufferwriter
//          - this bufferwriter should inject style into the data AND add other meta data
//          - that the output should track (ie timestamps)

pub const OutputWidget = struct {
    const RowInfo = struct { row: usize, offset: usize };

    alloc: std.mem.Allocator,
    text: MultiStyleText = undefined,
    scroll_bars: ScrollBar,
    scroll_sticky_mode: bool = false,
    force_sticky_off: bool = false,
    border: Border,
    process_name: []const u8,
    temp: vxfw.Text = undefined,
    output: Output,
    window: Window,

    rendered_text_offset_at_row_start: std.HashMapUnmanaged(
        usize,
        usize,
        std.hash_map.AutoContext(usize),
        std.hash_map.default_max_load_percentage,
    ) = .empty,
    rendered_text_offset_highest_key: ?usize = null,

    pub fn init(
        alloc: std.mem.Allocator,
        processname: []const u8,
        buffer: *ProcessBuffer,
        _: *vaxis.Unicode,
    ) !*OutputWidget {
        const pname = try alloc.dupe(u8, processname);
        errdefer alloc.free(pname);
        var output_widget = try alloc.create(OutputWidget);
        errdefer alloc.destroy(output_widget);
        output_widget.* = .{
            .alloc = alloc,
            .process_name = pname,
            .scroll_bars = undefined,
            .border = undefined,
            .output = Output.init(alloc, buffer),
            .window = .{ .num_lines = 200, .output = undefined },
        };
        output_widget.output.widget_ref = output_widget;
        output_widget.window.output = &output_widget.output;
        output_widget.scroll_bars = .{
            .scroll_view = .{
                .wheel_scroll = 1,
                .children = .{
                    .builder = .{
                        .userdata = output_widget,
                        .buildFn = OutputWidget.getScrollItems,
                    },
                },
            },
            .draw_vertical_scrollbar = false,
            .estimated_content_height = 20,
            .estimated_content_width = 30,
        };

        output_widget.border = .{ .child = output_widget.scroll_bars.widget() };

        //output_widget.text.style_base = .{ .fg = .{ .rgb = [3]u8{ 100, 50, 50 } } };
        //try output_widget.text.append(alloc, .{
        //    .bytes = "A string to be render in the output widget...\n",
        //    .unicode = unicode,
        //});
        //try output_widget.text.append(alloc, .{
        //    .bytes = "A somewhat different string to be render in the output widget...\n",
        //    .unicode = unicode,
        //});

        return output_widget;
    }

    pub fn deinit(self: *OutputWidget) void {
        //self.text.deinit(self.alloc);
        self.alloc.free(self.process_name);
        //self.alloc.destroy(self.text);
        self.output.deinit();
        self.alloc.destroy(self);
    }

    // We pass the uiconfig through the widget to output so the ui gets a chance
    // to do any setup
    pub fn setupViaUiconfig(self: *OutputWidget, config: *UiConfig) !void {
        try self.output.setupViaUiconfig(config, self.process_name);
    }

    fn getScrollItems(ptr: *const anyopaque, idx: usize, _: usize) ?vxfw.Widget {
        const self: *OutputWidget = @constCast(@ptrCast(@alignCast(ptr)));
        if (idx == 0) {
            return self.text.widget();
        } else return null;
    }

    pub fn widget(self: *OutputWidget) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = OutputWidget.typeErasedEventHandler,
            .captureHandler = OutputWidget.typeErasedCaptureHandler,
            .drawFn = OutputWidget.typeErasedDrawFn,
        };
    }

    pub fn typeErasedCaptureHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        var self: *OutputWidget = @ptrCast(@alignCast(ptr));
        return self.captureHandler(ctx, event);
    }

    pub fn captureHandler(self: *OutputWidget, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .mouse => |mouse| {
                //std.debug.print("output: mouse type {?}\n", .{mouse.type});

                if (mouse.button == .wheel_up) {
                    // turn of sticky scrolling on mouse wheel up
                    self.scroll_sticky_mode = false;
                    self.window.is_sticky = false;
                    self.scroll_bars.scroll_view.scroll.pending_lines = 0;
                    self.window.pending_lines = 0;

                    //if (self.window.linesUp(1)) ctx.consumeAndRedraw();
                    self.moveOutputUpLines(1);
                    ctx.consumeAndRedraw();
                }
                if (mouse.button == .wheel_down) {
                    //if (self.window.linesDown(1)) ctx.consumeAndRedraw();
                    self.moveOutputDownLines(1);
                    ctx.consumeAndRedraw();
                }
            },
            .key_press => |key| {
                // turn off sticky scrolling on up actions
                if (key.matches('u', .{ .ctrl = true }) or
                    key.matches(vaxis.Key.up, .{}) or
                    key.matches('k', .{ .ctrl = false }) or
                    key.matches('p', .{ .ctrl = true }))
                {
                    self.scroll_sticky_mode = false;
                    self.window.is_sticky = false;
                    self.scroll_bars.scroll_view.scroll.pending_lines = 0;
                    self.window.pending_lines = 0;

                    //if (self.window.linesUp(1)) ctx.consumeAndRedraw();
                    self.moveOutputUpLines(1);
                    ctx.consumeAndRedraw();
                }
                if (key.matches('k', .{ .ctrl = true })) {
                    self.scroll_sticky_mode = false;
                    self.window.is_sticky = false;
                    self.scroll_bars.scroll_view.scroll.pending_lines = 0;
                    self.window.pending_lines = 0;

                    self.moveOutputUpLines(5);
                    ctx.consumeAndRedraw();
                    //if (self.window.linesUp(5)) {
                    //    ctx.consumeAndRedraw();
                    //    return;
                    //}
                    //_ = self.scroll_bars.scroll_view.scroll.linesUp(5);
                }
                if (key.matches(vaxis.Key.escape, .{})) {
                    // TODO: this is busted, probably the check for if_sticky
                    self.scroll_sticky_mode = false;
                    self.window.is_sticky = false;
                    self.scroll_bars.scroll_view.scroll.pending_lines = 0;
                    self.window.pending_lines = 0;

                    if (self.window.linesUp(std.math.maxInt(u8))) ctx.consumeAndRedraw();
                }
                if (key.matches(vaxis.Key.down, .{}) or
                    key.matches('j', .{ .ctrl = false }) or
                    key.matches('n', .{ .ctrl = true }) or
                    key.matches('d', .{ .ctrl = true }))
                {
                    self.moveOutputDownLines(1);
                    ctx.consumeAndRedraw();
                    //if (self.window.linesDown(1)) ctx.consumeAndRedraw();
                }
                if (key.matches('j', .{ .ctrl = true })) {
                    self.moveOutputDownLines(5);
                    ctx.consumeAndRedraw();
                    //if (self.window.linesDown(5)) {
                    //    ctx.consumeAndRedraw();
                    //    return;
                    //}
                    //_ = self.scroll_bars.scroll_view.scroll.linesDown(5);
                }
            },
            else => {},
        }
    }

    pub fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        var self: *OutputWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    pub fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *OutputWidget = @ptrCast(@alignCast(ptr));
        return try self.handleEvent(ctx, event);
    }

    pub fn handleEvent(self: *OutputWidget, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .tick => {
                ctx.redraw = true;
            },
            .mouse_enter => {
                //std.debug.print("mouse enter output\n", .{});
                try self.scroll_bars.handleEvent(ctx, event);
                try self.scroll_bars.scroll_view.handleEvent(ctx, event);
            },
            .mouse_leave => {
                //std.debug.print("mouse leave output\n", .{});
                try self.scroll_bars.handleEvent(ctx, event);
                try self.scroll_bars.scroll_view.handleEvent(ctx, event);
            },
            .mouse => |mouse| {
                _ = mouse;
                //std.debug.print("output: mouse type {?}\n", .{mouse.type});
                try self.scroll_bars.handleEvent(ctx, event);
                try self.scroll_bars.scroll_view.handleEvent(ctx, event);
            },
            .key_press => {
                try self.scroll_bars.handleEvent(ctx, event);
                try self.scroll_bars.scroll_view.handleEvent(ctx, event);
            },
            else => {},
        }
    }

    fn calculate_sticky_scroll(self: *OutputWidget) void {
        if (self.scroll_sticky_mode == false and // not sticky_mode
            self.scroll_bars.scroll_view.scroll.has_more_vertical == false and // is previously scrolled to bottom
            self.scroll_bars.scroll_view.scroll.pending_lines >= 0) // and no pending lines to scroll up
        {
            if (self.force_sticky_off) {
                return;
            }
            self.scroll_sticky_mode = true;
            self.window.is_sticky = true;
            self.moveOutputUpLines(1);
        } else if (self.scroll_sticky_mode == true) {
            self.moveOutputDownLines(1);
        } else {
            if (self.force_sticky_off) {
                self.force_sticky_off = false;
            }
        }
    }

    pub fn jump_output_to_line(self: *OutputWidget, line_num: usize) !void {
        // get the first rendered line
        const first_rendered_line_offset = try self.get_rendered_line_buffer_offset(.first);
        const first_rendered_line = self.window.getLineFromOffset(first_rendered_line_offset);

        // Problem: what about a line that wraps, and therefore the match is not rendered!!!!
        // Fix: maybe I need to track the last byte that was rendered

        // get last line rendered
        const last_rendered_line_offset = try self.get_rendered_line_buffer_offset(.last);
        const last_rendered_line = self.window.getLineFromOffset(last_rendered_line_offset);

        // check if line is already within rendered bounds
        if (first_rendered_line <= line_num and line_num <= last_rendered_line) {
            return;
        }

        // line is below
        if (line_num > last_rendered_line) {
            self.removePendingLines();
            self.setStickyScroll(false);
            self.moveOutputDownLines(line_num - last_rendered_line);
            return;
        }

        // line is above
        if (line_num < first_rendered_line) {
            self.removePendingLines();
            self.setStickyScroll(false);
            self.moveOutputUpLines(first_rendered_line - line_num);
            return;
        }
    }

    pub fn moveOutputUpLines(self: *OutputWidget, n: usize) void {
        // TODO: allow a larger number than u8
        if (self.window.linesUp(@intCast(n))) return else _ = self.scroll_bars.scroll_view.scroll.linesUp(@intCast(n));
    }

    pub fn moveOutputDownLines(self: *OutputWidget, n: usize) void {
        // TODO: allow a larger number than u8
        if (self.window.linesDown(@intCast(n))) return else _ = self.scroll_bars.scroll_view.scroll.linesDown(@intCast(n));
    }

    pub fn setStickyScroll(self: *OutputWidget, is_sticky: bool) void {
        if (is_sticky) {
            self.scroll_sticky_mode = false;
            self.window.is_sticky = false;
            self.force_sticky_off = true;
            //self.scroll_bars.scroll_view.scroll.pending_lines = 0;
            //self.window.pending_lines = 0;
        } else {
            self.scroll_sticky_mode = true;
            self.window.is_sticky = true;
        }
    }

    fn removePendingLines(self: *OutputWidget) void {
        self.scroll_bars.scroll_view.scroll.pending_lines = 0;
        self.window.pending_lines = 0;
    }

    // We want to save buffer offsets for the start of every row for each call
    // so we can make queries of what position the buffer is on screen
    fn save_rendered_buffer_offset(ptr: *anyopaque, row: usize, offset: usize) std.mem.Allocator.Error!void {
        const self: *OutputWidget = @ptrCast(@alignCast(ptr));

        if (self.rendered_text_offset_highest_key == null) {
            self.rendered_text_offset_highest_key = row;
        } else if (self.rendered_text_offset_highest_key.? < row) {
            self.rendered_text_offset_highest_key.? = row;
        }
        try self.rendered_text_offset_at_row_start.put(self.alloc, row, offset + self.window.startingOffset());
    }

    const LineType = enum { first, last };
    pub fn get_rendered_line_buffer_offset(self: *OutputWidget, line: LineType) !usize {
        if (self.rendered_text_offset_at_row_start.size == 0) {
            return error.NoLinesRendered;
        }

        switch (line) {
            .first => {
                return self.rendered_text_offset_at_row_start.get(0).?;
            },
            .last => {
                return self.rendered_text_offset_at_row_start.get(self.rendered_text_offset_highest_key.?).?;
            },
        }
    }

    pub fn draw(self: *OutputWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const max_size = ctx.max.size();

        // clear the rendered buffer offsets at starting row positions
        self.rendered_text_offset_at_row_start.clearAndFree(self.alloc);
        self.rendered_text_offset_highest_key = null;

        self.window.updateWindow();

        // copy the style list
        var list_cpy = try std.ArrayList(vaxis.Style).initCapacity(ctx.arena, self.output.style_list.items.len);
        //var list_cpy = try ctx.arena.alloc(vaxis.Style, self.output.style_list.items.len);
        try list_cpy.appendSlice(self.output.style_list.items);

        // copy the style map
        var map_cpy = try utils.cloneHashMap(
            usize,
            usize,
            std.hash_map.AutoContext(usize),
            std.hash_map.default_max_load_percentage,
            ctx.arena,
            &self.output.style_map,
        );

        self.text = .{
            .text = self.window.getSlice(ctx.arena) catch @panic("Window requested buffer out of range!"),
            .style_cache = .init(
                &map_cpy,
                &list_cpy,
                self.window.startingOffset(),
            ),
            .cb_ptr = self,
            .cb_buffer_offset_at_row = save_rendered_buffer_offset,
        };

        if (self.output.is_focused) {
            // color border yellow
            self.border.style = vaxis.Style{ .fg = .{ .rgb = .{ 255, 255, 0 } } };
        } else {
            self.border.style = vaxis.Style{ .fg = .{ .rgb = .{ 255, 255, 255 } } };
        }

        self.calculate_sticky_scroll();

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

const Window = struct {
    top_line: usize = 0,
    num_lines: usize,
    has_more_vertical: bool = true,
    last_update_parent_len: usize = 0,
    last_update_parent_num_lines: usize = 0,
    //last_update_last_line_empty: bool = false, // is last char in buffer a newline
    is_sticky: bool = true,
    pending_lines: i17 = 0,
    output: *Output,

    const Index = union(enum) {
        idx: usize,
        first: void,
        outOfBounds: void,
    };

    pub const Range = struct {
        ofset: usize,
        len: usize,
    };

    fn calNewlineIndex(self: *Window, line_num: usize) Index {
        if (line_num == 0) return .first;
        if (line_num >= self.last_update_parent_num_lines) return .outOfBounds;
        return .{ .idx = line_num - 1 };
    }

    // newlines count as part of the preceding line
    pub fn getLineFromOffset(self: *Window, offset: usize) usize {
        // TODO: this needs an atomic access to filtered_newlines
        const filtered_newlines_slice = self.output.nonowned_process_buffer.filtered_newlines.items;

        const last_rendered_line = std.sort.lowerBound(
            usize,
            filtered_newlines_slice,
            offset,
            struct {
                pub fn compare(lhs: usize, rhs: usize) std.math.Order {
                    return std.math.order(lhs, rhs);
                }
            }.compare,
        );
        return last_rendered_line;
    }

    // set the offset of the first character
    pub fn getOffsetFromLine(self: *Window, line_num: usize) !usize {
        const idx = self.calNewlineIndex(line_num);
        switch (idx) {
            .idx => |i| {
                const offset = self.output.nonowned_process_buffer
                    .filtered_newlines.items[i] + 1;
                std.debug.assert(offset < self.last_update_parent_len);
                return offset;
            },
            .first => return 0,
            .outOfBounds => error.OutOfBounds,
        }
    }

    pub fn startingOffset(self: *Window) usize {
        const idx = self.calNewlineIndex(self.top_line);
        switch (idx) {
            .idx => |i| {
                const offset = self.output.nonowned_process_buffer
                    .filtered_newlines.items[i] + 1;
                std.debug.assert(offset < self.last_update_parent_len);
                return offset;
            },
            .first => return 0,
            .outOfBounds => @panic("Windows starting offset is beyond buffer length"),
        }
    }

    pub fn windowByteLen(self: *Window) usize {
        const last_line = self.lastLine();
        const idx = self.calNewlineIndex(last_line);
        const ofs = self.startingOffset();
        switch (idx) {
            .idx => |i| {
                if (self.last_update_parent_num_lines < 2) { // if there is only 1 newline
                    return self.last_update_parent_len - ofs;
                }
                if (i > self.last_update_parent_num_lines - 2) { // if i is last newline
                    return self.last_update_parent_len - ofs;
                } else {
                    const buffer_ofs = self.output.nonowned_process_buffer.filtered_newlines.items[i + 1];
                    return buffer_ofs - ofs;
                }
            },
            .first => return 0,
            .outOfBounds => {
                return self.last_update_parent_len - ofs;
            },
        }
    }

    pub fn getParentTotalLines(self: *Window) usize {
        return self.last_update_parent_num_lines;
    }

    pub fn lastLine(self: *Window) usize {
        std.debug.assert(self.num_lines != 0);
        return self.top_line + self.num_lines - 1;
    }

    pub fn linesUp(self: *Window, n: u8) bool {
        if (self.top_line == 0) return false;
        self.pending_lines -|= @intCast(n);
        return true;
    }

    pub fn linesDown(self: *Window, n: u8) bool {
        if (!self.has_more_vertical) return false;
        self.pending_lines += n;
        return true;
    }

    pub fn updateWindow(self: *Window) void {
        // before update, check if window previously was on the buffers last line
        const prev_last_line = self.lastLine();
        var prev_at_bottom = false;
        if (self.last_update_parent_num_lines == 0) {
            prev_at_bottom = true;
        } else if (prev_last_line >= self.last_update_parent_num_lines - 1) {
            prev_at_bottom = true;
        }

        // update parent buffer length
        self.last_update_parent_len = self.output
            .nonowned_process_buffer
            .getFilteredBufferLength();

        // update parent number of lines
        self.last_update_parent_num_lines = self.output
            .nonowned_process_buffer
            .getNumFilteredNewlines();

        if (prev_last_line < self.last_update_parent_num_lines) {
            self.has_more_vertical = true;
        } else {
            self.has_more_vertical = false;
        }

        // if previously the window was at the end of the buffer, keep it there
        if (self.is_sticky and prev_at_bottom) {
            self.top_line = self.last_update_parent_num_lines -| self.num_lines;
            self.has_more_vertical = false;
        }

        //std.debug.print("Updated Window...\n", .{});
        //std.debug.print("parent_len {d}\n", .{self.last_update_parent_len});
        //std.debug.print("parent_lines {d}\n", .{self.last_update_parent_num_lines});
        //std.debug.print("top {d}\n", .{self.top_line});
        //std.debug.print("end {d}\n", .{self.lastLine()});
    }

    pub fn setFocus(self: *OutputWidget, is_focus: bool) void {
        self.output.is_focused = is_focus;
    }

    pub fn getFocus(self: *OutputWidget) void {
        return self.output.is_focused;
    }

    pub fn resolvePendingLines(self: *Window) void {
        //std.debug.print("pending lines {d}\n", .{self.pending_lines});
        if (self.pending_lines >= 0) {
            self.top_line = self.top_line + @as(usize, @intCast(self.pending_lines));
        } else {
            self.top_line = self.top_line - @as(usize, @intCast(-self.pending_lines));
        }
        self.pending_lines = 0;

        // make sure the window doesn't reach passed the bottom of the buffer
        const last_line = self.lastLine();
        if (self.last_update_parent_num_lines <= last_line) {
            self.has_more_vertical = false;

            // check if the buffer is NOT smaller than the window
            if (self.last_update_parent_num_lines > self.num_lines) {
                self.top_line = self.last_update_parent_num_lines - self.num_lines;
            } else {
                self.top_line = 0;
            }
        }

        //std.debug.print("Resolved pending lines...\n", .{});
        //std.debug.print("top {d}\n", .{self.top_line});
        //std.debug.print("end {d}\n", .{self.lastLine()});
    }

    pub fn getSlice(self: *Window, alloc: std.mem.Allocator) ![]const u8 {
        // resolve pending lines
        self.resolvePendingLines();

        if (self.output.nonowned_process_buffer.filtered_buffer.items.len == 0) return "";

        const ofs = self.startingOffset();
        return try self
            .output
            .nonowned_process_buffer
            .copyRange(alloc, ofs, self.windowByteLen());
    }
};

test "Add a buffer to an OutputWidget" {
    // const alloc = std.testing.allocator;
    // const output_widget: OutputWidget = .{};
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
