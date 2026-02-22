const std = @import("std");

// what is this actually doing
// I want something that...
// acts as a reader/writer for a buffer that needs to
// track lines + a tail
pub const LineBuffer = struct {
    alloc: std.mem.Allocator,
    buf: std.ArrayList(u8),
    newlines: std.ArrayList(usize),

    pub fn init(alloc: std.mem.Allocator) !LineBuffer {
        return .{
            .alloc = alloc,
            .buf = try .initCapacity(alloc, 100),
            .newlines = try .initCapacity(alloc, 100),
        };
    }

    pub fn fromOwnedSlice(alloc: std.mem.Allocator, buf: []u8) !LineBuffer {
        var newlines_array: std.ArrayList(u8) = .initCapacity(alloc, 0);
        for (buf, 0..) |char, idx| {
            if (char == '\n') {
                try newlines_array.append(alloc, idx);
            }
        }

        return .{ .alloc = alloc, .buf = .fromOwnedSlice(buf), .newlines = .fromOwnedSlice(try newlines_array.toOwnedSlice(alloc)) };
    }

    pub fn deinit(self: *LineBuffer) void {
        self.buf.deinit(self.alloc);
        self.newlines.deinit(self.alloc);
    }

    pub fn append(self: *LineBuffer, buf: []const u8) !void {
        try self.updateNewlines(buf);
        try self.buf.appendSlice(self.alloc, buf);
    }

    pub fn clearRetainingCapacity(self: *LineBuffer) void {
        self.buf.clearRetainingCapacity();
        self.newlines.clearRetainingCapacity();
    }

    ///////////////////
    // HELPER FUNCTIONS
    ///////////////////

    pub fn count(self: *LineBuffer) usize {
        if (self.newlines.items.len > 0) {
            if (self.hasTail()) {
                return self.getLines().?.len;
            } else {
                return self.buf.items.len;
            }
        } else {
            return 0;
        }
    }

    pub fn countWithTail(self: *LineBuffer) usize {
        return self.buf.items.len;
    }

    pub fn countLines(self: *LineBuffer) usize {
        return self.newlines.items.len;
    }

    pub fn getLines(self: *LineBuffer) ?[]const u8 {
        if (self.isEmpty()) return null;

        return self.buf.items[0 .. self.newlines.items[self.newlines.items.len - 1] + 1];
    }

    pub fn getLine(self: *LineBuffer, line_number: usize) ?[]const u8 {
        if (self.isEmpty()) return null;
        if (!self.isValidLineIndex(line_number)) return null;
        return self.buf.items[self.lineIndex(line_number) .. self.lineIndex(line_number + 1) - 1];
    }

    pub fn getLineIndexFromOffset(self: *LineBuffer, offset: usize) ?usize {
        if (self.isEmpty()) return null;
        // we don't consider the tail a line, so if the index is part of the tail or
        // past the buffer return null
        if (offset >= self.getLines().?.len) return null;

        const newline_index = std.sort.lowerBound(
            usize,
            self.newlines.items,
            offset,
            struct {
                pub fn compare(lhs: usize, rhs: usize) std.math.Order {
                    return std.math.order(lhs, rhs);
                }
            }.compare,
        );
        // check if offset is larger than any newline positions
        if (newline_index == self.newlines.items.len) return null;

        return newline_index;
    }

    pub fn getLineFromOffset(self: *LineBuffer, offset: usize) ?[]u8 {
        if (self.isEmpty()) return null;

        if (offset >= self.tailIndex()) return null;
        const newline_index = std.sort.lowerBound(
            usize,
            self.newlines.items,
            offset,
            struct {
                pub fn compare(lhs: usize, rhs: usize) std.math.Order {
                    return std.math.order(lhs, rhs);
                }
            }.compare,
        );
        if (newline_index == self.newlines.len) return null;
        return self.getLine(newline_index);
    }

    pub fn getLinesStartingFrom(self: *LineBuffer, startingLine: usize) ?[]const u8 {
        if (self.isEmpty()) {
            std.log.debug("Called LineBuffer:getLinesStartingFrom() when buffer empty", .{});
            return null;
        }
        if (!self.isValidLineIndex(startingLine)) {
            std.log.debug("Called LineBuffer:getLinesStartingFrom() with invalid line index {d}", .{startingLine});
            return null;
        }

        const line_index = self.getIndexOfLine(startingLine).?;
        const end_of_lastline_index = self.tailIndex().?;

        return self.buf.items[line_index..end_of_lastline_index];
    }

    pub fn getIndexOfLine(self: *LineBuffer, line_number: usize) ?usize {
        if (!self.isValidLineIndex(line_number)) return null;
        return self.lineIndex(line_number);
    }

    pub fn getLineEndIndex(self: *LineBuffer, line_number: usize) ?usize {
        if (self.isEmpty()) return null;
        if (!self.isValidLineIndex(line_number)) return null;
        return self.lineIndex(line_number) + self.getLine(line_number).?.len;
    }

    pub fn hasTail(self: *LineBuffer) bool {
        if (self.newlines.items.len == 0)
            return self.buf.items.len > 0;

        return self.newlines.items[self.newlines.items.len - 1] + 1 < self.buf.items.len;
    }

    pub fn getTail(self: *LineBuffer) ?[]const u8 {
        if (self.hasTail()) {
            return self.buf.items[self.tailIndex().?..self.buf.items.len];
        }
        return null;
    }

    pub fn tailIndex(self: LineBuffer) ?usize {
        if (self.isEmpty()) return null;

        if (self.newlines.items.len > 0)
            return self.newlines.items[self.newlines.items.len - 1] + 1
        else
            return 0;
    }

    fn updateNewlines(self: *LineBuffer, buf: []const u8) !void {
        const current_buf_length = self.buf.items.len;

        for (buf, 0..) |char, idx| {
            if (char == '\n') {
                try self.newlines.append(self.alloc, idx + current_buf_length);
            }
        }
    }

    // A helper function without validation that returns either idx 0 or the index after a newline
    // for the nth line
    fn lineIndex(self: LineBuffer, line_num: usize) usize {
        return if (line_num == 0) 0 else self.newlines.items[line_num - 1] + 1;
    }

    fn isEmpty(self: LineBuffer) bool {
        return if (self.buf.items.len == 0) true else false;
    }

    fn isValidLineIndex(self: LineBuffer, line_index: usize) bool {
        if (self.isEmpty()) return false;
        // we only consider a line if it ends with a newline, therefore if no newlines
        // there is no valid lines
        if (self.newlines.items.len == 0) return false;
        if (self.newlines.items.len <= line_index) return false;
        return true;
    }
};

// REPROCESSING

// looking at ProcessBuffer I really don't like how it is structured
// should seperate concerns...

// how would I make filtered_buffer

// var buffer = LineBuffer.init(alloc);
// var filtered_buffer = LineBuffer.init(alloc);

// // run the transformers on all "lines" (ie ending with a newline)
// // note: we need to track the index
// const last_count = buffer.countLines();
// if (buffer.getLines()) |lines| {
//     const filtered_lines: [] u8 = runPipeline(self.alloc, buffer.getLines());
//     //assert last char fo filtered_lines
// } else {
//     const filtered_lines = "";
// }

// const filtered_buffer: LineBuffer = .fromOwnedSlice(alloc, filtered_buffer);

// // PROCESSING
// const new_count = buffer.countLines();
// if (new_count > last_count) {
//     const new_filtered_lines: [] u8 = runPipeline(self.alloc, buffer.getLines());
//     defer self.alloc.free(new_filtered_lines);
//     try filtered_buffer.append(new_filtered_lines);
// }

// if setting is to show the tail -
