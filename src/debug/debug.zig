const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils");
const ringbuffer_ = @import("ringbuffer.zig");
const RingBuffer = ringbuffer_.RingBuffer(.{});

var keep_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var buffer: [4096]u8 = [_]u8{0} ** 4096;
var dest: [4096]u8 = [_]u8{0} ** 4096;
var rbuf: RingBuffer = RingBuffer.init(&buffer);

var debug_id: utils.uuid.UUID = undefined;

pub fn start_debuginfo(
    alloc: std.mem.Allocator,
    createviewprocessfn: fn (std.mem.Allocator, []const u8) std.mem.Allocator.Error!utils.uuid.UUID,
    pushfn: utils.PushFnProto,
) !void {
    if (builtin.mode == .Debug) {
        keep_running.store(true, .monotonic);
        debug_id = try createviewprocessfn(alloc, "__debug");
        _ = try std.Thread.spawn(.{}, read_loop, .{ alloc, pushfn });
    }
}

pub fn stop_debuginfo() void {
    if (builtin.mode == .Debug) {
        keep_running.store(false, .monotonic);
    }
}

fn read_loop(alloc: std.mem.Allocator, pushfn: utils.PushFnProto) !void {
    if (builtin.mode == .Debug) {
        while (keep_running.load(.monotonic)) {
            if (rbuf.used > 0) {
                var stream = std.io.fixedBufferStream(&dest);
                try rbuf.flushEverythingToWriter(stream.writer());
                if (stream.pos > 0) {
                    try pushfn(alloc, debug_id, dest[0..stream.pos]);
                }
            }
        }
    }
}

pub fn print(comptime format: []const u8, args: anytype) !void {
    if (builtin.mode == .Debug) {
        try std.fmt.format(rbuf.writer(), format, args);
    }
}
