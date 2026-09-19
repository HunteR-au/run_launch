const std = @import("std");
const vaxis = @import("vaxis");

const Allocator = std.mem.Allocator;

const vxfw = vaxis.vxfw;

/// How the bytes of `text` are shown.
pub const Mode = enum {
    /// `text` is presentation text (the filtered buffer): graphemes are drawn as they are.
    /// Stray control bytes or invalid UTF-8 are drawn as U+FFFD so nothing raw reaches the tty.
    plain,
    /// Every byte is visible: C0 controls as `^X`, DEL as `^?`, invalid UTF-8 bytes as `\xNN`.
    /// An escape sequence therefore shows as `^[[31m`.
    raw,
};

/// Reports one rendered row: the byte offset into `text` of the row's first grapheme (the
/// line start for an empty row) and whether the row is the first row of its line.
pub const RowCallback = *const fn (ptr: *anyopaque, row: usize, buffer_ofs: usize, is_start: bool) Allocator.Error!void;

const replacement = "\u{FFFD}";
const hex_digits = "0123456789ABCDEF";
/// `vxfw.Surface.init` allocates `width * height` cells in `u16` arithmetic.
const surface_cells: usize = std.math.maxInt(u16);
const caret_letters = "@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_";

/// One piece of a grapheme that failed UTF-8 validation: either a well-formed sequence or a
/// single invalid byte. The grapheme iterator lumps an invalid lead byte together with the
/// bytes after it, so the valid ones are split back out and drawn normally.
const Segment = struct { end: usize, valid: bool };

fn nextSegment(bytes: []const u8, i: usize) Segment {
    const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch return .{ .end = i + 1, .valid = false };
    if (i + len > bytes.len or !std.unicode.utf8ValidateSlice(bytes[i .. i + len])) {
        return .{ .end = i + 1, .valid = false };
    }
    return .{ .end = i + len, .valid = true };
}

/// Columns one grapheme of the text occupies on screen in `mode`, mirroring how the widget
/// converts it to cells (see `buildLine`). Used by callers that map mouse cells to bytes.
pub fn displayWidth(mode: Mode, grapheme: []const u8, ctx: vxfw.DrawContext) usize {
    if (grapheme.len == 1 and (grapheme[0] < 0x20 or grapheme[0] == 0x7f)) {
        return switch (mode) {
            .raw => 2,
            .plain => 1,
        };
    }
    if (!std.unicode.utf8ValidateSlice(grapheme)) {
        var width: usize = 0;
        var i: usize = 0;
        while (i < grapheme.len) {
            const seg = nextSegment(grapheme, i);
            width += if (seg.valid)
                displayWidth(mode, grapheme[i..seg.end], ctx)
            else switch (mode) {
                .raw => 4,
                .plain => 1,
            };
            i = seg.end;
        }
        return width;
    }
    if (isC1(grapheme)) {
        return switch (mode) {
            .raw => 4 * grapheme.len,
            .plain => 0,
        };
    }
    return @min(ctx.stringWidth(grapheme), 2);
}

/// True for a lone C1 control (U+0080..U+009F), which terminals treat as a control.
fn isC1(grapheme: []const u8) bool {
    if (grapheme.len != 2 or grapheme[0] != 0xc2) return false;
    return grapheme[1] >= 0x80 and grapheme[1] < 0xa0;
}

