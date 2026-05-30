const std = @import("std");
const builtin = @import("builtin");
pub const Pipeline = @import("pipeline.zig");
pub const Filter = @import("filter.zig");
pub const Reviewer = @import("reviewer.zig");
pub const LineBuffer = @import("linebuffer.zig").LineBuffer;
pub const LineTimeStamps = @import("linetimestamps.zig").LineTimeStamps;
pub const linesAndMeta = @import("linesandmeta.zig").LinesAndMeta;
pub const MetaData = Pipeline.MetaData;

const Buffer = @import("buffer/buffer.zig");
const GraphHandle = Buffer.GraphHandle;
const BufferGraph = Buffer.BufferGraph;

const Graph = struct {
    ptr: *BufferGraph,
    handle: GraphHandle,

    pub fn get(self: *Graph) ?*BufferGraph.Node {
        return self.ptr.get(self.handle);
    }
};

const IteratorsCommon = @import("iterators/iterator_common.zig");
const Iterators = @import("iterators/generic_lineiterators.zig");

// TODO:
//      - now have to consider MetaLineBuffers interface
//      - I'm working on merging multiple ProcessBuffers based on timestamp
//      - Means I'll have a tree of of ProcessBuffers... and have to track that
//      - I'll also have to create merged outputviews (and kill them)
//      - I'll have to think about if I'm doing a full buffer copy (that keeps updated)
// IDEA: create a tagged enum on a LineBuffer and a LineBufferView to enable saving memory

