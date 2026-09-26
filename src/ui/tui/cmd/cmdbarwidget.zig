const std = @import("std");
const Io = std.Io;
const vaxis = @import("vaxis");
const Cmd = @import("cmd.zig");
const CmdWidget = @import("cmdwidget.zig").CmdWidget;
const HistoryWidget = @import("historywidget.zig").HistoryWidget;
const cmdevents = @import("cmdevents.zig");
const builtin = @import("builtin");
const utils = @import("utils");
const clipboardkeys = @import("../clipboardkeys.zig");

pub const vxfw = vaxis.vxfw;

/// Style painted over mouse-selected text in the bar.
const SelectionStyle: vaxis.Style = .{ .reverse = true };

/// A mouse selection over the bar's text, in grapheme indices (the text field addresses
/// graphemes, not bytes). Like the output panes, the grapheme under the head is included.
pub const BarSelection = struct {
    anchor: usize,
    head: usize,
    /// true between the left button press and its release
    dragging: bool = true,
    /// true once the mouse was dragged to another cell (a plain click only moves the cursor)
    moved: bool = false,
    /// For keyboard selection (Shift+arrows): the cursor boundary the selection grows from,
    /// as a grapheme index in `[0, count]`. Null for a mouse selection.
    boundary_anchor: ?usize = null,

    pub const Range = struct { lo: usize, hi: usize };

    /// A selection between two cursor boundaries, `anchor` and `cursor`; null when they meet.
    pub fn fromBoundaries(anchor: usize, cursor: usize) ?BarSelection {
        if (anchor == cursor) return null;
        // the grapheme fields are inclusive, so the higher boundary steps back by one
        return .{
            .anchor = if (cursor > anchor) anchor else anchor - 1,
            .head = if (cursor > anchor) cursor - 1 else cursor,
            .dragging = false,
            .moved = true,
            .boundary_anchor = anchor,
        };
    }

    /// Half-open grapheme range, clipped to `count` graphemes.
    pub fn range(self: BarSelection, count: usize) Range {
        const lo = @min(@min(self.anchor, self.head), count);
        const hi = @min(@max(self.anchor, self.head) + 1, count);
        return .{ .lo = lo, .hi = @max(lo, hi) };
    }
};

/// Column layout of the text field. Mirrors `vxfw.TextField.draw`, which skips `draw_offset`
/// graphemes (horizontal scroll) and lays the rest out from column 0; a leading ellipsis, when
/// present, overwrites column 0 without shifting the text.
pub const Layout = struct {
    text: []const u8,
    draw_offset: usize,
    width: usize,

    pub const Span = struct { start: usize, end: usize };

    fn width_of(g: []const u8) usize {
        // only the (static) width method is used; no arena or constraints are needed
        const dctx: vxfw.DrawContext = .{ .arena = undefined, .min = .{}, .max = .{}, .cell_size = .{} };
        return dctx.stringWidth(g);
    }

    pub fn graphemeCount(text: []const u8) usize {
        var it = vaxis.unicode.graphemeIterator(text);
        var n: usize = 0;
        while (it.next()) |_| n += 1;
        return n;
    }

    /// Index of the grapheme drawn at `col`, or the grapheme count when `col` is past the text.
    pub fn graphemeAtCol(self: Layout, col: usize) usize {
        var it = vaxis.unicode.graphemeIterator(self.text);
        var i: usize = 0;
        var acc: usize = 0;
        while (it.next()) |g| : (i += 1) {
            if (i < self.draw_offset) continue;
            const w = width_of(g.bytes(self.text));
            if (col < acc + w) return i;
            acc += w;
        }
        return i;
    }

    /// Columns covered by graphemes `[lo, hi)`, clipped to the field; null when none is visible.
    pub fn colSpan(self: Layout, lo: usize, hi: usize) ?Span {
        var it = vaxis.unicode.graphemeIterator(self.text);
        var i: usize = 0;
        var acc: usize = 0;
        var start: ?usize = null;
        var end: usize = 0;
        while (it.next()) |g| : (i += 1) {
            if (i >= hi) break;
            if (i < self.draw_offset) continue;
            const w = width_of(g.bytes(self.text));
            if (i >= lo) {
                if (start == null) start = acc;
                end = acc + w;
            }
            acc += w;
        }
        const s = @min(start orelse return null, self.width);
        const e = @min(end, self.width);
        if (s >= e) return null;
        return .{ .start = s, .end = e };
    }

    /// Byte range of graphemes `[lo, hi)` within `text`.
    pub fn byteRange(text: []const u8, lo: usize, hi: usize) Span {
        var it = vaxis.unicode.graphemeIterator(text);
        var i: usize = 0;
        var start: usize = text.len;
        var end: usize = text.len;
        while (it.next()) |g| : (i += 1) {
            if (i == lo) start = g.start;
            if (i >= lo and i + 1 >= hi) {
                end = if (hi > lo) g.start + g.bytes(text).len else start;
                break;
            }
        }
        if (hi <= lo) return .{ .start = start, .end = start };
        return .{ .start = start, .end = @max(start, end) };
    }
};

