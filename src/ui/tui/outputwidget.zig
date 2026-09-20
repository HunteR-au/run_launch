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
const clipboardkeys = @import("clipboardkeys.zig");
const UUID = utils.uuid.UUID;

pub const UiConfig = @import("uiconfig").UiConfig;
pub const Output = @import("output.zig");
const process_buffer_mod = @import("pipeline/processbuffer.zig");
pub const ProcessBuffer = process_buffer_mod.ProcessBuffer;
pub const WindowSnapshot = process_buffer_mod.WindowSnapshot;
pub const BufferSnapshot = process_buffer_mod.BufferSnapshot;
const mutistyletext = @import("widgets/mutistyletext.zig");
const MultiStyleText = mutistyletext.MultiStyleText(WindowSnapshot);

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

/// Style painted over mouse-selected text. It replaces the text's own styles while selected.
const SelectionStyle: vaxis.Style = .{ .reverse = true };

/// Byte range `[start, end)` of the grapheme under a mouse cell. Past the end of a row's
/// content both equal the offset of that end (before the line break).
const TextPoint = struct { start: usize, end: usize };

/// Half-open byte range.
const ByteRange = struct { lo: usize, hi: usize };

/// A mouse selection over the filtered text, in absolute filtered byte offsets so it survives
/// scrolling and appends. A change of the buffer `version` (filter/reprocess) drops it.
const Selection = struct {
    anchor: TextPoint,
    head: TextPoint,
    version: u64,
    /// true between the left button press and its release
    dragging: bool = true,
    /// true once the mouse has been dragged to another cell (a plain click is not a selection)
    moved: bool = false,

    /// From the earlier grapheme's start through the later grapheme's end, so the cell under
    /// the mouse is always included.
    fn range(self: Selection) ByteRange {
        if (self.head.start >= self.anchor.start) {
            return .{ .lo = self.anchor.start, .hi = @max(self.head.end, self.anchor.end) };
        }
        return .{ .lo = self.head.start, .hi = self.anchor.end };
    }
};

/// A rectangle in the output widget's local coordinates.
const Rect = struct {
    row: i17,
    col: i17,
    width: u16,
    height: u16,

    fn contains(self: Rect, row: i17, col: i17) bool {
        return row >= self.row and col >= self.col and
            row < self.row + @as(i17, self.height) and col < self.col + @as(i17, self.width);
    }
};

/// Where the text landed in the last frame, in widget-local coordinates: the scroll view's
/// viewport (the area that shows text, without border, gutter or scrollbar) and the origin
/// of the text surface, which is negative once scrolled.
const Geometry = struct {
    viewport: Rect,
    text_origin: vxfw.RelativePoint,
};

const Located = struct { origin: vxfw.RelativePoint, size: vxfw.Size };

/// Depth-first search of a surface tree for `target`'s surface. The origin is relative to
/// `surface`.
fn locateWidget(surface: vxfw.Surface, target: vxfw.Widget) ?Located {
    if (surface.widget.eql(target)) return .{ .origin = .{ .row = 0, .col = 0 }, .size = surface.size };
    for (surface.children) |child| {
        const found = locateWidget(child.surface, target) orelse continue;
        return .{
            .origin = .{
                .row = found.origin.row + child.origin.row,
                .col = found.origin.col + child.origin.col,
            },
            .size = found.size,
        };
    }
    return null;
}

/// Maps a column on one rendered row to the grapheme drawn there, mirroring how the text
/// widget lays a row out in `mode` (control bytes and invalid UTF-8 take several cells in
/// raw mode). `row_text` runs from the row's first grapheme to the next row's first grapheme
/// (or the end of the text); `base` is the offset of `row_text[0]`, and the result is
/// relative to the same origin as `base`. Columns past the content map to the content end,
/// before the line break.
fn cellToOffsets(row_text: []const u8, base: usize, col: usize, mode: mutistyletext.Mode) TextPoint {
    const content_len = std.mem.indexOfScalar(u8, row_text, '\n') orelse row_text.len;
    const content = row_text[0..content_len];
    // only the (static) width method is used; no arena or constraints are needed
    const dctx: vxfw.DrawContext = .{ .arena = undefined, .min = .{}, .max = .{}, .cell_size = .{} };

    var acc: usize = 0;
    var iter = dctx.graphemeIterator(content);
    while (iter.next()) |g| {
        const bytes = g.bytes(content);
        const width = mutistyletext.displayWidth(mode, bytes, dctx);
        if (col < acc + width) return .{ .start = base + g.start, .end = base + g.start + bytes.len };
        acc += width;
    }
    return .{ .start = base + content_len, .end = base + content_len };
}