/// A text widget that paints each grapheme with a style looked up from `StyleSource`.
///
/// `StyleSource` must provide `styleAt(self: *const StyleSource, cursor: *usize, ofs: usize) ?vaxis.Style`
/// where `ofs` is a byte offset into `text`. The widget reports every rendered row through
/// `cb_buffer_offset_at_row` so the caller can map rows back to lines.
///
/// Lines are split on '\n' only. Every drawn cell has a width of at least one column, so the
/// widget's column bookkeeping always agrees with what vaxis writes to the terminal.
pub fn MultiStyleText(comptime StyleSource: type) type {
    comptime {
        if (!@hasDecl(StyleSource, "styleAt")) {
            @compileError("StyleSource must have a 'styleAt' method");
        }
    }

    return struct {
        text: []const u8,
        styles: *const StyleSource,
        cb_ptr: ?*anyopaque = null,
        cb_buffer_offset_at_row: ?RowCallback = null,
        style: vaxis.Style = .{},
        text_align: enum { left, center, right } = .left,
        softwrap: bool = true,
        overflow: enum { ellipsis, clip } = .ellipsis,
        width_basis: enum { parent, longest_line } = .longest_line,
        /// Stop after this many rows (keeps the surface and the scroll offsets bounded).
        max_rows: u16 = std.math.maxInt(u16),
        mode: Mode = .plain,
        /// A line is cut (with an ellipsis) after this many columns, which keeps every width
        /// far from the `u16` limits of the surface.
        max_cols: u16 = 8192,

        const Text = @This();

        /// One drawn grapheme.
        const Cell = struct {
            grapheme: []const u8,
            /// columns, at least 1
            width: u8,
            /// offset into `text` of the byte(s) that produced this cell
            ofs: usize,
            /// a `^X` / `\xNN` marker (raw mode) or a U+FFFD replacement (plain mode)
            marker: bool = false,

            fn isBlank(self: Cell) bool {
                return !self.marker and std.mem.eql(u8, self.grapheme, " ");
            }
        };

        /// One stored line, converted to cells.
        const Line = struct {
            cells: []const Cell,
            /// offset into `text` of the line's first byte
            start: usize,
            /// the column cap was hit
            truncated: bool,
        };

        /// One rendered row: `cells[first..end]` of `lines[line]`.
        const Row = struct {
            line: usize,
            first: usize,
            end: usize,
            width: u16,
            is_start: bool,
        };

        const Prepared = struct {
            lines: []const Line,
            rows: []const Row,
        };

        pub fn widget(self: *const Text) vxfw.Widget {
            return .{
                .userdata = @constCast(self),
                .drawFn = typeErasedDrawFn,
            };
        }

        fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
            const self: *const Text = @ptrCast(@alignCast(ptr));
            return self.draw(ctx);
        }

        fn reportRow(self: *const Text, row: usize, offset: usize, is_start: bool) Allocator.Error!void {
            if (self.cb_ptr) |ptr| {
                if (self.cb_buffer_offset_at_row) |cb| {
                    try cb(ptr, row, offset, is_start);
                }
            }
        }

        pub fn draw(self: *const Text, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
            if (ctx.max.width != null and ctx.max.width.? == 0) {
                return .{
                    .size = ctx.min,
                    .widget = self.widget(),
                    .buffer = &.{},
                    .children = &.{},
                };
            }
            const prepared = try self.prepare(ctx);
            const container_size = self.findContainerSize(prepared, ctx);

            // Create a surface of target width and max height. We'll trim the result after drawing
            const surface = try vxfw.Surface.init(
                ctx.arena,
                self.widget(),
                container_size,
            );
            const base_style: vaxis.Style = .{
                .fg = self.style.fg,
                .bg = self.style.bg,
                .reverse = self.style.reverse,
            };
            const base: vaxis.Cell = .{ .style = base_style };
            @memset(surface.buffer, base);

            var marker_style = self.style;
            marker_style.dim = true;

            var style_cursor: usize = 0;
            var rows_drawn: u16 = 0;
            for (prepared.rows, 0..) |r, row_idx| {
                if (row_idx >= container_size.height) break;
                const row: u16 = @intCast(row_idx);
                rows_drawn = row + 1;

                const line = prepared.lines[r.line];
                const cells = line.cells[r.first..r.end];
                const row_ofs = if (r.is_start) line.start else cells[0].ofs;
                try self.reportRow(row_idx, row_ofs, r.is_start);

                const resolved_width = @min(container_size.width, r.width);
                var col: u16 = switch (self.text_align) {
                    .left => 0,
                    .center => (container_size.width - resolved_width) / 2,
                    .right => container_size.width - resolved_width,
                };
                const overflows = !self.softwrap and (r.width > container_size.width or line.truncated);

                for (cells) |cell| {
                    if (col >= container_size.width) break;
                    const style = self.styles.styleAt(&style_cursor, cell.ofs) orelse
                        (if (cell.marker) marker_style else self.style);

                    if (overflows and self.overflow == .ellipsis and col + cell.width >= container_size.width) {
                        surface.writeCell(col, row, .{
                            .char = .{ .grapheme = "…", .width = 1 },
                            .style = style,
                        });
                        break;
                    }
                    surface.writeCell(col, row, .{
                        .char = .{ .grapheme = cell.grapheme, .width = cell.width },
                        .style = style,
                    });
                    col += cell.width;
                }
            }
            return surface.trimHeight(@max(rows_drawn, ctx.min.height));
        }

        /// Converts the visible lines to cells and rows. Bounded by `max_rows` and the height
        /// constraint, so the work is proportional to what can be shown.
        fn prepare(self: *const Text, ctx: vxfw.DrawContext) Allocator.Error!Prepared {
            var lines: std.ArrayList(Line) = .empty;
            var rows: std.ArrayList(Row) = .empty;

            const wrap_width: u16 = if (self.softwrap) @max(self.wrapContext(ctx).max.width.?, 1) else 0;
            // A vaxis surface holds at most maxInt(u16) cells. Wrapped rows are all `wrap_width`
            // wide, so bound the row count here; unwrapped rows are bounded in width instead
            // (see `findContainerSize`).
            const row_cap: usize = if (self.softwrap)
                @min(self.max_rows, surface_cells / wrap_width)
            else
                self.max_rows;

            var iter: LineIterator = .{ .buf = self.text };
            while (iter.next()) |bytes| {
                if (self.rowsFull(rows.items.len, row_cap, ctx)) break;

                const line_idx = lines.items.len;
                const line = try self.buildLine(ctx, bytes, iter.last_start);
                try lines.append(ctx.arena, line);

                if (self.softwrap) {
                    try self.wrapRows(ctx, line, line_idx, wrap_width, row_cap, &rows);
                } else {
                    var width: usize = 0;
                    for (line.cells) |c| width += c.width;
                    try rows.append(ctx.arena, .{
                        .line = line_idx,
                        .first = 0,
                        .end = line.cells.len,
                        .width = @intCast(width),
                        .is_start = true,
                    });
                }
            }
            return .{ .lines = lines.items, .rows = rows.items };
        }

        fn rowsFull(_: *const Text, rows: usize, row_cap: usize, ctx: vxfw.DrawContext) bool {
            return rows >= row_cap or ctx.max.outsideHeight(@intCast(rows));
        }

        /// Converts one stored line to cells according to `mode`, capped at `max_cols`.
        fn buildLine(self: *const Text, ctx: vxfw.DrawContext, bytes: []const u8, start: usize) Allocator.Error!Line {
            var b: CellBuilder = .{ .arena = ctx.arena, .max_cols = self.max_cols };

            var iter = ctx.graphemeIterator(bytes);
            while (iter.next()) |g| {
                const grapheme = g.bytes(bytes);
                const ofs = start + g.start;

                if (!std.unicode.utf8ValidateSlice(grapheme)) {
                    // draw the well-formed pieces normally and only escape the bad bytes
                    var i: usize = 0;
                    while (i < grapheme.len and !b.truncated) {
                        const seg = nextSegment(grapheme, i);
                        if (seg.valid) {
                            try self.pushGrapheme(ctx, &b, grapheme[i..seg.end], ofs + i);
                        } else switch (self.mode) {
                            .raw => try b.hex(grapheme[i], ofs + i),
                            .plain => try b.push(.{ .grapheme = replacement, .width = 1, .ofs = ofs + i, .marker = true }),
                        }
                        i = seg.end;
                    }
                } else {
                    try self.pushGrapheme(ctx, &b, grapheme, ofs);
                }
                if (b.truncated) break;
            }
            return .{ .cells = b.cells.items, .start = start, .truncated = b.truncated };
        }

        /// Converts one valid-UTF-8 grapheme to cells according to `mode`.
        fn pushGrapheme(self: *const Text, ctx: vxfw.DrawContext, b: *CellBuilder, grapheme: []const u8, ofs: usize) Allocator.Error!void {
            if (grapheme.len == 1 and (grapheme[0] < 0x20 or grapheme[0] == 0x7f)) {
                switch (self.mode) {
                    .raw => try b.caret(grapheme[0], ofs),
                    .plain => try b.push(.{ .grapheme = replacement, .width = 1, .ofs = ofs, .marker = true }),
                }
            } else if (isC1(grapheme)) {
                switch (self.mode) {
                    .raw => for (grapheme, 0..) |byte, i| try b.hex(byte, ofs + i),
                    .plain => {},
                }
            } else {
                const w = ctx.stringWidth(grapheme);
                if (w == 0) {
                    // combining mark, joiner or variation selector on its own
                    if (!b.attach(grapheme)) {
                        switch (self.mode) {
                            .raw => for (grapheme, 0..) |byte, i| try b.hex(byte, ofs + i),
                            .plain => {},
                        }
                    }
                } else {
                    try b.push(.{ .grapheme = grapheme, .width = @intCast(@min(w, 2)), .ofs = ofs });
                }
            }
        }

        const CellBuilder = struct {
            arena: Allocator,
            max_cols: usize,
            cells: std.ArrayList(Cell) = .empty,
            width: usize = 0,
            truncated: bool = false,

            fn push(self: *CellBuilder, cell: Cell) Allocator.Error!void {
                if (self.truncated) return;
                if (self.width + cell.width > self.max_cols) {
                    self.truncated = true;
                    return;
                }
                try self.cells.append(self.arena, cell);
                self.width += cell.width;
            }

            fn caret(self: *CellBuilder, byte: u8, ofs: usize) Allocator.Error!void {
                try self.push(.{ .grapheme = "^", .width = 1, .ofs = ofs, .marker = true });
                const letter = if (byte == 0x7f) "?" else caret_letters[byte .. byte + 1];
                try self.push(.{ .grapheme = letter, .width = 1, .ofs = ofs, .marker = true });
            }

            fn hex(self: *CellBuilder, byte: u8, ofs: usize) Allocator.Error!void {
                try self.push(.{ .grapheme = "\\", .width = 1, .ofs = ofs, .marker = true });
                try self.push(.{ .grapheme = "x", .width = 1, .ofs = ofs, .marker = true });
                try self.push(.{ .grapheme = hex_digits[byte >> 4 .. (byte >> 4) + 1], .width = 1, .ofs = ofs, .marker = true });
                try self.push(.{ .grapheme = hex_digits[byte & 15 .. (byte & 15) + 1], .width = 1, .ofs = ofs, .marker = true });
            }

            /// Appends a zero-width grapheme to the previous cell. Returns false when there is
            /// no cell to attach to (or the previous cell is a marker).
            fn attach(self: *CellBuilder, grapheme: []const u8) bool {
                if (self.cells.items.len == 0) return false;
                const cell = &self.cells.items[self.cells.items.len - 1];
                if (cell.marker) return false;
                // graphemes come from one contiguous line, so the slice simply widens
                if (@intFromPtr(cell.grapheme.ptr) + cell.grapheme.len == @intFromPtr(grapheme.ptr)) {
                    cell.grapheme = cell.grapheme.ptr[0 .. cell.grapheme.len + grapheme.len];
                    return true;
                }
                return false;
            }
        };

        /// Soft-wraps one line's cells into rows of at most `max_width` columns, breaking at
        /// blanks when possible. Trailing blanks are dropped like `trimEnd` used to do.
        fn wrapRows(
            self: *const Text,
            ctx: vxfw.DrawContext,
            line: Line,
            line_idx: usize,
            max_width: u16,
            row_cap: usize,
            rows: *std.ArrayList(Row),
        ) Allocator.Error!void {
            var cells = line.cells;
            while (cells.len > 0 and cells[cells.len - 1].isBlank()) cells.len -= 1;

            if (cells.len == 0) {
                try rows.append(ctx.arena, .{ .line = line_idx, .first = 0, .end = 0, .width = 0, .is_start = true });
                return;
            }

            var idx: usize = 0;
            var first_row = true;
            while (idx < cells.len) {
                if (self.rowsFull(rows.items.len, row_cap, ctx)) return;

                const start = idx;
                var cur_width: usize = 0;
                var end: usize = undefined;
                while (true) {
                    if (idx >= cells.len) {
                        end = idx;
                        break;
                    }
                    const word_end = nextWrap(cells, idx);
                    var word_width: usize = 0;
                    for (cells[idx..word_end]) |c| word_width += c.width;

                    if (cur_width + word_width > max_width) {
                        // Would the word fit on a row of its own once its leading blanks go?
                        var t = idx;
                        while (t < word_end and cells[t].isBlank()) : (t += 1) {}
                        const trimmed_width = word_width - (t - idx); // blanks are one column each
                        if (trimmed_width > max_width) {
                            // No: fit as much of it as possible. A grapheme wider than the
                            // whole row is still consumed on an empty row so progress is made.
                            while (idx < word_end) {
                                const w = cells[idx].width;
                                if (cur_width + w > max_width and cur_width > 0) break;
                                cur_width += w;
                                idx += 1;
                            }
                        }
                        end = idx;
                        // the next row starts at the next word
                        while (idx < cells.len and cells[idx].isBlank()) : (idx += 1) {}
                        break;
                    }
                    idx = word_end;
                    cur_width += word_width;
                }

                try rows.append(ctx.arena, .{
                    .line = line_idx,
                    .first = start,
                    .end = end,
                    .width = @intCast(cur_width),
                    .is_start = first_row,
                });
                first_row = false;
            }
        }

        /// Index just past the word starting at (or after the blanks at) `idx`.
        fn nextWrap(cells: []const Cell, idx: usize) usize {
            var i = idx;
            while (i < cells.len and cells[i].isBlank()) : (i += 1) {}
            while (i < cells.len and !cells[i].isBlank()) : (i += 1) {}
            return i;
        }

        /// Inside a `ScrollView` the child gets no maximum width (`max.width == null`), which
        /// would disable wrapping. Wrap at the minimum width instead: the scroll view sets it to
        /// the viewport width.
        fn wrapContext(self: *const Text, ctx: vxfw.DrawContext) vxfw.DrawContext {
            if (!self.softwrap or ctx.max.width != null) return ctx;
            return ctx.withConstraints(ctx.min, .{ .width = @max(ctx.min.width, 1), .height = ctx.max.height });
        }

        /// Determines the container size from the widest prepared row. The surface is kept
        /// within vaxis' `maxInt(u16)` cell budget: with many rows a very long unwrapped line
        /// is cut (with an ellipsis) rather than overflowing the allocation size.
        fn findContainerSize(self: Text, prepared: Prepared, ctx: vxfw.DrawContext) vxfw.Size {
            var max_width: u16 = ctx.min.width;
            for (prepared.rows) |row| {
                const w = if (ctx.max.width) |max| @min(max, row.width) else row.width;
                max_width = @max(max_width, w);
            }
            const result_width = switch (self.width_basis) {
                .longest_line => blk: {
                    if (ctx.max.width) |max|
                        break :blk @min(max, max_width)
                    else
                        break :blk max_width;
                },
                .parent => blk: {
                    std.debug.assert(ctx.max.width != null);
                    break :blk ctx.max.width.?;
                },
            };
            const rows: u16 = @intCast(prepared.rows.len);
            const height = @max(rows, ctx.min.height);
            const width_cap: u16 = @intCast(@min(surface_cells / @max(height, 1), std.math.maxInt(u16)));
            return .{ .width = @min(result_width, width_cap), .height = height };
        }

        /// Iterates a slice of bytes by '\n'. A trailing line without '\n' is returned too.
        pub const LineIterator = struct {
            buf: []const u8,
            index: usize = 0,
            /// byte offset of the start of the line most recently returned by `next`
            last_start: usize = 0,

            fn next(self: *LineIterator) ?[]const u8 {
                if (self.index >= self.buf.len) return null;

                const start = self.index;
                self.last_start = start;
                const end = std.mem.indexOfScalarPos(u8, self.buf, start, '\n') orelse {
                    self.index = self.buf.len;
                    return self.buf[start..];
                };
                self.index = end + 1;
                return self.buf[start..end];
            }
        };
    };
}

