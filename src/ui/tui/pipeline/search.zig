const std = @import("std");
const Regex = @import("regex").Regex;
const processbuffer = @import("processbuffer.zig");
const helpers = @import("../helpers.zig");

const ProcessBuffer = processbuffer.ProcessBuffer;

const RegexIterator = helpers.RegexIterator;

// how do I want to use this

// FIND
// iter = ProcessBufferSearchIterator.init(alloc, &regex, line_iter)
// result = iter.next
// jump_to(result.lowerBound, result.upperBound)                        <- todo
// highlight(result.lowerBound, result.upperBound)                      <- todo
// deHighlight...                                                       <- todo
// output.save(iter)

// NEXT
// if iter
// result = iter.next()
// jump_to(result.lowerBound, result.upperBound)
// highlight(result.lowerBound, result.upperBound)
// deHighlight...
// output.save(iter)

// PREV
// if iter
// result = iter.prev()
// jump_to(result.lowerBound, result.upperBound)
// highlight(result.lowerBound, result.upperBound)
// deHighlight...
// output.save(iter)

pub fn startSearchFrom(alloc: std.mem.Allocator, process_buffer: *ProcessBuffer, regex: *Regex, line_num: usize) !ProcessBufferSearchIterator {
    var iter = ProcessBufferSearchIterator.init(
        alloc,
        regex,
        .{ .lineIterator = try ProcessBuffer.LineIterator.init(alloc, process_buffer) },
    );
    try iter.line_iter.lineIterator.setLine(line_num);
    return iter;
}

pub const ProcessBufferSearchIterator = struct {
    alloc: std.mem.Allocator,
    regex: *Regex,
    line_iter: ProcessBuffer.IteratorPtr,
    line_offset: usize = 0,
    cached_iter: ?CachedRegexMatchIterator = null,
    cached_line: ?[]const u8 = null,

    pub const Result = struct {
        str: []const u8,
        lowerBound: usize,
        upperBound: usize,
    };

    pub fn init(
        alloc: std.mem.Allocator,
        re: *Regex,
        line_iter: ProcessBuffer.IteratorPtr,
    ) ProcessBufferSearchIterator {
        return .{
            .alloc = alloc,
            .regex = re,
            .line_iter = line_iter,
        };
    }

    pub fn deinit(self: *ProcessBufferSearchIterator) void {
        if (self.cached_iter) |*iter| {
            iter.deinit();
        }

        if (self.cached_line) |line| {
            self.alloc.free(line);
        }

        switch (self.line_iter) {
            .lineIterator => |i| {
                i.deinit();
            },
            .reverseLineIterator => |i| {
                i.deinit();
            },
        }
    }

    pub fn next(self: *ProcessBufferSearchIterator) !?Result {
        while (true) {
            if (self.cached_iter) |*cached_iter| {
                if (cached_iter.next()) |match| {
                    return .{
                        .str = match.str,
                        .lowerBound = self.line_offset + match.lowerBound,
                        .upperBound = self.line_offset + match.upperBound,
                    };
                } else {
                    self.alloc.free(self.cached_line.?);
                    self.cached_line = null;
                    self.cached_iter.?.deinit();
                    self.cached_iter = null; // Exhausted current line
                }
            }

            switch (self.line_iter) {
                .lineIterator => |p| {
                    if (try p.next(self.alloc)) |result| {
                        self.cached_line = result.line;
                        self.cached_iter = try CachedRegexMatchIterator.init(self.alloc, self.regex, self.cached_line.?, .start);
                        self.line_offset = result.buffer_offset;
                        continue;
                    } else {
                        // We have exhausted all lines
                        return null;
                    }
                },
                .reverseLineIterator => |p| {
                    // TODO: this one is a bit more complicated - we need to cache all matches in the line
                    if (try p.next(self.alloc)) |result| {
                        // cache the results
                        self.cached_line = result.line;
                        self.cached_iter = try CachedRegexMatchIterator.init(self.alloc, self.regex, self.cached_line.?, .end);
                        self.line_offset = result.buffer_offset;
                        continue;
                    } else {
                        // We have exhausted all lines
                        return null;
                    }
                },
            }
        }
    }

    pub fn prev(self: *ProcessBufferSearchIterator) !?Result {
        while (true) {
            if (self.cached_iter) |*cached_iter| {
                if (cached_iter.prev()) |match| {
                    return .{
                        .str = match.str,
                        .lowerBound = self.line_offset + match.lowerBound,
                        .upperBound = self.line_offset + match.upperBound,
                    };
                } else {
                    self.alloc.free(self.cached_line.?);
                    self.cached_line = null;
                    self.cached_iter.?.deinit();
                    self.cached_iter = null; // Exhausted current line
                }
            }

            switch (self.line_iter) {
                .lineIterator => |p| {
                    if (try p.prev(self.alloc)) |result| {
                        // cache the results
                        self.cached_line = result.line;
                        self.cached_iter = try CachedRegexMatchIterator.init(self.alloc, self.regex, self.cached_line.?, .end);
                        self.line_offset = result.buffer_offset;
                        continue;
                    } else {
                        // We have exhausted all lines
                        return null;
                    }
                },
                .reverseLineIterator => |p| {
                    if (try p.prev(self.alloc)) |result| {
                        self.cached_line = result.line;
                        self.cached_iter = try CachedRegexMatchIterator.init(self.alloc, self.regex, self.cached_line.?, .start);
                        self.line_offset = result.buffer_offset;
                        continue;
                    } else {
                        // We have exhausted all lines
                        return null;
                    }
                },
            }
        }
    }
};