/// The text widget mode for the output's render mode.
fn textMode(render_mode: Output.RenderMode) mutistyletext.Mode {
    return switch (render_mode) {
        .terminal => .plain,
        .raw => .raw,
    };
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

    /// The mouse selection, if any. Kept (and drawn) after the release until Escape or the
    /// next click.
    selection: ?Selection = null,
    /// Layout of the last frame, used to map mouse cells to text. Null until the first draw.
    geom: ?Geometry = null,

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
                if (try self.handleSelectionMouse(ctx, mouse)) return;
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
                    self.selection = null;
                    ctx.consumeAndRedraw();
                }
                if (clipboardkeys.isCopy(key)) {
                    // copy the current selection again (same chord as the cmd bar)
                    try self.copySelection(ctx);
                    ctx.consumeEvent();
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
            .mouse => |mouse| {
                // Over the border or the gutter this widget is the deepest handler, so the
                // event arrives here (target phase) rather than in `captureHandler`.
                if (try self.handleSelectionMouse(ctx, mouse)) return;
                try self.scroll_bars.handleEvent(ctx, event);
                try self.scroll_bars.scroll_view.handleEvent(ctx, event);
            },
            .mouse_enter, .mouse_leave, .key_press => {
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

    /// Called when the render mode switches between the terminal and raw views. The two views
    /// read different buffers with different line numbering, so no position is carried over:
    /// the view simply follows the bottom again. Any selection belonged to the other buffer.
    pub fn onRenderModeChanged(self: *OutputWidget) void {
        self.scroll_bars.scroll_view.scroll.left = 0;
        self.removePendingLines();
        self.selection = null;
        self.window.is_sticky = true;
        self.window.anchor_pending = true;
    }

    /// Left-button press, drag and release over the text drive a selection; the release
    /// copies it to the clipboard. Returns true when the event was consumed. Events that are
    /// not part of a selection leave no trace, so being called from both the capture and
    /// the target phase for one event is harmless.
    fn handleSelectionMouse(self: *OutputWidget, ctx: *vxfw.EventContext, mouse: vaxis.Mouse) anyerror!bool {
        const geom = self.geom orelse return false;
        const row: i17 = mouse.row;
        const col: i17 = mouse.col;
        switch (mouse.type) {
            .press => {
                if (mouse.button != .left) return false;
                // presses on the border, gutter or scrollbar are not ours
                if (!geom.viewport.contains(row, col)) return false;
                const point = self.pointAtCell(geom, row, col) orelse return false;
                self.selection = .{ .anchor = point, .head = point, .version = self.frame.meta.version };
                ctx.consumeAndRedraw();
                return true;
            },
            .drag => {
                const sel: *Selection = if (self.selection) |*s| s else return false;
                if (!sel.dragging) return false;
                self.autoScrollForDrag(geom, row);
                sel.head = self.pointAtCell(geom, row, col) orelse sel.head;
                sel.moved = true;
                ctx.consumeAndRedraw();
                return true;
            },
            .release => {
                const sel: *Selection = if (self.selection) |*s| s else return false;
                if (!sel.dragging) return false;
                // the button may be reported as `none` on release; any release ends the drag
                sel.head = self.pointAtCell(geom, row, col) orelse sel.head;
                try self.finishSelection(ctx);
                ctx.consumeAndRedraw();
                return true;
            },
            .motion => {
                // motion without a button while "dragging": the button was released outside
                // this widget, where we get no release event
                const sel: *Selection = if (self.selection) |*s| s else return false;
                if (!sel.dragging) return false;
                try self.finishSelection(ctx);
                ctx.consumeAndRedraw();
                return true;
            },
        }
    }

    /// Ends the drag: a plain click clears the selection, a real drag copies it.
    fn finishSelection(self: *OutputWidget, ctx: *vxfw.EventContext) anyerror!void {
        const sel: *Selection = if (self.selection) |*s| s else return;
        sel.dragging = false;
        const r = sel.range();
        if (!sel.moved or r.lo >= r.hi) {
            self.selection = null;
            return;
        }
        try self.copySelection(ctx);
    }

    /// Dragging onto the border row above or below the viewport scrolls one line per event.
    fn autoScrollForDrag(self: *OutputWidget, geom: Geometry, row: i17) void {
        const vp = geom.viewport;
        if (row < vp.row) {
            self.stopFollowing();
            self.moveOutputUpLines(1);
        } else if (row >= vp.row + @as(i17, vp.height)) {
            self.moveOutputDownLines(1);
        }
    }

    /// Absolute filtered byte range of the grapheme drawn at a widget-local mouse cell. The
    /// cell is clamped into the viewport, so dragging over the gutter or border selects from
    /// the first column, and dragging below the text selects to the end of the last row.
    fn pointAtCell(self: *OutputWidget, geom: Geometry, row: i17, col: i17) ?TextPoint {
        const highest = self.highest_row orelse return null;
        const vp = geom.viewport;
        if (vp.width == 0 or vp.height == 0) return null;
        const c_row = std.math.clamp(row, vp.row, vp.row + @as(i17, vp.height) - 1);
        const c_col = std.math.clamp(col, vp.col, vp.col + @as(i17, vp.width) - 1);

        // text-surface coordinates (the surface origin is negative when scrolled)
        const text_row: i17 = c_row - geom.text_origin.row;
        const text_col: i17 = c_col - geom.text_origin.col;
        var trow: usize = @intCast(@max(text_row, 0));
        var tcol: usize = @intCast(@max(text_col, 0));
        if (trow > highest) {
            // below the last rendered row: the end of the last row
            trow = highest;
            tcol = std.math.maxInt(usize);
        }

        const entry = self.row_offsets.get(trow) orelse return null;
        const row_end = if (self.row_offsets.get(trow + 1)) |next| next.ofs else self.frame.text.len;
        if (entry.ofs > row_end or row_end > self.frame.text.len) return null;
        const p = cellToOffsets(self.frame.text[entry.ofs..row_end], entry.ofs, tcol, textMode(self.output.render_mode));
        return .{ .start = p.start + self.frame.base_offset, .end = p.end + self.frame.base_offset };
    }

    /// Copies the selected bytes to the system clipboard (OSC 52). Nothing is copied when the
    /// buffer was reprocessed since the selection was made, as its offsets no longer apply.
    pub fn copySelection(self: *OutputWidget, ctx: *vxfw.EventContext) anyerror!void {
        const sel = self.selection orelse return;
        const r = sel.range();
        if (r.lo >= r.hi) return;
        const copy = try self.output.nonowned_process_buffer.copyRange(self.alloc, self.output.viewBacking(), r.lo, r.hi);
        defer self.alloc.free(copy.bytes);
        if (copy.version != sel.version or copy.bytes.len == 0) return;
        if (builtin.os.tag == .windows) {
            // OSC 52 makes Windows Terminal block on the system clipboard for seconds, during
            // which it delivers no input; write the Win32 clipboard directly instead.
            utils.clipboard.setText(self.alloc, copy.bytes) catch |err| {
                std.log.warn("clipboard: could not copy the selection: {t}", .{err});
            };
        } else {
            try ctx.copyToClipboard(copy.bytes);
        }
    }

    /// Window-relative range of the selection inside `snap`, if it is visible. A selection
    /// made on another buffer version is dropped here.
    fn selectionHighlight(self: *OutputWidget, snap: *const WindowSnapshot) ?ByteRange {
        const sel = self.selection orelse return null;
        if (sel.version != snap.meta.version) {
            self.selection = null;
            return null;
        }
        const r = sel.range();
        const window_end = snap.base_offset + snap.text.len;
        if (r.hi <= snap.base_offset or r.lo >= window_end) return null;
        return .{
            .lo = @max(r.lo, snap.base_offset) - snap.base_offset,
            .hi = @min(r.hi, window_end) - snap.base_offset,
        };
    }

    /// Finds the scroll view's viewport and the text surface's origin in the frame just drawn.
    fn locateGeometry(self: *OutputWidget, root: vxfw.SubSurface) ?Geometry {
        const vp = locateWidget(root.surface, self.scroll_bars.scroll_view.widget()) orelse return null;
        const text = locateWidget(root.surface, self.text.widget()) orelse return null;
        return .{
            .viewport = .{
                .row = vp.origin.row + root.origin.row,
                .col = vp.origin.col + root.origin.col,
                .width = vp.size.width,
                .height = vp.size.height,
            },
            .text_origin = .{
                .row = text.origin.row + root.origin.row,
                .col = text.origin.col + root.origin.col,
            },
        };
    }

    /// Called by the text widget for every rendered row with the window-relative byte
    /// offset of the row's first grapheme.
    fn save_rendered_buffer_offset(ptr: *anyopaque, row: usize, offset: usize, is_start: bool) std.mem.Allocator.Error!void {
        const self: *OutputWidget = @ptrCast(@alignCast(ptr));

        if (self.highest_row == null or self.highest_row.? < row) {
            self.highest_row = row;
        }
        try self.row_offsets.put(self.alloc, row, .{
            .ofs = offset,
            .is_start = is_start,
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
            .backing = self.output.viewBacking(),
        });
        // the buffer may have changed between peek() and the lock; trust the snapshot
        self.window.top_line = snap.top_line;
        self.window.last_draw.process_buffer_len = snap.viewLen();
        self.window.last_draw.process_buffer_num_lines = snap.viewLines();

        if (self.output.searchHighlight(&snap)) |h| {
            snap = try snap.overlay(ctx.arena, h.start, h.end, h.style);
        }
        if (self.selectionHighlight(&snap)) |s| {
            snap = try snap.overlay(ctx.arena, s.lo, s.hi, SelectionStyle);
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
        const gutter_width = self.lines_widget.calculateGutterWidth(snap.viewLines());

        // build the MultiStyleText structure
        const wrap = self.output.wrap_lines;
        self.text = .{
            .text = self.frame.text,
            .styles = &self.frame,
            .cb_ptr = self,
            .cb_buffer_offset_at_row = save_rendered_buffer_offset,
            .softwrap = wrap,
            .max_rows = if (wrap) wrapped_row_cap else std.math.maxInt(u16),
            .mode = textMode(self.output.render_mode),
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
        self.geom = self.locateGeometry(border_child);

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

        const backing = self.output.viewBacking();
        self.last_draw.process_buffer_len = meta.lenOf(backing);
        self.last_draw.process_buffer_num_lines = meta.linesOf(backing);

        // never point past the end of the buffer (a filter may have shrunk it)
        self.top_line = @min(self.top_line, meta.linesOf(backing) -| 1);
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

test "cellToOffsets maps columns to graphemes the way each render mode draws them" {
    const testing = std.testing;
    vxfw.DrawContext.init(.unicode);
    // h(1) é(2) l l o (3) \t (1) x (1) = 8 content bytes, then the line break
    const row = "héllo\tx\n";
    const base: usize = 100;

    // plain mode: a stray control byte is one replacement cell
    try testing.expectEqual(TextPoint{ .start = 100, .end = 101 }, cellToOffsets(row, base, 0, .plain));
    try testing.expectEqual(TextPoint{ .start = 101, .end = 103 }, cellToOffsets(row, base, 1, .plain)); // é
    try testing.expectEqual(TextPoint{ .start = 105, .end = 106 }, cellToOffsets(row, base, 4, .plain)); // o
    try testing.expectEqual(TextPoint{ .start = 106, .end = 107 }, cellToOffsets(row, base, 5, .plain)); // tab
    try testing.expectEqual(TextPoint{ .start = 107, .end = 108 }, cellToOffsets(row, base, 6, .plain)); // x
    try testing.expectEqual(TextPoint{ .start = 108, .end = 108 }, cellToOffsets(row, base, 7, .plain)); // past the content
    try testing.expectEqual(TextPoint{ .start = 108, .end = 108 }, cellToOffsets(row, base, std.math.maxInt(usize), .plain));

    // raw mode: the tab is drawn as `^I`, two cells
    try testing.expectEqual(TextPoint{ .start = 106, .end = 107 }, cellToOffsets(row, base, 5, .raw));
    try testing.expectEqual(TextPoint{ .start = 106, .end = 107 }, cellToOffsets(row, base, 6, .raw));
    try testing.expectEqual(TextPoint{ .start = 107, .end = 108 }, cellToOffsets(row, base, 7, .raw)); // x
    // an invalid byte is `\xNN`, four cells
    try testing.expectEqual(TextPoint{ .start = 1, .end = 2 }, cellToOffsets("a\xffb", 0, 4, .raw));
    try testing.expectEqual(TextPoint{ .start = 2, .end = 3 }, cellToOffsets("a\xffb", 0, 5, .raw));
    // a bare carriage return is content in raw mode, not a line break
    try testing.expectEqual(TextPoint{ .start = 1, .end = 2 }, cellToOffsets("a\rb\n", 0, 2, .raw));

    // double-width graphemes occupy two cells each
    try testing.expectEqual(TextPoint{ .start = 0, .end = 3 }, cellToOffsets("漢字", 0, 1, .plain));
    try testing.expectEqual(TextPoint{ .start = 3, .end = 6 }, cellToOffsets("漢字", 0, 2, .plain));

    // an empty row (just the line break) always maps to its start
    try testing.expectEqual(TextPoint{ .start = 7, .end = 7 }, cellToOffsets("\n", 7, 3, .plain));
    // a wrapped continuation row has no line break; past its content is the next row's start
    try testing.expectEqual(TextPoint{ .start = 9, .end = 9 }, cellToOffsets("ab ", 6, 3, .plain));
}

test "Selection.range includes the grapheme under the head in both directions" {
    const testing = std.testing;
    const a: TextPoint = .{ .start = 10, .end = 11 };
    const b: TextPoint = .{ .start = 20, .end = 23 };

    const forward: Selection = .{ .anchor = a, .head = b, .version = 0 };
    try testing.expectEqual(ByteRange{ .lo = 10, .hi = 23 }, forward.range());

    const backward: Selection = .{ .anchor = b, .head = a, .version = 0 };
    try testing.expectEqual(ByteRange{ .lo = 10, .hi = 23 }, backward.range());

    const same: Selection = .{ .anchor = a, .head = a, .version = 0 };
    try testing.expectEqual(ByteRange{ .lo = 10, .hi = 11 }, same.range());

    // head past the end of a row (empty point) after the anchor: up to that end
    const to_end: Selection = .{ .anchor = a, .head = .{ .start = 30, .end = 30 }, .version = 0 };
    try testing.expectEqual(ByteRange{ .lo = 10, .hi = 30 }, to_end.range());
}

test "locateWidget accumulates origins through nested surfaces" {
    const testing = std.testing;
    const Dummy = struct {
        fn draw(_: *anyopaque, _: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
            unreachable;
        }
    };
    var a: u8 = 0;
    var b: u8 = 0;
    var c: u8 = 0;
    const wa: vxfw.Widget = .{ .userdata = &a, .drawFn = Dummy.draw };
    const wb: vxfw.Widget = .{ .userdata = &b, .drawFn = Dummy.draw };
    const wc: vxfw.Widget = .{ .userdata = &c, .drawFn = Dummy.draw };

    var inner = [_]vxfw.SubSurface{.{
        .origin = .{ .row = -3, .col = 4 },
        .surface = .{ .size = .{ .width = 7, .height = 9 }, .widget = wc, .buffer = &.{}, .children = &.{} },
    }};
    var outer = [_]vxfw.SubSurface{.{
        .origin = .{ .row = 1, .col = 1 },
        .surface = .{ .size = .{ .width = 20, .height = 10 }, .widget = wb, .buffer = &.{}, .children = &inner },
    }};
    const root: vxfw.Surface = .{ .size = .{ .width = 30, .height = 12 }, .widget = wa, .buffer = &.{}, .children = &outer };

    const found_b = locateWidget(root, wb).?;
    try testing.expectEqual(1, found_b.origin.row);
    try testing.expectEqual(1, found_b.origin.col);
    try testing.expectEqual(20, found_b.size.width);

    const found_c = locateWidget(root, wc).?;
    try testing.expectEqual(-2, found_c.origin.row);
    try testing.expectEqual(5, found_c.origin.col);
    try testing.expectEqual(9, found_c.size.height);

    var d: u8 = 0;
    const wd: vxfw.Widget = .{ .userdata = &d, .drawFn = Dummy.draw };
    try testing.expect(locateWidget(root, wd) == null);
}

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
