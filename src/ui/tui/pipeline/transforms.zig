const std = @import("std");
const Filter = @import("filter.zig");
const Reviewer = @import("reviewer.zig");

const helpers = @import("../helpers.zig");
const Regex = @import("regex").Regex;
const vaxis = @import("vaxis");

pub const FoldFilterData = struct { regexs: []Regex };
pub fn fold(_: *Filter, data: *anyopaque, line: []const u8) std.mem.Allocator.Error!Filter.TransformResult {
    if (line.len == 0) return Filter.TransformResult{ .empty = {} };

    const fold_data: *FoldFilterData = @ptrCast(@alignCast(data));

    for (fold_data.regexs) |*re| {
        if (try re.partialMatch(line) == true) {
            return Filter.TransformResult{ .line = line };
        }
    }
    return Filter.TransformResult{ .empty = {} };
}

pub const PruneFilterData = FoldFilterData;
pub fn prune(_: *Filter, data: *anyopaque, line: []const u8) std.mem.Allocator.Error!Filter.TransformResult {
    if (line.len == 0) return Filter.TransformResult{ .empty = {} };

    const fold_data: *PruneFilterData = @ptrCast(@alignCast(data));

    for (fold_data.regexs) |*re| {
        if (try re.partialMatch(line) == true) {
            return Filter.TransformResult{ .empty = {} };
        }
    }
    return Filter.TransformResult{ .line = line };
}

pub const ReplacePattern = struct { regex: Regex, replace_str: []u8 };
pub const ReplaceFilterData = struct { replace_patterns: []ReplacePattern };
pub fn replace(filter: *Filter, data: *anyopaque, line: []const u8) std.mem.Allocator.Error!Filter.TransformResult {
    if (line.len == 0) return Filter.TransformResult{ .empty = {} };

    const alloc = filter.scratch.allocator();
    const replace_data: *ReplaceFilterData = @ptrCast(@alignCast(data));

    // Each pattern runs over the output of the previous one (double buffering), and the
    // copied slices come from the same string the matcher ran over.
    var current: []const u8 = line;
    for (replace_data.replace_patterns) |*pattern| {
        var result = try std.ArrayList(u8).initCapacity(alloc, current.len);
        var start: usize = 0;

        var iter = helpers.regexMatchAll(&pattern.regex, current);
        while (try iter.next()) |match| {
            try result.appendSlice(alloc, current[start..match.lowerBound]);
            try result.appendSlice(alloc, pattern.replace_str);
            start = match.upperBound;
        }
        try result.appendSlice(alloc, current[start..current.len]);

        current = result.items;
    }

    return Filter.TransformResult{ .line = current };
}

pub const ColorPattern = struct { regex: Regex, style: vaxis.Style, full_line: bool = false };
pub const ColorReviewerData = struct { style_patterns: []ColorPattern };

pub fn color(_: *const Reviewer, data: *anyopaque, sink: *Reviewer.LineSink, line: []const u8) std.mem.Allocator.Error!void {
    const color_data: *ColorReviewerData = @ptrCast(@alignCast(data));

    // first - check for a full_line pattern and apply it to the whole line
    for (color_data.style_patterns) |*pattern| {
        if (pattern.full_line) {
            if (try pattern.regex.partialMatch(line)) {
                try sink.markLine(pattern.style);
                return;
            }
        }
    }

    // second - no full_line pattern matched, apply all other patterns to their matches
    for (color_data.style_patterns) |*pattern| {
        if (pattern.full_line) continue;
        var iter = helpers.regexMatchAll(&pattern.regex, line);
        while (try iter.next()) |match| {
            try sink.mark(pattern.style, match.lowerBound, match.upperBound);
        }
    }
}