const CachedRegexMatchIterator = struct {
    const Match = struct {
        str: []const u8,
        lowerBound: usize,
        upperBound: usize,
    };

    pub const Index = union(enum) {
        start: void,
        end: void,
        ofs: usize,
    };

    pub const StartPosition = enum { start, end };

    alloc: std.mem.Allocator,
    matches: []Match,
    index: Index = Index{ .start = {} },

    pub fn init(alloc: std.mem.Allocator, regex: *Regex, input: []const u8, starting_position: StartPosition) !CachedRegexMatchIterator {
        var match_list: std.ArrayListUnmanaged(Match) = .empty;
        var iter = RegexIterator{ .regex = regex, .input = input };

        while (try iter.next()) |m| {
            try match_list.append(alloc, .{
                .str = m.str,
                .lowerBound = m.lowerBound,
                .upperBound = m.upperBound,
            });
        }

        const index: Index = if (starting_position == .start) .start else .end;

        return CachedRegexMatchIterator{
            .alloc = alloc,
            .matches = try match_list.toOwnedSlice(alloc),
            .index = index,
        };
    }

    pub fn next(self: *CachedRegexMatchIterator) ?Match {
        self.index = switch (self.index) {
            .start => if (self.matches.len == 0) .end else .{ .ofs = 0 },
            .ofs => |i| if (i + 1 >= self.matches.len) .end else .{ .ofs = i + 1 },
            .end => .end,
        };
        return self.peek();
    }

    pub fn prev(self: *CachedRegexMatchIterator) ?Match {
        self.index = switch (self.index) {
            .end => if (self.matches.len == 0) .start else .{ .ofs = self.matches.len - 1 },
            .ofs => |i| if (i == 0) .start else .{ .ofs = i - 1 },
            .start => .start,
        };
        return self.peek();
    }

    pub fn peek(self: *CachedRegexMatchIterator) ?Match {
        if (self.index == .ofs) return self.matches[self.index.ofs] else return null;
    }

    pub fn reset(self: *CachedRegexMatchIterator) void {
        self.index = .start;
    }

    pub fn seekToEnd(self: *CachedRegexMatchIterator) void {
        self.index = .end;
    }

    pub fn deinit(self: *CachedRegexMatchIterator) void {
        self.alloc.free(self.matches);
    }
};

