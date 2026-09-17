//! A ProcessBuffer holds one process' (or merged view's) output: the raw lines, the
//! per-line ingest sequence numbers, the filtered lines the UI renders and their styles.
//!
//! Threading: the pump thread is the only writer. The UI thread reads through `peek`
//! (lock-free counters), `snapshotWindow` and `copyFilteredFrom` (one brief lock each).
//! Everything else is pump-thread-only.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const utils = @import("utils");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
pub const Pipeline = @import("pipeline.zig");
pub const Filter = @import("filter.zig");
pub const Reviewer = @import("reviewer.zig");
pub const LineBuffer = @import("linebuffer.zig").LineBuffer;
pub const styleindex = @import("styleindex.zig");
pub const StyleIndex = styleindex.StyleIndex;
pub const StyleRange = styleindex.StyleRange;
const Graph = @import("buffer/acyclicgraph.zig");

const UUID = utils.uuid.UUID;
pub const GraphHandle = Graph.Handle;
pub const Term = std.process.Child.Term;

/// Lock-free counters published by the writer after every change. The UI reads these on its
/// tick to decide whether a redraw is needed without taking the buffer lock.
pub const Published = struct {
    /// bumped on every publish (append or reprocess)
    change: std.atomic.Value(u64) = .init(0),
    /// bumped only when filtered line identity changes (reprocess/reset), which invalidates
    /// any UI state that stores filtered offsets (search results)
    version: std.atomic.Value(u64) = .init(0),
    filtered_lines: std.atomic.Value(usize) = .init(0),
    filtered_len: std.atomic.Value(usize) = .init(0),
    raw_lines: std.atomic.Value(usize) = .init(0),
};

/// Pump-thread-only bookkeeping used to emit the end-of-process marker exactly once.
pub const EndState = struct {
    /// indexed by stream (0 = stdout, 1 = stderr)
    eof: [2]bool = .{ false, false },
    exited: bool = false,
    term: ?Term = null,
    ended: bool = false,
};

pub const BufferSnapshot = struct {
    change: u64,
    version: u64,
    filtered_lines: usize,
    filtered_len: usize,
    raw_lines: usize,
};

pub const WindowRequest = struct {
    /// desired first line (already resolved from pending scroll by the caller)
    top_line: usize,
    /// maximum number of lines to copy
    max_lines: usize,
    /// when true the window is anchored to the last `max_lines` lines
    follow_bottom: bool,
};