/// Pasted text for a one-line field: line breaks become spaces. Caller owns the result.
pub fn sanitizePaste(alloc: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]u8 {
    var out = try std.ArrayList(u8).initCapacity(alloc, text.len);
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '\r') {
            if (i + 1 < text.len and text[i + 1] == '\n') i += 1;
            try out.append(alloc, ' ');
        } else if (c == '\n') {
            try out.append(alloc, ' ');
        } else {
            try out.append(alloc, c);
        }
    }
    return out.toOwnedSlice(alloc);
}

pub const CmdBarWidget = struct {
    alloc: std.mem.Allocator,
    textBox: vxfw.TextField,
    cmd: *Cmd.Cmd,
    //history_view: ?HistoryWidget = null,
    last_history_idx: ?usize = null,
    /// Mouse selection over the text, kept (and drawn) after the release until the text is
    /// edited or the bar is clicked again.
    selection: ?BarSelection = null,
    /// true between bracketed-paste markers: Enter then inserts a space instead of submitting
    in_paste: bool = false,
    /// width of the text field on the last draw (the bar minus its border)
    text_width: u16 = 0,

    pub fn init(alloc: std.mem.Allocator, cmd: *Cmd.Cmd) std.mem.Allocator.Error!*CmdBarWidget {
        var self = try alloc.create(CmdBarWidget);
        self.* = .{
            .alloc = alloc,
            .textBox = vxfw.TextField.init(alloc),
            .cmd = cmd,
        };
        self.textBox.onChange = onChange;
        self.textBox.onSubmit = onSubmit;
        self.textBox.userdata = self;
        return self;
    }

    pub fn deinit(self: *CmdBarWidget) void {
        self.textBox.deinit();
        self.alloc.destroy(self);
        //if (self.history_view) |v| v.deinit(self.alloc);
    }

    pub fn runCmd(self: *CmdBarWidget, io: Io, cmdstr: []u8, ctx: *vxfw.EventContext, event: vxfw.Event) !void {
        // run old style cmds
        try self.cmd.handleCmd(io, cmdstr, .{}, ctx, event);
        self.textBox.clearAndFree();
    }

    pub fn getShadow(self: *CmdBarWidget, prefix: []const u8) ?[]const u8 {
        _ = self;
        _ = prefix;
    }

    pub fn addToBuffer(self: *CmdBarWidget) !void {
        _ = self;
    }

    pub fn removeFromBuffer(self: *CmdBarWidget) !void {
        _ = self;
    }

    pub fn setCmdViaNextHistory(self: *CmdBarWidget) !void {
        if (self.cmd.history.count() == 0) return;

        const history_idx: usize = if (self.last_history_idx) |h| h -| 1 else self.cmd.history.count() - 1;
        const history_buffer = self.cmd.getHistory(history_idx);
        if (history_buffer) |*buf| {
            self.last_history_idx = history_idx;
            self.textBox.clearAndFree();
            try self.textBox.buf.insertSliceAtCursor(buf.*);
        }
    }

    pub fn setCmdViaPrevHistory(self: *CmdBarWidget) !void {
        if (self.last_history_idx == null) {
            // We haven't started searching up the history list
            return;
        } else if (self.last_history_idx == self.cmd.history.count() - 1) {
            // reset history searching
            self.last_history_idx = null;
            self.textBox.clearAndFree();
        } else {
            const history_idx = self.last_history_idx.? +| 1;
            const history_buffer = self.cmd.getHistory(history_idx);
            if (history_buffer) |*buf| {
                self.last_history_idx = history_idx;
                self.textBox.clearAndFree();
                try self.textBox.buf.insertSliceAtCursor(buf.*);
            } else {
                // Something unexpected happened decrementing the history list - reset
                self.last_history_idx = null;
                self.textBox.clearAndFree();
            }
        }
    }

    pub fn setCmdViaHistoryIndex(self: *CmdBarWidget, ctx: *vxfw.EventContext, index: u16) !void {
        const history_buffer = self.cmd.getHistory(@intCast(index));
        if (history_buffer) |*buf| {
            self.last_history_idx = index;
            self.textBox.clearAndFree();
            try self.textBox.buf.insertSliceAtCursor(buf.*);
            try self.checkChanged(ctx);
        }
    }

    /// The text in the bar as the user sees it. The text field is a gap buffer: the bytes
    /// after the cursor live at the far end of its storage and the gap in between holds
    /// stale or uninitialized memory, so the text must be assembled from both halves
    /// rather than read as `buffer[0..realLength()]`. Caller owns the result.
    pub fn commandText(self: *CmdBarWidget) std.mem.Allocator.Error![]u8 {
        return std.mem.concat(self.alloc, u8, &.{
            self.textBox.buf.firstHalf(),
            self.textBox.buf.secondHalf(),
        });
    }

    fn checkChanged(self: *CmdBarWidget, ctx: *vxfw.EventContext) anyerror!void {
        ctx.consumeAndRedraw();
        const new = try self.textBox.buf.dupe();
        defer {
            self.textBox.buf.allocator.free(self.textBox.previous_val);
            self.textBox.previous_val = new;
        }
        if (std.mem.eql(u8, new, self.textBox.previous_val)) return;
        try onChange(self, ctx, new);
    }

    pub fn widget(self: *CmdBarWidget) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = typeErasedEventHandler,
            .drawFn = typeErasedDrawFn,
        };
    }

    // ---- selection, copy and paste ----

    /// `commandText` allocated from any allocator (the draw uses the frame arena).
    fn commandTextWith(self: *CmdBarWidget, alloc: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return std.mem.concat(alloc, u8, &.{
            self.textBox.buf.firstHalf(),
            self.textBox.buf.secondHalf(),
        });
    }

    fn layout(self: *const CmdBarWidget, text: []const u8) Layout {
        return .{ .text = text, .draw_offset = self.textBox.draw_offset, .width = self.text_width };
    }

    /// True while a mouse selection is being dragged.
    pub fn isSelecting(self: *const CmdBarWidget) bool {
        const sel = self.selection orelse return false;
        return sel.dragging;
    }

    /// Mouse events in the bar's own coordinates: the border is row 0 and column 0, the text
    /// sits on row 1 from column 1. A left press puts the cursor under the mouse and anchors
    /// a selection, dragging extends it, the release copies it. Returns true when consumed.
    pub fn handleMouse(self: *CmdBarWidget, ctx: *vxfw.EventContext, mouse: vaxis.Mouse) anyerror!bool {
        const col: usize = @intCast(@max(@as(i32, mouse.col) - 1, 0));
        switch (mouse.type) {
            .press => {
                if (mouse.button != .left or mouse.row != 1) return false;
                const text = try self.commandText();
                defer self.alloc.free(text);
                const idx = self.layout(text).graphemeAtCol(col);
                self.moveCursorToGrapheme(text, idx);
                self.selection = .{ .anchor = idx, .head = idx };
                ctx.consumeAndRedraw();
                return true;
            },
            .drag => {
                const sel: *BarSelection = if (self.selection) |*s| s else return false;
                if (!sel.dragging) return false;
                const text = try self.commandText();
                defer self.alloc.free(text);
                // the row is ignored so dragging above or below the bar keeps selecting
                sel.head = self.layout(text).graphemeAtCol(col);
                sel.moved = true;
                ctx.consumeAndRedraw();
                return true;
            },
            .release, .motion => {
                // motion without a button while "dragging" means the release happened where we
                // could not see it
                const sel: *BarSelection = if (self.selection) |*s| s else return false;
                if (!sel.dragging) return false;
                if (mouse.type == .release) {
                    const text = try self.commandText();
                    defer self.alloc.free(text);
                    sel.head = self.layout(text).graphemeAtCol(col);
                }
                try self.finishSelection(ctx);
                ctx.consumeAndRedraw();
                return true;
            },
        }
    }

    /// Moves the text field's cursor (its gap) to the start of grapheme `idx`.
    fn moveCursorToGrapheme(self: *CmdBarWidget, text: []const u8, idx: usize) void {
        self.moveCursorToByte(Layout.byteRange(text, idx, idx + 1).start);
    }

    /// Deletes the selected text; the cursor ends up where the selection began.
    fn deleteSelection(self: *CmdBarWidget, ctx: *vxfw.EventContext) anyerror!void {
        const sel = self.selection orelse return;
        const text = try self.commandText();
        defer self.alloc.free(text);
        const r = sel.range(Layout.graphemeCount(text));
        const span = Layout.byteRange(text, r.lo, r.hi);
        self.selection = null;
        if (span.end <= span.start) return;
        // same shape as the text field's own word deletion: park the gap at the start of the
        // range and swallow the bytes after it
        self.moveCursorToByte(span.start);
        self.textBox.buf.growGapRight(span.end - span.start);
        self.last_history_idx = null;
        try self.checkChanged(ctx);
    }

    /// Moves the text field's cursor (its gap) to byte offset `target` of the text.
    fn moveCursorToByte(self: *CmdBarWidget, target: usize) void {
        const cursor = self.textBox.buf.cursor;
        if (target < cursor) {
            self.textBox.buf.moveGapLeft(cursor - target);
        } else if (target > cursor) {
            self.textBox.buf.moveGapRight(target - cursor);
        }
    }

    /// Ends the drag: a plain click leaves only the moved cursor, a real drag copies.
    fn finishSelection(self: *CmdBarWidget, ctx: *vxfw.EventContext) anyerror!void {
        const sel: *BarSelection = if (self.selection) |*s| s else return;
        sel.dragging = false;
        if (!sel.moved) {
            self.selection = null;
            return;
        }
        try self.copySelection(ctx);
    }

    /// Copies the selected graphemes; without a selection nothing happens, as in the views.
    pub fn copySelection(self: *CmdBarWidget, ctx: *vxfw.EventContext) anyerror!void {
        const text = try self.commandText();
        defer self.alloc.free(text);
        const bytes = self.selectedBytes(text) orelse return;
        if (bytes.len == 0) return;
        try writeClipboard(ctx, bytes);
    }

    /// The bytes of `text` (the current command text) covered by the selection, or null
    /// when nothing is selected.
    fn selectedBytes(self: *const CmdBarWidget, text: []const u8) ?[]const u8 {
        const sel = self.selection orelse return null;
        const r = sel.range(Layout.graphemeCount(text));
        const span = Layout.byteRange(text, r.lo, r.hi);
        return text[span.start..span.end];
    }

    /// Drops the selection; true when there was one (the first Esc in the bar does this).
    pub fn clearSelection(self: *CmdBarWidget) bool {
        if (self.selection == null) return false;
        self.selection = null;
        return true;
    }

    /// What a key press may change in the text field.
    const EditState = struct { cursor: usize, len: usize };

    fn editState(self: *const CmdBarWidget) EditState {
        return .{ .cursor = self.textBox.buf.cursor, .len = self.textBox.buf.realLength() };
    }

    /// Clears the selection when the text or the cursor moved since `before`.
    fn clearSelectionIfEdited(self: *CmdBarWidget, before: EditState) void {
        const now = self.editState();
        if (now.cursor != before.cursor or now.len != before.len) self.selection = null;
    }

    /// Moves the cursor one grapheme (or one word) and selects everything between the
    /// anchor boundary and the cursor. The anchor is where the cursor stood when the
    /// keyboard selection began; a mouse selection is continued from its far end.
    fn extendSelectionByCursor(self: *CmdBarWidget, direction: enum { left, right }, wordwise: bool) anyerror!void {
        const cursor_before: usize = self.textBox.graphemesBeforeCursor();
        const anchor: usize = if (self.selection) |sel| blk: {
            if (sel.boundary_anchor) |b| break :blk b;
            const text = try self.commandText();
            defer self.alloc.free(text);
            const r = sel.range(Layout.graphemeCount(text));
            break :blk if (cursor_before <= r.lo) r.hi else r.lo;
        } else cursor_before;

        switch (direction) {
            .left => if (wordwise) self.textBox.moveBackwardWordwise() else self.textBox.cursorLeft(),
            .right => if (wordwise) self.textBox.moveForwardWordwise() else self.textBox.cursorRight(),
        }
        const cursor_after: usize = self.textBox.graphemesBeforeCursor();
        self.selection = BarSelection.fromBoundaries(anchor, cursor_after);
    }

    /// Native clipboard on Windows (OSC 52 stalls Windows Terminal), OSC 52 elsewhere.
    fn writeClipboard(ctx: *vxfw.EventContext, bytes: []const u8) anyerror!void {
        if (builtin.os.tag == .windows) {
            utils.clipboard.setText(ctx.alloc, bytes) catch |err| {
                std.log.warn("clipboard: could not copy: {t}", .{err});
            };
        } else {
            try ctx.copyToClipboard(bytes);
        }
    }

    /// Pastes the system clipboard at the cursor. Only the Windows clipboard can be read
    /// directly; elsewhere the terminal's own paste key types the text into the bar.
    pub fn pasteFromClipboard(self: *CmdBarWidget, ctx: *vxfw.EventContext) anyerror!void {
        if (builtin.os.tag != .windows) return;
        const text = utils.clipboard.getText(self.alloc) catch |err| {
            std.log.warn("clipboard: could not paste: {t}", .{err});
            return;
        } orelse return;
        defer self.alloc.free(text);
        try self.pasteText(ctx, text);
    }

    /// Inserts `text` at the cursor as one line: line breaks become spaces.
    pub fn pasteText(self: *CmdBarWidget, ctx: *vxfw.EventContext, text: []const u8) anyerror!void {
        const line = try sanitizePaste(self.alloc, text);
        defer self.alloc.free(line);
        self.selection = null;
        self.last_history_idx = null;
        try self.textBox.insertSliceAtCursor(line);
        try self.checkChanged(ctx);
    }

    /// Reverses the cells of the selected graphemes on the freshly drawn text field surface.
    fn paintSelection(self: *CmdBarWidget, arena: std.mem.Allocator, border_surface: vxfw.Surface) std.mem.Allocator.Error!void {
        const sel = self.selection orelse return;
        const text = try self.commandTextWith(arena);
        const r = sel.range(Layout.graphemeCount(text));
        const span = self.layout(text).colSpan(r.lo, r.hi) orelse return;

        for (border_surface.children) |child| {
            if (!child.surface.widget.eql(self.textBox.widget())) continue;
            const field = child.surface;
            if (field.size.height == 0) return;
            const end = @min(span.end, field.size.width);
            var col = span.start;
            while (col < end) : (col += 1) {
                var cell = field.readCell(col, 0);
                cell.style.reverse = SelectionStyle.reverse;
                field.writeCell(@intCast(col), 0, cell);
            }
            return;
        }
    }

    pub fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        var self: *CmdBarWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    pub fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *CmdBarWidget = @ptrCast(@alignCast(ptr));
        return try self.eventHandler(ctx, event);
    }

    fn onChange(ptr: ?*anyopaque, ctx: *vxfw.EventContext, str: []const u8) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        try self.cmd.view.handleEvent(
            ctx,
            cmdevents.makeEvent(&cmdevents.CmdEvent{
                .cmdbar_change = .{
                    .cmd_str = str,
                },
            }),
        );
    }

    fn onSubmit(ptr: ?*anyopaque, ctx: *vxfw.EventContext, str: []const u8) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        _ = self;
        _ = ctx;
        _ = str;
    }

    pub fn eventHandler(self: *CmdBarWidget, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .paste_start => self.in_paste = true,
            .paste_end => self.in_paste = false,
            .key_press => |key| {
                if (clipboardkeys.isCopy(key)) {
                    try self.copySelection(ctx);
                    return ctx.consumeEvent();
                }
                if (clipboardkeys.isPaste(key)) {
                    try self.pasteFromClipboard(ctx);
                    return ctx.consumeAndRedraw();
                }
                if (self.in_paste and key.matches(vaxis.Key.enter, .{})) {
                    // a line break inside pasted text must not submit the half-pasted command
                    try self.pasteText(ctx, " ");
                    return;
                }
                // Shift+arrows grow or shrink the selection with the cursor, by word with Ctrl
                if (key.matches(vaxis.Key.left, .{ .shift = true }) or key.matches(vaxis.Key.left, .{ .shift = true, .ctrl = true })) {
                    try self.extendSelectionByCursor(.left, key.mods.ctrl);
                    return ctx.consumeAndRedraw();
                }
                if (key.matches(vaxis.Key.right, .{ .shift = true }) or key.matches(vaxis.Key.right, .{ .shift = true, .ctrl = true })) {
                    try self.extendSelectionByCursor(.right, key.mods.ctrl);
                    return ctx.consumeAndRedraw();
                }
                // Backspace and Delete remove the selection; with Ctrl and nothing selected, a word
                if (key.matches(vaxis.Key.backspace, .{}) or key.matches(vaxis.Key.backspace, .{ .ctrl = true }) or
                    key.matches(vaxis.Key.delete, .{}) or key.matches(vaxis.Key.delete, .{ .ctrl = true }))
                {
                    if (self.selection != null) {
                        try self.deleteSelection(ctx);
                        return ctx.consumeAndRedraw();
                    }
                    if (key.mods.ctrl) {
                        self.last_history_idx = null;
                        if (key.codepoint == vaxis.Key.backspace) {
                            self.textBox.deleteWordBefore();
                        } else {
                            self.textBox.deleteWordAfter();
                        }
                        try self.checkChanged(ctx);
                        return ctx.consumeAndRedraw();
                    }
                    // a plain Backspace/Delete with nothing selected: the text field handles it
                }
                // An edit or cursor move invalidates the selection. A key that changes nothing
                // must not: Windows reports the Ctrl of Ctrl+C as its own key press first.
                const before = self.editState();
                defer self.clearSelectionIfEdited(before);
                // Ctrl+arrows jump by word (the text field itself only binds Alt for this)
                if (key.matches(vaxis.Key.left, .{ .ctrl = true })) {
                    self.textBox.moveBackwardWordwise();
                    return ctx.consumeAndRedraw();
                }
                if (key.matches(vaxis.Key.right, .{ .ctrl = true })) {
                    self.textBox.moveForwardWordwise();
                    return ctx.consumeAndRedraw();
                }
                if (key.matches(vaxis.Key.enter, .{})) {
                    const cmdstr = try self.commandText();
                    try self.runCmd(
                        ctx.io,
                        cmdstr,
                        ctx,
                        cmdevents.makeEvent(&cmdevents.CmdEvent{ .run_cmd = .{
                            .cmd_str = cmdstr,
                        } }),
                    );
                    try self.cmd.view.handleEvent(
                        ctx,
                        cmdevents.makeEvent(&cmdevents.CmdEvent{
                            .history_update = .{
                                .cmd_str = cmdstr,
                                .success = true,
                            },
                        }),
                    );
                    self.alloc.free(cmdstr);
                    try self.checkChanged(ctx);
                    return ctx.consumeAndRedraw();
                } else if (key.matches(vaxis.Key.up, .{})) {
                    try self.setCmdViaNextHistory();
                    try self.checkChanged(ctx);
                } else if (key.matches(vaxis.Key.down, .{})) {
                    try self.setCmdViaPrevHistory();
                    try self.checkChanged(ctx);
                } else {
                    self.last_history_idx = null;
                    try self.textBox.handleEvent(ctx, event);
                }
            },
            else => {
                try self.textBox.handleEvent(ctx, event);
            },
        }
    }

    pub fn draw(self: *CmdBarWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const max_size = ctx.max.size();

        const border: vxfw.Border = .{ .child = self.textBox.widget() };

        const border_child: vxfw.SubSurface = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try border.draw(ctx),
        };
        self.text_width = max_size.width -| 2;
        try self.paintSelection(ctx.arena, border_child.surface);

        var children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = border_child;

        return .{
            .size = max_size,
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }
};

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

