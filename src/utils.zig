const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

pub const uuid = @import("utils/uuid.zig");
pub const ringbuffers = @import("utils/ringbuffer.zig");

pub const EnvTuple = struct {
    key: []u8,
    val: []u8,
};

pub fn parse_config_args(allocator: Allocator, args_object: std.json.Array) ![]const []const u8 {
    const args = try allocator.alloc([]u8, args_object.items.len);
    // Initialise every slot so the cleanup below is always safe
    for (args) |*arg| arg.* = &.{};
    errdefer {
        for (args) |arg| if (arg.len > 0) allocator.free(arg);
        allocator.free(args);
    }

    for (args_object.items, 0..) |item, i| switch (item) {
        .string => |str| args[i] = try allocator.dupe(u8, str),
        else => return error.FieldInvalidType,
    };

    return args;
}

pub fn parse_config_env(allocator: Allocator, env_object: std.json.ObjectMap) ![]const EnvTuple {
    const envs = try allocator.alloc(EnvTuple, env_object.count());
    // Initialise every slot so the cleanup below is always safe
    for (envs) |*env| env.* = .{ .key = &.{}, .val = &.{} };
    errdefer {
        for (envs) |env| {
            if (env.key.len > 0) allocator.free(env.key);
            if (env.val.len > 0) allocator.free(env.val);
        }
        allocator.free(envs);
    }

    for (env_object.keys(), env_object.values(), 0..) |key, val, i| switch (val) {
        .string => |str| {
            envs[i].key = try allocator.dupe(u8, key);
            envs[i].val = try allocator.dupe(u8, str);
        },
        else => return error.FieldInvalidType,
    };

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

pub fn parseArgsLineWithQuoteGroups(alloc: Allocator, input: []const u8) ![]const []const u8 {
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

pub fn create_env_map(alloc: Allocator, envtuples: []const EnvTuple) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(alloc);
    errdefer map.deinit();

    for (envtuples) |*env| {
        try map.put(env.key, env.val);
    }
    return map;
}

pub fn cloneHashMap(
    comptime K: type,
    comptime V: type,
    comptime Context: type,
    comptime LoadPercentage: comptime_float,
    alloc: Allocator,
    source: *std.HashMap(K, V, Context, LoadPercentage),
) !std.HashMap(K, V, Context, LoadPercentage) {
    var target = std.HashMap(K, V, Context, LoadPercentage).init(alloc);

    var it = source.iterator();
    while (it.next()) |entry| {
        try target.put(entry.key_ptr.*, entry.value_ptr.*);
    }

    return target;
}

pub fn get_home_path(alloc: Allocator) ?[]const u8 {
    return std.process.getEnvVarOwned(alloc, "HOME") catch {
        return null;
    };
}

pub fn makeWindowsSafeFilename(
    alloc: Allocator,
    input: []const u8,
) ![]u8 {
    // Forbidden characters on Windows
    const forbidden = "\\/:*?\"<>|";

    var list = try std.ArrayList(u8).initCapacity(alloc, 0);
    errdefer list.deinit(alloc);

    for (input) |c| {
        if (c < 32) continue; // skip control chars
        if (std.mem.indexOfScalar(u8, forbidden, c) != null) {
            try list.append(alloc, '_');
        } else {
            try list.append(alloc, c);
        }
    }

    var out = try list.toOwnedSlice(alloc);

    // Trim trailing spaces and periods
    while (out.len > 0 and (out[out.len - 1] == ' ' or out[out.len - 1] == '.')) {
        out = out[0 .. out.len - 1];
    }

    // Avoid empty filename
    if (out.len == 0) {
        return try alloc.dupe(u8, "unnamed");
    }

    // Avoid reserved device names
    const lower = try alloc.alloc(u8, out.len);
    _ = std.ascii.lowerString(lower, out);
    defer alloc.free(lower);

    const reserved = [_][]const u8{
        "con",  "prn",  "aux",  "nul",
        "com1", "com2", "com3", "com4",
        "com5", "com6", "com7", "com8",
        "com9", "lpt1", "lpt2", "lpt3",
        "lpt4", "lpt5", "lpt6", "lpt7",
        "lpt8", "lpt9",
    };

    for (reserved) |r| {
        if (std.mem.eql(u8, lower, r)) {
            // Append underscore to avoid collision
            return try std.mem.concat(alloc, u8, &.{ out, "_" });
        }
    }

    return out;
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

test "parse_config_args: strings are duped, non-strings are rejected without leaking" {
    const alloc = testing.allocator;

    var ok = try std.json.parseFromSlice(std.json.Value, alloc, "[\"a\", \"bee\"]", .{});
    defer ok.deinit();
    const args = try parse_config_args(alloc, ok.value.array);
    defer {
        for (args) |s| alloc.free(s);
        alloc.free(args);
    }
    try testing.expectEqual(2, args.len);
    try testing.expectEqualStrings("a", args[0]);
    try testing.expectEqualStrings("bee", args[1]);

    var bad = try std.json.parseFromSlice(std.json.Value, alloc, "[\"ok\", 42]", .{});
    defer bad.deinit();
    try testing.expectError(error.FieldInvalidType, parse_config_args(alloc, bad.value.array));
}

test "parse_config_env: pairs are duped, non-string values are rejected without leaking" {
    const alloc = testing.allocator;

    var ok = try std.json.parseFromSlice(std.json.Value, alloc, "{\"K\": \"v\", \"E\": \"\"}", .{});
    defer ok.deinit();
    const envs = try parse_config_env(alloc, ok.value.object);
    defer {
        for (envs) |e| {
            alloc.free(e.key);
            alloc.free(e.val);
        }
        alloc.free(envs);
    }
    try testing.expectEqual(2, envs.len);
    try testing.expectEqualStrings("K", envs[0].key);
    try testing.expectEqualStrings("v", envs[0].val);
    try testing.expectEqualStrings("E", envs[1].key);
    try testing.expectEqualStrings("", envs[1].val);

    var bad = try std.json.parseFromSlice(std.json.Value, alloc, "{\"K\": \"v\", \"N\": 1}", .{});
    defer bad.deinit();
    try testing.expectError(error.FieldInvalidType, parse_config_env(alloc, bad.value.object));
}