/// Everything a single draw needs, copied from the buffer under one lock acquisition.
/// All offsets are relative to `text[0]`; `base_offset` converts them to absolute filtered
/// offsets. Slices are allocated from the frame arena and live for one draw.
pub const WindowSnapshot = struct {
    meta: BufferSnapshot,
    /// actual first line after clamping against the buffer
    top_line: usize,
    /// absolute filtered byte offset of text[0]
    base_offset: usize,
    /// complete lines only, each ending in '\n'
    text: []const u8,
    /// window-relative start of each line plus a final entry equal to text.len
    line_starts: []const usize,
    /// window-relative, sorted, non-overlapping, clipped to [0, text.len)
    styles: []const StyleRange,
    palette: []const vaxis.Style,

    pub const empty: WindowSnapshot = .{
        .meta = .{ .change = 0, .version = 0, .filtered_lines = 0, .filtered_len = 0, .raw_lines = 0 },
        .top_line = 0,
        .base_offset = 0,
        .text = "",
        .line_starts = &.{0},
        .styles = &.{},
        .palette = &.{},
    };

    pub fn lineCount(self: *const WindowSnapshot) usize {
        return self.line_starts.len -| 1;
    }

    /// Window-relative index of the line containing the window-relative byte offset.
    fn lineIndexAt(self: *const WindowSnapshot, window_ofs: usize) ?usize {
        const count = self.lineCount();
        if (count == 0 or window_ofs >= self.text.len) return null;
        // largest i in [0, count) with line_starts[i] <= window_ofs
        var lo: usize = 0;
        var hi: usize = count;
        while (lo + 1 < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.line_starts[mid] <= window_ofs) lo = mid else hi = mid;
        }
        return lo;
    }

    /// Absolute line index of the line containing the window-relative byte offset.
    pub fn lineAt(self: *const WindowSnapshot, window_ofs: usize) ?usize {
        const idx = self.lineIndexAt(window_ofs) orelse return null;
        return self.top_line + idx;
    }

    /// True when the window-relative byte offset is the first byte of a line.
    pub fn isLineStart(self: *const WindowSnapshot, window_ofs: usize) bool {
        const idx = self.lineIndexAt(window_ofs) orelse return false;
        return self.line_starts[idx] == window_ofs;
    }

    /// Style at a window-relative byte offset. `cursor` is a hint that makes sequential
    /// lookups O(1); it is corrected when offsets move backwards.
    pub fn styleAt(self: *const WindowSnapshot, cursor: *usize, window_ofs: usize) ?vaxis.Style {
        const ranges = self.styles;
        if (ranges.len == 0) return null;
        var c = @min(cursor.*, ranges.len);
        while (c > 0 and ranges[c - 1].end > window_ofs) : (c -= 1) {}
        while (c < ranges.len and ranges[c].end <= window_ofs) : (c += 1) {}
        cursor.* = c;
        if (c < ranges.len and ranges[c].start <= window_ofs) {
            return self.palette[ranges[c].style];
        }
        return null;
    }

    /// Returns a copy of the snapshot with `[start, end)` (window-relative) painted with
    /// `style` on top of the existing ranges. Used for the search highlight.
    pub fn overlay(
        self: *const WindowSnapshot,
        arena: Allocator,
        start: usize,
        end: usize,
        style: vaxis.Style,
    ) Allocator.Error!WindowSnapshot {
        const clipped_end = @min(end, self.text.len);
        if (start >= clipped_end) return self.*;

        var palette = try std.ArrayList(vaxis.Style).initCapacity(arena, self.palette.len + 1);
        palette.appendSliceAssumeCapacity(self.palette);
        palette.appendAssumeCapacity(style);
        const new_id: styleindex.StyleId = @intCast(palette.items.len - 1);

        var ranges = try std.ArrayList(StyleRange).initCapacity(arena, self.styles.len + 3);
        var inserted = false;
        for (self.styles) |r| {
            if (r.end <= start or r.start >= clipped_end) {
                if (!inserted and r.start >= clipped_end) {
                    ranges.appendAssumeCapacity(.{ .start = start, .end = clipped_end, .style = new_id });
                    inserted = true;
                }
                ranges.appendAssumeCapacity(r);
                continue;
            }
            // r intersects the overlay: keep the parts outside it
            if (r.start < start) {
                ranges.appendAssumeCapacity(.{ .start = r.start, .end = start, .style = r.style });
            }
            if (!inserted) {
                ranges.appendAssumeCapacity(.{ .start = start, .end = clipped_end, .style = new_id });
                inserted = true;
            }
            if (r.end > clipped_end) {
                ranges.appendAssumeCapacity(.{ .start = clipped_end, .end = r.end, .style = r.style });
            }
        }
        if (!inserted) {
            ranges.appendAssumeCapacity(.{ .start = start, .end = clipped_end, .style = new_id });
        }

        var result = self.*;
        result.styles = ranges.items;
        result.palette = palette.items;
        return result;
    }
};

/// Range of raw lines appended by one call.
pub const NewLines = struct {
    first: usize,
    count: usize,
};