const testing = std.testing;

test "commandText: editing in the middle of the line submits the whole line, not gap bytes" {
    const alloc = testing.allocator;
    const cmd = try Cmd.Cmd.init(alloc);
    defer cmd.deinit();
    const bar = try CmdBarWidget.init(alloc, cmd);
    defer bar.deinit();

    // recall-style fill, then edit: Left x5 puts the gap inside the text
    try bar.textBox.insertSliceAtCursor("keep apple");
    for (0..5) |_| bar.textBox.cursorLeft();
    try bar.textBox.insertSliceAtCursor("s");
    try testing.expect(bar.textBox.buf.cursor != bar.textBox.buf.realLength());

    const text = try bar.commandText();
    defer alloc.free(text);
    try testing.expectEqualStrings("keep sapple", text);
    try testing.expect(std.unicode.utf8ValidateSlice(text));

    // the old read of buffer[0..realLength] would have returned the gap, not the tail
    const naive = bar.textBox.buf.buffer[0..bar.textBox.buf.realLength()];
    try testing.expect(!std.mem.eql(u8, naive, text));

    // deleting across the gap keeps the two halves consistent too
    bar.textBox.deleteBeforeCursor();
    const text2 = try bar.commandText();
    defer alloc.free(text2);
    try testing.expectEqualStrings("keep apple", text2);
}

