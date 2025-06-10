const std = @import("std");
// const grapheme = vaxis.grapheme;
const DisplayWidth = @import("DisplayWidth");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

// TODO - refactor the MultiStyle Text and pull out the Buffer code from the widget code
// TODO - the buffer code needs to have some mutex logic for multithreaded code

pub const BufferWriter = struct {
    pub const Error = error{OutOfMemory};
    pub const Writer = std.io.GenericWriter(@This(), Error, write);

    allocator: std.mem.Allocator,
    buffer: *MultiStyleText,
    gd: *const vaxis.grapheme.GraphemeData,
    wd: *const DisplayWidth.DisplayWidthData,

    pub fn write(self: @This(), bytes: []const u8) Error!usize {
        try self.buffer.append(self.allocator, .{
            .bytes = bytes,
            .gd = self.gd,
            .wd = self.wd,
        });
        return bytes.len;
    }
};

pub const MultiStyleText = struct {
    const StyleList = std.ArrayListUnmanaged(vaxis.Style);
    const StyleMap = std.HashMapUnmanaged(usize, usize, std.hash_map.AutoContext(usize), std.hash_map.default_max_load_percentage);

    pub const Content = struct {
        bytes: []const u8,
        gd: *const vaxis.grapheme.GraphemeData,
        wd: *const DisplayWidth.DisplayWidthData,
    };

    pub const Style = struct {
        begin: usize,
        end: usize,
        style: vaxis.Style,
    };

    pub const Error = error{OutOfMemory};

    grapheme: std.MultiArrayList(vaxis.grapheme.Grapheme) = .{},
    content: std.ArrayListUnmanaged(u8) = .{},
    style_list: StyleList = .{},
    style_map: StyleMap = .{},
    rows: usize = 0,
    cols: usize = 0,
    // used when appening to a buffer
    last_cols: usize = 0,

    text_align: enum { left, center, right } = .left,
    softwrap: bool = true,
    overflow: enum { ellipsis, clip } = .ellipsis,
    width_basis: enum { parent, longest_line } = .longest_line,

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        self.style_list.deinit(alloc);
        self.style_map.deinit(alloc);
        self.grapheme.deinit(alloc);
        self.content.deinit(alloc);
        self.* = undefined;
    }

    // Clears all buffers
    pub fn clear(self: *@This(), alloc: std.mem.Allocator) Error!void {
        self.deinit(alloc);
        self.* = .{};
    }

    // Replace the content of buffers, all previous buffer data is lost
    pub fn update(self: *@This(), alloc: std.mem.Allocator, content: Content) Error!void {
        self.clear(alloc);
        errdefer self.clear(alloc);
        try self.append(alloc, content);
    }

    pub fn append(self: *@This(), alloc: std.mem.Allocator, content: Content) Error!void {
        var cols: usize = self.last_cols;
        var iter = vaxis.grapheme.Iterator.init(content.bytes, content.gd);
        const dw: DisplayWidth = .{ .data = content.wd };
        while (iter.next()) |g| {
            try self.grapheme.append(alloc, .{
                .len = g.len,
                .offset = @as(u32, @intCast(self.content.items.len)) + g.offset,
            });
            const cluster = g.bytes(content.bytes);
            if (std.mem.eql(u8, cluster, "\n")) {
                self.cols = @max(self.cols, cols);
                cols = 0;
                continue;
            }
            cols +|= dw.strWidth(cluster);
        }
        try self.content.appendSlice(alloc, content.bytes);
        self.last_cols = cols;
        self.cols = @max(self.cols, cols);
        self.rows +|= std.mem.count(u8, content.bytes, "\n");
    }

    // Clears all styling data.
    pub fn clearStyle(self: *@This(), allocator: std.mem.Allocator) void {
        self.style_list.deinit(allocator);
        self.style_map.deinit(allocator);
    }

    /// Update style for range of the buffer contents.
    pub fn updateStyle(self: *@This(), allocator: std.mem.Allocator, style: Style) Error!void {
        const style_index = blk: {
            for (self.style_list.items, 0..) |s, i| {
                if (std.meta.eql(s, style.style)) {
                    break :blk i;
                }
            }
            try self.style_list.append(allocator, style.style);
            break :blk self.style_list.items.len - 1;
        };
        for (style.begin..style.end) |i| {
            try self.style_map.put(allocator, i, style_index);
        }
    }

    pub fn text(self: *@This()) []u8 {
        return self.content.bytes;
    }

    pub fn writer(
        self: *@This(),
        alloc: std.mem.Allocator,
        gd: *const vaxis.grapheme.GraphemeData,
        wd: *const DisplayWidth.DisplayWidthData,
    ) BufferWriter.Writer {
        return .{
            .context = .{
                .allocator = alloc,
                .buffer = self,
                .gd = gd,
                .wd = wd,
            },
        };
    }

    pub fn widget(self: *MultiStyleText) vxfw.Widget {
        return .{
            .userdata = self,
            .drawFn = MultiStyleText.typeErasedDrawFn,
        };
    }

    fn get_style(self: *MultiStyleText, byte_index: usize) vaxis.Style {
        const style: vaxis.Style = blk: {
            if (self.style_map.get(byte_index)) |style_index| {
                break :blk self.style_list.items[style_index];
            }
            break :blk .{};
        };
        return style;
    }

    pub fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *MultiStyleText = @ptrCast(@alignCast(ptr));
        // if max.height or max.width is null, that means we are expected to take up as much room as needed
        if (ctx.max.width != null and ctx.max.width == 0) {
            return .{
                .size = ctx.min,
                .widget = self.widget(),
                .buffer = &.{},
                .children = &.{},
            };
        }

        // We can calculate the container size using the buffer rather than
        // dynamically calcualting it
        //const size: vxfw.Size = .{
        //    .width = if (ctx.max.width == null) self.cols else @min(self.cols, ctx.max.width.?),
        //    .height = if (ctx.max.height == null) self.rows else @min(self.rows, ctx.max.height.?),
        //};

        // TODO - replace this with buffer cols and rows
        const container_size = self.findContainerSize(ctx);

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

        // This index is used to index into the style map
        var byte_index: usize = 0;

        var row: u16 = 0;
        if (self.softwrap) {
            var iter = SoftwrapIterator.init(self.text(), ctx);
            while (iter.next()) |line| {
                byte_index = iter.index;
                if (row >= container_size.height) break;
                defer row += 1;
                var col: u16 = switch (self.text_align) {
                    .left => 0,
                    .center => (container_size.width - line.width) / 2,
                    .right => container_size.width - line.width,
                };
                var char_iter = ctx.graphemeIterator(line.bytes);
                while (char_iter.next()) |char| {
                    const grapheme = char.bytes(line.bytes);
                    if (std.mem.eql(u8, grapheme, "\t")) {
                        for (0..8) |i| {
                            byte_index = iter.index + char.offset;
                            surface.writeCell(@intCast(col + i), row, .{
                                .char = .{ .grapheme = " ", .width = 1 },
                                .style = self.style,
                            });
                        }
                        col += 8;
                        continue;
                    }
                    const grapheme_width: u8 = @intCast(ctx.stringWidth(grapheme));
                    byte_index = iter.index + char.offset;
                    surface.writeCell(col, row, .{
                        .char = .{ .grapheme = grapheme, .width = grapheme_width },
                        .style = self.style,
                    });
                    col += grapheme_width;
                }
            }
        } else {
            var line_iter: LineIterator = .{ .buf = self.text() };
            while (line_iter.next()) |line| {
                if (row >= container_size.height) break;
                // \t is default 1 wide. We add 7x the count of tab characters to get the full width
                const line_width = ctx.stringWidth(line) + 7 * std.mem.count(u8, line, "\t");
                defer row += 1;
                const resolved_line_width = @min(container_size.width, line_width);
                var col: u16 = switch (self.text_align) {
                    .left => 0,
                    .center => (container_size.width - resolved_line_width) / 2,
                    .right => container_size.width - resolved_line_width,
                };
                var char_iter = ctx.graphemeIterator(line);
                while (char_iter.next()) |char| {
                    if (col >= container_size.width) break;
                    const grapheme = char.bytes(line);
                    const grapheme_width: u8 = @intCast(ctx.stringWidth(grapheme));

                    if (col + grapheme_width >= container_size.width and
                        line_width > container_size.width and
                        self.overflow == .ellipsis)
                    {
                        byte_index = line_iter.index + char.offset;
                        surface.writeCell(col, row, .{
                            .char = .{ .grapheme = "…", .width = 1 },
                            .style = self.style,
                        });
                        col = container_size.width;
                    } else {
                        byte_index = line_iter.index + char.offset;
                        surface.writeCell(col, row, .{
                            .char = .{ .grapheme = grapheme, .width = grapheme_width },
                            .style = self.style,
                        });
                        col += @intCast(grapheme_width);
                    }
                }
            }
        }
        return surface.trimHeight(@max(row, ctx.min.height));
    }

    // pub fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    //     const self: *MultiStyleText = @ptrCast(@alignCast(ptr));
    // }

    // Determines the container size by finding the widest line in the viewable area
    fn findContainerSize(self: *MultiStyleText, ctx: vxfw.DrawContext) vxfw.Size {
        var row: u16 = 0;
        var max_width: u16 = ctx.min.width;
        if (self.softwrap) {
            var iter = SoftwrapIterator.init(self.text(), ctx);
            while (iter.next()) |line| {
                if (ctx.max.outsideHeight(row))
                    break;

                defer row += 1;
                max_width = @max(max_width, line.width);
            }
        } else {
            var line_iter: LineIterator = .{ .buf = self.text() };
            while (line_iter.next()) |line| {
                if (ctx.max.outsideHeight(row))
                    break;
                const line_width: u16 = @truncate(ctx.stringWidth(line));
                defer row += 1;
                const resolved_line_width = if (ctx.max.width) |max|
                    @min(max, line_width)
                else
                    line_width;
                max_width = @max(max_width, resolved_line_width);
            }
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
        return .{ .width = result_width, .height = @max(row, ctx.min.height) };
    }

    /// Iterates a slice of bytes by linebreaks. Lines are split by '\r', '\n', or '\r\n'
    pub const LineIterator = struct {
        buf: []const u8,
        index: usize = 0,

        fn next(self: *LineIterator) ?[]const u8 {
            if (self.index >= self.buf.len) return null;

            const start = self.index;
            const end = std.mem.indexOfAnyPos(u8, self.buf, self.index, "\r\n") orelse {
                self.index = self.buf.len;
                return self.buf[start..];
            };

            self.index = end;
            self.consumeCR();
            self.consumeLF();
            return self.buf[start..end];
        }

        // consumes a \n byte
        fn consumeLF(self: *LineIterator) void {
            if (self.index >= self.buf.len) return;
            if (self.buf[self.index] == '\n') self.index += 1;
        }

        // consumes a \r byte
        fn consumeCR(self: *LineIterator) void {
            if (self.index >= self.buf.len) return;
            if (self.buf[self.index] == '\r') self.index += 1;
        }
    };

    pub const SoftwrapIterator = struct {
        ctx: vxfw.DrawContext,
        line: []const u8 = "",
        index: usize = 0,
        hard_iter: LineIterator,

        pub const Line = struct {
            width: u16,
            bytes: []const u8,
        };

        const soft_breaks = " \t";

        fn init(buf: []const u8, ctx: vxfw.DrawContext) SoftwrapIterator {
            return .{
                .ctx = ctx,
                .hard_iter = .{ .buf = buf },
            };
        }

        fn next(self: *SoftwrapIterator) ?Line {
            // Advance the hard iterator
            if (self.index == self.line.len) {
                self.line = self.hard_iter.next() orelse return null;
                self.line = std.mem.trimRight(u8, self.line, " \t");
                self.index = 0;
            }

            const start = self.index;
            var cur_width: u16 = 0;
            while (self.index < self.line.len) {
                const idx = self.nextWrap();
                const word = self.line[self.index..idx];
                const next_width = self.ctx.stringWidth(word);

                if (self.ctx.max.width) |max| {
                    if (cur_width + next_width > max) {
                        // Trim the word to see if it can fit on a line by itself
                        const trimmed = std.mem.trimLeft(u8, word, " \t");
                        const trimmed_bytes = word.len - trimmed.len;
                        // The number of bytes we trimmed is equal to the reduction in length
                        const trimmed_width = next_width - trimmed_bytes;
                        if (trimmed_width > max) {
                            // Won't fit on line by itself, so fit as much on this line as we can
                            var iter = self.ctx.graphemeIterator(word);
                            while (iter.next()) |item| {
                                const grapheme = item.bytes(word);
                                const w = self.ctx.stringWidth(grapheme);
                                if (cur_width + w > max) {
                                    const end = self.index;
                                    return .{ .width = cur_width, .bytes = self.line[start..end] };
                                }
                                cur_width += @intCast(w);
                                self.index += grapheme.len;
                            }
                        }
                        // We are softwrapping, advance index to the start of the next word
                        const end = self.index;
                        self.index = std.mem.indexOfNonePos(u8, self.line, self.index, soft_breaks) orelse self.line.len;
                        return .{ .width = cur_width, .bytes = self.line[start..end] };
                    }
                }

                self.index = idx;
                cur_width += @intCast(next_width);
            }
            return .{ .width = cur_width, .bytes = self.line[start..] };
        }

        /// Determines the index of the end of the next word
        fn nextWrap(self: *SoftwrapIterator) usize {
            // Find the first linear whitespace char
            const start_pos = std.mem.indexOfNonePos(u8, self.line, self.index, soft_breaks) orelse
                return self.line.len;
            if (std.mem.indexOfAnyPos(u8, self.line, start_pos, soft_breaks)) |idx| {
                return idx;
            }
            return self.line.len;
        }

        // consumes a \n byte
        fn consumeLF(self: *SoftwrapIterator) void {
            if (self.index >= self.buf.len) return;
            if (self.buf[self.index] == '\n') self.index += 1;
        }

        // consumes a \r byte
        fn consumeCR(self: *SoftwrapIterator) void {
            if (self.index >= self.buf.len) return;
            if (self.buf[self.index] == '\r') self.index += 1;
        }
    };
};
