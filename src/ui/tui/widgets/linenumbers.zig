const std = @import("std");

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const primary_style: vaxis.Style = .{ .bg = .{ .rgb = .{ 10, 10, 10 } } };
const secondary_style: vaxis.Style = .{ .bg = .{ .rgb = .{ 50, 50, 50 } } };

pub const LineNumbersWidget = struct {
    alloc: std.mem.Allocator,

    // Key: row, Value: line number
    line_map: std.AutoHashMap(u64, u64),
    largest_num_width: usize,

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

    pub fn addLine(self: *LineNumbersWidget, row: u64, line_num: u64) !void {
        try self.line_map.put(row, line_num);
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

        // we don't draw anything in the last row of the outputwidget
        const last_row = size.height - 1;

        // Draw line numbers
        var style = secondary_style;
        var row: u16 = 0;
        while (row < last_row) : (row += 1) {
            const line_str = try ctx.arena.alloc(u8, str_width);

            const number = self.line_map.get(row);

            // if number exists, alternate the style
            if (number) |n| {
                style = if (n % 2 == 0) primary_style else secondary_style;

                const formated_str = formatPaddedNumber(line_str, n, self.largest_num_width);
                var col: u16 = 0;
                while (col < formated_str.len) : (col += 1) {
                    surf.writeCell(col, row, .{ .char = .{ .grapheme = formated_str[col .. col + 1] }, .style = style });
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