test "Layout maps columns to graphemes, honouring the horizontal scroll offset" {
    vxfw.DrawContext.init(.unicode);
    // h é l l o (5 graphemes, 6 bytes) then a double-width 漢
    const text = "héllo漢";
    const plain: Layout = .{ .text = text, .draw_offset = 0, .width = 20 };
    try testing.expectEqual(0, plain.graphemeAtCol(0));
    try testing.expectEqual(1, plain.graphemeAtCol(1));
    try testing.expectEqual(4, plain.graphemeAtCol(4));
    try testing.expectEqual(5, plain.graphemeAtCol(5)); // first cell of 漢
    try testing.expectEqual(5, plain.graphemeAtCol(6)); // second cell of 漢
    try testing.expectEqual(6, plain.graphemeAtCol(7)); // past the text: the count

    // scrolled by two graphemes: column 0 shows 'l'
    const scrolled: Layout = .{ .text = text, .draw_offset = 2, .width = 20 };
    try testing.expectEqual(2, scrolled.graphemeAtCol(0));
    try testing.expectEqual(5, scrolled.graphemeAtCol(3));

    try testing.expectEqual(6, Layout.graphemeCount(text));
}

test "Layout.colSpan gives the cells of a grapheme range and clips to the field" {
    vxfw.DrawContext.init(.unicode);
    const text = "héllo漢";
    const plain: Layout = .{ .text = text, .draw_offset = 0, .width = 20 };
    try testing.expectEqual(Layout.Span{ .start = 1, .end = 3 }, plain.colSpan(1, 3).?);
    try testing.expectEqual(Layout.Span{ .start = 5, .end = 7 }, plain.colSpan(5, 6).?); // the wide grapheme
    try testing.expectEqual(null, plain.colSpan(3, 3)); // empty range

    const narrow: Layout = .{ .text = text, .draw_offset = 0, .width = 4 };
    try testing.expectEqual(Layout.Span{ .start = 2, .end = 4 }, narrow.colSpan(2, 6).?);
    try testing.expectEqual(null, narrow.colSpan(5, 6)); // scrolled out of view

    const scrolled: Layout = .{ .text = text, .draw_offset = 2, .width = 20 };
    try testing.expectEqual(Layout.Span{ .start = 0, .end = 2 }, scrolled.colSpan(0, 4).?); // 'h','é' hidden
}

