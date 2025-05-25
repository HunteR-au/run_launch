const std = @import("std");
const uiview = @import("ui/uiview.zig");

pub const EnvTuple = struct {
    key: []u8,
    val: []u8,
};

pub fn parse_config_args(allocator: std.mem.Allocator, args_object: std.json.Array) ![]const []const u8 {
    var args = try allocator.alloc([]u8, args_object.items.len);
    errdefer allocator.free(args);

    for (args_object.items, 0..) |item, i| {
        switch (item) {
            .string => |s| {
                args[i] = try allocator.dupe(u8, s);
                errdefer allocator.free(args[i]);
            },
            else => {},
        }
    }

    return args;
}

pub fn parse_config_env(allocator: std.mem.Allocator, env_object: std.json.ObjectMap) ![]const EnvTuple {
    var envs = try allocator.alloc(EnvTuple, env_object.count());
    errdefer allocator.free(envs);

    for (env_object.keys(), env_object.values(), 0..) |key, val, i| {
        switch (val) {
            .string => |s| {
                const valcopy = try allocator.dupe(u8, s);
                errdefer allocator.free(valcopy);
                const keycopy = try allocator.dupe(u8, key);
                errdefer allocator.free(keycopy);
                envs[i] = EnvTuple{ .key = keycopy, .val = valcopy };
            },
            else => {},
        }
    }
    return envs;
}

pub fn pullpushLoop(alloc: std.mem.Allocator, childproc: std.process.Child, processname: []const u8) !void {
    const chunk_size: usize = 1024;
    std.debug.print("starting pushpull: {s}\n", .{processname});

    std.debug.assert(childproc.stdout_behavior == .Pipe);
    std.debug.assert(childproc.stderr_behavior == .Pipe);

    const outbuffer: []u8 = try alloc.alloc(u8, chunk_size);
    const errbuffer: []u8 = try alloc.alloc(u8, chunk_size);

    defer alloc.free(outbuffer);
    defer alloc.free(errbuffer);

    const stdout_reader = childproc.stdout.?;
    const stderr_reader = childproc.stderr.?;

    var poller = std.io.poll(alloc, enum { stdout, stderr }, .{
        .stdout = stdout_reader,
        .stderr = stderr_reader,
    });
    defer poller.deinit();

    std.debug.print("polling...\n", .{});
    while (try poller.pollTimeout(100000000)) {
        const stdout = poller.fifo(.stdout).readableSlice(0);
        if (stdout.len > 0) {
            try uiview.pushLogging(alloc, processname, stdout);
            poller.fifo(.stdout).discard(stdout.len);
        }

        const stderr = poller.fifo(.stderr).readableSlice(0);
        if (stderr.len > 0) {
            try uiview.pushLogging(alloc, processname, stderr);
            poller.fifo(.stderr).discard(stderr.len);
        }
    }
}
