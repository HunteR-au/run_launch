const std = @import("std");
const Filter = @import("filter.zig");
const Reviewer = @import("reviewer.zig");
const ProcessBuffer = @import("processbuffer.zig").ProcessBuffer;

pub const Pipeline = @This();

pub const MetaData = Reviewer.MetaData;

arena: std.heap.ArenaAllocator,
filters: std.ArrayList(Filter),
reviewers: std.ArrayList(Reviewer),
m: std.Thread.Mutex,

pub fn init(alloc: std.mem.Allocator) !Pipeline {
    return .{
        .arena = std.heap.ArenaAllocator.init(alloc),
        .filters = std.ArrayList(Filter).init(alloc),
        .reviewers = std.ArrayList(Reviewer).init(alloc),
        .m = std.Thread.Mutex{},
    };
}

pub fn deinit(self: *Pipeline) void {
    for (self.filters.items) |*filter| {
        filter.deinit();
    }
    self.filters.deinit();
    for (self.reviewers.items) |*reviewer| {
        reviewer.deinit();
    }
    self.reviewers.deinit();
    self.arena.deinit();
}

pub fn runPipeline(self: *Pipeline, alloc: std.mem.Allocator, buffer: []const u8, metadata: MetaData) ![]u8 {
    self.m.lock();
    defer self.m.unlock();

    var temp_buf = buffer;
    for (self.filters.items) |*filter| {
        temp_buf = try filter.transform(temp_buf);
    }
    const result = try alloc.dupe(u8, temp_buf);

    // release all the memory allocated transforming the buffers
    for (self.filters.items) |*filter| {
        filter.freeMemory();
    }

    // run all reviewers over the filtered data
    for (self.reviewers.items) |*reviewer| {
        try reviewer.review(result, metadata);
    }

    return result;
}

pub fn appendFilter(self: *Pipeline, filter: Filter) !void {
    self.m.lock();
    defer self.m.unlock();

    try self.filters.append(filter);
}

pub fn removeFilter(self: *Pipeline, id: Filter.HandleId) ?Filter {
    self.m.lock();
    defer self.m.unlock();

    for (self.filters.items, 0..) |*filter, i| {
        if (filter.id == id) {
            return self.filters.orderedRemove(i);
        }
    }
    return null;
}

pub fn appendReviewer(self: *Pipeline, reviewer: Reviewer) !void {
    self.m.lock();
    defer self.m.unlock();

    try self.reviewers.append(reviewer);
}

pub fn removeReviewer(self: *Pipeline, id: Reviewer.HandleId) ?Reviewer {
    self.m.lock();
    defer self.m.unlock();

    for (self.reviewers.items, 0..) |*reviewer, i| {
        if (reviewer.id == id) {
            return self.reviewers.orderedRemove(i);
        }
    }
    return null;
}
