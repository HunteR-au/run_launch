const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const utils = @import("utils");
const debug_ui = @import("debug_ui");

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Border = vxfw.Border;
const ScrollBar = vxfw.ScrollBars;
const ScrollView = vxfw.ScrollView;
const linenumbers_mod = @import("widgets/linenumbers.zig");
const LineNumbers = linenumbers_mod.LineNumbersWidget;
pub const RowInfo = linenumbers_mod.RowInfo;
const LinesAndTextWidget = @import("widgets/linesandtext.zig").LinesAndTextWidget;
const UUID = utils.uuid.UUID;

pub const UiConfig = @import("uiconfig").UiConfig;
pub const Output = @import("output.zig");
const process_buffer_mod = @import("pipeline/processbuffer.zig");
pub const ProcessBuffer = process_buffer_mod.ProcessBuffer;
pub const WindowSnapshot = process_buffer_mod.WindowSnapshot;
pub const BufferSnapshot = process_buffer_mod.BufferSnapshot;
const MultiStyleText = @import("widgets/mutistyletext.zig").MultiStyleText(WindowSnapshot);

const FocusedBorder: vaxis.Style = .{ .fg = .{ .rgb = .{ 255, 255, 0 } } };
const UnfocusedBorder: vaxis.Style = .{ .fg = .{ .rgb = .{ 255, 255, 255 } } };

/// The vaxis scroll helpers take a `u8`; clamp instead of truncating.
fn clampU8(n: anytype) u8 {
    return @intCast(@min(n, std.math.maxInt(u8)));
}

/// Rows rendered for a wrapped window are capped so the surface (`u16` rows) and the scroll
/// view's `i17` offsets stay far from overflow even with pathological line lengths.
const wrapped_row_cap: u16 = 8192;

/// One rendered text row: the window-relative byte offset of its first grapheme and whether
/// that offset starts a line (false for the continuation rows of a wrapped line).
pub const RowEntry = struct { ofs: usize, is_start: bool };
const RowMap = std.AutoHashMapUnmanaged(usize, RowEntry);

/// Rows between the first row of the line shown on `row` and `row` itself.
fn rowsIntoLine(map: *const RowMap, row: usize) usize {
    var r = row;
    while (true) {
        const entry = map.get(r) orelse return row - r;
        if (entry.is_start or r == 0) return row - r;
        r -= 1;
    }
}

/// True when `row` is the last row of the line shown on it: the next row is absent or starts
/// another line.
fn rowEndsLine(map: *const RowMap, row: usize) bool {
    const next = map.get(row + 1) orelse return true;
    return next.is_start;
}

