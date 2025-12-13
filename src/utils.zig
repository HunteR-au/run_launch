const std = @import("std");
const builtin = @import("builtin");

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

pub fn parseTripleInt(input: []const u8) ![3]u32 {
    var parts: [3]u32 = undefined;
    var part_index: usize = 0;
    var start: usize = 0;

    var i: usize = 0;
    while (i <= input.len) {
        if (i == input.len or input[i] == ',') {
            if (part_index >= 3) return error.TooManyParts;

            const slice = input[start..i];
            if (slice.len == 0) return error.InvalidFormat;

            parts[part_index] = std.fmt.parseInt(u32, slice, 10) catch return error.InvalidNumber;
            part_index += 1;
            start = i + 1;
        }
        i += 1;
    }

    if (part_index != 3) return error.TooFewParts;
    return parts;
}

pub fn parseArgsLineWithQuoteGroups(alloc: std.mem.Allocator, input: []const u8) ![]const []const u8 {
    var list = try std.ArrayList([]const u8).initCapacity(alloc, 10);
    var i: usize = 0;

    while (i < input.len) {
        // Skip whitespace
        while (i < input.len and std.ascii.isWhitespace(input[i])) : (i += 1) {}

        if (i >= input.len) break;

        // Handle quoted string with escapes
        if (input[i] == '"') {
            i += 1;
            var buffer = try std.ArrayList(u8).initCapacity(alloc, 10);

            while (i < input.len) {
                if (input[i] == '\\') {
                    i += 1;
                    if (i < input.len) {
                        try buffer.append(alloc, input[i]);
                        i += 1;
                    }
                } else if (input[i] == '"') {
                    i += 1;
                    break;
                } else {
                    try buffer.append(alloc, input[i]);
                    i += 1;
                }
            }

            try list.append(alloc, try buffer.toOwnedSlice(alloc));
        } else {
            // Handle unquoted work
            const start = i;
            while (i < input.len and !std.ascii.isWhitespace(input[i])) : (i += 1) {}
            try list.append(alloc, try alloc.dupe(u8, input[start..i]));
        }
    }

    return list.toOwnedSlice(alloc);
}

pub fn create_env_map(alloc: std.mem.Allocator, envtuples: []const EnvTuple) !std.process.EnvMap {
    var env_map = try std.process.getEnvMap(alloc);
    errdefer env_map.deinit();

    for (envtuples) |*env| {
        try env_map.put(env.key, env.val);
    }
    return env_map;
}

pub fn parse_dotenv_file(alloc: std.mem.Allocator, filepath: []const u8) ![]EnvTuple {
    var filebuf: []u8 = undefined;

    if (std.fs.path.isAbsolute(filepath)) {
        var file = try std.fs.openFileAbsolute(filepath, .{ .mode = .read_only });
        defer file.close();
        filebuf = try file.readToEndAlloc(alloc, std.math.maxInt(usize));
    } else {
        var file = try std.fs.cwd().openFile(filepath, .{ .mode = .read_only });
        defer file.close();
        filebuf = try file.readToEndAlloc(alloc, std.math.maxInt(usize));
    }
    defer alloc.free(filebuf);

    var split_iter = undefined;
    switch (builtin.target.os.tag) {
        .windows => {
            split_iter = std.mem.splitScalar(u8, filebuf, std.fs.path.set_windows);
        },
        else => {
            split_iter = std.mem.splitScalar(u8, filebuf, std.fs.path.sep_posix);
        },
    }

    var linecount = 0;
    while (split_iter.next()) |_| {
        linecount = linecount + 1;
    }

    var tuples = try alloc(EnvTuple, linecount);
    errdefer alloc.free(tuples);
    split_iter.reset();
    var i: usize = 0;
    while (split_iter.next()) |line| : (i += 1) {
        // find first '=' char
        const idx = try std.mem.indexOfScalar(u8, line, "=");
        const first = alloc.dupe(u8, line[0..idx]);
        const second = alloc.dupe(u8, line[idx..line.len]);
        tuples[i] = EnvTuple{ .key = first, .val = second };
    }

    return tuples;
}

pub const PushFnProto = fn (std.mem.Allocator, []const u8, []const u8) std.mem.Allocator.Error!void;

pub fn pullpushLoop(
    alloc: std.mem.Allocator,
    pushfn: PushFnProto,
    childproc: std.process.Child,
    processname: []const u8,
) !void {
    const chunk_size: usize = 1024;
    //std.debug.print("starting pushpull: {s}\n", .{processname});

    std.debug.assert(childproc.stdout_behavior == .Pipe);
    std.debug.assert(childproc.stderr_behavior == .Pipe);

    const outbuffer: []u8 = try alloc.alloc(u8, chunk_size);
    const errbuffer: []u8 = try alloc.alloc(u8, chunk_size);

    defer alloc.free(outbuffer);
    defer alloc.free(errbuffer);

    const stdout_reader = childproc.stdout.?;
    const stderr_reader = childproc.stderr.?;

    //const Stream = enum { stdout, stderr };
    //var poller = std.Io.Poller(Stream);

    var poller = std.Io.poll(alloc, enum { stdout, stderr }, .{
        .stdout = stdout_reader,
        .stderr = stderr_reader,
    });
    defer poller.deinit();

    //std.debug.print("polling...\n", .{});
    while (try poller.pollTimeout(100_000_000)) {
        const stdout_buf = try poller.toOwnedSlice(.stdout);
        if (stdout_buf.len > 0) {
            try pushfn(alloc, processname, stdout_buf);
        }

        const stderr_buf = try poller.toOwnedSlice(.stderr);
        if (stderr_buf.len > 0) {
            try pushfn(alloc, processname, stderr_buf);
        }

        //const stdout = poller.fifo(.stdout).readableSlice(0);
        //if (stdout.len > 0) {
        //    try pushfn(alloc, processname, stdout);
        //    poller.fifo(.stdout).discard(stdout.len);
        //}

        //const stderr = poller.fifo(.stderr).readableSlice(0);
        //if (stderr.len > 0) {
        //    try pushfn(alloc, processname, stderr);
        //    poller.fifo(.stderr).discard(stderr.len);
        //}
    }
}

