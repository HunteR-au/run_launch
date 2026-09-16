//! Pump-owned style storage for a ProcessBuffer.
//!
//! Reviewers produce `Pending` marks (absolute filtered-buffer byte offsets, style by value)
//! while the pipeline runs. The results are folded into a sorted, non-overlapping list of
//! `StyleRange`s whose `style` indexes a small deduplicated palette. The UI never reads this
//! directly: `ProcessBuffer.snapshotWindow` copies the ranges intersecting the visible window
//! into the frame arena under the buffer lock.
const std = @import("std");
const vaxis = @import("vaxis");
const Allocator = std.mem.Allocator;

pub const StyleId = u16;
const no_style: StyleId = std.math.maxInt(StyleId);

/// Half-open byte range `[start, end)` painted with `palette[style]`.
pub const StyleRange = struct {
    start: usize,
    end: usize,
    style: StyleId,
};

/// A mark produced by a reviewer before it has been interned into the palette.
pub const Pending = struct {
    start: usize,
    end: usize,
    style: vaxis.Style,
};

pub const StyleIndex = struct {
    ranges: std.ArrayList(StyleRange),
    palette: std.ArrayList(vaxis.Style),

    pub const empty: StyleIndex = .{ .ranges = .empty, .palette = .empty };

    pub fn deinit(self: *StyleIndex, alloc: Allocator) void {
        self.ranges.deinit(alloc);
        self.palette.deinit(alloc);
    }

    pub fn clearRetainingCapacity(self: *StyleIndex) void {
        self.ranges.clearRetainingCapacity();
        // The palette is tiny and stable; keeping it avoids re-interning on every reprocess.
    }

    /// Returns the palette index for `style`, adding it if it is not present yet.
    pub fn intern(self: *StyleIndex, alloc: Allocator, style: vaxis.Style) Allocator.Error!StyleId {
        for (self.palette.items, 0..) |s, i| {
            if (std.meta.eql(s, style)) return @intCast(i);
        }
        std.debug.assert(self.palette.items.len < no_style);
        try self.palette.append(alloc, style);
        return @intCast(self.palette.items.len - 1);
    }

    /// Folds a batch of marks into the range list.
    ///
    /// Marks in the batch may overlap each other; within the batch the last mark wins
    /// (matching the old `HashMap.put` semantics). Every mark must start at or after the end
    /// of the last stored range, which holds because batches are appended in filtered-buffer
    /// order and reprocessing clears the index first.
    pub fn appendPending(self: *StyleIndex, alloc: Allocator, pending: []const Pending) Allocator.Error!void {
        if (pending.len == 0) return;

        var lo: usize = std.math.maxInt(usize);
        var hi: usize = 0;
        for (pending) |p| {
            if (p.end <= p.start) continue;
            lo = @min(lo, p.start);
            hi = @max(hi, p.end);
        }
        if (hi <= lo) return;

        if (self.ranges.items.len > 0) {
            std.debug.assert(self.ranges.items[self.ranges.items.len - 1].end <= lo);
        }

        // Paint the batch span byte by byte, later marks overwrite earlier ones.
        const span = try alloc.alloc(StyleId, hi - lo);
        defer alloc.free(span);
        @memset(span, no_style);
        for (pending) |p| {
            if (p.end <= p.start) continue;
            const id = try self.intern(alloc, p.style);
            @memset(span[p.start - lo .. p.end - lo], id);
        }

        // Run-length encode into ranges.
        var i: usize = 0;
        while (i < span.len) {
            const id = span[i];
            var j = i + 1;
            while (j < span.len and span[j] == id) : (j += 1) {}
            if (id != no_style) {
                try self.ranges.append(alloc, .{ .start = lo + i, .end = lo + j, .style = id });
            }
            i = j;
        }
    }

    /// Returns the stored ranges that intersect `[lo, hi)`, in order. The first and last
    /// returned ranges may extend past the bounds; callers clip as needed.
    pub fn rangesIntersecting(self: *const StyleIndex, lo: usize, hi: usize) []const StyleRange {
        const items = self.ranges.items;
        if (items.len == 0 or hi <= lo) return &.{};

        // first range whose end is > lo
        var left: usize = 0;
        var right: usize = items.len;
        while (left < right) {
            const mid = left + (right - left) / 2;
            if (items[mid].end <= lo) left = mid + 1 else right = mid;
        }
        const first = left;

        // first range whose start is >= hi
        right = items.len;
        while (left < right) {
            const mid = left + (right - left) / 2;
            if (items[mid].start < hi) left = mid + 1 else right = mid;
        }
        return items[first..left];
    }

    pub fn styleOf(self: *const StyleIndex, id: StyleId) vaxis.Style {
        return self.palette.items[id];
    }
};

const testing = std.testing;
const red: vaxis.Style = .{ .fg = .{ .rgb = .{ 255, 0, 0 } } };
const blue: vaxis.Style = .{ .fg = .{ .rgb = .{ 0, 0, 255 } } };

test "appendPending encodes runs and interns the palette" {
    const alloc = testing.allocator;
    var idx: StyleIndex = .empty;
    defer idx.deinit(alloc);

    try idx.appendPending(alloc, &.{
        .{ .start = 2, .end = 8, .style = red },
        .{ .start = 10, .end = 16, .style = red },
    });
    try testing.expectEqual(2, idx.ranges.items.len);
    try testing.expectEqual(1, idx.palette.items.len);
    try testing.expectEqual(StyleRange{ .start = 2, .end = 8, .style = 0 }, idx.ranges.items[0]);
    try testing.expectEqual(StyleRange{ .start = 10, .end = 16, .style = 0 }, idx.ranges.items[1]);
}

test "appendPending: later marks win within a batch" {
    const alloc = testing.allocator;
    var idx: StyleIndex = .empty;
    defer idx.deinit(alloc);

    try idx.appendPending(alloc, &.{
        .{ .start = 0, .end = 10, .style = red },
        .{ .start = 3, .end = 5, .style = blue },
    });
    try testing.expectEqual(3, idx.ranges.items.len);
    try testing.expectEqual(StyleRange{ .start = 0, .end = 3, .style = 0 }, idx.ranges.items[0]);
    try testing.expectEqual(StyleRange{ .start = 3, .end = 5, .style = 1 }, idx.ranges.items[1]);
    try testing.expectEqual(StyleRange{ .start = 5, .end = 10, .style = 0 }, idx.ranges.items[2]);
}

test "rangesIntersecting clips to the window" {
    const alloc = testing.allocator;
    var idx: StyleIndex = .empty;
    defer idx.deinit(alloc);

    try idx.appendPending(alloc, &.{
        .{ .start = 0, .end = 4, .style = red },
        .{ .start = 10, .end = 14, .style = red },
        .{ .start = 20, .end = 24, .style = red },
    });
    try testing.expectEqual(0, idx.rangesIntersecting(4, 10).len);
    try testing.expectEqual(1, idx.rangesIntersecting(12, 13).len);
    try testing.expectEqual(2, idx.rangesIntersecting(3, 11).len);
    try testing.expectEqual(3, idx.rangesIntersecting(0, 100).len);
    try testing.expectEqual(1, idx.rangesIntersecting(23, 100).len);
}
