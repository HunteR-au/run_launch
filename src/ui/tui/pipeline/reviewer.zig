//! A Reviewer inspects each filtered line without modifying it and may attach styles to
//! byte ranges of the line through a `LineSink`. Reviewers run on the pump thread only.
const std = @import("std");
const vaxis = @import("vaxis");
const styleindex = @import("styleindex.zig");

pub const Reviewer = @This();
pub const Pending = styleindex.Pending;

pub const HandleId = usize;
var last_id: std.atomic.Value(HandleId) = .init(0);

/// Handed to a reviewer for exactly one line. Offsets passed to `mark` are relative to the
/// start of the line; the sink converts them to absolute filtered-buffer offsets.
pub const LineSink = struct {
    /// absolute filtered offset of line[0]
    line_abs: usize,
    line_len: usize,
    alloc: std.mem.Allocator,
    out: *std.ArrayList(Pending),

    pub fn mark(self: *LineSink, style: vaxis.Style, lo: usize, hi: usize) std.mem.Allocator.Error!void {
        const clamped_hi = @min(hi, self.line_len);
        if (lo >= clamped_hi) return;
        try self.out.append(self.alloc, .{
            .start = self.line_abs + lo,
            .end = self.line_abs + clamped_hi,
            .style = style,
        });
    }

    pub fn markLine(self: *LineSink, style: vaxis.Style) std.mem.Allocator.Error!void {
        try self.mark(style, 0, self.line_len);
    }
};

pub const ReviewLineFn = *const fn (
    self: *const Reviewer,
    data: *anyopaque,
    sink: *LineSink,
    line: []const u8,
) std.mem.Allocator.Error!void;

/// Owns the reviewer's payload (regexes, patterns). Never reset while the reviewer lives.
/// Heap allocated so allocators handed out by `ownedAllocator` stay valid when the Reviewer
/// struct itself is moved into the pipeline's list.
owned: *std.heap.ArenaAllocator,
id: HandleId,
reviewLine: ReviewLineFn,
data: *anyopaque,

pub fn init(alloc: std.mem.Allocator, review_fn: ReviewLineFn) std.mem.Allocator.Error!Reviewer {
    const owned = try alloc.create(std.heap.ArenaAllocator);
    owned.* = std.heap.ArenaAllocator.init(alloc);
    return .{
        .id = last_id.fetchAdd(1, .monotonic) + 1,
        .owned = owned,
        .reviewLine = review_fn,
        .data = undefined,
    };
}

/// Allocator for the reviewer's payload. Allocate the data, then assign `data`.
pub fn ownedAllocator(self: *const Reviewer) std.mem.Allocator {
    return self.owned.allocator();
}

pub fn deinit(self: *Reviewer) void {
    const alloc = self.owned.child_allocator;
    self.owned.deinit();
    alloc.destroy(self.owned);
}