// ----------------------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------------------

const testing = std.testing;

const NoStyles = struct {
    pub fn styleAt(_: *const NoStyles, _: *usize, _: usize) ?vaxis.Style {
        return null;
    }
};

/// Styles `[lo, hi)` with `style`.
const OneRange = struct {
    lo: usize,
    hi: usize,
    style: vaxis.Style,

    pub fn styleAt(self: *const OneRange, _: *usize, ofs: usize) ?vaxis.Style {
        if (ofs >= self.lo and ofs < self.hi) return self.style;
        return null;
    }
};

/// Collects the row reports of a draw.
const RowLog = struct {
    offsets: std.ArrayList(usize) = .empty,
    starts: std.ArrayList(bool) = .empty,

    fn record(ptr: *anyopaque, row: usize, ofs: usize, is_start: bool) Allocator.Error!void {
        const self: *RowLog = @ptrCast(@alignCast(ptr));
        std.debug.assert(row == self.offsets.items.len); // rows are reported in order
        try self.offsets.append(testing.allocator, ofs);
        try self.starts.append(testing.allocator, is_start);
    }

    fn deinit(self: *RowLog) void {
        self.offsets.deinit(testing.allocator);
        self.starts.deinit(testing.allocator);
    }
};

const TestText = MultiStyleText(NoStyles);

