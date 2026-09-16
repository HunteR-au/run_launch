const std = @import("std");
const vaxis = @import("vaxis");

const Allocator = std.mem.Allocator;

const vxfw = vaxis.vxfw;

/// A text widget that paints each grapheme with a style looked up from `StyleSource`.
///
/// `StyleSource` must provide `styleAt(self: *const StyleSource, cursor: *usize, ofs: usize) ?vaxis.Style`
/// where `ofs` is a byte offset into `text`. The widget reports the byte offset of the first
/// grapheme of every rendered row through `cb_buffer_offset_at_row` so the caller can map
/// rows back to lines.
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
        cb_buffer_offset_at_row: ?*const fn (ptr: *anyopaque, row: usize, buffer_ofs: usize) std.mem.Allocator.Error!void = null,
        style: vaxis.Style = .{},
        text_align: enum { left, center, right } = .left,
        softwrap: bool = true,
        overflow: enum { ellipsis, clip } = .ellipsis,
        width_basis: enum { parent, longest_line } = .longest_line,

        const Text = @This();

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

        fn reportRow(self: *const Text, row: usize, offset: usize) Allocator.Error!void {
            if (self.cb_ptr) |ptr| {
                if (self.cb_buffer_offset_at_row) |cb| {
                    try cb(ptr, row, offset);
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

            var style_cursor: usize = 0;
            var row: u16 = 0;
            if (self.softwrap) {
                var iter = SoftwrapIterator.init(self.text, ctx);
                while (iter.next()) |line| {
                    if (row >= container_size.height) break;
                    defer row += 1;

                    // `line.offset` is the byte offset of line.bytes[0] within self.text, which
                    // is correct for soft-wrapped continuation rows too.
                    const row_offset = line.offset;
                    var reported = false;

                    if (line.bytes.len == 0) {
                        try self.reportRow(row, row_offset);
                        reported = true;
                    }

                    var col: u16 = switch (self.text_align) {
                        .left => 0,
                        .center => (container_size.width - line.width) / 2,
                        .right => container_size.width - line.width,
                    };
                    var char_iter = ctx.graphemeIterator(line.bytes);
                    while (char_iter.next()) |char| {
                        const grapheme = char.bytes(line.bytes);
                        const byte_ofs = row_offset + char.start;

                        if (!reported) {
                            try self.reportRow(row, byte_ofs);
                            reported = true;
                        }

                        const style = self.styles.styleAt(&style_cursor, byte_ofs);

                        if (std.mem.eql(u8, grapheme, "\t")) {
                            for (0..8) |i| {
                                surface.writeCell(@intCast(col + i), row, .{
                                    .char = .{ .grapheme = " ", .width = 1 },
                                    .style = if (style) |s| s else self.style,
                                });
                            }
                            col += 8;
                            continue;
                        }
                        const grapheme_width: u8 = @intCast(ctx.stringWidth(grapheme));

                        surface.writeCell(col, row, .{
                            .char = .{ .grapheme = grapheme, .width = grapheme_width },
                            .style = if (style) |s| s else self.style,
                        });
                        col += grapheme_width;
                    }
                }
            } else {
                var line_iter: LineIterator = .{ .buf = self.text };
                while (line_iter.next()) |line| {
                    if (row >= container_size.height) break;
                    defer row += 1;

                    const row_offset = line_iter.last_start;
                    var reported = false;

                    // \t is default 1 wide. We add 7x the count of tab characters to get the full width
                    const line_width = ctx.stringWidth(line) + 7 * std.mem.count(u8, line, "\t");
                    const resolved_line_width = @min(container_size.width, line_width);

                    if (line.len == 0) {
                        try self.reportRow(row, row_offset);
                        reported = true;
                    }

                    var col: u16 = switch (self.text_align) {
                        .left => 0,
                        .center => (container_size.width - resolved_line_width) / 2,
                        .right => container_size.width - resolved_line_width,
                    };
                    var char_iter = ctx.graphemeIterator(line);
                    while (char_iter.next()) |char| {
                        if (col >= container_size.width) break;
                        const grapheme = char.bytes(line);
                        const byte_ofs = row_offset + char.start;
                        const grapheme_width: u8 = @intCast(ctx.stringWidth(grapheme));

                        if (!reported) {
                            try self.reportRow(row, byte_ofs);
                            reported = true;
                        }

                        const style = self.styles.styleAt(&style_cursor, byte_ofs);

                        if (col + grapheme_width >= container_size.width and
                            line_width > container_size.width and
                            self.overflow == .ellipsis)
                        {
                            surface.writeCell(col, row, .{
                                .char = .{ .grapheme = "…", .width = 1 },
                                .style = if (style) |s| s else self.style,
                            });
                            col = container_size.width;
                        } else {
                            surface.writeCell(col, row, .{
                                .char = .{ .grapheme = grapheme, .width = grapheme_width },
                                .style = if (style) |s| s else self.style,
                            });
                            col += @intCast(grapheme_width);
                        }
                    }
                }
            }
            return surface.trimHeight(@max(row, ctx.min.height));
        }

        /// Determines the container size by finding the widest line in the viewable area
        fn findContainerSize(self: Text, ctx: vxfw.DrawContext) vxfw.Size {
            var row: u16 = 0;
            var max_width: u16 = ctx.min.width;
            if (self.softwrap) {
                var iter = SoftwrapIterator.init(self.text, ctx);
                while (iter.next()) |line| {
                    if (ctx.max.outsideHeight(row))
                        break;

                    defer row += 1;
                    max_width = @max(max_width, line.width);
                }
            } else {
                var line_iter: LineIterator = .{ .buf = self.text };
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
            /// byte offset of the start of the line most recently returned by `next`
            last_start: usize = 0,

            fn next(self: *LineIterator) ?[]const u8 {
                if (self.index >= self.buf.len) return null;

                const start = self.index;
                self.last_start = start;
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
            /// byte offset of `line[0]` within the full buffer
            line_start: usize = 0,
            hard_iter: LineIterator,

            pub const Line = struct {
                width: u16,
                bytes: []const u8,
                /// byte offset of `bytes[0]` within the full buffer
                offset: usize,
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
                    self.line = std.mem.trimEnd(u8, self.line, " \t");
                    self.line_start = self.hard_iter.last_start;
                    self.index = 0;
                }

                const start = self.index;
                const offset = self.line_start + start;
                var cur_width: u16 = 0;
                while (self.index < self.line.len) {
                    const idx = self.nextWrap();
                    const word = self.line[self.index..idx];
                    const next_width = self.ctx.stringWidth(word);

                    if (self.ctx.max.width) |max| {
                        if (cur_width + next_width > max) {
                            // Trim the word to see if it can fit on a line by itself
                            const trimmed = std.mem.trimStart(u8, word, " \t");
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
                                        return .{ .width = cur_width, .bytes = self.line[start..end], .offset = offset };
                                    }
                                    cur_width += @intCast(w);
                                    self.index += grapheme.len;
                                }
                            }
                            // We are softwrapping, advance index to the start of the next word
                            const end = self.index;
                            self.index = std.mem.indexOfNonePos(u8, self.line, self.index, soft_breaks) orelse self.line.len;
                            return .{ .width = cur_width, .bytes = self.line[start..end], .offset = offset };
                        }
                    }

                    self.index = idx;
                    cur_width += @intCast(next_width);
                }
                return .{ .width = cur_width, .bytes = self.line[start..], .offset = offset };
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
        };
    };
}
