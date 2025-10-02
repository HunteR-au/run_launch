const std = @import("std");
const Regex = @import("regex").Regex;

pub const RegexIterator = struct {
    regex: *Regex,
    input: []const u8,
    offset: usize = 0,
    match_len: ?usize = null,

    const Result = struct {
        str: []const u8,
        lowerBound: usize,
        upperBound: usize,
    };

    pub fn next(self: *RegexIterator) !?Result {
        const result = try self.peek() orelse return null;
        self.offset +|= result.upperBound;
        return result;
    }

    pub fn peek(self: *RegexIterator) !?Result {
        if (self.offset >= self.input.len) return null;

        const slice = self.input[self.offset..];
        var captures = try self.regex.captures(slice);
        if (captures == null) return null;
        defer captures.?.deinit();

        const start = captures.?.boundsAt(0).?.lower;
        return .{
            .str = captures.?.sliceAt(0).?,
            .lowerBound = captures.?.boundsAt(0).?.lower,
            .upperBound = start + captures.?.sliceAt(0).?.len,
        };
    }

    pub fn reset(self: *RegexIterator) void {
        self.offset = 0;
    }
};

pub const RegexMutilineIterator = struct {
    regex: *Regex,
    input: []const u8,
    line_iter: std.mem.TokenIterator(u8, .scalar),
    line_offset: usize = 0,
    match_iter: ?RegexIterator = null,

    const Result = struct {
        str: []const u8,
        lowerBound: usize,
        upperBound: usize,
    };

    pub fn next(self: *RegexMutilineIterator) !?Result {
        while (true) {
            if (self.match_iter) |*iter| {
                if (try iter.next()) |match| {
                    return .{
                        .str = match.str,
                        .lowerBound = self.line_offset + match.lowerBound,
                        .upperBound = self.line_offset + match.upperBound,
                    };
                } else {
                    self.match_iter = null; // Exhausted current line
                }
            }

            if (self.line_iter.next()) |line| {
                self.match_iter = RegexIterator{
                    .regex = self.regex,
                    .input = line,
                };
                self.line_offset = @intFromPtr(line.ptr) - @intFromPtr(self.input.ptr);
                continue;
            }

            return null; // No more lines
        }
    }

    //pub fn lowerBound(self: *RegexMutilineIterator) usize {
    //    if (self.match_len == null) @panic("Called lowerBound without regex match");
    //    return self.offset - self.match_len.?;
    //}
    //
    //pub fn upperBound(self: *RegexMutilineIterator) usize {
    //    if (self.match_len == null) @panic("Called lowerBound without regex match");
    //    return self.offset;
    //}
};

pub fn regexMatchAll(re: *Regex, input: []const u8) RegexIterator {
    return RegexIterator{
        .regex = re,
        .input = input,
        .offset = 0,
    };
}

pub fn regexMutilineMatchAll(re: *Regex, input: []const u8) RegexMutilineIterator {
    return RegexMutilineIterator{
        .regex = re,
        .input = input,
        .line_iter = std.mem.tokenizeScalar(u8, input, '\n'),
    };
}
