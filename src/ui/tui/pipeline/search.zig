//! UI-side regex search over a ProcessBuffer's filtered lines.
//!
//! The searcher keeps its own copy of the filtered text (`SearchIndex`) that is refreshed
//! incrementally: while the buffer's `version` is unchanged only the newly appended bytes
//! are copied; when a reprocess changes line identity the copy is rebuilt. Match offsets
//! are absolute filtered offsets and are only valid for the `version` they were found in.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Regex = @import("regex").Regex;
const processbuffer = @import("processbuffer.zig");
const helpers = @import("../helpers.zig");

const ProcessBuffer = processbuffer.ProcessBuffer;
const RegexIterator = helpers.RegexIterator;

pub const Match = struct {
    /// absolute filtered line index containing the match
    line: usize,
    /// absolute filtered byte offsets
    lo: usize,
    hi: usize,
};

pub const SearchIndex = struct {
    /// buffer version the copy corresponds to; null before the first refresh
    version: ?u64 = null,
    /// complete filtered lines, each ending in '\n'
    text: std.ArrayList(u8) = .empty,
    /// byte offset of the start of every line in `text`
    line_starts: std.ArrayList(usize) = .empty,

    pub const Refresh = enum { unchanged, extended, rebuilt };

    pub fn deinit(self: *SearchIndex, alloc: Allocator) void {
        self.text.deinit(alloc);
        self.line_starts.deinit(alloc);
    }

    pub fn lineCount(self: *const SearchIndex) usize {
        return self.line_starts.items.len;
    }

    /// The line without its trailing '\n'.
    pub fn line(self: *const SearchIndex, i: usize) []const u8 {
        const start = self.line_starts.items[i];
        const end = if (i + 1 < self.line_starts.items.len) self.line_starts.items[i + 1] else self.text.items.len;
        return self.text.items[start .. end - 1];
    }

    pub fn lineStart(self: *const SearchIndex, i: usize) usize {
        return self.line_starts.items[i];
    }

    /// Brings the copy up to date with the buffer using one lock acquisition (none at all
    /// when the published counters show nothing changed).
    pub fn refresh(self: *SearchIndex, alloc: Allocator, pb: *ProcessBuffer) Allocator.Error!Refresh {
        const meta = pb.peek();
        if (self.version != null and self.version.? == meta.version and self.text.items.len == meta.filtered_len) {
            return .unchanged;
        }

        var from: usize = if (self.version != null and self.version.? == meta.version) self.text.items.len else 0;
        var copy = try pb.copyFilteredFrom(alloc, from);
        if (from != 0 and copy.version != self.version.?) {
            // the buffer was reprocessed between peek() and the copy: start over
            alloc.free(copy.bytes);
            from = 0;
            copy = try pb.copyFilteredFrom(alloc, 0);
        }
        defer alloc.free(copy.bytes);

        const rebuilt = from == 0;
        if (rebuilt) {
            self.text.clearRetainingCapacity();
            self.line_starts.clearRetainingCapacity();
        }

        const base = self.text.items.len;
        try self.text.appendSlice(alloc, copy.bytes);
        var pos: usize = 0;
        while (std.mem.indexOfScalarPos(u8, copy.bytes, pos, '\n')) |nl| : (pos = nl + 1) {
            try self.line_starts.append(alloc, base + pos);
        }
        self.version = copy.version;

        return if (rebuilt) .rebuilt else .extended;
    }
};

pub const Searcher = struct {
    alloc: Allocator,
    index: SearchIndex = .{},
    regex: Regex,
    /// line the cursor is on; `cached` holds that line's matches when non-null
    cursor_line: usize = 0,
    cached: ?CachedRegexMatchIterator = null,

    pub fn init(alloc: Allocator, pattern: []const u8) !Searcher {
        return .{
            .alloc = alloc,
            .regex = try Regex.compile(alloc, pattern),
        };
    }

    pub fn deinit(self: *Searcher) void {
        self.dropCached();
        self.index.deinit(self.alloc);
        self.regex.deinit();
    }

    fn dropCached(self: *Searcher) void {
        if (self.cached) |*c| c.deinit();
        self.cached = null;
    }

    /// Refreshes the index. After a rebuild the cursor is clamped and any cached line
    /// matches are dropped because line identity may have changed.
    pub fn refresh(self: *Searcher, pb: *ProcessBuffer) Allocator.Error!SearchIndex.Refresh {
        const result = try self.index.refresh(self.alloc, pb);
        if (result == .rebuilt) {
            self.dropCached();
            self.cursor_line = @min(self.cursor_line, self.index.lineCount() -| 1);
        }
        return result;
    }

    /// Positions the cursor before the first match of `line` (for `next`) / after the last
    /// match of `line` (for `prev`).
    pub fn seekLine(self: *Searcher, line: usize) void {
        self.dropCached();
        self.cursor_line = @min(line, self.index.lineCount() -| 1);
    }

    fn cacheLine(self: *Searcher, position: CachedRegexMatchIterator.StartPosition) !void {
        self.cached = try CachedRegexMatchIterator.init(
            self.alloc,
            &self.regex,
            self.index.line(self.cursor_line),
            position,
        );
    }

    fn toMatch(self: *const Searcher, m: CachedRegexMatchIterator.LineMatch) Match {
        const base = self.index.lineStart(self.cursor_line);
        return .{ .line = self.cursor_line, .lo = base + m.lowerBound, .hi = base + m.upperBound };
    }

    /// Next match at or after the cursor, or null at the end of the buffer (the cursor then
    /// stays on the last line, positioned after its last match).
    pub fn next(self: *Searcher) !?Match {
        const count = self.index.lineCount();
        if (count == 0) return null;
        while (true) {
            if (self.cached == null) try self.cacheLine(.start);
            if (self.cached.?.next()) |m| return self.toMatch(m);
            if (self.cursor_line + 1 >= count) return null;
            self.dropCached();
            self.cursor_line += 1;
        }
    }

    /// Previous match before the cursor, or null at the start of the buffer (the cursor then
    /// stays on the first line, positioned before its first match).
    pub fn prev(self: *Searcher) !?Match {
        const count = self.index.lineCount();
        if (count == 0) return null;
        while (true) {
            if (self.cached == null) try self.cacheLine(.end);
            if (self.cached.?.prev()) |m| return self.toMatch(m);
            if (self.cursor_line == 0) return null;
            self.dropCached();
            self.cursor_line -= 1;
        }
    }
};