test "Layout.byteRange returns the bytes of a grapheme range" {
    const text = "héllo漢";
    try testing.expectEqual(Layout.Span{ .start = 0, .end = 1 }, Layout.byteRange(text, 0, 1));
    try testing.expectEqual(Layout.Span{ .start = 1, .end = 3 }, Layout.byteRange(text, 1, 2)); // é
    try testing.expectEqual(Layout.Span{ .start = 3, .end = 9 }, Layout.byteRange(text, 2, 6));
    try testing.expectEqual(Layout.Span{ .start = 3, .end = 9 }, Layout.byteRange(text, 2, 99)); // hi past the end
    try testing.expectEqual(Layout.Span{ .start = 9, .end = 9 }, Layout.byteRange(text, 6, 7)); // lo past the end
    try testing.expectEqual(Layout.Span{ .start = 3, .end = 3 }, Layout.byteRange(text, 2, 2)); // empty
}

test "BarSelection.range includes the head grapheme in both directions and clips" {
    const fwd: BarSelection = .{ .anchor = 2, .head = 5 };
    try testing.expectEqual(BarSelection.Range{ .lo = 2, .hi = 6 }, fwd.range(10));
    const back: BarSelection = .{ .anchor = 5, .head = 2 };
    try testing.expectEqual(BarSelection.Range{ .lo = 2, .hi = 6 }, back.range(10));
    // head past the end of a 4-grapheme text
    const past: BarSelection = .{ .anchor = 1, .head = 9 };
    try testing.expectEqual(BarSelection.Range{ .lo = 1, .hi = 4 }, past.range(4));
}

