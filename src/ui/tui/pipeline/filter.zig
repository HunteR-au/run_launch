//! A Filter rewrites or drops individual lines. Filters run on the pump thread only.
const std = @import("std");

pub const Filter = @This();

pub const TransformResult = union(enum) {
    line: []const u8,
    empty: void,
};
pub const TransformLineFn = *const fn (self: *Filter, data: *anyopaque, line: []const u8) std.mem.Allocator.Error!TransformResult;

pub const HandleId = usize;
var last_id: std.atomic.Value(HandleId) = .init(0);

/// Owns the filter's payload (regexes, replacement strings). Never reset while the filter lives.
/// Heap allocated so allocators handed out by `ownedAllocator` stay valid when the Filter
/// struct itself is moved into the pipeline's list.
owned: *std.heap.ArenaAllocator,
/// Scratch memory for one `transform` call; reset by `freeMemory` after every pipeline run.
scratch: *std.heap.ArenaAllocator,
id: HandleId,
transformLine: TransformLineFn,
data: *anyopaque,

pub fn init(alloc: std.mem.Allocator, transform_fn: TransformLineFn) std.mem.Allocator.Error!Filter {
    const owned = try alloc.create(std.heap.ArenaAllocator);
    errdefer alloc.destroy(owned);
    owned.* = std.heap.ArenaAllocator.init(alloc);

    const scratch = try alloc.create(std.heap.ArenaAllocator);
    scratch.* = std.heap.ArenaAllocator.init(alloc);

    return .{
        .id = last_id.fetchAdd(1, .monotonic) + 1,
        .owned = owned,
        .scratch = scratch,
        .transformLine = transform_fn,
        .data = undefined,
    };
}

/// Allocator for the filter's payload. Allocate the data, then assign `data`.
pub fn ownedAllocator(self: *const Filter) std.mem.Allocator {
    return self.owned.allocator();
}

pub fn deinit(self: *Filter) void {
    const alloc = self.owned.child_allocator;
    self.scratch.deinit();
    alloc.destroy(self.scratch);
    self.owned.deinit();
    alloc.destroy(self.owned);
}

pub fn freeMemory(self: *Filter) void {
    _ = self.scratch.reset(.retain_capacity);
}

/// Transforms a buffer of complete lines (each ending in '\n') and returns a buffer of
/// complete lines allocated from the scratch arena. Lines are split on '\n' on every platform;
/// a trailing '\r' is stripped so the filtered buffer is LF-only.
pub fn transform(self: *Filter, buffer: []const u8) std.mem.Allocator.Error![]const u8 {
    const alloc = self.scratch.allocator();

    var out = try std.ArrayList(u8).initCapacity(alloc, buffer.len);

    var pos: usize = 0;
    while (std.mem.indexOfScalarPos(u8, buffer, pos, '\n')) |nl| : (pos = nl + 1) {
        var line = buffer[pos..nl];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];

        switch (try self.transformLine(self, self.data, line)) {
            .line => |new_line| {
                try out.appendSlice(alloc, new_line);
                try out.append(alloc, '\n');
            },
            .empty => {},
        }
    }
    return out.items;
}