// AI impl

//pub fn pullpushLoop(
//    alloc: std.mem.Allocator,
//    pushfn: PushFnProto,
//    childproc: std.process.Child,
//    processname: []const u8,
//) !void {
//    const chunk_size: usize = 1024;
//
//    const outbuffer: []u8 = try alloc.alloc(u8, chunk_size);
//    const errbuffer: []u8 = try alloc.alloc(u8, chunk_size);
//    defer alloc.free(outbuffer);
//    defer alloc.free(errbuffer);
//
//    const stdout_reader = childproc.stdout orelse return error.NotOpenForReading;
//    const stderr_reader = childproc.stderr orelse return error.NotOpenForReading;
//
//    var poller = std.io.poll(alloc, enum { stdout, stderr }, .{
//        .stdout = stdout_reader,
//        .stderr = stderr_reader,
//    });
//    defer poller.deinit();
//
//    while (true) {
//        const polled = poller.pollTimeout(100_000_000) catch |err| {
//            switch (err) {
//                error.NotOpenForReading => break, // pipes closed → exit loop
//                else => return err,              // propagate other errors
//            }
//        };
//
//        if (!polled) break; // timeout → no more events
//
//        const stdout = poller.fifo(.stdout).readableSlice(0);
//        if (stdout.len > 0) {
//            try pushfn(alloc, processname, stdout);
//            poller.fifo(.stdout).discard(stdout.len);
//        }
//
//        const stderr = poller.fifo(.stderr).readableSlice(0);
//        if (stderr.len > 0) {
//            try pushfn(alloc, processname, stderr);
//            poller.fifo(.stderr).discard(stderr.len);
//        }
//    }
//}

pub fn cloneHashMap(
    comptime K: type,
    comptime V: type,
    comptime Context: type,
    comptime LoadPercentage: comptime_float,
    alloc: std.mem.Allocator,
    source: *std.HashMap(K, V, Context, LoadPercentage),
) !std.HashMap(K, V, Context, LoadPercentage) {
    var target = std.HashMap(K, V, Context, LoadPercentage).init(alloc);

    var it = source.iterator();
    while (it.next()) |entry| {
        try target.put(entry.key_ptr.*, entry.value_ptr.*);
    }

    return target;
}

pub fn get_home_path(alloc: std.mem.Allocator) ?[]const u8 {
    return std.process.getEnvVarOwned(alloc, "HOME") catch {
        return null;
    };
}

const testing = std.testing;
test "parseArgsLineWithQuoteGroups: with quotes" {
    const alloc = testing.allocator_instance.allocator();

    const results = try parseArgsLineWithQuoteGroups(alloc, "arg1 arg2 \"arg3 arg3\"");
    defer {
        for (results) |s| alloc.free(s);
        alloc.free(results);
    }

    try testing.expectEqualStrings("arg1", results[0]);
    try testing.expectEqualStrings("arg2", results[1]);
    try testing.expectEqualStrings("arg3 arg3", results[2]);
}

test "parseArgsLineWithQuoteGroups: with escaped quotes" {
    const alloc = testing.allocator_instance.allocator();

    const results = try parseArgsLineWithQuoteGroups(alloc, "arg1 \"\\\"quote\\\" not quote\"");
    defer {
        for (results) |s| alloc.free(s);
        alloc.free(results);
    }

    try testing.expectEqualStrings("arg1", results[0]);
    try testing.expectEqualStrings("\"quote\" not quote", results[1]);
}

test "parseTripleInt" {
    const input1 = "1,2,3";
    const parts1 = try parseTripleInt(input1);
    const expected1: [3]u32 = .{ 1, 2, 3 };

    const input2 = "255,255,255";
    const parts2 = try parseTripleInt(input2);
    const expected2: [3]u32 = .{ 255, 255, 255 };

    const input3 = "1,2";
    const parts3 = parseTripleInt(input3);

    const input4 = "1,2,3,4";
    const parts4 = parseTripleInt(input4);

    const input5 = "001,100,3";
    const parts5 = try parseTripleInt(input5);
    const expected5: [3]u32 = .{ 1, 100, 3 };

    try testing.expectEqualSlices(u32, &expected1, &parts1);
    try testing.expectEqualSlices(u32, &expected2, &parts2);
    try testing.expectError(error.TooFewParts, parts3);
    try testing.expectError(error.TooManyParts, parts4);
    try testing.expectEqualSlices(u32, &expected5, &parts5);
}