test "sanitizePaste flattens line breaks into spaces" {
    const a = testing.allocator;
    const one = try sanitizePaste(a, "keep a\r\nb\nc\rd");
    defer a.free(one);
    try testing.expectEqualStrings("keep a b c d", one);
}

test "mouse press moves the cursor and anchors, drag extends the selection" {
    vxfw.DrawContext.init(.unicode);
    const alloc = testing.allocator;
    const cmd = try Cmd.Cmd.init(alloc);
    defer cmd.deinit();
    const bar = try CmdBarWidget.init(alloc, cmd);
    defer bar.deinit();
    var ctx: vxfw.EventContext = .{ .io = testing.io, .alloc = alloc, .cmds = .empty };
    defer ctx.cmds.deinit(alloc);

    try bar.textBox.insertSliceAtCursor("keep apple");
    bar.text_width = 40;

    // click on the 'a' of apple (text column 5 is bar column 6)
    const press: vaxis.Mouse = .{ .col = 6, .row = 1, .button = .left, .mods = .{}, .type = .press };
    try testing.expect(try bar.handleMouse(&ctx, press));
    try testing.expectEqual(5, bar.textBox.buf.cursor);
    try testing.expectEqual(5, bar.selection.?.anchor);
    try testing.expect(bar.selection.?.dragging);

    // drag to the last grapheme
    const drag: vaxis.Mouse = .{ .col = 10, .row = 1, .button = .left, .mods = .{}, .type = .drag };
    try testing.expect(try bar.handleMouse(&ctx, drag));
    try testing.expectEqual(9, bar.selection.?.head);
    try testing.expect(bar.selection.?.moved);
    try testing.expectEqual(BarSelection.Range{ .lo = 5, .hi = 10 }, bar.selection.?.range(10));

    // a press on the border row is not ours
    const border: vaxis.Mouse = .{ .col = 3, .row = 0, .button = .left, .mods = .{}, .type = .press };
    try testing.expect(!try bar.handleMouse(&ctx, border));
}