pub const OutputWidget = struct {
    alloc: std.mem.Allocator,
    text: MultiStyleText = undefined,
    scroll_bars: ScrollBar,
    scroll_sticky_mode: bool = false,
    lines_widget: *LineNumbers,
    process_name: []const u8,
    id: UUID,
    strid: usize = 0,
    output: Output,
    window: Window,

    /// The snapshot the current/last frame was drawn from. Arena backed: valid during a
    /// draw and, for `text`/`line_starts`, until the next frame's arena reset. Only
    /// `lineAt` on it is used between frames (from the gutter callbacks of the same frame).
    frame: WindowSnapshot = .empty,
    /// `frame.meta.change` at the time of the last draw; the root tick compares it with
    /// `peek().change` to decide whether a redraw is needed.
    last_drawn_change: ?u64 = null,

    /// Key: rendered row of the text child (not the viewport), Value: see `RowEntry`.
    row_offsets: RowMap = .empty,
    highest_row: ?usize = null,

    pub fn init(
        alloc: std.mem.Allocator,
        processname: []const u8,
        id: UUID,
        buffer: *ProcessBuffer,
        store: *Output.IngestStore,
    ) !*OutputWidget {
        const pname = try alloc.dupe(u8, processname);
        errdefer alloc.free(pname);
        var output_widget = try alloc.create(OutputWidget);
        errdefer alloc.destroy(output_widget);
        output_widget.* = .{
            .alloc = alloc,
            .process_name = pname,
            .id = id,
            .scroll_bars = undefined,
            .lines_widget = try .init(alloc),
            .output = try Output.init(alloc, buffer, store),
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

        return output_widget;
    }

    pub fn deinit(self: *OutputWidget, io: Io) void {
        self.alloc.free(self.process_name);
        self.lines_widget.deinit();
        self.output.deinit(io);
        self.row_offsets.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    // We pass the uiconfig through the widget to output so the ui gets a chance
    // to do any setup
    pub fn setupViaUiconfig(self: *OutputWidget, config: *UiConfig) !void {
        try self.output.setupViaUiconfig(config, self.process_name);
    }

    /// True when the buffer has published a change since the last draw.
    pub fn needsRedraw(self: *const OutputWidget) bool {
        const change = self.output.nonowned_process_buffer.peek().change;
        return self.last_drawn_change == null or self.last_drawn_change.? != change;
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

    fn stopFollowing(self: *OutputWidget) void {
        self.scroll_sticky_mode = false;
        self.window.is_sticky = false;
        self.scroll_bars.scroll_view.scroll.pending_lines = 0;
        self.window.pending_lines = 0;
    }

    pub fn captureHandler(self: *OutputWidget, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .mouse => |mouse| {
                if (mouse.button == .wheel_up) {
                    // turn of sticky scrolling on mouse wheel up
                    self.stopFollowing();
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
                    self.stopFollowing();
                    self.moveOutputUpLines(1);
                    ctx.consumeAndRedraw();
                }
                if (key.matches('k', .{ .ctrl = true })) {
                    self.stopFollowing();
                    self.moveOutputUpLines(5);
                    ctx.consumeAndRedraw();
                }
                if (key.matches(vaxis.Key.escape, .{})) {
                    try self.output.removeSearch(ctx.io);
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
                    self.output.searchNext(ctx.io);
                    ctx.consumeAndRedraw();
                }
                if (key.matches('n', .{ .ctrl = true })) {
                    self.output.searchPrev(ctx.io);
                    ctx.consumeAndRedraw();
                }
                if (key.matches(vaxis.Key.page_up, .{ .ctrl = true }) or
                    key.matches('i', .{ .ctrl = true }))
                {
                    self.jump_to_start() catch {};
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
                    self.stopFollowing();
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
            .mouse_enter, .mouse_leave, .mouse, .key_press => {
                try self.scroll_bars.handleEvent(ctx, event);
                try self.scroll_bars.scroll_view.handleEvent(ctx, event);
            },
            else => {},
        }
    }

    pub fn jump_to_start(self: *OutputWidget) !void {
        try self.jump_output_to_line(0);
    }

    pub fn jump_to_end(self: *OutputWidget) !void {
        try self.jump_output_to_line(self.window.last_draw.process_buffer_num_lines);
    }

    /// Whole lines visible on the last frame, less one so a page keeps one line of overlap.
    /// Counted in lines, not rows: with wrapping a screen holds fewer lines than rows.
    fn pageLines(self: *const OutputWidget) usize {
        return @max(self.window.last_draw.bottom_line -| self.window.last_draw.top_line, 1);
    }

    pub fn pageUp(self: *OutputWidget) !void {
        self.moveOutputUpLines(self.pageLines());
    }

    pub fn pageDown(self: *OutputWidget) !void {
        self.moveOutputDownLines(self.pageLines());
    }

    pub fn jump_output_to_line(self: *OutputWidget, jump_to: usize) !void {
        const total_lines = self.window.last_draw.process_buffer_num_lines;
        const line_num: usize = @min(jump_to, total_lines);

        const first_rendered_line = self.window.last_draw.top_line;
        const last_rendered_line = self.window.last_draw.bottom_line;

        // check if line is already within rendered bounds (a bottom line whose wrapped tail
        // is cut off does not count)
        const bottom_visible = if (line_num == last_rendered_line)
            self.window.last_draw.bottom_line_complete
        else
            line_num < last_rendered_line;
        if (first_rendered_line <= line_num and bottom_visible) {
            return;
        }

        // line is below (or is the partially visible bottom line)
        if (line_num >= last_rendered_line) {
            self.removePendingLines();
            self.setStickyScroll(line_num == total_lines);
            self.moveOutputDownLines(@max(line_num - last_rendered_line, 1));
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
        self.window.linesUpEx(std.math.lossyCast(u32, n));
    }

    pub fn moveOutputDownLines(self: *OutputWidget, n: usize) void {
        self.window.linesDownEx(std.math.lossyCast(u32, n));
    }

    pub fn setStickyScroll(self: *OutputWidget, is_sticky: bool) void {
        self.scroll_sticky_mode = is_sticky;
        self.window.is_sticky = is_sticky;
    }

    fn removePendingLines(self: *OutputWidget) void {
        self.scroll_bars.scroll_view.scroll.pending_lines = 0;
        self.window.pending_lines = 0;
    }

    /// Called when `wrap_lines` changes: forget any horizontal scroll and re-anchor the window
    /// on the first visible line at the next draw.
    pub fn onWrapToggled(self: *OutputWidget) void {
        self.scroll_bars.scroll_view.scroll.left = 0;
        self.removePendingLines();
        self.window.anchor_pending = true;
    }

    /// Called by the text widget for every rendered row with the window-relative byte
    /// offset of the row's first grapheme.
    fn save_rendered_buffer_offset(ptr: *anyopaque, row: usize, offset: usize) std.mem.Allocator.Error!void {
        const self: *OutputWidget = @ptrCast(@alignCast(ptr));

        if (self.highest_row == null or self.highest_row.? < row) {
            self.highest_row = row;
        }
        try self.row_offsets.put(self.alloc, row, .{
            .ofs = offset,
            .is_start = self.frame.isLineStart(offset),
        });
    }

    // Used as a callback to remove type information for widgets needing to call this
    fn rowToLineCallback(ptr: *anyopaque, row: usize) ?RowInfo {
        var self: *OutputWidget = @ptrCast(@alignCast(ptr));
        const scroll_offset: usize = @intCast(@max(self.scroll_bars.scroll_view.scroll.vertical_offset, 0));
        const text_row = row + scroll_offset;
        return self.getRowInfo(text_row);
    }

    /// Maps a rendered text row to the absolute filtered line number shown on it.
    pub fn getLineNumberViaRow(self: *OutputWidget, row: usize) ?usize {
        const entry = self.row_offsets.get(row) orelse return null;
        return self.frame.lineAt(entry.ofs);
    }

    /// `getLineNumberViaRow` plus whether the row is the first row of that line.
    pub fn getRowInfo(self: *OutputWidget, row: usize) ?RowInfo {
        const entry = self.row_offsets.get(row) orelse return null;
        const line = self.frame.lineAt(entry.ofs) orelse return null;
        return .{ .line = line, .is_start = entry.is_start };
    }

    pub fn draw(self: *OutputWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const max_size = ctx.max.size();
        const pb = self.output.nonowned_process_buffer;

        // 1. lock-free counters drive the scroll bookkeeping
        const meta = pb.peek();
        self.window.updateWindow(meta);
        self.window.resolvePendingLines();

        // 2. one locked copy of everything this frame needs
        var snap = try pb.snapshotWindow(ctx.arena, .{
            .top_line = self.window.top_line,
            .max_lines = self.window.num_lines,
            .follow_bottom = self.window.is_sticky,
        });
        // the buffer may have changed between peek() and the lock; trust the snapshot
        self.window.top_line = snap.top_line;
        self.window.last_draw.process_buffer_len = snap.meta.filtered_len;
        self.window.last_draw.process_buffer_num_lines = snap.meta.filtered_lines;

        if (self.output.searchHighlight(&snap)) |h| {
            snap = try snap.overlay(ctx.arena, h.start, h.end, h.style);
        }
        self.frame = snap;
        self.last_drawn_change = snap.meta.change;

        if (self.window.is_sticky) {
            // Follow mode: pin the scroll view to its bottom in this very frame. The vaxis
            // ScrollView anchors its child's bottom to the viewport when the pending downward
            // scroll overshoots, so one large value replaces the old one-row-per-frame nudge
            // (which no longer works now that frames are only drawn on change).
            self.scroll_bars.scroll_view.scroll.pending_lines = std.math.maxInt(i17) / 2;
        }

        // clear the rendered buffer offsets at starting row positions
        self.row_offsets.clearRetainingCapacity();
        self.highest_row = null;

        // Pre-calculate gutter width
        const gutter_width = self.lines_widget.calculateGutterWidth(snap.meta.filtered_lines);

        // build the MultiStyleText structure
        const wrap = self.output.wrap_lines;
        self.text = .{
            .text = self.frame.text,
            .styles = &self.frame,
            .cb_ptr = self,
            .cb_buffer_offset_at_row = save_rendered_buffer_offset,
            .softwrap = wrap,
            .max_rows = if (wrap) wrapped_row_cap else std.math.maxInt(u16),
        };
        // wrapped text never needs the horizontal scrollbar row: reclaim it (gutter included)
        self.scroll_bars.draw_horizontal_scrollbar = !wrap;
        self.lines_widget.reserve_last_row = !wrap;
        if (wrap) self.scroll_bars.scroll_view.scroll.left = 0;

        const is_focused = self.output.is_focused;
        var border_child: vxfw.SubSurface = undefined;
        if (self.output.show_lines) {
            // Create the lines and text widget
            var lines_and_text = try ctx.arena.create(LinesAndTextWidget);
            lines_and_text.* = .{
                .gutter_width = gutter_width,
                .window_ofs = self.window.last_draw.top_line,
                .text = self.scroll_bars.widget(),
                .lines = self.lines_widget,
                .line_to_row = .{
                    .ptr = self,
                    .callback = rowToLineCallback,
                },
            };

            const border: vxfw.Border = .{
                .child = lines_and_text.widget(),
                .style = if (is_focused) FocusedBorder else UnfocusedBorder,
                .labels = &.{.{
                    .text = self.process_name,
                    .alignment = .top_left,
                }},
            };
            border_child = .{
                .origin = .{ .row = 0, .col = 0 },
                .surface = try border.draw(ctx),
            };
        } else {
            const border: vxfw.Border = .{
                .child = self.scroll_bars.widget(),
                .style = if (is_focused) FocusedBorder else UnfocusedBorder,
                .labels = &.{.{
                    .text = self.process_name,
                    .alignment = .top_left,
                }},
            };
            border_child = .{
                .origin = .{ .row = 0, .col = 0 },
                .surface = try border.draw(ctx),
            };
        }

        self.window.updateWindowPostRender(self, border_child.surface.size.height);

        const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = border_child;

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
    last_draw: RenderInfo = .{},
    is_sticky: bool = true,
    pending_lines: i64 = 0,
    /// Set while following (the viewport is pinned deep inside the window) and on a wrap
    /// toggle; consumed by `reanchorIfNeeded` on the next non-following frame.
    anchor_pending: bool = false,
    output: *Output,

    const RenderInfo = struct {
        /// first line visible on screen
        top_line: usize = 0,
        /// last line visible on screen (inclusive)
        bottom_line: usize = 0,
        /// false when the bottom line is wrapped and its last rows are below the viewport
        bottom_line_complete: bool = true,
        /// number of text rows the scroll view showed
        rows: usize = 0,
        process_buffer_len: usize = 0,
        process_buffer_num_lines: usize = 0,
    };

    pub fn getParentTotalLines(self: *Window) usize {
        return self.last_draw.process_buffer_num_lines;
    }

    pub fn lastLine(self: *Window) usize {
        std.debug.assert(self.num_lines != 0);
        return self.top_line + self.num_lines - 1;
    }

    // Use the information in the last_draw to determine if
    // the window is at the bottom of the buffer
    fn isOnBottom(self: *Window) bool {
        if (self.last_draw.process_buffer_num_lines == 0) return true;
        if (self.last_draw.bottom_line_complete and
            self.last_draw.bottom_line >= self.last_draw.process_buffer_num_lines - 1) return true;
        return false;
    }

    pub fn linesUpEx(self: *Window, n: u32) void {
        self.pending_lines -|= @intCast(n);
    }

    pub fn linesDownEx(self: *Window, n: u32) void {
        self.pending_lines +|= n;
    }

    fn isPendingUp(self: *Window) bool {
        return self.pending_lines < 0;
    }

    /// Refreshes the buffer-derived bookkeeping from a lock-free snapshot and applies the
    /// sticky-follow rule. All values used by scrolling come from this one snapshot.
    pub fn updateWindow(self: *Window, meta: BufferSnapshot) void {
        // re-engage follow mode once the user has scrolled back to the bottom
        if (!self.is_sticky and self.isOnBottom() and !self.isPendingUp()) {
            self.is_sticky = true;
        }

        self.last_draw.process_buffer_len = meta.filtered_len;
        self.last_draw.process_buffer_num_lines = meta.filtered_lines;

        // never point past the end of the buffer (a filter may have shrunk it)
        self.top_line = @min(self.top_line, meta.filtered_lines -| 1);
    }

    /// Records which lines ended up visible. Derived from what was actually rendered (the
    /// row -> byte-offset map filled by the text widget and the scroll view's height), so
    /// borders, scrollbars and soft-wrapped rows are all accounted for exactly.
    pub fn updateWindowPostRender(self: *Window, ow: *OutputWidget, pane_height: usize) void {
        const scroll_view = &ow.scroll_bars.scroll_view;
        // vertical_offset only tracks the offset from the `top` widget; we have one child (the
        // window's text), so it is the number of text rows scrolled off the top.
        const first_row: usize = @intCast(@max(scroll_view.scroll.vertical_offset, 0));
        // viewport = pane minus the border rows minus the horizontal scrollbar row
        const border_rows = 2;
        const rows: usize = pane_height -| border_rows -| @intFromBool(ow.scroll_bars.draw_horizontal_scrollbar);
        self.last_draw.rows = rows;

        self.last_draw.top_line = ow.getLineNumberViaRow(first_row) orelse self.top_line + first_row;

        // the last visible row is the bottom of the viewport, or the last row that got text
        var last_row = first_row + (rows -| 1);
        if (ow.highest_row) |h| last_row = @min(last_row, h);
        self.last_draw.bottom_line = ow.getLineNumberViaRow(last_row) orelse self.last_draw.top_line;
        self.last_draw.bottom_line_complete = rowEndsLine(&ow.row_offsets, last_row);

        if (self.is_sticky) self.anchor_pending = true;
    }

    /// Makes the window top coincide with the viewport top: `top_line` becomes the first
    /// visible line and the scroll view keeps only the rows inside that line. Needed once rows
    /// and lines differ (wrapping): scrolling `top_line` then moves exactly the lines at the
    /// viewport rather than the lines entering the window far above it.
    fn reanchorIfNeeded(self: *Window) void {
        if (!self.anchor_pending or self.is_sticky) return;
        self.anchor_pending = false;
        const ow = self.output.widget_ref orelse return;
        const scroll = &ow.scroll_bars.scroll_view.scroll;
        const first_row: usize = @intCast(@max(scroll.vertical_offset, 0));
        self.top_line = self.last_draw.top_line;
        scroll.vertical_offset = @intCast(@min(rowsIntoLine(&ow.row_offsets, first_row), std.math.maxInt(i17)));
    }

    pub fn resolvePendingLines(self: *Window) void {
        self.reanchorIfNeeded();
        switch (self.pending_lines) {
            // moving up, negative number
            std.math.minInt(i64)...-1 => |lines_to_move| {
                const pending_delta: i64 = @as(i64, @intCast(self.top_line)) + lines_to_move;
                if (pending_delta < 0) {
                    // attempted to move the window beyond the top
                    _ = self.output
                        .widget_ref.?
                        .scroll_bars.scroll_view.scroll
                        .linesUp(clampU8(@abs(pending_delta)));

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
                            .linesDown(clampU8(diff));

                        self.top_line = lowest_possible_top_line;
                    } else {
                        // buffer IS smaller than the window - top line must be zero

                        // scroll the scroll widget with the difference
                        _ = self.output
                            .widget_ref.?
                            .scroll_bars.scroll_view.scroll
                            .linesDown(clampU8(self.top_line));

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
    }
};

test "row map helpers: rows into a wrapped line and line completeness" {
    const testing = std.testing;
    var map: RowMap = .empty;
    defer map.deinit(testing.allocator);
    // line A on rows 0-2 (wrapped), line B on row 3, line C on rows 4-5
    try map.put(testing.allocator, 0, .{ .ofs = 0, .is_start = true });
    try map.put(testing.allocator, 1, .{ .ofs = 10, .is_start = false });
    try map.put(testing.allocator, 2, .{ .ofs = 20, .is_start = false });
    try map.put(testing.allocator, 3, .{ .ofs = 30, .is_start = true });
    try map.put(testing.allocator, 4, .{ .ofs = 40, .is_start = true });
    try map.put(testing.allocator, 5, .{ .ofs = 50, .is_start = false });

    try testing.expectEqual(0, rowsIntoLine(&map, 0));
    try testing.expectEqual(2, rowsIntoLine(&map, 2));
    try testing.expectEqual(0, rowsIntoLine(&map, 3));
    try testing.expectEqual(1, rowsIntoLine(&map, 5));
    try testing.expectEqual(0, rowsIntoLine(&map, 9)); // unknown row

    try testing.expect(!rowEndsLine(&map, 0));
    try testing.expect(rowEndsLine(&map, 2));
    try testing.expect(rowEndsLine(&map, 3));
    try testing.expect(!rowEndsLine(&map, 4));
    try testing.expect(rowEndsLine(&map, 5)); // last row of the surface
}