pub const ProcessBuffer = struct {
    alloc: Allocator,
    io: Io,
    /// Guards `buffer`, `line_seqs`, `filtered_buffer`, `styles` and `lines_processed`
    /// against the UI's snapshot readers. The pump is the only writer.
    m: std.Io.Mutex,
    /// raw output (CRLF normalised to LF)
    buffer: LineBuffer,
    /// one global ingest sequence number per complete raw line; the merge ordering key
    line_seqs: std.ArrayList(u64) = .empty,
    filtered_buffer: LineBuffer,
    styles: StyleIndex = .empty,
    lines_processed: usize = 0,
    pipeline: Pipeline,
    published: Published = .{},
    end_state: EndState = .{},
    /// a trailing '\r' from the previous chunk that may be the start of a CRLF
    pending_cr: bool = false,
    /// sequence counter used by `append` for buffers that are not managed by a store
    standalone_seq: u64 = 0,

    /// node in the store's merge graph, when managed by a store
    handle: ?GraphHandle = null,
    id: ?UUID = null,
    /// Used for matching against queries such as "!0"
    strid: usize = 0,
    /// owned display name
    name: ?[]u8 = null,
    /// Debug only: the thread that first wrote to this buffer. Every later write must come
    /// from the same thread (the pump), which catches accidental UI-thread mutation.
    owner: if (builtin.mode == .Debug) ?std.Thread.Id else void = if (builtin.mode == .Debug) null else {},

    pub const BufferBacking = enum { Raw, Filtered };

    fn assertWriter(self: *ProcessBuffer) void {
        if (builtin.mode != .Debug) return;
        const me = std.Thread.getCurrentId();
        if (self.owner) |owner| {
            if (owner != me) @panic("ProcessBuffer written from a thread other than the pump");
        } else {
            self.owner = me;
        }
    }

    pub fn init(io: Io, alloc: Allocator) !*ProcessBuffer {
        const self = try alloc.create(ProcessBuffer);
        errdefer alloc.destroy(self);

        var buffer = try LineBuffer.init(alloc);
        errdefer buffer.deinit();
        var filtered = try LineBuffer.init(alloc);
        errdefer filtered.deinit();

        self.* = .{
            .alloc = alloc,
            .io = io,
            .m = .init,
            .buffer = buffer,
            .filtered_buffer = filtered,
            .pipeline = try .init(alloc),
        };
        return self;
    }

    pub fn deinit(self: *ProcessBuffer) void {
        self.filtered_buffer.deinit();
        self.styles.deinit(self.alloc);
        self.pipeline.deinit();
        self.buffer.deinit();
        self.line_seqs.deinit(self.alloc);
        if (self.name) |n| self.alloc.free(n);
        self.alloc.destroy(self);
    }

    pub fn setName(self: *ProcessBuffer, name: []const u8) Allocator.Error!void {
        const copy = try self.alloc.dupe(u8, name);
        if (self.name) |old| self.alloc.free(old);
        self.name = copy;
    }

    pub fn displayName(self: *const ProcessBuffer) []const u8 {
        return self.name orelse "?";
    }

    // ------------------------------------------------------------------
    // Writer side (pump thread only)
    // ------------------------------------------------------------------

    /// Appends raw bytes, normalising CRLF to LF, and assigns a sequence number to every
    /// newly completed line. Returns the range of new complete lines.
    pub fn appendChunk(self: *ProcessBuffer, bytes: []const u8, next_seq: *u64) Allocator.Error!NewLines {
        self.assertWriter();
        // Normalise outside the lock: strip '\r' when it precedes '\n'; hold back a trailing '\r'.
        var norm = try std.ArrayList(u8).initCapacity(self.alloc, bytes.len + 1);
        defer norm.deinit(self.alloc);

        var i: usize = 0;
        if (self.pending_cr) {
            self.pending_cr = false;
            if (bytes.len == 0 or bytes[0] != '\n') norm.appendAssumeCapacity('\r');
        }
        while (i < bytes.len) : (i += 1) {
            const c = bytes[i];
            if (c == '\r') {
                if (i + 1 == bytes.len) {
                    self.pending_cr = true;
                } else if (bytes[i + 1] != '\n') {
                    norm.appendAssumeCapacity('\r');
                }
                continue;
            }
            norm.appendAssumeCapacity(c);
        }

        self.m.lockUncancelable(self.io);
        defer self.m.unlock(self.io);

        const before = self.buffer.countLines();
        try self.buffer.append(norm.items);
        const after = self.buffer.countLines();

        try self.line_seqs.ensureUnusedCapacity(self.alloc, after - before);
        for (before..after) |_| {
            next_seq.* += 1;
            self.line_seqs.appendAssumeCapacity(next_seq.*);
        }
        self.published.raw_lines.store(after, .release);

        return .{ .first = before, .count = after - before };
    }

    /// Merge-child append: complete lines plus their (already assigned) sequence numbers.
    /// Numbers are monotonic by construction because propagation runs in the same pump step
    /// as the parent's ingest; assert in Debug and clamp otherwise so ordering never breaks.
    pub fn appendLinesWithSeq(self: *ProcessBuffer, lines: []const u8, seqs: []const u64) Allocator.Error!NewLines {
        self.assertWriter();
        std.debug.assert(seqs.len == std.mem.count(u8, lines, "\n"));

        self.m.lockUncancelable(self.io);
        defer self.m.unlock(self.io);

        const before = self.buffer.countLines();
        try self.buffer.append(lines);
        const after = self.buffer.countLines();
        std.debug.assert(after - before == seqs.len);

        try self.line_seqs.ensureUnusedCapacity(self.alloc, seqs.len);
        var last: u64 = if (self.line_seqs.items.len > 0) self.line_seqs.items[self.line_seqs.items.len - 1] else 0;
        for (seqs) |s| {
            std.debug.assert(s >= last);
            last = @max(last, s);
            self.line_seqs.appendAssumeCapacity(last);
        }
        self.published.raw_lines.store(after, .release);

        return .{ .first = before, .count = after - before };
    }

    /// Raw bytes of the given range of complete lines (pump-thread-only, no lock).
    pub fn linesRange(self: *ProcessBuffer, nl: NewLines) []const u8 {
        if (nl.count == 0) return "";
        const start = self.buffer.getIndexOfLine(nl.first).?;
        const end = self.buffer.getLineEndIndex(nl.first + nl.count - 1).? + 1;
        return self.buffer.buf.items[start..end];
    }

    /// Sequence numbers of the given range of complete lines (pump-thread-only, no lock).
    pub fn seqsRange(self: *ProcessBuffer, nl: NewLines) []const u64 {
        return self.line_seqs.items[nl.first .. nl.first + nl.count];
    }

    /// Convenience for buffers that are not managed by a store (tests, standalone use):
    /// appends and runs the pipeline with a private sequence counter.
    pub fn append(self: *ProcessBuffer, buf: []const u8) Allocator.Error!void {
        _ = try self.appendChunk(buf, &self.standalone_seq);
        try self.processPipeline();
    }

    /// Publishes the current counters. `identity_changed` must be true whenever filtered
    /// line identity changed (reprocess/reset) so offset-based UI state can invalidate itself.
    fn publish(self: *ProcessBuffer, identity_changed: bool) void {
        self.published.filtered_lines.store(self.filtered_buffer.countLines(), .release);
        self.published.filtered_len.store(self.filtered_buffer.count(), .release);
        self.published.raw_lines.store(self.buffer.countLines(), .release);
        if (identity_changed) _ = self.published.version.fetchAdd(1, .release);
        _ = self.published.change.fetchAdd(1, .release);
    }

    /// Runs any unprocessed raw lines through the pipeline and appends the result to the
    /// filtered buffer.
    pub fn processPipeline(self: *ProcessBuffer) Allocator.Error!void {
        self.assertWriter();
        self.m.lockUncancelable(self.io);
        defer self.m.unlock(self.io);
        try self.processPipelineLocked();
    }

    fn processPipelineLocked(self: *ProcessBuffer) Allocator.Error!void {
        const current_lines = self.buffer.countLines();
        if (self.lines_processed < current_lines) {
            var pending: std.ArrayList(Pipeline.Pending) = .empty;
            defer pending.deinit(self.alloc);

            const new_filtered_lines: []u8 = try self.pipeline.run(
                self.alloc,
                self.buffer.getLinesStartingFrom(self.lines_processed).?,
                self.filtered_buffer.count(),
                &pending,
            );
            defer self.alloc.free(new_filtered_lines);

            try self.filtered_buffer.append(new_filtered_lines);
            try self.styles.appendPending(self.alloc, pending.items);
            self.lines_processed = current_lines;
        }
        self.publish(false);
    }

    /// Rebuilds the filtered buffer and styles from the raw buffer. Must be called with `m` held.
    fn reprocessPipelineLocked(self: *ProcessBuffer) Allocator.Error!void {
        self.filtered_buffer.clearRetainingCapacity();
        self.styles.clearRetainingCapacity();
        self.lines_processed = 0;
        try self.processPipelineLocked();
        self.publish(true);
    }

    /// Rebuilds only the styles over the existing filtered buffer. Line identity is unchanged
    /// so `version` is not bumped. Must be called with `m` held.
    fn rereviewLocked(self: *ProcessBuffer) Allocator.Error!void {
        self.styles.clearRetainingCapacity();
        var pending: std.ArrayList(Pipeline.Pending) = .empty;
        defer pending.deinit(self.alloc);

        if (self.filtered_buffer.getLines()) |lines| {
            try self.pipeline.review(self.alloc, lines, 0, &pending);
            try self.styles.appendPending(self.alloc, pending.items);
        }
        self.publish(false);
    }

    pub fn addFilter(self: *ProcessBuffer, filter: Filter) Allocator.Error!void {
        self.assertWriter();
        self.m.lockUncancelable(self.io);
        defer self.m.unlock(self.io);

        try self.pipeline.appendFilter(filter);
        try self.reprocessPipelineLocked();
    }

    pub fn removeFilter(self: *ProcessBuffer, id: Filter.HandleId) Allocator.Error!void {
        self.assertWriter();
        self.m.lockUncancelable(self.io);
        defer self.m.unlock(self.io);

        if (self.pipeline.removeFilter(id)) |removed| {
            var f = removed;
            f.deinit();
            try self.reprocessPipelineLocked();
        }
    }

    pub fn addReviewer(self: *ProcessBuffer, reviewer: Reviewer) Allocator.Error!void {
        self.assertWriter();
        self.m.lockUncancelable(self.io);
        defer self.m.unlock(self.io);

        try self.pipeline.appendReviewer(reviewer);
        try self.rereviewLocked();
    }

    pub fn removeReviewer(self: *ProcessBuffer, id: Reviewer.HandleId) Allocator.Error!void {
        self.assertWriter();
        self.m.lockUncancelable(self.io);
        defer self.m.unlock(self.io);

        if (self.pipeline.removeReviewer(id)) |removed| {
            var r = removed;
            r.deinit();
            try self.rereviewLocked();
        }
    }

    pub fn removeAllFilters(self: *ProcessBuffer) Allocator.Error!void {
        self.assertWriter();
        self.m.lockUncancelable(self.io);
        defer self.m.unlock(self.io);

        for (self.pipeline.filters.items) |*f| f.deinit();
        self.pipeline.filters.clearRetainingCapacity();
        try self.reprocessPipelineLocked();
    }

    pub fn removeAllReviewers(self: *ProcessBuffer) Allocator.Error!void {
        self.assertWriter();
        self.m.lockUncancelable(self.io);
        defer self.m.unlock(self.io);

        for (self.pipeline.reviewers.items) |*r| r.deinit();
        self.pipeline.reviewers.clearRetainingCapacity();
        try self.rereviewLocked();
    }

    pub fn resetPipeline(self: *ProcessBuffer) Allocator.Error!void {
        self.assertWriter();
        self.m.lockUncancelable(self.io);
        defer self.m.unlock(self.io);

        self.pipeline.deinit();
        self.pipeline = try Pipeline.init(self.alloc);
        try self.reprocessPipelineLocked();
    }

    /// Pump-thread-only view of a whole backing buffer (no copy, no lock).
    pub fn rawBytes(self: *ProcessBuffer, backing: BufferBacking) []const u8 {
        return switch (backing) {
            .Raw => self.buffer.buf.items,
            .Filtered => self.filtered_buffer.buf.items,
        };
    }

    // ------------------------------------------------------------------
    // Reader side (UI thread)
    // ------------------------------------------------------------------

    /// Lock-free view of the published counters.
    pub fn peek(self: *const ProcessBuffer) BufferSnapshot {
        return .{
            .change = self.published.change.load(.acquire),
            .version = self.published.version.load(.acquire),
            .filtered_lines = self.published.filtered_lines.load(.acquire),
            .filtered_len = self.published.filtered_len.load(.acquire),
            .raw_lines = self.published.raw_lines.load(.acquire),
        };
    }

    /// Copies the requested window of the filtered buffer and its styles into `arena` under
    /// a single lock acquisition. The lock is held for O(bytes copied).
    pub fn snapshotWindow(self: *ProcessBuffer, arena: Allocator, req: WindowRequest) Allocator.Error!WindowSnapshot {
        self.m.lockUncancelable(self.io);
        defer self.m.unlock(self.io);

        const fb = &self.filtered_buffer;
        const lines = fb.countLines();

        const top: usize = if (lines == 0)
            0
        else if (req.follow_bottom)
            lines -| req.max_lines
        else
            @min(req.top_line, lines - 1);
        const end_line = @min(top + req.max_lines, lines);

        var snap: WindowSnapshot = .{
            .meta = .{
                .change = self.published.change.load(.acquire),
                .version = self.published.version.load(.acquire),
                .filtered_lines = lines,
                .filtered_len = fb.count(),
                .raw_lines = self.published.raw_lines.load(.acquire),
            },
            .top_line = top,
            .base_offset = 0,
            .text = "",
            .line_starts = &.{0},
            .styles = &.{},
            .palette = &.{},
        };

        if (end_line > top) {
            const base = fb.getIndexOfLine(top).?;
            const end = fb.getLineEndIndex(end_line - 1).? + 1; // include the '\n'
            snap.base_offset = base;
            snap.text = try arena.dupe(u8, fb.buf.items[base..end]);

            const count = end_line - top;
            const starts = try arena.alloc(usize, count + 1);
            starts[0] = 0;
            for (0..count) |i| {
                starts[i + 1] = fb.newlines.items[top + i] + 1 - base;
            }
            snap.line_starts = starts;

            const ranges = self.styles.rangesIntersecting(base, end);
            if (ranges.len > 0) {
                const copy = try arena.alloc(StyleRange, ranges.len);
                for (ranges, 0..) |r, i| {
                    copy[i] = .{
                        .start = @max(r.start, base) - base,
                        .end = @min(r.end, end) - base,
                        .style = r.style,
                    };
                }
                snap.styles = copy;
                snap.palette = try arena.dupe(vaxis.Style, self.styles.palette.items);
            }
        }

        return snap;
    }

    /// Copies the complete filtered lines starting at byte `from` (used by search to keep an
    /// incrementally refreshed private copy). One lock acquisition.
    pub const FilteredCopy = struct {
        bytes: []u8,
        version: u64,
        total_len: usize,
        total_lines: usize,
    };

    pub fn copyFilteredFrom(self: *ProcessBuffer, alloc: Allocator, from: usize) Allocator.Error!FilteredCopy {
        self.m.lockUncancelable(self.io);
        defer self.m.unlock(self.io);

        const total = self.filtered_buffer.count();
        const start = @min(from, total);
        return .{
            .bytes = try alloc.dupe(u8, self.filtered_buffer.buf.items[start..total]),
            .version = self.published.version.load(.acquire),
            .total_len = total,
            .total_lines = self.filtered_buffer.countLines(),
        };
    }

    /// Copies the absolute filtered byte range `[lo, hi)`, clipped to the buffer, and the
    /// version it was read under (offsets are only meaningful for one version). One lock
    /// acquisition; the caller owns `bytes`.
    pub fn copyFilteredRange(self: *ProcessBuffer, alloc: Allocator, lo: usize, hi: usize) Allocator.Error!FilteredCopy {
        self.m.lockUncancelable(self.io);
        defer self.m.unlock(self.io);

        const total = self.filtered_buffer.count();
        const start = @min(lo, total);
        const end = @max(start, @min(hi, total));
        return .{
            .bytes = try alloc.dupe(u8, self.filtered_buffer.buf.items[start..end]),
            .version = self.published.version.load(.acquire),
            .total_len = total,
            .total_lines = self.filtered_buffer.countLines(),
        };
    }

    /// Copies a whole backing buffer. One lock acquisition.
    pub fn copyBuffer(self: *ProcessBuffer, alloc: Allocator, backing: BufferBacking) Allocator.Error![]u8 {
        self.m.lockUncancelable(self.io);
        defer self.m.unlock(self.io);
        return try alloc.dupe(u8, self.rawBytes(backing));
    }
};

