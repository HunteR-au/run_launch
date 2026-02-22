const std = @import("std");
const builtin = @import("builtin");
const ProcessBuffer = @import("processbuffer.zig").ProcessBuffer;

pub const Filter = @This();

pub const TransformResult = union(enum) {
    line: []const u8,
    empty: void,
};
pub const TransformLineFn = *const fn (self: *Filter, data: *anyopaque, line: []const u8) std.mem.Allocator.Error!TransformResult;

pub const HandleId = usize;
var lastId: HandleId = 0;

arena: std.heap.ArenaAllocator,
id: HandleId,
transformLine: TransformLineFn,
data: *anyopaque,

pub fn init(alloc: std.mem.Allocator, data: *anyopaque, transform_func: TransformLineFn) !Filter {
    lastId = lastId +| 1;
    return .{
        .id = lastId,
        .arena = std.heap.ArenaAllocator.init(alloc),
        .transformLine = transform_func,
        .data = data,
    };
}

pub fn deinit(self: *Filter) void {
    self.arena.deinit();
}

pub fn freeMemory(self: *Filter) void {
    _ = self.arena.reset(.retain_capacity);
}

//
// TODO: define the requirements for this function
//
pub fn transform(self: *Filter, buffer: []const u8) ![]const u8 {
    const alloc = self.arena.allocator();

    var lines = try std.ArrayList([]const u8).initCapacity(alloc, 1);

    // TODO: This contains bugs. newlines are being chopped apart and not put back together!!!
    switch (builtin.target.os.tag) {
        .windows => {
            const sep = "\r\n";
            var it = std.mem.tokenizeSequence(u8, buffer, sep);
            while (it.next()) |line| {
                switch (try self.transformLine(self, self.data, line)) {
                    .line => |new_buf| {
                        try lines.append(alloc, new_buf);
                    },
                    .empty => {},
                }
            }
            const new_buffer = try joinWithEndingSep(alloc, sep, lines.items);
            std.log.debug("filtered lines: {s}", .{new_buffer});
            return new_buffer;
        },
        else => {
            const sep: u8 = '\n';
            var it = std.mem.tokenizeScalar(u8, buffer, sep);
            while (it.next()) |line| {
                switch (try self.transformLine(self, self.data, line)) {
                    .line => |new_buf| {
                        try lines.append(alloc, new_buf);
                    },
                    .empty => {},
                }
            }
            if (lines.items.len == 0) {
                return "";
            } else {
                try lines.append(alloc, "");
                const new_buffer = try joinWithEndingSep(alloc, &[1]u8{sep}, lines.items);
                return new_buffer;
            }
        },
    }
}

/// Naively combines a series of slices with a separator plus a separator at the end.
/// Allocates memory for the result, which must be freed by the caller.
fn joinWithEndingSep(allocator: std.mem.Allocator, separator: []const u8, slices: []const []const u8) std.mem.Allocator.Error![]u8 {
    if (slices.len == 0) return &[0]u8{};

    const total_len = blk: {
        var sum: usize = separator.len * (slices.len);
        for (slices) |slice| sum += slice.len;
        break :blk sum;
    };

    const buf = try allocator.alloc(u8, total_len);
    errdefer allocator.free(buf);

    @memcpy(buf[0..slices[0].len], slices[0]);
    var buf_index: usize = slices[0].len;
    for (slices[1..]) |slice| {
        @memcpy(buf[buf_index .. buf_index + separator.len], separator);
        buf_index += separator.len;
        @memcpy(buf[buf_index .. buf_index + slice.len], slice);
        buf_index += slice.len;
    }
    @memcpy(buf[buf_index .. buf_index + separator.len], separator);

    // No need for shrink since buf is exactly the correct size.
    return buf;
}
