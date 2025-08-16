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
    alloc: std.mem.Allocator,
    text: MultiStyleText = undefined,
    scroll_bars: ScrollBar,
    scroll_sticky_mode: bool = false,
    border: Border,
    process_name: []const u8,
    is_focused: bool = false,
    temp: vxfw.Text = undefined,
    output: Output,
    window: Window,

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
                std.debug.print("output: mouse type {?}\n", .{mouse.type});

                if (mouse.button == .wheel_up) {
                    // turn of sticky scrolling on mouse wheel up
                    self.scroll_sticky_mode = false;
                    self.window.is_sticky = false;
                    self.scroll_bars.scroll_view.scroll.pending_lines = 0;

                    if (self.window.linesUp(1)) ctx.consumeAndRedraw();
                }
                if (mouse.button == .wheel_down) {
                    if (self.window.linesDown(1)) ctx.consumeAndRedraw();
                }
            },
            .key_press => |key| {
                // turn off sticky scrolling on up actions
                if (key.matches('u', .{ .ctrl = true }) or
                    key.matches(vaxis.Key.up, .{}) or
                    key.matches('k', .{}) or
                    key.matches('p', .{ .ctrl = true }))
                {
                    self.scroll_sticky_mode = false;
                    self.window.is_sticky = false;
                    self.scroll_bars.scroll_view.scroll.pending_lines = 0;

                    if (self.window.linesUp(1)) ctx.consumeAndRedraw();
                }
                if (key.matches(vaxis.Key.down, .{}) or
                    key.matches('j', .{}) or
                    key.matches('n', .{ .ctrl = true }) or
                    key.matches('d', .{ .ctrl = true }))
                {
                    if (self.window.linesDown(1)) ctx.consumeAndRedraw();
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
            self.scroll_sticky_mode = true;
            self.window.is_sticky = true;
            if (!self.window.linesDown(1)) {
                _ = self.scroll_bars.scroll_view.scroll.linesDown(1);
            }
        } else if (self.scroll_sticky_mode == true) {
            if (!self.window.linesDown(1)) {
                _ = self.scroll_bars.scroll_view.scroll.linesDown(1);
            }
        }
    }

    pub fn draw(self: *OutputWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const max_size = ctx.max.size();

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
        };

        if (self.is_focused) {
            // color border yellow
            self.border.style = vaxis.Style{ .fg = .{ .rgb = .{ 255, 255, 0 } } };
        } else {
            self.border.style = vaxis.Style{ .fg = .{ .rgb = .{ 255, 255, 255 } } };
        }

        // To not have to draw all text
        // 1) - set windowing size (double height of output's height)
        // 2) - get previous scrollview.total_height (which is lines of text)
        // 3) ----- if lines is > windowing size
        // 4) ---------- capture events to control windowing (windowing must track offset for style_map)
        // 5) ---------- if window is at bottom, keep it there
        // 6) ----- if lines reduces to > windowing size
        // 7) ---------- don't window the text

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

// NOTE:
// window should contain a referece to either processBuffer or output
// -- have to concern about sub-processes adding to parent_buffer
// -- don't have to worry about UI thread (ie the loop)
// -- -- which is where events are processed
// -- probably want a function to copy all requred data structs
// -- probably want a function to check process buffer len, num lines, if last line is empty

// algo : update_window
// -- get flitered buffer len and number of lines
// -- update pending lines move +/-
// -- if num lines has increased
// -- -- check if on bottom and sticky
// -- -- -- if so, stay on bottom line
// -- -- -- else, keep on current top_line
// -- if num lines has decreased
// -- -- check if window size ranges beyond bottom line
// -- -- -- calculate top_line to put on bottom of buffer

// algo : getSlice(self)
// -- get top_line
// -- get last_line
// -- -- using processBuffer get top_line first char index
// -- -- using processBuffer get last_line first char index
// -- -- if last_line_is_empty and window.last_line == buffer.last_line
// -- -- -- set end_idx to last_newline
// -- -- else if window.last_line != buffer.last_line
// -- -- -- set end_idx to the index of the next newline char
// -- -- else
// -- -- -- set end_idx buffer.len
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
        self.pending_lines -= @intCast(n);
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

