const std = @import("std");

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const primary_style: vaxis.Style = .{ .bg = .{ .rgb = .{ 10, 10, 10 } } };
const secondary_style: vaxis.Style = .{ .bg = .{ .rgb = .{ 50, 50, 50 } } };

/// What a gutter row shows: the line on it and whether the row is the first row of that line.
pub const RowInfo = struct {
    line: u64,
    is_start: bool = true,
};

pub const LineNumbersWidget = struct {
    alloc: std.mem.Allocator,

    // Key: row, Value: the line shown on it
    line_map: std.AutoHashMap(u64, RowInfo),
    largest_num_width: usize,
    /// Leave the last row empty (the text widget uses it for its horizontal scrollbar).
    reserve_last_row: bool = true,

    pub fn init(alloc: std.mem.Allocator) !*LineNumbersWidget {
        const self = try alloc.create(LineNumbersWidget);
        errdefer alloc.destroy(self);

        self.* = .{
            .alloc = alloc,
            .line_map = .init(alloc),
            .largest_num_width = 0,
        };

        return self;
    }

    pub fn deinit(self: *LineNumbersWidget) void {
        self.line_map.deinit();
        self.alloc.destroy(self);
    }

    pub fn reset(self: *LineNumbersWidget) void {
        self.line_map.clearRetainingCapacity();
        self.largest_num_width = 0;
    }

    pub fn addLine(self: *LineNumbersWidget, row: u64, line_num: u64, is_start: bool) !void {
        try self.line_map.put(row, .{ .line = line_num, .is_start = is_start });
        const num_width = getDecimalWidth(line_num);
        if (num_width > self.largest_num_width) self.largest_num_width = num_width;
    }

    pub fn getDecimalWidth(x: anytype) usize {
        var buf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{}", .{x}) catch unreachable;
        return s.len;
    }

    pub fn calculateGutterWidth(self: *LineNumbersWidget, totalLines: usize) usize {
        const extra_grapheme_width = 2;
        self.largest_num_width = getDecimalWidth(totalLines);
        return self.largest_num_width + extra_grapheme_width;
    }

    fn formatPaddedNumber(buf: []u8, value: u64, str_width: usize) []const u8 {
        // write the number without padding
        const s = std.fmt.bufPrint(buf, "{d}", .{value}) catch unreachable;

        const len = s.len;
        if (len >= str_width) return s;

        const pad = str_width - len;

        // shift the digits to the right
        std.mem.copyBackwards(u8, buf[pad .. pad + len], buf[0..len]);

        // fill left side with spaces
        @memset(buf[0..pad], ' ');

        return buf[0..str_width];
    }

    pub fn widget(self: *LineNumbersWidget) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = LineNumbersWidget.typeErasedEventHandler,
            .captureHandler = null,
            .drawFn = LineNumbersWidget.typeErasedDrawFn,
        };
    }

    pub fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        var self: *LineNumbersWidget = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    pub fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        var self: *LineNumbersWidget = @ptrCast(@alignCast(ptr));
        return self.handleEvent(ctx, event);
    }

    pub fn handleEvent(self: *LineNumbersWidget, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        _ = self;
        _ = ctx;
        _ = event;
    }

    pub fn draw(self: *LineNumbersWidget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const max_size = ctx.max.size();

        const str_width = self.largest_num_width + 2;
        const size: vxfw.Size = .{ .height = max_size.height, .width = @min(max_size.width, @as(u16, @intCast(str_width))) };

        var surf = try vxfw.Surface.init(ctx.arena, self.widget(), size);

        // the last row belongs to the text widget's horizontal scrollbar, when it has one
        const last_row = if (self.reserve_last_row) size.height -| 1 else size.height;

        // Draw line numbers
        var style = secondary_style;
        var row: u16 = 0;
        while (row < last_row) : (row += 1) {
            const line_str = try ctx.arena.alloc(u8, str_width);

            // alternate the style by line, so the rows of one wrapped line form one block
            if (self.line_map.get(row)) |info| {
                style = if (info.line % 2 == 0) primary_style else secondary_style;

                var col: u16 = 0;
                if (info.is_start) {
                    const formated_str = formatPaddedNumber(line_str, info.line, self.largest_num_width);
                    while (col < formated_str.len) : (col += 1) {
                        surf.writeCell(col, row, .{ .char = .{ .grapheme = formated_str[col .. col + 1] }, .style = style });
                    }
                } else {
                    // continuation row of a wrapped line: no number, same background
                    while (col < self.largest_num_width) : (col += 1) {
                        surf.writeCell(col, row, .{ .char = .{ .grapheme = " " }, .style = style });
                    }
                }
                surf.writeCell(col, row, .{ .char = .{ .grapheme = " " }, .style = style });
                col += 1;
                surf.writeCell(col, row, .{ .char = .{ .grapheme = "│" }, .style = style });
            } else {
                var col: u16 = 0;
                while (col < size.width) : (col += 1) {
                    surf.writeCell(col, row, .{ .char = .{ .grapheme = " " } });
                }
            }
        }

        return surf;
    }
};

test "continuation rows of a wrapped line are blank but keep the stripe and separator" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    vxfw.DrawContext.init(.unicode);

    const gutter = try LineNumbersWidget.init(testing.allocator);
    defer gutter.deinit();
    _ = gutter.calculateGutterWidth(12); // two digits wide
    try gutter.addLine(0, 5, true);
    try gutter.addLine(1, 5, false);
    try gutter.addLine(2, 6, true);

    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 10, .height = 4 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    const surf = try gutter.draw(ctx);
    try testing.expectEqual(4, surf.size.width);

    try testing.expectEqualStrings("5", surf.readCell(1, 0).char.grapheme);
    try testing.expectEqualStrings(" ", surf.readCell(1, 1).char.grapheme);
    try testing.expectEqualStrings("│", surf.readCell(3, 1).char.grapheme);
    try testing.expectEqualStrings("6", surf.readCell(1, 2).char.grapheme);
    // both rows of line 5 share one stripe, line 6 gets the other
    try testing.expectEqual(surf.readCell(0, 0).style.bg, surf.readCell(0, 1).style.bg);
    try testing.expect(!std.meta.eql(surf.readCell(0, 0).style.bg, surf.readCell(0, 2).style.bg));
}