test "a selection survives a modifier-only key press but not a cursor move" {
    vxfw.DrawContext.init(.unicode);
    const alloc = testing.allocator;
    const cmd = try Cmd.Cmd.init(alloc);
    defer cmd.deinit();
    const bar = try CmdBarWidget.init(alloc, cmd);
    defer bar.deinit();
    var ctx: vxfw.EventContext = .{ .io = testing.io, .alloc = alloc, .cmds = .empty };
    defer ctx.cmds.deinit(alloc);

    try bar.textBox.insertSliceAtCursor("keep apple");
    bar.text_width = 40;
    bar.selection = .{ .anchor = 5, .head = 9, .dragging = false, .moved = true };

    const text = try bar.commandText();
    defer alloc.free(text);
    try testing.expectEqualStrings("apple", bar.selectedBytes(text).?);

    // Windows reports the Ctrl of Ctrl+C as its own key press: nothing changes, keep it
    const ctrl: vaxis.Key = .{ .codepoint = vaxis.Key.left_control, .mods = .{ .ctrl = true } };
    try bar.eventHandler(&ctx, .{ .key_press = ctrl });
    try testing.expect(bar.selection != null);

    // moving the cursor is an edit as far as the selection is concerned
    const left: vaxis.Key = .{ .codepoint = vaxis.Key.left };
    try bar.eventHandler(&ctx, .{ .key_press = left });
    try testing.expect(bar.selection == null);
    try testing.expect(bar.selectedBytes(text) == null);

    // clearSelection reports whether there was anything to clear
    try testing.expect(!bar.clearSelection());
    bar.selection = .{ .anchor = 0, .head = 3 };
    try testing.expect(bar.clearSelection());
    try testing.expect(bar.selection == null);
}

test "BarSelection.fromBoundaries builds an inclusive range from cursor boundaries" {
    try testing.expect(BarSelection.fromBoundaries(4, 4) == null);
    const grow_right = BarSelection.fromBoundaries(4, 7).?;
    try testing.expectEqual(BarSelection.Range{ .lo = 4, .hi = 7 }, grow_right.range(10));
    try testing.expectEqual(4, grow_right.boundary_anchor.?);
    const grow_left = BarSelection.fromBoundaries(7, 4).?;
    try testing.expectEqual(BarSelection.Range{ .lo = 4, .hi = 7 }, grow_left.range(10));
    try testing.expectEqual(7, grow_left.boundary_anchor.?);
}