const DrawOptions = struct {
    softwrap: bool,
    min_width: u16,
    max_rows: u16 = std.math.maxInt(u16),
    mode: Mode = .plain,
    max_cols: u16 = 8192,
};

/// Draws `text` the way a `ScrollView` child sees it: a minimum width and no maximum width.
fn drawInScrollView(arena: Allocator, log: *RowLog, text: []const u8, softwrap: bool, min_width: u16, max_rows: u16) !vxfw.Surface {
    return drawWith(arena, log, text, .{ .softwrap = softwrap, .min_width = min_width, .max_rows = max_rows });
}

fn drawWith(arena: Allocator, log: *RowLog, text: []const u8, opts: DrawOptions) !vxfw.Surface {
    vxfw.DrawContext.init(.unicode);
    const styles: NoStyles = .{};
    const widget: TestText = .{
        .text = text,
        .styles = &styles,
        .softwrap = opts.softwrap,
        .max_rows = opts.max_rows,
        .mode = opts.mode,
        .max_cols = opts.max_cols,
        .cb_ptr = log,
        .cb_buffer_offset_at_row = RowLog.record,
    };
    const ctx: vxfw.DrawContext = .{
        .arena = arena,
        .min = .{ .width = opts.min_width, .height = 0 },
        .max = .{ .width = null, .height = null },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    return widget.draw(ctx);
}

fn expectCell(surf: vxfw.Surface, col: usize, row: usize, grapheme: []const u8) !void {
    try testing.expectEqualStrings(grapheme, surf.readCell(col, row).char.grapheme);
}

const sample_text = "aaaa bbbb cccc\nd\n\ne";

test "softwrap inside a scroll view wraps at the minimum width and reports row offsets" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var log: RowLog = .{};
    defer log.deinit();

    const surf = try drawInScrollView(arena.allocator(), &log, sample_text, true, 10, std.math.maxInt(u16));
    try testing.expectEqual(10, surf.size.width);
    try testing.expectEqual(5, surf.size.height);
    try testing.expectEqualSlices(usize, &.{ 0, 10, 15, 17, 18 }, log.offsets.items);
    try testing.expectEqualSlices(bool, &.{ true, false, true, true, true }, log.starts.items);
}

