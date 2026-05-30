// we want to add timestamps as microseconds

const std = @import("std");
const time = std.time;

// This is bad design and should be reconsidered at some point.
// Currently what the refactor would look like...
pub const LineTimeStamps = struct {
    alloc: std.mem.Allocator,
    list: std.ArrayList(i64),

    pub const TimeEntry = struct {
        timestamp: i64,
        source_id: u32,
        index: usize,
    };

    pub fn init(alloc: std.mem.Allocator) !*LineTimeStamps {
        const self = try alloc.create(LineTimeStamps);
        self.* = .{
            .alloc = alloc,
            .list = try .initCapacity(alloc, 0),
        };
        return self;
    }

    pub fn deinit(self: *LineTimeStamps) void {
        self.list.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    pub fn append_timestamp(self: *LineTimeStamps, micro_timestamp: i64) !void {
        try self.list.append(self.alloc, micro_timestamp);
    }

    pub fn append(self: *LineTimeStamps) !void {
        try self.list.append(self.alloc, time.microTimestamp());
    }
};
