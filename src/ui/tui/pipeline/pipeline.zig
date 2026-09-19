//! The per-buffer processing pipeline: the terminal stage interprets each raw line into the
//! text a terminal would show (SGR colours become marks), filters transform or drop lines,
//! reviewers annotate them. Owned and mutated by the pump thread only, so no internal locking.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Filter = @import("filter.zig");
const Reviewer = @import("reviewer.zig");
const styleindex = @import("styleindex.zig");
const term = @import("terminal.zig");

pub const Pipeline = @This();
pub const Pending = styleindex.Pending;

alloc: Allocator,
filters: std.ArrayList(Filter),
reviewers: std.ArrayList(Reviewer),
/// SGR state carried between lines; reset whenever the filtered buffer is rebuilt.
terminal: term.Interpreter = .{},
/// Scratch memory for one `run` call (interpreted lines); reset at the end of every run.
scratch: std.heap.ArenaAllocator,

pub fn init(alloc: Allocator) !Pipeline {
    return .{
        .alloc = alloc,
        .filters = try std.ArrayList(Filter).initCapacity(alloc, 1),
        .reviewers = try std.ArrayList(Reviewer).initCapacity(alloc, 1),
        .scratch = std.heap.ArenaAllocator.init(alloc),
    };
}

pub fn deinit(self: *Pipeline) void {
    for (self.filters.items) |*filter| filter.deinit();
    self.filters.deinit(self.alloc);
    for (self.reviewers.items) |*reviewer| reviewer.deinit();
    self.reviewers.deinit(self.alloc);
    self.scratch.deinit();
}

/// Forgets the SGR state carried between lines. Call before re-running from the first line.
pub fn resetTerminal(self: *Pipeline) void {
    self.terminal.reset();
}

/// Runs `lines` (complete raw lines, each ending in '\n') through the terminal stage and every
/// filter, then reviews the result. `base_filtered_offset` is the absolute filtered-buffer
/// offset the returned bytes will be appended at. Marks are emitted into `pending` as
/// absolute offsets: first the program's own SGR colours, then the reviewers' marks, so a
/// colour rule wins over the program where they overlap. The SGR marks are also appended to
/// `sgr_out` so the caller can keep them for a later reviewer-only rebuild.
/// The returned slice is owned by the caller (allocated with `alloc`).
pub fn run(
    self: *Pipeline,
    alloc: Allocator,
    lines: []const u8,
    base_filtered_offset: usize,
    pending: *std.ArrayList(Pending),
    sgr_out: *std.ArrayList(Pending),
) Allocator.Error![]u8 {
    if (lines.len == 0) return try alloc.alloc(u8, 0);
    std.debug.assert(lines[lines.len - 1] == '\n');

    const scratch = self.scratch.allocator();
    defer {
        _ = self.scratch.reset(.retain_capacity);
        for (self.filters.items) |*filter| filter.freeMemory();
    }

    var result = try std.ArrayList(u8).initCapacity(alloc, lines.len);
    errdefer result.deinit(alloc);
    const first_sgr = sgr_out.items.len;

    var pos: usize = 0;
    while (std.mem.indexOfScalarPos(u8, lines, pos, '\n')) |nl| : (pos = nl + 1) {
        var raw_line = lines[pos..nl];
        // a CR split from its LF by a chunk boundary is normalised here rather than stored
        if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r') raw_line = raw_line[0 .. raw_line.len - 1];

        var rec = try self.terminal.interpretLine(scratch, raw_line);

        var keep = true;
        for (self.filters.items) |*filter| {
            switch (try filter.transformLine(filter, filter.data, rec.text)) {
                .empty => {
                    keep = false;
                    break;
                },
                .line => |new_line| {
                    if (!std.mem.eql(u8, new_line, rec.text)) {
                        // the line was rewritten: its colour marks no longer line up
                        rec.marks = &.{};
                    }
                    rec.text = new_line;
                },
            }
        }
        if (!keep) continue;

        const line_abs = base_filtered_offset + result.items.len;
        try result.appendSlice(alloc, rec.text);
        try result.append(alloc, '\n');
        for (rec.marks) |m| {
            try sgr_out.append(alloc, .{ .start = line_abs + m.lo, .end = line_abs + m.hi, .style = m.style });
        }
    }

    const out = try result.toOwnedSlice(alloc);
    errdefer alloc.free(out);

    try pending.appendSlice(alloc, sgr_out.items[first_sgr..]);
    try self.review(alloc, out, base_filtered_offset, pending);

    if (out.len > 0) std.debug.assert(out[out.len - 1] == '\n');
    return out;
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
        const line = filtered[pos..nl];

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