test "without softwrap lines are not broken and the surface is as wide as the longest line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var log: RowLog = .{};
    defer log.deinit();

    const surf = try drawInScrollView(arena.allocator(), &log, sample_text, false, 10, std.math.maxInt(u16));
    try testing.expectEqual(14, surf.size.width);
    try testing.expectEqual(4, surf.size.height);
    try testing.expectEqualSlices(usize, &.{ 0, 15, 17, 18 }, log.offsets.items);
}

test "a grapheme wider than the viewport still makes progress" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var log: RowLog = .{};
    defer log.deinit();

    // two double-width CJK graphemes, three bytes each, in a one-column viewport
    const surf = try drawInScrollView(arena.allocator(), &log, "漢字", true, 1, std.math.maxInt(u16));
    try testing.expectEqual(2, surf.size.height);
    try testing.expectEqualSlices(usize, &.{ 0, 3 }, log.offsets.items);
}

test "max_rows bounds the rendered rows" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var log: RowLog = .{};
    defer log.deinit();

    const surf = try drawInScrollView(arena.allocator(), &log, "a\nb\nc", true, 10, 2);
    try testing.expectEqual(2, surf.size.height);
    try testing.expectEqualSlices(usize, &.{ 0, 2 }, log.offsets.items);
}

test "control bytes never reach a cell: plain mode replaces, raw mode shows caret notation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var log: RowLog = .{};
    defer log.deinit();

    const plain = try drawWith(arena.allocator(), &log, "a\x1bb\x07\n", .{ .softwrap = false, .min_width = 1 });
    try testing.expectEqual(4, plain.size.width);
    try expectCell(plain, 0, 0, "a");
    try expectCell(plain, 1, 0, replacement);
    try expectCell(plain, 2, 0, "b");
    try expectCell(plain, 3, 0, replacement);

    var raw_log: RowLog = .{};
    defer raw_log.deinit();
    const raw = try drawWith(arena.allocator(), &raw_log, "a\x1bb\x07\n", .{ .softwrap = false, .min_width = 1, .mode = .raw });
    try testing.expectEqual(6, raw.size.width);
    try expectCell(raw, 1, 0, "^");
    try expectCell(raw, 2, 0, "[");
    try expectCell(raw, 3, 0, "b");
    try expectCell(raw, 4, 0, "^");
    try expectCell(raw, 5, 0, "G");
    try testing.expect(raw.readCell(1, 0).style.dim);
    try testing.expect(!raw.readCell(3, 0).style.dim);
}

