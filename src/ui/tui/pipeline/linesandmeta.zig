const std = @import("std");
const LineBuffer = @import("linebuffer.zig").LineBuffer;
const LineTimeStamps = @import("linetimestamps.zig").LineTimeStamps;

pub const LinesAndMeta = struct {
    linebuffer: *LineBuffer,
    timestamps: *LineTimeStamps,

    // This is exclusive of micro_timestamp
    pub fn get_lines_before(self: *LinesAndMeta, micro_timestamp: i64) ?[]const u8 {
        std.debug.assert(self.linebuffer.countLines() == self.timestamps.list.items.len);

        const line_index = std.sort.lowerBound(
            i64,
            self.timestamps.list,
            micro_timestamp,
            std.sort.asc(i64),
        );

        // The index of the line returned is greater or equal to micro_timestamp
        // Therefore exit early if that line is zero
        if (line_index == 0) return null;

        const lines_opt = self.linebuffer.getLines();
        if (lines_opt == null) return null;

        const lines = lines_opt.?;

        // A timestamp that is equal or larger wasn't found
        if (line_index >= lines.len) return lines;

        return lines[0..line_index];
    }

    // This is inclusive of micro_timestamp
    pub fn get_lines_now_and_after(self: *LinesAndMeta, micro_timestamp: i64) ?[]const u8 {
        std.debug.assert(self.linebuffer.countLines() == self.timestamps.list.items.len);

        const line_index = std.sort.lowerBound(
            i64,
            self.timestamps.list,
            micro_timestamp,
            std.sort.asc(i64),
        );

        if (line_index == self.timestamps.list.items.len) return null;
        return self.linebuffer.getLinesStartingFrom(line_index);
    }

    // this is in the range of [before, after)
    pub fn get_lines_range(self: *LinesAndMeta, micro_timestamp_start: i64, micro_timestamp_end: i64) !void {
        const lines_before = self.get_lines_before(micro_timestamp_end);
        if (lines_before == null) return null;

        return self.get_lines_now_and_after(micro_timestamp_start);
    }

    fn create_sorted_timeentries(alloc: std.mem.Allocator, buffers: []LinesAndMeta) ![]LineTimeStamps.TimeEntry {
        const TimeEntry = LineTimeStamps.TimeEntry;
        var list = try std.ArrayList(TimeEntry).initCapacity(alloc, 0);
        defer list.deinit(alloc);

        for (buffers, 0..) |meta_buffer, src_id| {
            // src_id is based on the index within the buffers array
            for (meta_buffer.timestamps.list.items, 0..) |ts, idx| {
                try list.append(alloc, .{
                    .timestamp = ts,
                    .source_id = @intCast(src_id),
                    .index = idx,
                });
            }
        }

        const slice = try list.toOwnedSlice(alloc);

        std.sort.block(TimeEntry, slice, {}, struct {
            fn less(_: void, a: TimeEntry, b: TimeEntry) bool {
                return a.timestamp < b.timestamp;
            }
        }.less);

        return slice;
    }

    pub fn merge_buffers_by_time(alloc: std.mem.Allocator, buffers: []LinesAndMeta) !LinesAndMeta {
        const time_entries = try create_sorted_timeentries(alloc, buffers);
        defer alloc.free(time_entries);

        var result = LinesAndMeta{
            .linebuffer = blk: {
                const ptr = try alloc.create(LineBuffer);
                errdefer alloc.destroy(ptr);
                ptr.* = try .init(alloc);
                break :blk ptr;
            },
            .timestamps = try .init(alloc),
        };

        // create a LineBuffer from the slice of time entries
        for (time_entries) |entry| {
            // The line should exist
            try result.linebuffer.append(buffers[entry.source_id].linebuffer.getLineWithSep(entry.index).?);
            try result.timestamps.append_timestamp(entry.timestamp);
        }

        return result;
    }
};
