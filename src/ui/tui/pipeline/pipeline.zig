//! The per-buffer processing pipeline: filters transform lines, reviewers annotate them.
//! Owned and mutated by the pump thread only, so no internal locking.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Filter = @import("filter.zig");
const Reviewer = @import("reviewer.zig");
const styleindex = @import("styleindex.zig");

pub const Pipeline = @This();
pub const Pending = styleindex.Pending;

alloc: Allocator,
filters: std.ArrayList(Filter),
reviewers: std.ArrayList(Reviewer),

pub fn init(alloc: Allocator) !Pipeline {
    return .{
        .alloc = alloc,
        .filters = try std.ArrayList(Filter).initCapacity(alloc, 1),
        .reviewers = try std.ArrayList(Reviewer).initCapacity(alloc, 1),
    };
}

pub fn deinit(self: *Pipeline) void {
    for (self.filters.items) |*filter| filter.deinit();
    self.filters.deinit(self.alloc);
    for (self.reviewers.items) |*reviewer| reviewer.deinit();
    self.reviewers.deinit(self.alloc);
}

/// Runs `lines` (complete lines, each ending in '\n') through every filter, then reviews the
/// result. `base_filtered_offset` is the absolute filtered-buffer offset the returned bytes
/// will be appended at; reviewer marks are emitted into `pending` as absolute offsets.
/// The returned slice is owned by the caller (allocated with `alloc`).
pub fn run(
    self: *Pipeline,
    alloc: Allocator,
    lines: []const u8,
    base_filtered_offset: usize,
    pending: *std.ArrayList(Pending),
) Allocator.Error![]u8 {
    if (lines.len == 0) return try alloc.alloc(u8, 0);
    std.debug.assert(lines[lines.len - 1] == '\n');

    var temp = lines;
    for (self.filters.items) |*filter| {
        temp = try filter.transform(temp);
    }
    const result = try alloc.dupe(u8, temp);
    errdefer alloc.free(result);

    // release the scratch memory used while transforming
    for (self.filters.items) |*filter| filter.freeMemory();

    try self.review(alloc, result, base_filtered_offset, pending);

    if (result.len > 0) std.debug.assert(result[result.len - 1] == '\n');
    return result;
}

/// Runs only the reviewers over `filtered` (complete lines starting at absolute offset
/// `base_filtered_offset`). Used to rebuild styles without re-filtering.
pub fn review(
    self: *Pipeline,
    alloc: Allocator,
    filtered: []const u8,
    base_filtered_offset: usize,
    pending: *std.ArrayList(Pending),
) Allocator.Error!void {
    if (self.reviewers.items.len == 0) return;

    var pos: usize = 0;
    while (std.mem.indexOfScalarPos(u8, filtered, pos, '\n')) |nl| : (pos = nl + 1) {
        var line = filtered[pos..nl];
        // match without a trailing CR, offsets are unaffected
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];

        var sink: Reviewer.LineSink = .{
            .line_abs = base_filtered_offset + pos,
            .line_len = line.len,
            .alloc = alloc,
            .out = pending,
        };
        for (self.reviewers.items) |*reviewer| {
            try reviewer.reviewLine(reviewer, reviewer.data, &sink, line);
        }
    }
}

pub fn appendFilter(self: *Pipeline, filter: Filter) !void {
    try self.filters.append(self.alloc, filter);
}

pub fn removeFilter(self: *Pipeline, id: Filter.HandleId) ?Filter {
    for (self.filters.items, 0..) |*filter, i| {
        if (filter.id == id) return self.filters.orderedRemove(i);
    }
    return null;
}

pub fn appendReviewer(self: *Pipeline, reviewer: Reviewer) !void {
    try self.reviewers.append(self.alloc, reviewer);
}

pub fn removeReviewer(self: *Pipeline, id: Reviewer.HandleId) ?Reviewer {
    for (self.reviewers.items, 0..) |*reviewer, i| {
        if (reviewer.id == id) return self.reviewers.orderedRemove(i);
    }
    return null;
}
