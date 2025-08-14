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
    lastNewLine: usize = 0,
    pipeline: Pipeline,

    pub fn init(alloc: std.mem.Allocator) !*ProcessBuffer {
        const self = try alloc.create(ProcessBuffer);
        self.* = .{
            .alloc = alloc,
            .m = std.Thread.Mutex{},
            .buffer = std.ArrayList(u8).init(alloc),
            .buffer_newlines = std.ArrayList(usize).init(alloc),
            .filtered_buffer = std.ArrayList(u8).init(alloc),
            .filtered_newlines = std.ArrayList(usize).init(alloc),
            .pipeline = try Pipeline.init(alloc),
        };
        return self;
    }

    pub fn deinit(self: *ProcessBuffer) void {
        self.buffer.deinit();
        self.buffer_newlines.deinit();
        self.filtered_buffer.deinit();
        self.filtered_newlines.deinit();
        self.pipeline.deinit();
        self.alloc.destroy(self);
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
                    try self.update_newline_indexs(
                        self.filtered_newlines,
                        filtered_lines,
                        self.filtered_buffer.items.len,
                    );
                    try self.filtered_buffer.appendSlice(filtered_lines);
                }
            },
        }
    }

    pub fn reprocessPipeline(self: *ProcessBuffer) !void {
        self.m.lock();
        defer self.m.unlock();

        self.filtered_newlines.clearRetainingCapacity();
        self.filtered_buffer.clearRetainingCapacity();
        self.lastNewLine = 0;
        try self.processPipeline();
    }

    pub fn addFilter(self: *ProcessBuffer, filter: Filter) !void {
        self.m.lock();
        defer self.m.unlock();

        std.debug.print("ProcessBuffer:addFilter()\n", .{});

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
};