test "raw mode shows an escape sequence byte by byte and keeps the row a single line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var log: RowLog = .{};
    defer log.deinit();

    const surf = try drawWith(arena.allocator(), &log, "\x1b[31mred\x1b[0m\nab\rc\n", .{ .softwrap = false, .min_width = 1, .mode = .raw });
    try testing.expectEqual(2, surf.size.height);
    try testing.expectEqual(14, surf.size.width);
    try expectCell(surf, 0, 0, "^");
    try expectCell(surf, 1, 0, "[");
    try expectCell(surf, 5, 0, "m");
    try expectCell(surf, 6, 0, "r");
    try expectCell(surf, 2, 1, "^");
    try expectCell(surf, 3, 1, "M");
    try expectCell(surf, 4, 1, "c");
    try testing.expectEqualSlices(usize, &.{ 0, 13 }, log.offsets.items);
    try testing.expectEqualSlices(bool, &.{ true, true }, log.starts.items);
}

test "a wrapped marker at the start of a line reports the continuation row correctly" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var log: RowLog = .{};
    defer log.deinit();

    // `^[[0m` is 5 columns; a 3-column viewport splits it into `^[[` and `0m`
    const surf = try drawWith(arena.allocator(), &log, "\x1b[0m\n", .{ .softwrap = true, .min_width = 3, .mode = .raw });
    try testing.expectEqual(2, surf.size.height);
    try testing.expectEqualSlices(usize, &.{ 0, 2 }, log.offsets.items);
    try testing.expectEqualSlices(bool, &.{ true, false }, log.starts.items);
}