// TODO: take the parent buffer out of the window!
// TODO: make the newlines just a reference
//const Window = struct {
//    starting_line: usize = 0, // in lines
//    lines: usize, // in lines
//    parent: []u8,
//    parent_len: usize,
//    is_last_char_newline: bool,
//    //TODO: just reference filtered_buffer
//    newlines: std.ArrayList(usize),
//    is_sticky_end: bool = true,
//
//    pub fn startingByteOffset(self: *Window) usize {
//        if (self.starting_line == 0) return 0;
//        const idx = self.starting_line - 1;
//        std.debug.assert(idx < self.newlines.items.len);
//        return self.newlines.items[idx] + 1;
//    }
//
//    pub fn endByteOffset(self: *Window) usize {
//        const last_line = self.bottomLine();
//        if (last_line >= self.newlines.items.len) {
//            // the parent has less lines than its window size
//            return self.parent.len;
//        } else {
//            return self.newlines.items[last_line] + 1;
//        }
//    }
//
//    fn _totalLines(parent: []u8, newlines: *const std.ArrayList(usize)) usize {
//        if (parent.len == 0) return 0;
//        // check if lastchar is newline
//        if (parent[parent.len - 1] == '\n') {
//            return newlines.items.len;
//        } else {
//            return newlines.items.len + 1;
//        }
//    }
//
//    pub fn totalLines(self: *Window) usize {
//        return _totalLines(self.parent_len, &self.newlines);
//    }
//
//    inline fn bottomLine(self: *Window) usize {
//        return self.starting_line + self.lines;
//    }
//
//    pub fn linesDown(self: *Window, n: u8) bool {
//        const total_lines = self.totalLines();
//        const bottom_line = self.bottomLine();
//        if (total_lines < self.lines) return false;
//        if (total_lines <= bottom_line) return false;
//        if (total_lines <= bottom_line + n) {
//            self.starting_line = total_lines - self.lines;
//        } else {
//            self.starting_line += n;
//        }
//        return true;
//    }
//
//    pub fn linesUp(self: *Window, n: u8) bool {
//        const total_lines = self.totalLines();
//        if (total_lines < self.lines) return false;
//        if (self.starting_line == 0) return false;
//        self.starting_line -|= n;
//        return true;
//    }
//
//    pub fn updateParent(self: *Window, new_parent: []u8, new_newlines: std.ArrayList(usize)) void {
//        const new_total_lines = _totalLines(new_parent, &new_newlines);
//        if (new_total_lines < self.lines) {
//            self.starting_line = 0;
//            self.parent_len = new_parent.len;
//            self.newlines = new_newlines;
//        }
//
//        const total_lines = self.totalLines();
//        if (self.is_sticky_end) {
//            // check if the window is currently at the bottom
//            var is_bottom = false;
//            if (total_lines <= self.bottomLine()) {
//                is_bottom = true;
//            }
//
//            if (is_bottom) {
//                // keep window on the bottom
//                self.parent_len = new_parent.len;
//                self.newlines = new_newlines;
//                self.starting_line = total_lines -| self.lines;
//            } else {
//                // increased parent length - keep offset the same
//                // decreased parent length - keep offset the same unless it hits the bottom
//
//                // check if window will collide with the bottom
//                if (new_total_lines < self.starting_line + self.lines) {
//                    self.parent_len = new_parent.len;
//                    self.newlines = new_newlines;
//                    self.starting_line = new_total_lines -| self.lines;
//                } else {
//                    self.parent_len = new_parent.len;
//                    self.newlines = new_newlines;
//                }
//            }
//        }
//    }
//
//    pub fn getSlice(self: *Window, parent: []u8) []u8 {
//        if (parent.len == 0) return "";
//        const offset = self.startingByteOffset();
//        const offset_end = offset + self.endByteOffset();
//        // TODO: hitting this assert
//        std.debug.print("getSlice(): {d},{d}\n", .{ offset_end, parent.len });
//        std.debug.assert(offset_end <= parent.len);
//        return parent[offset..offset_end];
//    }
//};

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
