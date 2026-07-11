const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const utils = @import("utils");
const ringbuffer_ = @import("ringbuffer.zig");
const RingBuffer = ringbuffer_.RingBuffer(.{});

var keep_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var buffer: [4096]u8 = [_]u8{0} ** 4096;
var dest: [4096]u8 = [_]u8{0} ** 4096;
var rbuf: RingBuffer = RingBuffer.init(&buffer);
var __io: Io = undefined;

var debug_id: utils.uuid.UUID = undefined;

pub fn start_debuginfo(
    io: Io,
    alloc: std.mem.Allocator,
    createviewprocessfn: fn (Io, std.mem.Allocator, []const u8) std.mem.Allocator.Error!utils.uuid.UUID,
    pushfn: utils.PushFnProto,
) !void {
    if (builtin.mode == .Debug) {
        keep_running.store(true, .monotonic);
        debug_id = try createviewprocessfn(io, alloc, "__debug");
        __io = io;
        _ = try std.Thread.spawn(.{}, read_loop, .{ io, alloc, pushfn });
    }
}

pub fn stop_debuginfo() void {
    if (builtin.mode == .Debug) {
        keep_running.store(false, .monotonic);
    }
}

fn read_loop(io: Io, alloc: std.mem.Allocator, pushfn: utils.PushFnProto) !void {
    if (builtin.mode == .Debug) {
        while (keep_running.load(.monotonic)) {
            if (rbuf.used > 0) {
                var writer: std.Io.Writer = .fixed(&dest);
                try rbuf.flushEverythingToWriter(io, &writer);
                if (writer.end > 0) {
                    try pushfn(io, alloc, debug_id, dest[0..writer.end]);
                }

                //var stream = std.io.fixedBufferStream(&dest);
                //try rbuf.flushEverythingToWriter(stream.writer());
                // if (stream.pos > 0) {
                //     try pushfn(alloc, debug_id, dest[0..stream.pos]);
                // }
            }
        }
    }
}

pub fn print(comptime format: []const u8, args: anytype) !void {
    if (builtin.mode == .Debug) {
        var buf: [128]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, format, args);
        try rbuf.writeAll(__io, msg);
    }
}
