const std = @import("std");
const utils = @import("utils");
const debug_ui = @import("debug_ui");

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Border = vxfw.Border;
const ScrollBar = vxfw.ScrollBars;
const ScrollView = vxfw.ScrollView;
const graphemedata = vaxis.Graphemes;
const Unicode = vaxis.Unicode;

pub const UiConfig = @import("uiconfig").UiConfig;
pub const Output = @import("output.zig");
pub const ProcessBuffer = @import("pipeline/processbuffer.zig").ProcessBuffer;
const MultiStyleText = @import("widgets/mutistyletext.zig").MultiStyleText(
    Output.StyleMap,
    Output.StyleList,
);

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
            .output = try Output.init(alloc, buffer),
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

        return output_widget;
    }

    pub fn deinit(self: *OutputWidget) void {
        self.alloc.free(self.process_name);
        self.output.deinit();
        self.alloc.destroy(self);
    }

    // We pass the uiconfig through the widget to output so the ui gets a chance
    // to do any setup
    pub fn setupViaUiconfig(self: *OutputWidget, config: *UiConfig) !void {
        try self.output.setupViaUiconfig(config, self.process_name);
    }

    fn getScrollItems(ptr: *const anyopaque, idx: usize, _: usize) ?vxfw.Widget {
        const self: *OutputWidget = @ptrCast(@alignCast(@constCast(ptr)));
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
                if (mouse.button == .wheel_up) {
                    // turn of sticky scrolling on mouse wheel up
                    self.scroll_sticky_mode = false;
                    self.window.is_sticky = false;
                    self.scroll_bars.scroll_view.scroll.pending_lines = 0;
                    self.window.pending_lines = 0;

                    self.moveOutputUpLines(1);
                    ctx.consumeAndRedraw();
                }
                if (mouse.button == .wheel_down) {
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
                }
                if (key.matches(vaxis.Key.escape, .{})) {
                    try self.output.removeSearch();
                    ctx.consumeAndRedraw();
                }
                if (key.matches(vaxis.Key.down, .{}) or
                    key.matches('j', .{ .ctrl = false }) or
                    key.matches('d', .{ .ctrl = true }))
                {
                    self.moveOutputDownLines(1);
                    ctx.consumeAndRedraw();
                }
                if (key.matches('j', .{ .ctrl = true })) {
                    self.moveOutputDownLines(5);
                    ctx.consumeAndRedraw();
                }
                if (key.matches('n', .{})) {
                    self.output.searchNext();
                    ctx.consumeAndRedraw();
                }
                if (key.matches('n', .{ .ctrl = true })) {
                    self.output.searchPrev();
                    ctx.consumeAndRedraw();
                }
                if (key.matches(vaxis.Key.page_up, .{ .ctrl = true }) or
                    key.matches('i', .{ .ctrl = true }))
                {
                    //self.jump_to_start() catch {};
                    try self.jump_to_start();
                    ctx.consumeAndRedraw();
                }
                if (key.matches(vaxis.Key.page_down, .{ .ctrl = true }) or
                    key.matches('u', .{ .ctrl = true }))
                {
                    self.jump_to_end() catch {};
                    ctx.consumeAndRedraw();
                }
                if (key.matches(vaxis.Key.page_up, .{ .ctrl = false }) or
                    key.matches('i', .{ .ctrl = false }))
                {
                    self.scroll_sticky_mode = false;
                    self.window.is_sticky = false;
                    self.scroll_bars.scroll_view.scroll.pending_lines = 0;
                    self.window.pending_lines = 0;

                    self.pageUp() catch {};
                    ctx.consumeAndRedraw();
                }
                if (key.matches(vaxis.Key.page_down, .{ .ctrl = false }) or
                    key.matches('u', .{ .ctrl = false }))
                {
                    self.pageDown() catch {};
                    ctx.consumeAndRedraw();
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
        if (self.scroll_sticky_mode == true) {
            if (self.force_sticky_off) return;
            self.moveOutputDownLines(1);
        } else {
            if (self.force_sticky_off) {
                self.force_sticky_off = false;
            }
        }
    }

    pub fn jump_to_start(self: *OutputWidget) !void {
        try self.jump_output_to_line(0);
    }

    pub fn jump_to_end(self: *OutputWidget) !void {
        try self.jump_output_to_line(self.output.widget_ref.?.window.last_draw.process_buffer_num_lines);
    }

    pub fn pageUp(self: *OutputWidget) !void {
        const page_len: usize = self.window.last_draw.bottom_line - self.window.last_draw.top_line;
        self.moveOutputUpLines(page_len);
    }

    pub fn pageDown(self: *OutputWidget) !void {
        const page_len: usize = self.window.last_draw.bottom_line - self.window.last_draw.top_line;
        self.moveOutputDownLines(page_len);
    }

    pub fn jump_output_to_line(self: *OutputWidget, jump_to: usize) !void {
        var line_num: usize = undefined;
        if (jump_to > self.output.widget_ref.?.window.last_draw.process_buffer_num_lines) {
            line_num = self.output.widget_ref.?.window.last_draw.process_buffer_num_lines;
        } else {
            line_num = jump_to;
        }

        // get the first rendered line
        const first_rendered_line_offset = try self.get_rendered_line_buffer_offset(.first);
        //const first_rendered_line = self.window.getLineFromOffset(first_rendered_line_offset);
        const first_rendered_line = self.window.last_draw.top_line;

        // Problem: what about a line that wraps, and therefore the match is not rendered!!!!
        // Fix: maybe I need to track the last byte that was rendered

        // get last line rendered
        const last_rendered_line_offset = try self.get_rendered_line_buffer_offset(.last);
        //const last_rendered_line = self.window.getLineFromOffset(last_rendered_line_offset);
        const last_rendered_line = self.window.last_draw.bottom_line;

        // check if line is already within rendered bounds
        if (first_rendered_line <= line_num and line_num <= last_rendered_line) {
            try debug_ui.print("--\njump - no need to jump\n", .{});
            try debug_ui.print("jump - first row {d}\n", .{self.window.last_draw.top_line});
            try debug_ui.print("jump - last row {d}\n", .{self.window.last_draw.bottom_line});
            try debug_ui.print("jump - first_rendered_line_offset: {d}\n", .{first_rendered_line_offset});
            try debug_ui.print("jump - first_rendered_line {d}\n", .{first_rendered_line});
            try debug_ui.print("jump - line_num {d}\n", .{line_num});
            try debug_ui.print("jump - last_rendered_line {d}\n", .{last_rendered_line});
            return;
        }

        // last_rendered_line AND first_rendered_line are WRONG!!!
        try debug_ui.print("--\njump - starting offset {d}\n", .{self.window.startingOffset()});
        try debug_ui.print("jump - first row {d}\n", .{self.window.last_draw.top_line});
        try debug_ui.print("jump - last row {d}\n", .{self.window.last_draw.bottom_line});
        try debug_ui.print("jump - line_num: {d}\n", .{line_num});
        try debug_ui.print("jump - last_rendered_line_offset: {d}\n", .{last_rendered_line_offset});
        try debug_ui.print("jump - last_rendered_line: {d}\n", .{last_rendered_line});
        try debug_ui.print("jump - first_rendered_line_offset: {d}\n", .{first_rendered_line_offset});
        try debug_ui.print("jump - first_rendered_line: {d}\n\n", .{first_rendered_line});

        // line is below
        if (line_num > last_rendered_line) {
            self.removePendingLines();
            if (line_num != self.output.widget_ref.?.window.last_draw.process_buffer_num_lines) {
                self.setStickyScroll(false);
            } else {
                self.setStickyScroll(true);
            }
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
        // TODO: pending lines should just be cached in the window, and resolved later in an update call
        // we should calculate how much the window can move, move it, then add the rest to the scroll

        self.window.linesUpEx(@truncate(n));

        // TODO: allow a larger number than u8
        //if (self.window.linesUp(@intCast(n))) return else _ = self.scroll_bars.scroll_view.scroll.linesUp(@intCast(n));
    }

    pub fn moveOutputDownLines(self: *OutputWidget, n: usize) void {
        self.window.linesDownEx(@truncate(n));

        //// TODO: allow a larger number than u8
        //if (self.window.linesDown(@intCast(n))) {
        //    //std.debug.print("window linesjDown returned\n", .{});
        //} else {
        //    //std.debug.print("scroll_view linesDown returned\n", .{});
        //    _ = self.scroll_bars.scroll_view.scroll.linesDown(@intCast(n));
        //}
    }

    pub fn setStickyScroll(self: *OutputWidget, is_sticky: bool) void {
        if (!is_sticky) {
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
        try self.rendered_text_offset_at_row_start.put(
            self.alloc,
            row,
            offset + self.window.startingOffset(), // this line seg faults from callback :(
        );
    }

    const LineType = enum { first, last };
    pub fn get_rendered_line_buffer_offset(self: *OutputWidget, line: LineType) !usize {
        if (self.rendered_text_offset_at_row_start.size == 0) {
            return error.NoLinesRendered;
        }

        switch (line) {
            // This function has some problems - .first will get the top of the window not
            // the first rendered line
            .first => {
                return self.rendered_text_offset_at_row_start.get(0) orelse
                    {
                        // NOTE: I've obsered this being rendered where line 1 to 199 exists
                        // in the map self.rendered_text_offset_at_row_start
                        // but for somereason index 0 is missing... top_line was 1719
                        std.log.debug("top_line: {d}\n", .{self.window.last_draw.top_line});
                        var it = self.rendered_text_offset_at_row_start.iterator();
                        while (it.next()) |e| {
                            std.log.debug("{d} : {d}\n", .{ e.key_ptr.*, e.value_ptr.* });
                        }
                        return error.LineNotRendered;
                    };
            },
            .last => {
                if (self.rendered_text_offset_at_row_start.get(self.window.num_lines)) |l| {
                    return l;
                } else {
                    // The outputwidget isn't filled to the bottom
                    return self.rendered_text_offset_at_row_start.get(self.rendered_text_offset_highest_key.?) orelse error.LineNotRendered;
                }
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
        try list_cpy.appendSlice(ctx.arena, self.output.style_list.items);

        // copy the style map
        var map_cpy = try utils.cloneHashMap(
            usize,
            usize,
            std.hash_map.AutoContext(usize),
            std.hash_map.default_max_load_percentage,
            ctx.arena,
            &self.output.style_map,
        );

        self.window.resolvePendingLines();

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

        // This should probably be in a tick event
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

        // somehow this is causing a bug
        self.window.updateWindowPostRender(border_child.surface.size.height - 2);

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
    // refactor last_update vars into a struct
    last_draw: RenderInfo = .{},
    //last_update_last_line_empty: bool = false, // is last char in buffer a newline
    is_sticky: bool = true,
    pending_lines: i64 = 0,
    output: *Output,

    const RenderInfo = struct {
        top_line: usize = 0,
        bottom_line: usize = 0,
        process_buffer_len: usize = 0,
        process_buffer_num_lines: usize = 0,
    };

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
        if (line_num >= self.last_draw.process_buffer_num_lines) {
            return .outOfBounds;
        }
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

    // set the offset of the first character of the line
    pub fn getOffsetFromLine(self: *Window, line_num: usize) !usize {
        const idx = self.calNewlineIndex(line_num);
        switch (idx) {
            .idx => |i| {
                const offset = self.output.nonowned_process_buffer
                    .filtered_newlines.items[i] + 1;
                std.debug.assert(offset < self.last_draw.process_buffer_len);
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
                std.debug.assert(self.output.nonowned_process_buffer.filtered_newlines.items.len >= i);

                const offset = self.output.nonowned_process_buffer
                    .filtered_newlines.items[i] + 1;
                //std.debug.assert(offset < self.last_draw.process_buffer_len);
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
                if (self.last_draw.process_buffer_num_lines < 2) { // if there is only 1 newline
                    return self.last_draw.process_buffer_len - ofs;
                }
                if (i > self.last_draw.process_buffer_num_lines - 2) { // if i is last newline
                    return self.last_draw.process_buffer_len - ofs;
                } else {
                    const buffer_ofs = self.output.nonowned_process_buffer.filtered_newlines.items[i + 1];
                    return buffer_ofs - ofs;
                }
            },
            .first => return 0,
            .outOfBounds => {
                return self.last_draw.process_buffer_len - ofs;
            },
        }
    }

    pub fn getParentTotalLines(self: *Window) usize {
        return self.last_draw.process_buffer_num_lines;
    }

    pub fn bottomLineLastDrawn(self: *Window) !usize {
        std.debug.assert(self.num_lines != 0);

        const lines: usize = self.getParentTotalLines();
        // Unsure if lines being zero is an error, or just the first line without a newline
        // For now assume an error
        if (lines == 0) return error.NotRenderedYet;

        if (lines < self.num_lines) {
            return self.getParentTotalLines() - 1;
        } else {
            return self.top_line + self.num_lines - 1;
        }
    }

    pub fn lastLine(self: *Window) usize {
        std.debug.assert(self.num_lines != 0);
        return self.top_line + self.num_lines - 1;
    }

    // TODO: change this from returning if move, to returning the number moved
    pub fn linesUp(self: *Window, n: u32) bool {
        if (self.top_line == 0) return false;
        self.pending_lines -|= @intCast(n);
        return true;
    }

    pub fn linesUpEx(self: *Window, n: u32) void {
        self.pending_lines -|= @intCast(n);
    }

    pub fn linesDownEx(self: *Window, n: u32) void {
        self.pending_lines +|= n;
    }

    // TODO: change this from returning if move, to returning the number moved
    pub fn linesDown(self: *Window, n: u32) bool {
        if (!self.has_more_vertical) return false;
        self.pending_lines += n;
        return true;
    }

    pub fn updateWindow(self: *Window) void {
        // before update, check if window previously was on the buffers last line
        const prev_last_line = self.lastLine();

        var prev_at_bottom = false;
        if (self.last_draw.process_buffer_num_lines == 0) {
            prev_at_bottom = true;
        } else if (self.last_draw.process_buffer_num_lines == 0) {
            prev_at_bottom = true;
        } else if (prev_last_line >= self.last_draw.process_buffer_num_lines - 1) {
            prev_at_bottom = true;
        }

        const prev_bottom_line_drawn = self.last_draw.bottom_line;
        const prev_number_of_lines = self.last_draw.process_buffer_num_lines;
        const scroll_pending_lines = self.output.widget_ref.?.scroll_bars.scroll_view.scroll.pending_lines;
        const window_pending_lines = self.pending_lines;

        var previously_scrolled_to_bottom: bool = false;
        if (prev_bottom_line_drawn == 0 or prev_number_of_lines == 0) {
            previously_scrolled_to_bottom = true;
        } else if (scroll_pending_lines >= 0 and
            window_pending_lines >= 0 and
            prev_bottom_line_drawn == prev_number_of_lines - 1)
        {
            previously_scrolled_to_bottom = true;
        }

        // update parent buffer length
        self.last_draw.process_buffer_len = self.output
            .nonowned_process_buffer
            .getFilteredBufferLength();

        // update parent number of lines
        self.last_draw.process_buffer_num_lines = self.output
            .nonowned_process_buffer
            .getNumFilteredNewlines();

        if (prev_last_line < self.last_draw.process_buffer_num_lines) {
            self.has_more_vertical = true;
        } else {
            self.has_more_vertical = false;
        }

        // if previously the window was at the end of the buffer, keep it there
        if (previously_scrolled_to_bottom) {
            self.top_line = self.last_draw.process_buffer_num_lines -| self.num_lines;
            self.has_more_vertical = false;
            self.is_sticky = true;
            self.output.widget_ref.?.scroll_sticky_mode = true;
        }
    }

    pub fn updateWindowPostRender(self: *Window, window_size: usize) void {
        // vertical_offset only tracks the offset from the `top` widget
        // however we only have 1, which is the window's slice...convenient
        self.last_draw.top_line = self.top_line + @as(usize, @intCast(self.output.widget_ref.?
            .scroll_bars
            .scroll_view
            .scroll
            .vertical_offset));

        const border_vertical_rows = 2;
        const rendered_text_rows: usize = window_size -| border_vertical_rows;
        self.last_draw.bottom_line = self.last_draw.top_line + rendered_text_rows;
    }

    pub fn setFocus(self: *OutputWidget, is_focus: bool) void {
        self.output.is_focused = is_focus;
    }

    pub fn getFocus(self: *OutputWidget) bool {
        return self.output.is_focused;
    }

    pub fn resolvePendingLines(self: *Window) void {
        switch (self.pending_lines) {
            // moving up, negative number
            std.math.minInt(i64)...-1 => |lines_to_move| {
                const pending_delta: i64 = @as(i64, @intCast(self.top_line)) + lines_to_move;
                if (pending_delta < 0) {
                    // attempted to move the window beyond the top
                    _ = self.output
                        .widget_ref.?
                        .scroll_bars.scroll_view.scroll
                        .linesUp(@truncate(@abs(pending_delta)));

                    self.top_line = 0;
                } else {
                    self.top_line = @intCast(pending_delta);
                }
            },
            // moving down, positive number
            1...std.math.maxInt(i64) => |lines_to_move| {
                // update the top line
                self.top_line = self.top_line + @as(usize, @intCast(lines_to_move));

                // check if top_line would set the window's range beyond the bottom of the buffer
                const updated_last_line = self.lastLine();
                const last_drawn_num_lines = self.last_draw.process_buffer_num_lines;
                if (last_drawn_num_lines <= updated_last_line) {
                    self.has_more_vertical = false;

                    // check if the buffer is NOT smaller than the window
                    if (last_drawn_num_lines > self.num_lines) {
                        const lowest_possible_top_line = last_drawn_num_lines - self.num_lines;

                        // scroll the scroll widget with the difference
                        const diff = self.top_line - lowest_possible_top_line;
                        _ = self.output
                            .widget_ref.?
                            .scroll_bars.scroll_view.scroll
                            .linesDown(@truncate(diff));

                        self.top_line = lowest_possible_top_line;
                    } else {
                        // buffer IS smaller than the window - top line must be zero

                        // scroll the scroll widget with the difference
                        _ = self.output
                            .widget_ref.?
                            .scroll_bars.scroll_view.scroll
                            .linesDown(@truncate(self.top_line));

                        // it is smaller, set to zero
                        self.top_line = 0;
                    }
                }
            },
            else => {
                // zero, no pending lines
                return;
            },
        }

        // reset pending lines
        self.pending_lines = 0;

        // if (self.pending_lines >= 0) {
        //     self.top_line = self.top_line + @as(usize, @intCast(self.pending_lines));
        // } else {
        //     // BUG: this is broken when window is full
        //     const pending_delta: i64 = @as(i64, @intCast(self.top_line)) + self.pending_lines;
        //     if (pending_delta < 0) self.top_line = 0 else self.top_line = @intCast(pending_delta);
        // }
        // self.pending_lines = 0;

        // // make sure the window doesn't reach passed the bottom of the buffer
        // const last_line = self.lastLine();
        // if (self.last_draw.process_buffer_num_lines <= last_line) {
        //     self.has_more_vertical = false;

        //     // check if the buffer is NOT smaller than the window
        //     if (self.last_draw.process_buffer_num_lines > self.num_lines) {
        //         self.top_line = self.last_draw.process_buffer_num_lines - self.num_lines;
        //     } else {
        //         self.top_line = 0;
        //     }
        // }
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
