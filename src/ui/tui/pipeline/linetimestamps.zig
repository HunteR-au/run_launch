const std = @import("std");
const time = std.time;

pub const TimeStamp = i64;
pub const TimeStamps = std.ArrayList(TimeStamp);

pub fn append_now(alloc: std.mem.Allocator, timestamps: TimeStamps) !void {
    timestamps.append(alloc, time.microTimestamp());
}

pub fn append_timestamp(alloc: std.mem.Allocator, timestamps: *TimeStamps, tstamp: TimeStamp) !void {
    const len = timestamps.items.len;
    if (len > 0 and tstamp < timestamps.items[len - 1]) {
        return error.TimeStampOutOfOrder;
    }
    try timestamps.append(alloc, tstamp);
}