test "invalid UTF-8 is replaced in plain mode and hex-escaped in raw mode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var log: RowLog = .{};
    defer log.deinit();

    const plain = try drawWith(arena.allocator(), &log, "a\xffb\n", .{ .softwrap = false, .min_width = 1 });
    try testing.expectEqual(3, plain.size.width);
    try expectCell(plain, 1, 0, replacement);

    var raw_log: RowLog = .{};
    defer raw_log.deinit();
    const raw = try drawWith(arena.allocator(), &raw_log, "a\xffb\n", .{ .softwrap = false, .min_width = 1, .mode = .raw });
    try testing.expectEqual(6, raw.size.width);
    try expectCell(raw, 1, 0, "\\");
    try expectCell(raw, 2, 0, "x");
    try expectCell(raw, 3, 0, "F");
    try expectCell(raw, 4, 0, "F");
    try expectCell(raw, 5, 0, "b");

    // a lone lead byte followed by printable text: only the bad byte is escaped
    var lead_log: RowLog = .{};
    defer lead_log.deinit();
    const lead = try drawWith(arena.allocator(), &lead_log, "a\xc3 b\n", .{ .softwrap = false, .min_width = 1, .mode = .raw });
    try testing.expectEqual(7, lead.size.width);
    try expectCell(lead, 1, 0, "\\");
    try expectCell(lead, 4, 0, "3");
    try expectCell(lead, 5, 0, " ");
    try expectCell(lead, 6, 0, "b");
    const dctx: vxfw.DrawContext = .{ .arena = undefined, .min = .{}, .max = .{}, .cell_size = .{} };
    try testing.expectEqual(5, displayWidth(.raw, "\xc3 ", dctx));
    try testing.expectEqual(2, displayWidth(.plain, "\xc3 ", dctx));
}