test "Shift+arrows select with the cursor and Ctrl+arrows jump by word" {
    vxfw.DrawContext.init(.unicode);
    const alloc = testing.allocator;
    const cmd = try Cmd.Cmd.init(alloc);
    defer cmd.deinit();
    const bar = try CmdBarWidget.init(alloc, cmd);
    defer bar.deinit();
    var ctx: vxfw.EventContext = .{ .io = testing.io, .alloc = alloc, .cmds = .empty };
    defer ctx.cmds.deinit(alloc);

    try bar.textBox.insertSliceAtCursor("keep apple");
    bar.text_width = 40;
    const text = try bar.commandText();
    defer alloc.free(text);

    const shift_left: vaxis.Key = .{ .codepoint = vaxis.Key.left, .mods = .{ .shift = true } };
    const shift_right: vaxis.Key = .{ .codepoint = vaxis.Key.right, .mods = .{ .shift = true } };
    const ctrl_left: vaxis.Key = .{ .codepoint = vaxis.Key.left, .mods = .{ .ctrl = true } };
    const ctrl_right: vaxis.Key = .{ .codepoint = vaxis.Key.right, .mods = .{ .ctrl = true } };
    const ctrl_shift_left: vaxis.Key = .{ .codepoint = vaxis.Key.left, .mods = .{ .ctrl = true, .shift = true } };

    // from the end: two Shift+Left select "le", Shift+Right shrinks to "e", again: empty
    try bar.eventHandler(&ctx, .{ .key_press = shift_left });
    try bar.eventHandler(&ctx, .{ .key_press = shift_left });
    try testing.expectEqualStrings("le", bar.selectedBytes(text).?);
    try testing.expectEqual(8, bar.textBox.buf.cursor);
    try bar.eventHandler(&ctx, .{ .key_press = shift_right });
    try testing.expectEqualStrings("e", bar.selectedBytes(text).?);
    try bar.eventHandler(&ctx, .{ .key_press = shift_right });
    try testing.expect(bar.selection == null);
    try testing.expectEqual(10, bar.textBox.buf.cursor);

    // Ctrl+Left jumps to the start of "apple" and keeps nothing selected
    try bar.eventHandler(&ctx, .{ .key_press = ctrl_left });
    try testing.expectEqual(5, bar.textBox.buf.cursor);
    try testing.expect(bar.selection == null);

    // Ctrl+Shift+Left from there selects the previous word plus the space
    try bar.eventHandler(&ctx, .{ .key_press = ctrl_shift_left });
    try testing.expectEqualStrings("keep ", bar.selectedBytes(text).?);
    try testing.expectEqual(0, bar.textBox.buf.cursor);

    // a plain Ctrl+Right is a cursor move: the selection goes away
    try bar.eventHandler(&ctx, .{ .key_press = ctrl_right });
    try testing.expect(bar.selection == null);
    try testing.expect(bar.textBox.buf.cursor > 0);
}

test "Backspace deletes the selection, Ctrl+Backspace deletes a word" {
    vxfw.DrawContext.init(.unicode);
    const alloc = testing.allocator;
    const cmd = try Cmd.Cmd.init(alloc);
    defer cmd.deinit();
    const bar = try CmdBarWidget.init(alloc, cmd);
    defer bar.deinit();
    var ctx: vxfw.EventContext = .{ .io = testing.io, .alloc = alloc, .cmds = .empty };
    defer ctx.cmds.deinit(alloc);

    const backspace: vaxis.Key = .{ .codepoint = vaxis.Key.backspace };
    const ctrl_backspace: vaxis.Key = .{ .codepoint = vaxis.Key.backspace, .mods = .{ .ctrl = true } };
    const delete: vaxis.Key = .{ .codepoint = vaxis.Key.delete };
    const shift_left: vaxis.Key = .{ .codepoint = vaxis.Key.left, .mods = .{ .shift = true } };

    // Ctrl+Backspace with nothing selected removes the word before the cursor
    try bar.textBox.insertSliceAtCursor("keep apple");
    try bar.eventHandler(&ctx, .{ .key_press = ctrl_backspace });
    {
        const text = try bar.commandText();
        defer alloc.free(text);
        try testing.expectEqualStrings("keep ", text);
    }

    // select "pear" with the keyboard, then Backspace removes exactly that
    try bar.textBox.insertSliceAtCursor("pear");
    for (0..4) |_| try bar.eventHandler(&ctx, .{ .key_press = shift_left });
    try bar.eventHandler(&ctx, .{ .key_press = backspace });
    try testing.expect(bar.selection == null);
    try testing.expectEqual(5, bar.textBox.buf.cursor);
    {
        const text = try bar.commandText();
        defer alloc.free(text);
        try testing.expectEqualStrings("keep ", text);
    }

    // a selection in the middle, deleted with Delete, leaves the cursor at its start
    try bar.textBox.insertSliceAtCursor("apple");
    bar.selection = BarSelection.fromBoundaries(1, 3); // "ee"
    try bar.eventHandler(&ctx, .{ .key_press = delete });
    try testing.expectEqual(1, bar.textBox.buf.cursor);
    {
        const text = try bar.commandText();
        defer alloc.free(text);
        try testing.expectEqualStrings("kp apple", text);
    }
}

// Features:
//  --> select a cmdwidget on pressing `/` (done)
//  --> will operate on the currently selected output
//  --> cmds are in the format cmd: args
//  --> remember history, nav history with up and down, (done)
//  --> maybe shadow prediction
//  --> maybe remember buffer for each output
//  --> on notify of buffer change, send an event

// POPUPS
// history list
// hints
//  - if no cmd match, list of commands based on entered input
//  - if cmd, arg format hint AND list of options if they exist

// SHADOW - when added
// list suggestions based on history
