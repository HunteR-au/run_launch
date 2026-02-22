const std = @import("std");
const Filter = @import("filter.zig");
const Reviewer = @import("reviewer.zig");
const Pipeline = @import("pipeline.zig").Pipeline;
const Output = @import("../output.zig").Output;

const helpers = @import("../helpers.zig");
const Regex = @import("regex").Regex;
const vaxis = @import("vaxis");

pub const FoldFilterData = struct { regexs: []Regex };
pub fn fold(_: *Filter, data: *anyopaque, line: []const u8) std.mem.Allocator.Error!Filter.TransformResult {
    if (line.len == 0) return Filter.TransformResult{ .empty = {} };

    const fold_data: *FoldFilterData = @ptrCast(@alignCast(data));

    for (fold_data.regexs) |*re| {
        std.log.debug("Output:fold() comparing \"{s}\"", .{line});
        if (try re.partialMatch(line) == true) {
            std.log.debug("MATCH", .{});
            //std.debug.print("Output:fold -> regex found a match on line {s}\n", .{line});

            // found match
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

    const alloc = filter.arena.allocator();
    const replace_data: *ReplaceFilterData = @ptrCast(@alignCast(data));

    // we need to keep the altered line for the next pattern
    var final_result = try std.ArrayListUnmanaged(u8).initCapacity(alloc, line.len);
    try final_result.appendSlice(alloc, line);
    for (replace_data.replace_patterns) |*patterns| {
        var result = try std.ArrayListUnmanaged(u8).initCapacity(alloc, final_result.items.len);
        var start: usize = 0;
        defer start = 0;

        var iter = helpers.regexMatchAll(&patterns.regex, final_result.items);
        while (try iter.next()) |match| {
            try result.appendSlice(alloc, line[start..match.lowerBound]);
            try result.appendSlice(alloc, patterns.replace_str);
            start = match.upperBound;
        }

        // append the end of the line
        try result.appendSlice(alloc, line[start..line.len]);

        // move over the altered line into the outer array for the
        // next pattern or to be returned
        final_result.deinit(alloc);
        const slice = try result.toOwnedSlice(alloc);
        final_result = std.ArrayListUnmanaged(u8){
            .items = slice,
            .capacity = slice.len,
        };
    }

    return Filter.TransformResult{
        .line = try final_result.toOwnedSlice(alloc),
    };
}

pub const ColorPattern = struct { regex: Regex, style: vaxis.Style, full_line: bool = false };
pub const ColorReviewerData = struct { style_patterns: []ColorPattern, output: *Output };

pub fn color(_: *const Reviewer, data: *anyopaque, metadata: Pipeline.MetaData, line: []const u8) std.mem.Allocator.Error!void {
    const color_data: *ColorReviewerData = @ptrCast(@alignCast(data));

    // first - check for first full_line pattern and apply
    for (color_data.style_patterns) |*pattern| {
        if (pattern.full_line) {
            // check if there is a regex match in the line
            if (try pattern.regex.partialMatch(line)) {
                try color_data.output.updateStyle(
                    &pattern.style,
                    metadata.bufferOffset,
                    metadata.bufferOffset + line.len,
                );

                // now that we have applied a full line pattern, exit
                return;
            }
        }
    }

    // second - if no full_line patterns, apply all other patterns
    for (color_data.style_patterns) |*pattern| {
        var iter = helpers.regexMatchAll(&pattern.regex, line);
        while (try iter.next()) |match| {
            try color_data.output.updateStyle(
                &pattern.style,
                metadata.bufferOffset + match.lowerBound,
                metadata.bufferOffset + match.upperBound,
            );
        }
    }
}