test "zero-width graphemes attach to the previous cell and never make a width-0 cell" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var log: RowLog = .{};
    defer log.deinit();

    const surf = try drawWith(arena.allocator(), &log, "漢\u{200B}字\n\u{200B}x\n", .{ .softwrap = false, .min_width = 1 });
    try testing.expectEqual(4, surf.size.width);
    try testing.expectEqual(2, surf.readCell(0, 0).char.width);
    try expectCell(surf, 2, 0, "字");
    try expectCell(surf, 0, 1, "x");
}

test "very long lines are cut at max_cols instead of overflowing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var log: RowLog = .{};
    defer log.deinit();

    const long = try arena.allocator().alloc(u8, 9000);
    @memset(long, '\t');
    long[8999] = '\n';

    // 8999 tabs in raw mode is 17998 columns of `^I`
    const surf = try drawWith(arena.allocator(), &log, long, .{ .softwrap = false, .min_width = 1, .mode = .raw, .max_cols = 64 });
    try testing.expectEqual(64, surf.size.width);
    try expectCell(surf, 63, 0, "…");
    try expectCell(surf, 62, 0, "^");

    var wrap_log: RowLog = .{};
    defer wrap_log.deinit();
    const wrapped = try drawWith(arena.allocator(), &wrap_log, long, .{ .softwrap = true, .min_width = 10, .mode = .raw, .max_cols = 64 });
    try testing.expectEqual(7, wrapped.size.height); // 64 columns / 10 per row
    try testing.expect(!wrap_log.starts.items[1]);
}

test "the surface never exceeds the u16 cell budget of vaxis" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var log: RowLog = .{};
    defer log.deinit();

    // 60 lines of 1500 columns: 90000 cells would overflow `width * height`
    var text: std.ArrayList(u8) = .empty;
    for (0..60) |_| {
        try text.appendNTimes(arena.allocator(), 'x', 1500);
        try text.append(arena.allocator(), '\n');
    }

    const surf = try drawWith(arena.allocator(), &log, text.items, .{ .softwrap = false, .min_width = 80 });
    try testing.expectEqual(60, surf.size.height);
    try testing.expect(@as(usize, surf.size.width) * surf.size.height <= std.math.maxInt(u16));
    try expectCell(surf, surf.size.width - 1, 0, "…");

    // wrapped: 1500 columns at 100 per row is 15 rows per line, 900 rows in total, 90000 cells
    var wrap_log: RowLog = .{};
    defer wrap_log.deinit();
    const wrapped = try drawWith(arena.allocator(), &wrap_log, text.items, .{ .softwrap = true, .min_width = 100 });
    try testing.expectEqual(100, wrapped.size.width);
    try testing.expect(@as(usize, wrapped.size.width) * wrapped.size.height <= std.math.maxInt(u16));
    try testing.expectEqual(655, wrapped.size.height);
}

test "leading blanks before a long word no longer underflow the wrap measurement" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var log: RowLog = .{};
    defer log.deinit();

    const surf = try drawWith(arena.allocator(), &log, "ab     cd\n", .{ .softwrap = true, .min_width = 3 });
    try testing.expectEqual(2, surf.size.height);
    try expectCell(surf, 0, 0, "a");
    try expectCell(surf, 0, 1, "c");
    try testing.expectEqualSlices(bool, &.{ true, false }, log.starts.items);
}

test "the style source wins over the base style and applies by byte offset" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    vxfw.DrawContext.init(.unicode);

    const styles: OneRange = .{ .lo = 1, .hi = 3, .style = .{ .bg = .{ .index = 4 } } };
    const widget: MultiStyleText(OneRange) = .{
        .text = "abcd\n",
        .styles = &styles,
        .softwrap = false,
        .mode = .plain,
    };
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{ .width = 1, .height = 0 },
        .max = .{ .width = null, .height = null },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    const surf = try widget.draw(ctx);
    try testing.expect(std.meta.eql(vaxis.Color{ .index = 4 }, surf.readCell(1, 0).style.bg));
    try testing.expect(std.meta.eql(vaxis.Color{ .index = 4 }, surf.readCell(2, 0).style.bg));
    try testing.expect(std.meta.eql(vaxis.Color.default, surf.readCell(0, 0).style.bg));
    try testing.expect(std.meta.eql(vaxis.Color.default, surf.readCell(3, 0).style.bg));
}