const testing = std.testing;
test "Reverse direction of ProcessBufferSearchIterator within line" {
    const alloc = testing.allocator_instance.allocator();

    const prefixes = comptime [_][]const u8{
        "",
        "Line 2 with ",
        "Line 3 with ",
    };

    const lines = comptime [_][]const u8{
        prefixes[0] ++ "string Line 1 with string string string x",
        prefixes[1] ++ "string out",
        prefixes[2] ++ "string out",
    };

    const line_lens = comptime blk: {
        var result: [lines.len]usize = undefined;
        for (0..lines.len) |i| {
            result[i] = lines[i].len;
        }
        break :blk result;
    };
    _ = line_lens;

    const input = comptime blk: {
        var input: []const u8 = "";
        for (0..lines.len - 1) |i| {
            input = input ++ lines[i] ++ "\n";
        }
        input = input ++ lines[lines.len - 1];
        break :blk input;
    };

    const match_str = "string";
    const process_buffer = try ProcessBuffer.init(alloc);
    defer process_buffer.deinit();

    try process_buffer.append(input);

    var regex = try Regex.compile(alloc, match_str);
    defer regex.deinit();

    var iter = ProcessBufferSearchIterator.init(
        alloc,
        &regex,
        .{ .lineIterator = try ProcessBuffer.LineIterator.init(
            alloc,
            process_buffer,
        ) },
    );
    defer iter.deinit();

    const m = try iter.next();
    try testing.expect(m != null);
    try testing.expectEqual(0, iter.line_offset);
    try testing.expectEqualStrings(match_str, m.?.str);

    const m1 = try iter.next();
    try testing.expect(m1 != null);
    try testing.expectEqual(0, iter.line_offset);
    try testing.expectEqualStrings(match_str, m1.?.str);

    const m2 = try iter.next();
    try testing.expect(m2 != null);
    try testing.expectEqual(0, iter.line_offset);
    try testing.expectEqualStrings(match_str, m2.?.str);

    const m3 = try iter.prev();
    try testing.expect(m3 != null);
    try testing.expectEqual(0, iter.line_offset);
    try testing.expectEqualStrings(match_str, m3.?.str);
    try testing.expectEqualDeep(m3, m1);

    // TODO fix memory leaks
}

test "Reverse direction of ProcessBufferSearchIterator over lines" {
    const alloc = testing.allocator_instance.allocator();

    const prefixes = comptime [_][]const u8{
        "Line 1 with ",
        "Line 2 with ",
        "Line 3 with ",
        "Line 4 with ",
        "Line 5 with ",
    };

    const lines = comptime [_][]const u8{
        prefixes[0] ++ "string out",
        prefixes[1] ++ "string out",
        prefixes[2] ++ "string out",
    };

    const line_lens = comptime blk: {
        var result: [lines.len]usize = undefined;
        for (0..lines.len) |i| {
            result[i] = lines[i].len;
        }
        break :blk result;
    };

    const input = comptime blk: {
        var input: []const u8 = "";
        for (0..lines.len - 1) |i| {
            input = input ++ lines[i] ++ "\n";
        }
        input = input ++ lines[lines.len - 1];
        break :blk input;
    };

    const match_str = "string";
    const process_buffer = try ProcessBuffer.init(alloc);
    defer process_buffer.deinit();

    try process_buffer.append(input);

    var regex = try Regex.compile(alloc, match_str);
    defer regex.deinit();

    var iter = ProcessBufferSearchIterator.init(
        alloc,
        &regex,
        .{ .lineIterator = try ProcessBuffer.LineIterator.init(
            alloc,
            process_buffer,
        ) },
    );
    defer iter.deinit();

    const m = try iter.next();
    try testing.expect(m != null);
    try testing.expectEqual(0, iter.line_offset);
    try testing.expectEqualStrings(match_str, m.?.str);

    const m1 = try iter.next();
    try testing.expect(m1 != null);
    try testing.expectEqual(line_lens[0] + 1, iter.line_offset);
    try testing.expectEqualStrings(match_str, m1.?.str);

    const m2 = try iter.prev();
    try testing.expect(m2 != null);
    try testing.expectEqual(0, iter.line_offset);
    try testing.expectEqualStrings(match_str, m2.?.str);
    try testing.expectEqualDeep(m2, m);
}
