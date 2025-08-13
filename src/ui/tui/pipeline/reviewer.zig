const std = @import("std");
const builtin = @import("builtin");
const ProcessBuffer = @import("processbuffer.zig").ProcessBuffer;

pub const Reviewer = @This();

pub const MetaData = struct {
    bufferOffset: usize,
    // note: could add view info in here
};

pub const HandleId = usize;
var lastId: HandleId = 0;

pub const ReviewLineFn = *const fn (self: *const Reviewer, data: *anyopaque, metadata: MetaData, line: []const u8) std.mem.Allocator.Error!void;

arena: std.heap.ArenaAllocator,
id: HandleId,
reviewLine: ReviewLineFn,
data: *anyopaque,

pub fn init(alloc: std.mem.Allocator, data: *anyopaque, transform_func: ReviewLineFn) !Reviewer {
    lastId = lastId +| 1;
    return .{
        .id = lastId,
        .arena = std.heap.ArenaAllocator.init(alloc),
        .reviewLine = transform_func,
        .data = data,
    };
}

pub fn deinit(self: *Reviewer) void {
    self.arena.deinit();
}

pub fn review(self: *Reviewer, buffer: []const u8, metadata: MetaData) !void {
    var updated_metadata = metadata;
    switch (builtin.target.os.tag) {
        .windows => {
            const sep = "\n";
            var it = std.mem.tokenizeSequence(u8, buffer, sep);
            var offset: usize = 0;
            while (it.next()) |line| : (offset = it.index + 1 + metadata.bufferOffset) {
                updated_metadata.bufferOffset = offset + metadata.bufferOffset;
                try self.reviewLine(self, self.data, updated_metadata, line);
            }
        },
        else => {
            const sep: u8 = '\n';
            var it = std.mem.tokenizeScalar(u8, buffer, sep);
            var offset: usize = 0;
            while (it.next()) |line| : (offset = it.index + 1 + metadata.bufferOffset) {
                updated_metadata.bufferOffset = offset + metadata.bufferOffset;
                try self.reviewLine(self, self.data, updated_metadata, line);
            }
        },
    }
}