const testing = std.testing;

test "snapshotWindow copies the requested lines and clamps" {
    const alloc = testing.allocator;
    const io = testing.io;

    const pb = try ProcessBuffer.init(io, alloc);
    defer pb.deinit();

    try pb.append("a\nb\nc\nta");

    const meta = pb.peek();
    try testing.expectEqual(3, meta.filtered_lines);
    try testing.expectEqual(3, meta.raw_lines);
    try testing.expectEqual(6, meta.filtered_len);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const snap = try pb.snapshotWindow(a, .{ .top_line = 1, .max_lines = 10, .follow_bottom = false });
    try testing.expectEqualStrings("b\nc\n", snap.text);
    try testing.expectEqual(2, snap.base_offset);
    try testing.expectEqual(1, snap.top_line);
    try testing.expectEqualSlices(usize, &.{ 0, 2, 4 }, snap.line_starts);
    try testing.expectEqual(2, snap.lineCount());
    try testing.expectEqual(1, snap.lineAt(0).?);
    try testing.expectEqual(2, snap.lineAt(3).?);
    try testing.expectEqual(null, snap.lineAt(4));
    try testing.expect(snap.isLineStart(0));
    try testing.expect(!snap.isLineStart(1));
    try testing.expect(snap.isLineStart(2));
    try testing.expect(!snap.isLineStart(4));

    const follow = try pb.snapshotWindow(a, .{ .top_line = 0, .max_lines = 2, .follow_bottom = true });
    try testing.expectEqual(1, follow.top_line);
    try testing.expectEqualStrings("b\nc\n", follow.text);

    const clamped = try pb.snapshotWindow(a, .{ .top_line = 99, .max_lines = 2, .follow_bottom = false });
    try testing.expectEqual(2, clamped.top_line);
    try testing.expectEqualStrings("c\n", clamped.text);
}

