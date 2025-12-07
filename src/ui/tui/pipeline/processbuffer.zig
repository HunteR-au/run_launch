const std = @import("std");
const builtin = @import("builtin");
pub const Pipeline = @import("pipeline.zig");
pub const Filter = @import("filter.zig");
pub const Reviewer = @import("reviewer.zig");
pub const MetaData = Pipeline.MetaData;

pub const ProcessBuffer = struct {
    const Error = error{
        InvalidArguments,
    };
    alloc: std.mem.Allocator,
    m: std.Thread.Mutex,
    buffer: std.ArrayList(u8),
    buffer_newlines: std.ArrayList(usize),
    filtered_buffer: std.ArrayList(u8),
    filtered_newlines: std.ArrayList(usize),
    nonowned_iterators: std.ArrayList(IteratorPtr),
    lastNewLine: usize = 0,
    pipeline: Pipeline,

    pub const IteratorKind = enum {
        lineIterator,
        reverseLineIterator,
    };

    pub const IteratorPtr = union(IteratorKind) {
        lineIterator: *LineIterator,
        reverseLineIterator: *ReverseLineIterator,
    };

    pub fn init(alloc: std.mem.Allocator) !*ProcessBuffer {
        const self = try alloc.create(ProcessBuffer);
        self.* = .{
            .alloc = alloc,
            .m = std.Thread.Mutex{},
            .buffer = std.ArrayList(u8).init(alloc),
            .buffer_newlines = std.ArrayList(usize).init(alloc),
            .filtered_buffer = std.ArrayList(u8).init(alloc),
            .filtered_newlines = std.ArrayList(usize).init(alloc),
            .nonowned_iterators = std.ArrayList(IteratorPtr).init(alloc),
            .pipeline = try Pipeline.init(alloc),
        };
        return self;
    }

    pub fn deinit(self: *ProcessBuffer) void {
        self.buffer.deinit();
        self.nonowned_iterators.deinit();
        self.buffer_newlines.deinit();
        self.filtered_buffer.deinit();
        self.filtered_newlines.deinit();
        self.pipeline.deinit();
        self.alloc.destroy(self);
    }

    fn invalidateAllIterators(self: *ProcessBuffer) void {
        for (self.nonowned_iterators.items) |iter| {
            switch (iter) {
                .lineIterator => |i| {
                    i.invalidate();
                },
                .reverseLineIterator => |i| {
                    i.invalidate();
                },
            }
        }
        self.nonowned_iterators.clearAndFree();
    }

    pub fn append(self: *ProcessBuffer, buf: []const u8) std.mem.Allocator.Error!void {
        self.m.lock();
        defer self.m.unlock();

        try update_newline_indexs(&self.buffer_newlines, buf, self.buffer.items.len);
        try self.buffer.appendSlice(buf);
        try self.processPipeline();
    }

    fn update_newline_indexs(
        newline_cache: *std.ArrayList(usize),
        buf: []const u8,
        offset: usize,
    ) std.mem.Allocator.Error!void {
        for (buf, 0..) |c, i| {
            if (c == '\n') {
                try newline_cache.append(i + offset);
            }
        }
    }

    pub fn processPipeline(self: *ProcessBuffer) !void {
        // pass any new lines into the pipeline
        switch (builtin.target.os.tag) {
            .windows => {
                const sep = "\n";
                const idx = std.mem.lastIndexOf(u8, self.buffer.items, sep);
                if (idx) |i| {
                    if (i <= self.lastNewLine) return;
                    const newlines = self.buffer.items[self.lastNewLine .. i + 1];
                    const filtered_lines = try self.pipeline.runPipeline(
                        self.alloc,
                        newlines,
                        MetaData{ .bufferOffset = self.lastNewLine },
                    );
                    defer self.alloc.free(filtered_lines);
                    self.lastNewLine = i + 1;
                    try update_newline_indexs(
                        &self.filtered_newlines,
                        filtered_lines,
                        self.filtered_buffer.items.len,
                    );
                    try self.filtered_buffer.appendSlice(filtered_lines);
                }
            },
            else => {
                const sep = '\n';
                const idx = std.mem.lastIndexOfScalar(u8, self.buffer.items, sep);
                if (idx) |i| {
                    const newlines = self.buffer.items[self.lastNewLine .. i + 1];
                    const filtered_lines = try self.pipeline.runPipeline(
                        self.alloc,
                        newlines,
                        MetaData{ .bufferOffset = self.lastNewLine },
                    );
                    defer self.alloc.free(filtered_lines);
                    self.lastNewLine = i + 1;
                    try update_newline_indexs(
                        &self.filtered_newlines,
                        filtered_lines,
                        self.filtered_buffer.items.len,
                    );
                    try self.filtered_buffer.appendSlice(filtered_lines);
                }
            },
        }
    }

    fn reprocessPipeline(self: *ProcessBuffer) !void {
        self.filtered_newlines.clearRetainingCapacity();
        self.filtered_buffer.clearRetainingCapacity();
        self.lastNewLine = 0;
        self.invalidateAllIterators();
        try self.processPipeline();
    }

    pub fn addFilter(self: *ProcessBuffer, filter: Filter) !void {
        self.m.lock();
        defer self.m.unlock();

        //std.debug.print("ProcessBuffer:addFilter()\n", .{});

        try self.pipeline.appendFilter(filter);
        try self.reprocessPipeline();
    }

    pub fn removeFilter(self: *ProcessBuffer, id: Filter.HandleId) void {
        self.m.lock();
        defer self.m.unlock();

        const filter = self.pipeline.removeFilter(id);
        if (filter) |f| f.deinit();

        // re-run the buffer through the pipeline
        try self.reprocessPipeline();
    }

    pub fn addReviewer(self: *ProcessBuffer, reviewer: Reviewer) !void {
        self.m.lock();
        defer self.m.unlock();

        try self.pipeline.appendReviewer(reviewer);

        try self.reprocessPipeline();
    }

    pub fn removeReviewer(self: *ProcessBuffer, id: Reviewer.HandleId) !void {
        self.m.lock();
        defer self.m.unlock();

        const reviewer = self.pipeline.reviewReviewer(id);
        if (reviewer) |r| r.deinit();

        try self.reprocessPipeline();
    }

    pub fn removeAllFilters(self: *ProcessBuffer) !void {
        self.m.lock();
        defer self.m.unlock();

        // get all pipeline ids
        var id_array = std.ArrayList(Filter.HandleId).init(self.alloc);
        for (self.pipeline.filters.items) |f| {
            try id_array.append(f.id);
        }
        for (id_array.items) |id| {
            var f = self.pipeline.removeFilter(id);
            if (f != null) f.?.deinit();
        }
        id_array.deinit();
        try self.reprocessPipeline();
    }

    pub fn removeAllReviewers(self: *ProcessBuffer) !void {
        self.m.lock();
        defer self.m.unlock();

        // get all pipeline ids
        var id_array = std.ArrayList(Reviewer.HandleId).init(self.alloc);
        for (self.pipeline.reviewers.items) |r| {
            try id_array.append(r.id);
        }
        for (id_array.items) |id| {
            var r = self.pipeline.removeReviewer(id);
            if (r != null) r.?.deinit();
        }
        id_array.deinit();
        try self.reprocessPipeline();
    }

    pub fn resetPipeline(self: *ProcessBuffer) !void {
        self.m.lock();
        defer self.m.unlock();

        self.pipeline.deinit();
        self.pipeline = try Pipeline.init(self.alloc);
        try self.reprocessPipeline();
    }

    pub fn copyFilteredBuffer(
        self: *ProcessBuffer,
        alloc: std.mem.Allocator,
    ) std.mem.Allocator.Error![]u8 {
        self.m.lock();
        defer self.m.unlock();

        return try alloc.dupe(u8, self.filtered_buffer.items);
    }

    pub fn copyUnfilteredBuffer(
        self: *ProcessBuffer,
        alloc: std.mem.Allocator,
    ) std.mem.Allocator.Error![]u8 {
        self.m.lock();
        defer self.m.unlock();

        return try alloc.dupe(u8, self.filter.items);
    }

    pub fn copyRange(
        self: *ProcessBuffer,
        alloc: std.mem.Allocator,
        offset: usize,
        len: usize,
    ) ![]u8 {
        self.m.lock();
        defer self.m.unlock();

        if (offset + len > self.filtered_buffer.items.len) {
            //std.debug.print("buffer length: {d}, offset: {d}, to_idx: {d}\n", .{
            //    self.buffer.items.len,
            //    offset,
            //    len,
            //});
            return Error.InvalidArguments;
        }
        return try alloc.dupe(u8, self.filtered_buffer.items[offset .. offset + len]);
    }

    pub fn copyUnfilteredRange(
        self: *ProcessBuffer,
        alloc: std.mem.Allocator,
        offset: usize,
        len: usize,
    ) ![]u8 {
        self.m.lock();
        defer self.m.unlock();

        if (offset + len > self.buffer.items.len) {
            return Error.InvalidArguments;
        }
        return try alloc.dupe(u8, self.buffer.items[offset .. offset + len]);
    }

    pub fn getFilteredBufferLength(
        self: *ProcessBuffer,
    ) usize {
        self.m.lock();
        defer self.m.unlock();
        return self.filtered_buffer.items.len;
    }

    pub fn getNumFilteredNewlines(
        self: *ProcessBuffer,
    ) usize {
        self.m.lock();
        defer self.m.unlock();
        return self.filtered_newlines.items.len;
    }

    // newlines count as part of the preceding line
    pub fn getLineFromOffset(self: *ProcessBuffer, offset: usize) usize {
        self.m.lock();
        defer self.m.unlock();
        const filtered_newlines_slice = self.filtered_newlines.items;

        const last_rendered_line = std.sort.lowerBound(
            usize,
            filtered_newlines_slice,
            offset,
            struct {
                pub fn compare(lhs: usize, rhs: usize) std.math.Order {
                    return std.math.order(lhs, rhs);
                }
            }.compare,
        );
        return last_rendered_line;
    }

    const Index = union(enum) {
        idx: usize,
        first: void,
        outOfBounds: void,
    };

    fn calNewlineIndex(self: *ProcessBuffer, line_num: usize) Index {
        if (line_num == 0) return .first;
        if (line_num >= self.lastNewLine) return .outOfBounds;
        return .{ .idx = line_num - 1 };
    }

    // set the offset of the first character of the line
    // TODO: This needs a review
    pub fn getOffsetFromLine(self: *ProcessBuffer, line_num: usize) !usize {
        self.m.lock();
        defer self.m.unlock();
        const idx = self.calNewlineIndex(line_num);
        switch (idx) {
            .idx => |i| {
                const offset = self.filtered_newlines.items[i] + 1;
                return offset;
            },
            .first => return 0,
            .outOfBounds => error.OutOfBounds,
        }
    }

    pub fn createLineIterator(
        self: *ProcessBuffer,
        alloc: std.mem.Allocator,
        kind: IteratorKind,
    ) !LineIterator {
        switch (kind) {
            .lineIterator => return .{ .lineIterator = try LineIterator.init(alloc, self) },
            .reverseLineIterator => return .{ .reverseLineIterator = try ReverseLineIterator.init(alloc, self) },
        }
    }

    //////////////////////////////////
    // Generic functions for Iterators
    //////////////////////////////////
    fn commonPeek(self: anytype, alloc: std.mem.Allocator) !?IteratorResult {
        if (self._invalid.load(.seq_cst)) return error.IteratorInvalid;
        self.process_buffer.m.lock();
        defer self.process_buffer.m.unlock();
        const result = self._peek() orelse return null;
        return .{
            .line = try alloc.dupe(u8, result.line),
            .offset = result.offset,
        };
    }

    fn commonReset(self: anytype, index: IteratorIndex) void {
        if (self._invalid.load(.seq_cst)) return error.IteratorInvalid;
        self.process_buffer.m.lock();
        defer self.process_buffer.m.unlock();
        self.newlines_index = index;
    }

    fn commonInvalidate(self: anytype) void {
        self._invalid.store(true, .seq_cst);
    }

    fn commonInit(comptime T: type, alloc: std.mem.Allocator, pProcessBuffer: *ProcessBuffer) !*T {
        pProcessBuffer.m.lock();
        defer pProcessBuffer.m.unlock();

        //const inital_index: IteratorIndex = if (T == ReverseLineIterator)
        //    pProcessBuffer.filtered_newlines.len + 1
        //else
        //    0;
        const inital_index: IteratorIndex = .start;

        const self = try alloc.create(T);
        self.* = .{
            .alloc = alloc,
            .process_buffer = pProcessBuffer,
            .newlines_index = inital_index,
        };

        if (T == ReverseLineIterator) {
            try self.process_buffer.nonowned_iterators.append(.{ .reverseLineIterator = self });
        } else if (T == LineIterator) {
            try self.process_buffer.nonowned_iterators.append(.{ .lineIterator = self });
        }

        return self;
    }

    fn commonDeinit(self: anytype, comptime kind: IteratorKind) void {
        if (self._invalid.load(.seq_cst)) {
            // we can't touch process_buffer if invalid
            self.alloc.destroy(self);
        } else {
            self.process_buffer.m.lock();
            var mutex = self.process_buffer.m;
            defer mutex.unlock();

            for (self.process_buffer.nonowned_iterators.items, 0..) |iter, i| {
                // BUG: using swapRemove may cause issues while iterating over it
                switch (kind) {
                    .lineIterator => {
                        if (iter == .lineIterator and iter.lineIterator == self)
                            _ = self.process_buffer.nonowned_iterators.swapRemove(i);
                    },
                    .reverseLineIterator => {
                        if (iter == .reverseLineIterator and iter.reverseLineIterator == self)
                            _ = self.process_buffer.nonowned_iterators.swapRemove(i);
                    },
                }
            }
            self.alloc.destroy(self);
        }
    }

    fn commonNext(comptime T: type, self: anytype, alloc: std.mem.Allocator) !?IteratorResult {
        if (self._invalid.load(.seq_cst)) return error.IteratorInvalid;
        self.process_buffer.m.lock();
        defer self.process_buffer.m.unlock();

        if (T == LineIterator) {
            const next_index: IteratorIndex = switch (self.newlines_index) {
                .start => .{ .index = 0 },
                .index => |i| .{ .index = i +| 1 },
                .end => unreachable,
            };
            if (!self._checkBounds(next_index.index)) return null;
            self.newlines_index = next_index;
        } else if (T == ReverseLineIterator) {
            const next_index: IteratorIndex = switch (self.newlines_index) {
                .start => .{ .index = self.process_buffer.filtered_newlines.items.len },
                .index => |i| if (i == 0) .end else .{ .index = i -| 1 },
                .end => return null,
            };

            if (next_index == .end) {
                self.newlines_index = next_index;
                return null;
            } else if (self._checkBounds(next_index.index)) {
                return null;
            } else {
                self.newlines_index = next_index;
            }
        }

        const result = try self._peek() orelse return null;

        return .{
            .line = try alloc.dupe(u8, result.line),
            .buffer_offset = result.buffer_offset,
        };
    }

    fn commonPrev(comptime T: type, self: anytype, alloc: std.mem.Allocator) !?IteratorResult {
        if (self._invalid.load(.seq_cst)) return error.IteratorInvalid;
        self.process_buffer.m.lock();
        defer self.process_buffer.m.unlock();

        if (T == LineIterator) {
            const next_index: IteratorIndex = switch (self.newlines_index) {
                .start => return null,
                .index => |i| if (i == 0) .start else .{ .index = i -| 1 },
                .end => unreachable,
            };

            if (next_index == .start) {
                self.newlines_index = next_index;
                return null;
            } else if (!self._checkBounds(next_index.index)) {
                return null;
            } else {
                self.newlines_index = next_index;
            }
        } else if (T == ReverseLineIterator) {
            const next_index: IteratorIndex = switch (self.newlines_index) {
                .start => return null,
                .index => |i| .{ .index = i +| 1 },
                .end => .{ .index = 0 },
            };

            if (!self._checkBounds(next_index.index)) return null;
            self.newlines_index = next_index;
        }

        const result = try self._peek() orelse return null;

        return .{
            .line = try alloc.dupe(u8, result.line),
            .buffer_offset = result.buffer_offset,
        };
    }

    pub const IteratorResult = struct {
        line: []const u8,
        buffer_offset: usize,
    };

    pub const IteratorIndex = union(enum) {
        start: void,
        end: void,
        index: usize,
    };

    pub const LineIterator = struct {
        alloc: std.mem.Allocator,
        process_buffer: *ProcessBuffer,
        newlines_index: IteratorIndex,
        _invalid: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        pub fn init(alloc: std.mem.Allocator, pProcessBuffer: *ProcessBuffer) !*LineIterator {
            return commonInit(LineIterator, alloc, pProcessBuffer);
        }

        pub fn deinit(self: *LineIterator) void {
            commonDeinit(self, .lineIterator);
        }

        pub fn next(self: *LineIterator, alloc: std.mem.Allocator) !?IteratorResult {
            return commonNext(LineIterator, self, alloc);
        }

        pub fn prev(self: *LineIterator, alloc: std.mem.Allocator) !?IteratorResult {
            return try commonPrev(LineIterator, self, alloc);
        }

        pub fn peek(self: *LineIterator, alloc: std.mem.Allocator) !?IteratorResult {
            return commonPeek(self, alloc);
        }

        pub fn _checkBounds(self: *LineIterator, line_index: usize) bool {
            return if (line_index > self.process_buffer.filtered_newlines.items.len) false else true;
        }

        fn _peek(self: *LineIterator) !?IteratorResult {
            if (self._invalid.load(.seq_cst)) return error.IteratorInvalid;
            if (self.newlines_index == .start) return null;
            if (self.newlines_index == .end) return null;
            if (self.newlines_index.index > self.process_buffer.filtered_newlines.items.len) return null;

            var line_start: usize = undefined;
            var line_end: usize = undefined;

            if (self.newlines_index.index == self.process_buffer.filtered_newlines.items.len) {
                line_end = self.process_buffer.filtered_buffer.items.len;
            } else {
                line_end = self.process_buffer.filtered_newlines.items[self.newlines_index.index];
            }

            if (self.newlines_index.index == 0) {
                line_start = 0;
            } else {
                // TODO: check that +1 doesn't go over buffer length
                line_start = self.process_buffer.filtered_newlines.items[self.newlines_index.index - 1] + 1;
            }

            return .{
                .line = self.process_buffer.filtered_buffer.items[line_start..line_end],
                .buffer_offset = line_start,
            };
        }

        pub fn setLine(self: *LineIterator, line_num: usize) !void {
            self.process_buffer.m.lock();
            defer self.process_buffer.m.unlock();
            // validate that the line number is within bounds
            if (line_num > self.process_buffer.filtered_newlines.items.len) return error.OutOfRange;
            self.newlines_index = .{ .index = line_num };
        }

        pub fn reset(self: *LineIterator) void {
            commonReset(self, 0);
        }

        pub fn invalidate(self: *LineIterator) void {
            commonInvalidate(self);
        }
    };

    pub const ReverseLineIterator = struct {
        alloc: std.mem.Allocator,
        process_buffer: *ProcessBuffer,
        newlines_index: IteratorIndex,
        _invalid: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        pub fn init(alloc: std.mem.Allocator, pProcessBuffer: *ProcessBuffer) !*ReverseLineIterator {
            return commonInit(ReverseLineIterator, alloc, pProcessBuffer);
        }

        pub fn deinit(self: *ReverseLineIterator) void {
            commonDeinit(self, .reverseLineIterator);
        }

        pub fn next(self: *ReverseLineIterator, alloc: std.mem.Allocator) !?IteratorResult {
            return try commonNext(ReverseLineIterator, self, alloc);
        }

        pub fn prev(self: *ReverseLineIterator, alloc: std.mem.Allocator) !?IteratorResult {
            return try commonPrev(ReverseLineIterator, self, alloc);
        }

        pub fn peek(self: *ReverseLineIterator, alloc: std.mem.Allocator) !?IteratorResult {
            return commonPeek(self, alloc);
        }

        fn _checkBounds(self: *ReverseLineIterator, line_index: usize) bool {
            return if (line_index > self.process_buffer.filtered_newlines.items.len) false else true;
        }

        fn _peek(self: *ReverseLineIterator) !?IteratorResult {
            if (self._invalid.load(.seq_cst)) return error.IteratorInvalid;
            //if (self.newlines_index == 0) return null;
            if (self.newlines_index.index > self.process_buffer.filtered_newlines.items.len) return null;

            var line_start: usize = undefined;
            var line_end: usize = undefined;

            if (self.newlines_index.index == self.process_buffer.filtered_newlines.items.len) {
                line_end = self.process_buffer.filtered_buffer.items.len;
            } else {
                line_end = self.process_buffer.filtered_newlines.items[self.newlines_index.index];
            }

            if (self.newlines_index.index == 1) {
                line_start = 0;
            } else {
                line_start = self.process_buffer.filtered_newlines.items[self.newlines_index.index - 1] + 1;
            }

            return .{
                .line = self.process_buffer.filtered_buffer.items[line_start..line_end],
                .buffer_offset = line_start,
            };
        }

        pub fn reset(self: *ReverseLineIterator) void {
            commonReset(self, 0);
        }

        pub fn setLine(self: *ReverseLineIterator, line_num: usize) !void {
            self.process_buffer.m.lock();
            defer self.process_buffer.m.unlock();
            const internal_index = line_num + 1;
            // validate that the line number is within bounds
            if (internal_index > self.process_buffer.filtered_newlines.items.len + 1) return error.OutOfRange;
            self.newlines_index = .{ .index = line_num };
        }

        pub fn invalidate(self: *ReverseLineIterator) void {
            commonInvalidate(self);
        }
    };
};

const testing = std.testing;
test "Line iterator" {
    const alloc = testing.allocator_instance.allocator();
    const input =
        \\Line 1
        \\Line 2
        \\Line 3
        \\Line 4
        \\Line 5
        \\Line 6
    ;

    const process_buffer = try ProcessBuffer.init(alloc);
    defer process_buffer.deinit();

    try process_buffer.append(input);

    var iter = try ProcessBuffer.LineIterator.init(
        alloc,
        process_buffer,
    );
    defer iter.deinit();

    var m = try iter.next(alloc);
    try testing.expectEqualStrings("Line 1", m.?.line);
    alloc.free(m.?.line);

    m = try iter.next(alloc);
    try testing.expectEqualStrings("Line 2", m.?.line);
    alloc.free(m.?.line);

    m = try iter.next(alloc);
    try testing.expectEqualStrings("Line 3", m.?.line);
    alloc.free(m.?.line);

    m = try iter.prev(alloc);
    try testing.expectEqualStrings("Line 2", m.?.line);
    alloc.free(m.?.line);
}
