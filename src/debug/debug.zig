//! Debug-only diagnostics view. Messages are pushed through the pump like any other
//! process output, into a buffer named `__debug`. Never blocks: a print from inside a UI
//! draw drops the message rather than waiting on backpressure.
const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const utils = @import("utils");
const pump_ = @import("pump");

const Pump = pump_.Pump;

var g_pump: ?*Pump = null;
var g_io: Io = undefined;
var g_id: utils.uuid.UUID = undefined;

pub fn init(io: Io, pump: *Pump) !void {
    if (builtin.mode != .Debug) return;
    g_io = io;
    g_id = utils.uuid.newV4(io);
    const name = try pump.alloc.dupe(u8, "__debug");
    pump.submit(io, .{ .create_buffer = .{ .id = g_id, .name = name } }) catch |err| {
        pump.alloc.free(name);
        return err;
    };
    g_pump = pump;
}

pub fn deinit() void {
    g_pump = null;
}

pub fn print(comptime format: []const u8, args: anytype) !void {
    if (builtin.mode != .Debug) return;
    const pump = g_pump orelse return;

    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, format, args) catch buf[0..];
    const copy = try pump.alloc.dupe(u8, text);
    const accepted = pump.trySubmit(g_io, .{ .bytes = .{ .id = g_id, .stream = .stdout, .data = copy } }) catch false;
    if (!accepted) pump.alloc.free(copy);
}