test "snapshotWindow on an empty buffer" {
    const alloc = testing.allocator;
    const io = testing.io;

    const pb = try ProcessBuffer.init(io, alloc);
    defer pb.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const snap = try pb.snapshotWindow(arena.allocator(), .{ .top_line = 0, .max_lines = 10, .follow_bottom = true });
    try testing.expectEqualStrings("", snap.text);
    try testing.expectEqual(0, snap.lineCount());
    try testing.expectEqual(null, snap.lineAt(0));
}

test "reprocess bumps version, append does not" {
    const alloc = testing.allocator;
    const io = testing.io;

    const pb = try ProcessBuffer.init(io, alloc);
    defer pb.deinit();

    try pb.append("apple\n");
    const v0 = pb.peek();
    try pb.append("carrot\n");
    const v1 = pb.peek();
    try testing.expectEqual(v0.version, v1.version);
    try testing.expect(v1.change > v0.change);

    try pb.removeAllFilters();
    const v2 = pb.peek();
    try testing.expect(v2.version > v1.version);
}

test "appendChunk normalises CRLF across chunk boundaries and numbers lines" {
    const alloc = testing.allocator;
    const io = testing.io;

    const pb = try ProcessBuffer.init(io, alloc);
    defer pb.deinit();

    var seq: u64 = 10;
    const n1 = try pb.appendChunk("a\r\nb\r", &seq);
    try testing.expectEqual(NewLines{ .first = 0, .count = 1 }, n1);
    const n2 = try pb.appendChunk("\nc\rd\n", &seq);
    try testing.expectEqual(NewLines{ .first = 1, .count = 2 }, n2);
    try testing.expectEqualStrings("a\nb\nc\rd\n", pb.buffer.buf.items);
    try testing.expectEqualSlices(u64, &.{ 11, 12, 13 }, pb.line_seqs.items);
    try testing.expectEqualStrings("b\nc\rd\n", pb.linesRange(n2));
    try testing.expectEqualSlices(u64, &.{ 12, 13 }, pb.seqsRange(n2));
}