pub const ProcessBuffer = struct {
    const Error = error{
        InvalidArguments,
    };
    alloc: std.mem.Allocator,
    m: std.Thread.Mutex,
    buffer: *LineBuffer,
    line_timestamps: *LineTimeStamps,
    filtered_buffer: LineBuffer,
    lastNewLine: usize = 0,
    lines_processed: usize = 0,
    pipeline: Pipeline,
    merge_graph: ?Graph = null,

    nonowned_iterators: std.ArrayList(IteratorsCommon.IteratorRecord),

    // Create a generic iterator for iterating over lines
    const IteratorTypes = Iterators.LineIteratorsClass(
        @This(),
        "filtered_buffer",
        "nonowned_iterators",
    );
    pub const LineIterator = IteratorTypes.LineIterator;
    pub const ReverseLineIterator = IteratorTypes.ReverseLineIterator;
    pub const IteratorIndex = IteratorTypes.IteratorIndex;
    pub const IteratorResult = IteratorTypes.IteratorResult;
    pub const IteratorPtr = IteratorTypes.IteratorPtr;
    pub const IteratorKind = IteratorTypes.IteratorKind;

    pub fn init(alloc: std.mem.Allocator) !*ProcessBuffer {
        const self = try alloc.create(ProcessBuffer);

        self.* = .{
            .alloc = alloc,
            .m = std.Thread.Mutex{},
            .buffer = blk: {
                const ptr: *LineBuffer = try alloc.create(LineBuffer);
                ptr.* = try .init(alloc);
                break :blk ptr;
            },
            .line_timestamps = try .init(alloc),
            .filtered_buffer = try .init(alloc),
            .nonowned_iterators = try .initCapacity(alloc, 100),
            .pipeline = try .init(alloc),
        };
        return self;
    }

    /// The created ProcessBuffer will take ownership of everything inside meta
    /// The contents sinde linesAndMeta also must be valid for contact ProcessBuffer expects.
    /// That timestamps are ordered and there is a timestamp for every line in the buffer
    pub fn initWithLines(alloc: std.mem.Allocator, meta: linesAndMeta) !*ProcessBuffer {
        const self = try alloc.create(ProcessBuffer);

        self.* = .{
            .alloc = alloc,
            .m = std.Thread.Mutex{},
            .buffer = meta.linebuffer,
            .line_timestamps = meta.linebuffer,
            .filtered_buffer = try .init(alloc),
            .nonowned_iterators = try .initCapacity(alloc, 100),
            .pipeline = try .init(alloc),
        };
        return self;
    }

    pub fn deinit(self: *ProcessBuffer) void {
        self.nonowned_iterators.deinit(self.alloc);
        self.filtered_buffer.deinit();
        self.pipeline.deinit();
        self.line_timestamps.deinit();
        self.alloc.destroy(self);
    }

    fn invalidateAllIterators(self: *ProcessBuffer) void {
        for (self.nonowned_iterators.items) |record| {
            switch (record.kind) {
                .lineIterator => {
                    const it: *LineIterator = @ptrCast(@alignCast(record.ptr));
                    it.invalidate();
                },
                .reverseLineIterator => {
                    const it: *ReverseLineIterator = @ptrCast(@alignCast(record.ptr));
                    it.invalidate();
                },
            }
        }
        self.nonowned_iterators.clearAndFree(self.alloc);
    }

    pub fn append(self: *ProcessBuffer, buf: []const u8) std.mem.Allocator.Error!void {
        self.m.lock();
        defer self.m.unlock();

        const lines = self.buffer.countLines();

        try self.buffer.append(buf);

        const new_lines = self.buffer.countLines();

        // if we have added new lines, update timestamps and children
        if (lines < new_lines) {
            // add timestamps for each new line
            const timestamp = std.time.microTimestamp();
            for (lines..new_lines) |_| {
                try self.line_timestamps.append_timestamp(timestamp);
            }

            // append new lines to children
            if (self.merge_graph) |graph| {
                var graph_iter = graph.ptr.children(graph.handle);
                if (graph_iter) |*it| {
                    while (it.next()) |child_hdl| {
                        const child_buffer = graph.ptr.getObject(child_hdl) orelse @panic("ProcessBuffer has a dead child handle!");
                        try child_buffer.append_with_timestamps(
                            self.buffer.getLinesStartingFrom(lines).?,
                            self.line_timestamps.list.items[lines..new_lines],
                        );
                    }
                }
            }
        }

        try self.processPipeline();
    }

    /// assumes that times are ordered
    pub fn append_with_timestamps(self: *ProcessBuffer, buf: []const u8, times: []const i64) std.mem.Allocator.Error!void {
        self.m.lock();
        defer self.m.unlock();

        // check that adding times won't unorder our lines_timestamps array
        if (self.line_timestamps.list.items.len > 0 and times.len > 0) {
            if (self.line_timestamps.list.items[self.line_timestamps.list.items.len - 1] > times[0]) {
                @panic("Adding these times will make this processbuffer has unordered timestamps");
            }
        }

        const lines = self.buffer.countLines();

        // appends lines and timestamps
        try self.buffer.append(buf);
        try self.line_timestamps.list.appendSlice(self.line_timestamps.alloc, times);

        const new_lines = self.buffer.countLines();

        // append new lines to children
        if (self.merge_graph) |graph| {
            var graph_ptr = graph.ptr.children(graph.handle);
            if (graph_ptr) |*it| {
                while (it.next()) |child_hdl| {
                    const child_buffer = graph.ptr.getObject(child_hdl) orelse @panic("ProcessBuffer has a dead child handle!");
                    try child_buffer.append_with_timestamps(
                        self.buffer.getLinesStartingFrom(lines).?,
                        self.line_timestamps.list.items[lines..new_lines],
                    );
                }
            }
        }

        try self.processPipeline();
    }

    fn update_newline_indexs(
        alloc: std.mem.Allocator,
        newline_cache: *std.ArrayList(usize),
        buf: []const u8,
        offset: usize,
    ) std.mem.Allocator.Error!void {
        for (buf, 0..) |c, i| {
            if (c == '\n') {
                try newline_cache.append(alloc, i + offset);
            }
        }
    }

    pub fn processPipeline(self: *ProcessBuffer) !void {
        // check if there are any new lines to process
        const current_lines = self.buffer.countLines();
        if (self.lines_processed < current_lines) {
            const new_filtered_lines: []u8 = try self.pipeline.runPipeline(
                self.alloc,
                self.buffer.getLinesStartingFrom(self.lines_processed).?,
                MetaData{ .bufferOffset = self.filtered_buffer.count() },
            );

            defer self.alloc.free(new_filtered_lines);

            try self.filtered_buffer.append(new_filtered_lines);
            self.lines_processed = current_lines;

            // TODO work out what to do about the tail!!
        }
    }

    fn reprocessPipeline(self: *ProcessBuffer) !void {
        std.log.debug("ProcessBuffer:reprocessPipeline()", .{});

        // NOTE: this doesn't consider external pipeline data that is managed by
        // a reviewer...

        self.filtered_buffer.clearRetainingCapacity();
        self.lines_processed = 0;
        self.invalidateAllIterators();
        try self.processPipeline();
    }

    pub fn addFilter(self: *ProcessBuffer, filter: Filter) !void {
        self.m.lock();
        defer self.m.unlock();

        std.log.debug("ProcessBuffer:addFilter()", .{});

        try self.pipeline.appendFilter(filter);
        try self.reprocessPipeline();
    }

    pub fn removeFilter(self: *ProcessBuffer, id: Filter.HandleId) void {
        self.m.lock();
        defer self.m.unlock();

        std.log.debug("ProcessBuffer:removeFilter()", .{});

        const filter = self.pipeline.removeFilter(id);
        if (filter) |f| f.deinit();

        // re-run the buffer through the pipeline
        try self.reprocessPipeline();
    }

    pub fn addReviewer(self: *ProcessBuffer, reviewer: Reviewer) !void {
        self.m.lock();
        defer self.m.unlock();

        std.log.debug("ProcessBuffer:addReviewer()", .{});

        try self.pipeline.appendReviewer(reviewer);

        try self.reprocessPipeline();
    }

    pub fn removeReviewer(self: *ProcessBuffer, id: Reviewer.HandleId) !void {
        self.m.lock();
        defer self.m.unlock();

        std.log.debug("ProcessBuffer:removeReviewer()", .{});

        const reviewer = self.pipeline.reviewReviewer(id);
        if (reviewer) |r| r.deinit();

        try self.reprocessPipeline();
    }

    pub fn removeAllFilters(self: *ProcessBuffer) !void {
        self.m.lock();
        defer self.m.unlock();

        // get all pipeline ids
        var id_array = try std.ArrayList(Filter.HandleId).initCapacity(self.alloc, self.pipeline.filters.items.len);
        for (self.pipeline.filters.items) |f| {
            try id_array.append(self.alloc, f.id);
        }
        for (id_array.items) |id| {
            var f = self.pipeline.removeFilter(id);
            if (f != null) f.?.deinit();
        }
        id_array.deinit(self.alloc);
        try self.reprocessPipeline();
    }

    pub fn removeAllReviewers(self: *ProcessBuffer) !void {
        self.m.lock();
        defer self.m.unlock();

        // get all pipeline ids
        var id_array = try std.ArrayList(Reviewer.HandleId).initCapacity(self.alloc, self.pipeline.reviewers.items.len);
        for (self.pipeline.reviewers.items) |r| {
            try id_array.append(self.alloc, r.id);
        }
        for (id_array.items) |id| {
            var r = self.pipeline.removeReviewer(id);
            if (r != null) r.?.deinit();
        }
        id_array.deinit(self.alloc);
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

        return try alloc.dupe(u8, self.filtered_buffer.buf.items);
    }

    pub fn copyUnfilteredBuffer(
        self: *ProcessBuffer,
        alloc: std.mem.Allocator,
    ) std.mem.Allocator.Error![]u8 {
        self.m.lock();
        defer self.m.unlock();

        return try alloc.dupe(u8, self.buffer.buf.items);
    }

    pub fn copyRange(
        self: *ProcessBuffer,
        alloc: std.mem.Allocator,
        offset: usize,
        len: usize,
    ) ![]u8 {
        self.m.lock();
        defer self.m.unlock();

        if (offset + len > self.filtered_buffer.buf.items.len) {
            std.log.debug("buffer length: {d}, offset: {d}, to_idx: {d}\n", .{
                self.filtered_buffer.buf.items.len,
                offset,
                len,
            });
            return Error.InvalidArguments;
        }
        return try alloc.dupe(u8, self.filtered_buffer.buf.items[offset .. offset + len]);
    }

    pub fn copyUnfilteredRange(
        self: *ProcessBuffer,
        alloc: std.mem.Allocator,
        offset: usize,
        len: usize,
    ) ![]u8 {
        self.m.lock();
        defer self.m.unlock();

        if (offset + len > self.buffer.buf.items.len) {
            return Error.InvalidArguments;
        }
        return try alloc.dupe(u8, self.buffer.buf.items[offset .. offset + len]);
    }

    pub fn getFilteredBufferLength(
        self: *ProcessBuffer,
    ) usize {
        self.m.lock();
        defer self.m.unlock();
        return self.filtered_buffer.count();
    }

    pub fn getNumFilteredNewlines(
        self: *ProcessBuffer,
    ) usize {
        self.m.lock();
        defer self.m.unlock();
        return self.filtered_buffer.newlines.items.len;
    }

    pub fn getLineFromOffset(self: *ProcessBuffer, offset: usize) usize {
        self.m.lock();
        defer self.m.unlock();
        self.filtered_buffer.getLineIndexFromOffset(offset).?;
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
    pub fn getOffsetFromLine(self: *ProcessBuffer, line_num: usize) !usize {
        self.m.lock();
        defer self.m.unlock();
        const offset = self.filtered_buffer.getIndexOfLine(line_num);
        // This line isn't considering tails
        return if (offset) |ofs| ofs else error.OutOfBounds;
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