const CachedRegexMatchIterator = struct {
    const LineMatch = struct {
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

    alloc: Allocator,
    matches: []LineMatch,
    index: Index = Index{ .start = {} },

    pub fn init(alloc: Allocator, regex: *Regex, input: []const u8, starting_position: StartPosition) !CachedRegexMatchIterator {
        var match_list: std.ArrayList(LineMatch) = .empty;
        errdefer match_list.deinit(alloc);
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

    pub fn next(self: *CachedRegexMatchIterator) ?LineMatch {
        self.index = switch (self.index) {
            .start => if (self.matches.len == 0) .end else .{ .ofs = 0 },
            .ofs => |i| if (i + 1 >= self.matches.len) .end else .{ .ofs = i + 1 },
            .end => .end,
        };
        return self.peek();
    }

    pub fn prev(self: *CachedRegexMatchIterator) ?LineMatch {
        self.index = switch (self.index) {
            .end => if (self.matches.len == 0) .start else .{ .ofs = self.matches.len - 1 },
            .ofs => |i| if (i == 0) .start else .{ .ofs = i - 1 },
            .start => .start,
        };
        return self.peek();
    }

    pub fn peek(self: *CachedRegexMatchIterator) ?LineMatch {
        if (self.index == .ofs) return self.matches[self.index.ofs] else return null;
    }

    pub fn deinit(self: *CachedRegexMatchIterator) void {
        self.alloc.free(self.matches);
    }
};

const testing = std.testing;

test "Searcher: matches within a line and across lines, forward and backward" {
    const alloc = testing.allocator;
    const io = testing.io;

    const pb = try ProcessBuffer.init(io, alloc);
    defer pb.deinit();
    try pb.append("string Line 1 with string string x\nLine 2 with string out\nLine 3 with string out");

    var s = try Searcher.init(alloc, "string");
    defer s.deinit();
    try testing.expectEqual(.rebuilt, try s.refresh(pb));
    try testing.expectEqual(2, s.index.lineCount()); // the tail line is incomplete

    const m0 = (try s.next()).?;
    try testing.expectEqual(Match{ .line = 0, .lo = 0, .hi = 6 }, m0);
    const m1 = (try s.next()).?;
    try testing.expectEqual(Match{ .line = 0, .lo = 19, .hi = 25 }, m1);
    const m2 = (try s.next()).?;
    try testing.expectEqual(Match{ .line = 0, .lo = 26, .hi = 32 }, m2);
    const m3 = (try s.next()).?;
    try testing.expectEqual(1, m3.line);
    try testing.expectEqual(35 + 12, m3.lo);
    try testing.expectEqual(null, try s.next());

    // backwards from the end walks the same matches in reverse
    try testing.expectEqual(m3, (try s.prev()).?);
    try testing.expectEqual(m2, (try s.prev()).?);
    try testing.expectEqual(m1, (try s.prev()).?);
    try testing.expectEqual(m0, (try s.prev()).?);
    try testing.expectEqual(null, try s.prev());
    // and forward again from the start
    try testing.expectEqual(m0, (try s.next()).?);
}

test "Searcher: refresh extends on append and rebuilds on reprocess" {
    const alloc = testing.allocator;
    const io = testing.io;

    const pb = try ProcessBuffer.init(io, alloc);
    defer pb.deinit();
    try pb.append("apple\n");

    var s = try Searcher.init(alloc, "apple");
    defer s.deinit();
    try testing.expectEqual(.rebuilt, try s.refresh(pb));
    try testing.expectEqual(.unchanged, try s.refresh(pb));

    try pb.append("carrot\napple\n");
    try testing.expectEqual(.extended, try s.refresh(pb));
    try testing.expectEqual(3, s.index.lineCount());
    try testing.expectEqualStrings("carrot", s.index.line(1));

    s.seekLine(1);
    try testing.expectEqual(Match{ .line = 2, .lo = 13, .hi = 18 }, (try s.next()).?);

    // a reprocess changes line identity: the index is rebuilt and the cursor clamped
    try pb.removeAllFilters();
    try testing.expectEqual(.rebuilt, try s.refresh(pb));
    try testing.expectEqual(pb.peek().version, s.index.version.?);
}