test "WindowSnapshot.overlay splits existing ranges" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const red: vaxis.Style = .{ .fg = .{ .rgb = .{ 255, 0, 0 } } };
    const hi: vaxis.Style = .{ .bg = .{ .rgb = .{ 255, 255, 255 } } };
    const base: WindowSnapshot = .{
        .meta = WindowSnapshot.empty.meta,
        .top_line = 0,
        .base_offset = 0,
        .text = "0123456789\n",
        .line_starts = &.{ 0, 11 },
        .styles = &.{.{ .start = 0, .end = 10, .style = 0 }},
        .palette = &.{red},
    };
    const over = try base.overlay(a, 3, 5, hi);
    try testing.expectEqual(3, over.styles.len);
    var cursor: usize = 0;
    try testing.expectEqual(red, over.styleAt(&cursor, 1).?);
    try testing.expectEqual(hi, over.styleAt(&cursor, 4).?);
    try testing.expectEqual(red, over.styleAt(&cursor, 7).?);
    try testing.expectEqual(null, over.styleAt(&cursor, 10));
    // backwards lookup corrects the cursor
    try testing.expectEqual(hi, over.styleAt(&cursor, 3).?);
}

test "copyFilteredRange clips to the buffer and reports the version" {
    const alloc = testing.allocator;
    const pb = try ProcessBuffer.init(testing.io, alloc);
    defer pb.deinit();

    try pb.append("hello\nworld\n");

    const mid = try pb.copyFilteredRange(alloc, 2, 8);
    defer alloc.free(mid.bytes);
    try testing.expectEqualStrings("llo\nwo", mid.bytes);
    try testing.expectEqual(pb.peek().version, mid.version);
    try testing.expectEqual(12, mid.total_len);

    // hi past the end is clipped, lo past the end yields nothing
    const tail = try pb.copyFilteredRange(alloc, 6, 100);
    defer alloc.free(tail.bytes);
    try testing.expectEqualStrings("world\n", tail.bytes);

    const none = try pb.copyFilteredRange(alloc, 50, 60);
    defer alloc.free(none.bytes);
    try testing.expectEqual(0, none.bytes.len);

    // an inverted range is empty rather than a panic
    const inverted = try pb.copyFilteredRange(alloc, 8, 2);
    defer alloc.free(inverted.bytes);
    try testing.expectEqual(0, inverted.bytes.len);
}
