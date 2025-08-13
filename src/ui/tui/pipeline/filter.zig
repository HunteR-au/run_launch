const std = @import("std");
const builtin = @import("builtin");
const ProcessBuffer = @import("processbuffer.zig").ProcessBuffer;

pub const Filter = @This();

pub const TransformResult = union(enum) {
    line: []const u8,
    empty: void,
};
pub const TransformLineFn = *const fn (self: *const Filter, data: *anyopaque, line: []const u8) std.mem.Allocator.Error!TransformResult;

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

pub fn transform(self: *Filter, buffer: []const u8) ![]const u8 {
    const alloc = self.arena.allocator();

    var lines = std.ArrayList([]const u8).init(alloc);

    switch (builtin.target.os.tag) {
        .windows => {
            const sep = "\n";
            var it = std.mem.tokenizeSequence(u8, buffer, sep);
            std.debug.print("filter:transform()\n", .{});
            while (it.next()) |line| {
                std.debug.print("processing line: {s}\n", .{line});
                std.debug.print("\n", .{});
                switch (try self.transformLine(self, self.data, line)) {
                    .line => |new_buf| {
                        std.debug.print("for line: {s}\ntransforming to: {s}\n", .{ line, new_buf });
                        try lines.append(new_buf);
                    },
                    .empty => {
                        std.debug.print("filter:empty...\n", .{});
                    },
                }
            }
            const new_buffer = try std.mem.join(alloc, sep, lines.items);
            return new_buffer;
        },
        else => {
            const sep: u8 = '\n';
            var it = std.mem.tokenizeScalar(u8, buffer, sep);
            while (it.next()) |line| {
                switch (try self.transformLine(self, self.data, line)) {
                    .line => |new_buf| {
                        try lines.append(new_buf);
                    },
                    .empty => {},
                }
            }
            if (lines.items.len == 0) {
                return "";
            } else {
                try lines.append("");
                const new_buffer = try std.mem.join(alloc, &[1]u8{sep}, lines.items);
                return new_buffer;
            }
        },
    }
}
