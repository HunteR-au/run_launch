const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Filter = @import("filter.zig");
const Reviewer = @import("reviewer.zig");
const ProcessBuffer = @import("processbuffer.zig").ProcessBuffer;

pub const Pipeline = @This();

pub const MetaData = Reviewer.MetaData;

arena: std.heap.ArenaAllocator,
alloc: Allocator,
filters: std.ArrayList(Filter),
reviewers: std.ArrayList(Reviewer),
m: std.Io.Mutex,

pub fn init(alloc: Allocator) !Pipeline {
    return .{
        .arena = std.heap.ArenaAllocator.init(alloc),
        .alloc = alloc,
        .filters = try std.ArrayList(Filter).initCapacity(alloc, 1),
        .reviewers = try std.ArrayList(Reviewer).initCapacity(alloc, 1),
        .m = .init,
    };
}

pub fn deinit(self: *Pipeline) void {
    for (self.filters.items) |*filter| {
        filter.deinit();
    }
    self.filters.deinit(self.alloc);
    for (self.reviewers.items) |*reviewer| {
        reviewer.deinit();
    }
    self.reviewers.deinit(self.alloc);
    self.arena.deinit();
}

/// runPipeline processes the buffer through a series of filters which transform each individual
/// line based on their internal rules. The resulting series of transformed lines are then passed
/// through 2nd pass via a series of objects called reviewers. Reviewers do not make edit to the buffer!
pub fn runPipeline(
    self: *Pipeline,
    io: Io,
    alloc: Allocator,
    /// A list of lines, noting that a line is defined as a string ending in a '\n'
    buffer: []const u8,
    metadata: MetaData,
) ![]u8 {
    self.m.lockUncancelable(io);
    defer self.m.unlock(io);

    // Require that the buffer consist of ONLY lines
    std.debug.assert(buffer[buffer.len - 1] == '\n');

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

    // Require that we are returning a buffer of lines with no tail
    if (result.len > 0) std.debug.assert(result[result.len - 1] == '\n');

    return result;
}

pub fn appendFilter(self: *Pipeline, io: Io, filter: Filter) !void {
    self.m.lockUncancelable(io);
    defer self.m.unlock(io);

    try self.filters.append(self.alloc, filter);
}

pub fn removeFilter(self: *Pipeline, io: Io, id: Filter.HandleId) ?Filter {
    self.m.lockUncancelable(io);
    defer self.m.unlock(io);

    for (self.filters.items, 0..) |*filter, i| {
        if (filter.id == id) {
            return self.filters.orderedRemove(i);
        }
    }
    return null;
}

pub fn appendReviewer(self: *Pipeline, io: Io, reviewer: Reviewer) !void {
    self.m.lockUncancelable(io);
    defer self.m.unlock(io);

    try self.reviewers.append(self.alloc, reviewer);
}

pub fn removeReviewer(self: *Pipeline, io: Io, id: Reviewer.HandleId) ?Reviewer {
    self.m.lockUncancelable(io);
    defer self.m.unlock(io);

    for (self.reviewers.items, 0..) |*reviewer, i| {
        if (reviewer.id == id) {
            return self.reviewers.orderedRemove(i);
        }
    }
    return null;
}
