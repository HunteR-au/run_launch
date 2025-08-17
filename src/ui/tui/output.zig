const std = @import("std");
const utils = @import("utils");

const process_buffer_mod = @import("pipeline/processbuffer.zig");
const cmd_mod = @import("cmd.zig");

// ui data structures
const vaxis = @import("vaxis");
const uiconfig_mod = @import("uiconfig");
pub const UiConfig = uiconfig_mod.UiConfig;
pub const ProcessConfig = uiconfig_mod.ProcessConfig;
pub const ColorRule = uiconfig_mod.ColorRule;
pub const StyleMap = std.HashMap(usize, usize, std.hash_map.AutoContext(usize), std.hash_map.default_max_load_percentage);
pub const StyleList = std.ArrayList(vaxis.Style);

pub const Output = @This();
const Regex = @import("regex").Regex;
pub const ProcessBuffer = process_buffer_mod.ProcessBuffer;
pub const Filter = process_buffer_mod.Filter;
pub const Pipeline = process_buffer_mod.Pipeline;
pub const Reviewer = process_buffer_mod.Reviewer;
pub const Cmd = cmd_mod.Cmd;
const Handler = cmd_mod.Handler;

// output contain the process buffer
// output will manage handlers

arena: std.heap.ArenaAllocator,
nonowned_process_buffer: *ProcessBuffer,
cmd_ref: ?*Cmd = null,
handlers_ids: std.ArrayList(cmd_mod.HandleId),
filter_ids: std.ArrayList(Filter.HandleId),
reviewer_ids: std.ArrayList(Reviewer.HandleId),

style_list: StyleList,
style_map: StyleMap,

const UnfoldHandlerData = .{ .event_str = "unfold", .handle = handleUnfoldCmd };
const FoldHandlerData = .{ .event_str = "fold", .handle = handleFoldCmd };
const FoldFilterData = struct { regexs: []Regex };

const UncolorHandlerData = .{ .event_str = "uncolor", .handle = handleUncolorCmd };
const ColorHandlerData = .{ .event_str = "color", .handle = handleColorCmd };
const ColorPattern = struct { regex: Regex, style: vaxis.Style, full_line: bool = false };
const ColorReviewerData = struct { style_patterns: []ColorPattern, output: *Output };

pub fn init(alloc: std.mem.Allocator, process_buf: *ProcessBuffer) Output {
    return .{
        .arena = std.heap.ArenaAllocator.init(alloc),
        .handlers_ids = std.ArrayList(cmd_mod.HandleId).init(alloc),
        .filter_ids = std.ArrayList(Filter.HandleId).init(alloc),
        .reviewer_ids = std.ArrayList(Reviewer.HandleId).init(alloc),
        .nonowned_process_buffer = process_buf,
        .style_list = StyleList.init(alloc),
        .style_map = StyleMap.init(alloc),
    };
}

pub fn deinit(self: *Output) void {
    if (self.cmd_ref != null) {
        self.unsubscribeHandlersFromCmd();
    }
    self.handlers_ids.deinit();
    for (self.filter_ids.items) |fId| {
        var filter = self.nonowned_process_buffer.pipeline.removeFilter(fId);
        if (filter) |*f| {
            f.deinit();
        }
    }
    self.filter_ids.deinit();
    for (self.reviewer_ids.items) |rId| {
        var reviewer = self.nonowned_process_buffer.pipeline.removeReviewer(rId);
        if (reviewer) |*r| {
            r.deinit();
        }
    }
    self.reviewer_ids.deinit();
    self.style_map.deinit();
    self.style_list.deinit();
    self.arena.deinit();
}

fn handleFoldCmd(args: []const u8, listener: *anyopaque) std.mem.Allocator.Error!void {
    const self: *Output = @alignCast(@ptrCast(listener));

    //TODO: check if active first

    const alloc = self.arena.allocator();

    // parse the arguments
    const arguments = try utils.parseArgsLineWithQuoteGroups(alloc, args);
    defer {
        for (arguments) |s| alloc.free(s);
        alloc.free(arguments);
    }

    // create a list of compiled regex objects
    var regex_list = std.ArrayList(Regex).init(alloc);
    for (arguments) |arg| {
        const re = Regex.compile(alloc, arg) catch {
            continue;
        };
        try regex_list.append(re);
    }

    const filter_data = try alloc.create(FoldFilterData);
    filter_data.* = .{ .regexs = try regex_list.toOwnedSlice() };

    // we need to recalculate the color styles
    self.clearStyle();

    // Create the filter and add to the pipeline
    const filter = try Filter.init(self.arena.allocator(), filter_data, fold);
    try self.filter_ids.append(filter.id);
    try self.nonowned_process_buffer.addFilter(filter);
}

fn handleUnfoldCmd(_: []const u8, listener: *anyopaque) std.mem.Allocator.Error!void {
    const self: *Output = @alignCast(@ptrCast(listener));
    // we need to recalculate the color styles
    self.clearStyle();

    try self.nonowned_process_buffer.removeAllFilters();
    self.filter_ids.clearAndFree();
}

fn handleUncolorCmd(_: []const u8, listener: *anyopaque) std.mem.Allocator.Error!void {
    const self: *Output = @alignCast(@ptrCast(listener));
    self.clearStyle();
    try self.nonowned_process_buffer.removeAllReviewers();
    self.reviewer_ids.clearAndFree();
}

fn fold(_: *const Filter, data: *anyopaque, line: []const u8) std.mem.Allocator.Error!Filter.TransformResult {
    if (line.len == 0) return Filter.TransformResult{ .empty = {} };

    const fold_data: *FoldFilterData = @ptrCast(@alignCast(data));

    for (fold_data.regexs) |*re| {
        std.debug.print("Output:fold() comparing \"{s}\"\n", .{line});
        if (try re.partialMatch(line) == true) {
            std.debug.print("Output:fold -> regex found a match on line {s}\n", .{line});

            // found match
            return Filter.TransformResult{ .line = line };
        }
    }
    return Filter.TransformResult{ .empty = {} };
}

// a rule
//"pattern": "\\[Error\\]",
//"just_pattern": true,
//"foreground_color": "220,6,6", or null
//"background_color": "200,184,208" or null
const ColorGround = enum { Fg, Bg };
const Red = vaxis.Color{ .rgb = .{ 255, 0, 0 } };
const Green = vaxis.Color{ .rgb = .{ 0, 255, 0 } };
const Blue = vaxis.Color{ .rgb = .{ 0, 0, 255 } };
const Yellow = vaxis.Color{ .rgb = .{ 255, 255, 0 } };
const Magenta = vaxis.Color{ .rgb = .{ 255, 0, 255 } };
const Cyan = vaxis.Color{ .rgb = .{ 0, 255, 255 } };
const White = vaxis.Color{ .rgb = .{ 255, 255, 255 } };
const Black = vaxis.Color{ .rgb = .{ 0, 0, 0 } };
fn parseColor(arg: []const u8, ground: ColorGround) !vaxis.Style {
    if (std.mem.eql(u8, arg, "red")) {
        return switch (ground) {
            .Bg => return vaxis.Style{ .bg = Red },
            .Fg => return vaxis.Style{ .fg = Red },
        };
    } else if (std.mem.eql(u8, arg, "green")) {
        return switch (ground) {
            .Bg => return vaxis.Style{ .bg = Green },
            .Fg => return vaxis.Style{ .fg = Green },
        };
    } else if (std.mem.eql(u8, arg, "yellow")) {
        return switch (ground) {
            .Bg => return vaxis.Style{ .bg = Yellow },
            .Fg => return vaxis.Style{ .fg = Yellow },
        };
    } else if (std.mem.eql(u8, arg, "blue")) {
        return switch (ground) {
            .Bg => return vaxis.Style{ .bg = Blue },
            .Fg => return vaxis.Style{ .fg = Blue },
        };
    } else if (std.mem.eql(u8, arg, "magenta")) {
        return switch (ground) {
            .Bg => return vaxis.Style{ .bg = Magenta },
            .Fg => return vaxis.Style{ .fg = Magenta },
        };
    } else if (std.mem.eql(u8, arg, "cyan")) {
        return switch (ground) {
            .Bg => return vaxis.Style{ .bg = Cyan },
            .Fg => return vaxis.Style{ .fg = Cyan },
        };
    } else if (std.mem.eql(u8, arg, "white")) {
        return switch (ground) {
            .Bg => return vaxis.Style{ .bg = White },
            .Fg => return vaxis.Style{ .fg = White },
        };
    } else if (std.mem.eql(u8, arg, "black")) {
        return switch (ground) {
            .Bg => return vaxis.Style{ .bg = Black },
            .Fg => return vaxis.Style{ .fg = Black },
        };
    } else {
        const parts = utils.parseTripleInt(arg) catch {
            // invalid RGB code
            return error.InvalidRGBFormat;
        };

        // check if each part is within range
        for (parts) |part| {
            if (part > 255) return error.InvalidRGBFormat;
        }

        const u8_parts: [3]u8 = .{
            @intCast(parts[0]),
            @intCast(parts[1]),
            @intCast(parts[2]),
        };
        return switch (ground) {
            .Bg => return vaxis.Style{ .bg = .{ .rgb = u8_parts } },
            .Fg => return vaxis.Style{ .fg = .{ .rgb = u8_parts } },
        };
    }
    return error.InvalidArgument;
}

const ArgStateMachine = enum {
    Empty,
    Fg,
    Bg,
};
fn createStyleFromArg(arg: []const u8) ?ColorPattern {
    // fg:color:bg:color:line

    //var state = ArgStateMachine.Empty;
    var parsedBg = false;
    var parsedFg = false;
    var color_line = false;
    var isFirstSegment = true;
    var it = std.mem.tokenizeScalar(u8, arg, ':');
    var result_style: ?vaxis.Style = null;
    state: switch (ArgStateMachine.Empty) {
        .Fg => {
            const segment = it.next();
            if (segment == null) // invalid arg
                return null;

            const style = parseColor(segment.?, .Fg) catch { // invalid arg
                return null;
            };
            if (result_style) |*s| {
                s.fg = style.fg;
            } else {
                result_style = style;
            }
            continue :state .Empty;
        },
        .Bg => {
            const segment = it.next();
            if (segment == null) // invalid arg
                return null;

            const style = parseColor(segment.?, .Bg) catch { // invalid args
                return null;
            };
            if (result_style) |*s| {
                s.bg = style.bg;
            } else {
                result_style = style;
            }
            continue :state .Empty;
        },
        .Empty => {
            const is_current_seg_first = isFirstSegment;
            if (!isFirstSegment) isFirstSegment = false;
            const segment = it.next();
            if (segment == null) // no more arguments
                break :state;

            if (std.mem.eql(u8, segment.?, "fg")) {
                if (parsedFg) {
                    // invalid arg, can't have fg twice
                    return null;
                } else {
                    parsedFg = true;
                    continue :state .Fg;
                }
                continue :state .Empty;
            } else if (std.mem.eql(u8, segment.?, "bg")) {
                if (parsedBg) {
                    // invalid arg, can't have fg twice
                    return null;
                } else {
                    parsedBg = true;
                    continue :state .Bg;
                }
            } else if (std.mem.eql(u8, segment.?, "line") and !is_current_seg_first) {
                // we need to parse this to make sure it is a valid
                std.debug.print("print full line\n", .{});
                color_line = true;
                continue :state .Empty;
            } else if (is_current_seg_first) {
                // if it is the first segment we accept a color and assume fg
                const style = parseColor(segment.?, .Fg) catch { // invalid args
                    return null;
                };
                if (result_style) |*s| {
                    s.bg = style.bg;
                } else {
                    result_style = style;
                }
                continue :state .Empty;
            }
        },
    }
    if (result_style) |res| {
        return ColorPattern{ .regex = undefined, .full_line = color_line, .style = res };
    } else return null;
}

pub fn setupViaUiconfig(
    self: *Output,
    config: *UiConfig,
    ui_name: []const u8,
) std.mem.Allocator.Error!void {
    const alloc = self.arena.allocator();
    var scratch_arena = std.heap.ArenaAllocator.init(alloc);
    defer scratch_arena.deinit();
    const salloc = scratch_arena.allocator();
    const self_config = config.get(ui_name);
    const global_config = config.globalConfig;

    var num_color_rules: usize = 0;
    if (global_config) |c| num_color_rules += c.colorRules.len;
    if (self_config) |c| num_color_rules += c.colorRules.len;

    if (num_color_rules == 0) return;

    // combine all ProcessConfigs
    var applied_color_rules = try std.ArrayList(*ColorRule).initCapacity(salloc, num_color_rules);
    if (global_config) |c| {
        for (c.colorRules) |*c_rule| {
            try applied_color_rules.append(c_rule);
        }
    }
    if (self_config) |c| {
        for (c.colorRules) |*c_rule| {
            try applied_color_rules.append(c_rule);
        }
    }

    // parse all color rules
    var patterns = std.ArrayList(ColorPattern).init(alloc);
    for (applied_color_rules.items) |c_rule| {
        if (c_rule.background_color == null and c_rule.foreground_color == null) continue;
        if (c_rule.pattern == null) continue;

        const re = Regex.compile(alloc, c_rule.pattern.?) catch {
            continue;
        };

        // create style argument
        var style_args = std.ArrayList([]u8).init(salloc);
        if (c_rule.background_color) |bg_str| {
            try style_args.append(try salloc.dupe(u8, "bg"));
            try style_args.append(try salloc.dupe(u8, bg_str));
        }
        if (c_rule.foreground_color) |fg_str| {
            try style_args.append(try salloc.dupe(u8, "fg"));
            try style_args.append(try salloc.dupe(u8, fg_str));
        }
        if (!c_rule.just_pattern) {
            try style_args.append(try salloc.dupe(u8, "line"));
        }
        const style_arg = try std.mem.join(salloc, ":", style_args.items);

        var color_pattern = createStyleFromArg(style_arg);
        if (color_pattern == null) continue;

        color_pattern.?.regex = re;
        try patterns.append(color_pattern.?);
    }

    const reviewer_data = try alloc.create(ColorReviewerData);
    reviewer_data.* = .{
        .output = self,
        .style_patterns = try patterns.toOwnedSlice(),
    };

    // Create and add the reviewer to the process buffer
    const reviewer = try Reviewer.init(self.arena.allocator(), reviewer_data, color);
    try self.reviewer_ids.append(reviewer.id);
    try self.nonowned_process_buffer.addReviewer(reviewer);
}

fn handleColorCmd(args: []const u8, listener: *anyopaque) std.mem.Allocator.Error!void {
    const self: *Output = @alignCast(@ptrCast(listener));
    const alloc = self.arena.allocator();

    // parse the arguments for the color command
    const arg_array = try utils.parseArgsLineWithQuoteGroups(alloc, args);
    defer {
        for (arg_array) |s| alloc.free(s);
        alloc.free(arg_array);
    }

    if (arg_array.len % 2 != 0) {
        // don't parse any arguments if the full line is invalid
        return;
    }

    // each pair comes in the form of `regex` `style`
    // add each pair
    var color_patterns = std.ArrayList(ColorPattern).init(alloc);
    for (0..arg_array.len / 2) |i| {
        const regex_arg = arg_array[i * 2];
        const style_arg = arg_array[i * 2 + 1];

        const re = Regex.compile(alloc, regex_arg) catch {
            continue;
        };
        var color_pattern = createStyleFromArg(style_arg);
        if (color_pattern == null) continue;

        color_pattern.?.regex = re;
        try color_patterns.append(color_pattern.?);
    }

    // Create the data object for the colorReviewer
    const reviewer_data = try alloc.create(ColorReviewerData);
    reviewer_data.* = .{
        .output = self,
        .style_patterns = try color_patterns.toOwnedSlice(),
    };

    // Create and add the reviewer to the process buffer
    const reviewer = try Reviewer.init(self.arena.allocator(), reviewer_data, color);
    try self.reviewer_ids.append(reviewer.id);
    try self.nonowned_process_buffer.addReviewer(reviewer);
}

fn color(_: *const Reviewer, data: *anyopaque, metadata: Pipeline.MetaData, line: []const u8) std.mem.Allocator.Error!void {
    const color_data: *ColorReviewerData = @ptrCast(@alignCast(data));

    for (color_data.style_patterns) |*pattern| {
        if (try pattern.regex.captures(line)) |c| {
            if (pattern.full_line) {
                std.debug.print("match full line {s}\n", .{pattern.regex.string});
                std.debug.print("start of match = {d}\n", .{metadata.bufferOffset});
                std.debug.print("end of match = {d}\n", .{metadata.bufferOffset + line.len - 1});
                try color_data.output.updateStyle(
                    pattern.style,
                    metadata.bufferOffset,
                    metadata.bufferOffset + line.len - 1,
                );
            } else {
                for (0..c.len()) |n| {
                    const span = c.boundsAt(n).?;
                    std.debug.print("{s}\n", .{pattern.regex.string});
                    std.debug.print("start of match = {d}\n", .{metadata.bufferOffset + span.lower});
                    std.debug.print("end of match = {d}\n", .{metadata.bufferOffset + span.upper});
                    try color_data.output.updateStyle(
                        pattern.style,
                        metadata.bufferOffset + span.lower,
                        metadata.bufferOffset + span.upper,
                    );
                }
            }
        }
    }
}

pub fn clearStyle(self: *Output) void {
    self.style_list.clearAndFree();
    self.style_map.clearAndFree();
}

/// Update the style structures in the output style_map and style_list
pub fn updateStyle(self: *Output, style: vaxis.Style, begin_offset: usize, end_offset: usize) !void {
    const style_index = blk: {
        for (self.style_list.items, 0..) |s, i| {
            if (std.meta.eql(s, style)) {
                break :blk i;
            }
        }
        try self.style_list.append(style);
        break :blk self.style_list.items.len - 1;
    };
    for (begin_offset..end_offset + 1) |i| {
        try self.style_map.put(i, style_index);
    }
}

pub fn subscribeHandlersToCmd(self: *Output, cmd: *Cmd) !void {
    std.debug.assert(self.cmd_ref == null);

    self.cmd_ref = cmd;

    // Add fold handler
    const fold_handler: Handler = .{
        .event_str = FoldHandlerData.event_str,
        .handle = FoldHandlerData.handle,
        .listener = self,
    };
    const fold_id = try self.cmd_ref.?.addHandler(fold_handler);
    try self.handlers_ids.append(fold_id);

    // Add unfold handler
    const unfold_handler: Handler = .{
        .event_str = UnfoldHandlerData.event_str,
        .handle = UnfoldHandlerData.handle,
        .listener = self,
    };
    const unfold_id = try self.cmd_ref.?.addHandler(unfold_handler);
    try self.handlers_ids.append(unfold_id);

    // Add color handler
    const color_handler: Handler = .{
        .event_str = ColorHandlerData.event_str,
        .handle = ColorHandlerData.handle,
        .listener = self,
    };
    const color_id = try self.cmd_ref.?.addHandler(color_handler);
    try self.handlers_ids.append(color_id);

    // Add uncolor handler
    const uncolor_handler: Handler = .{
        .event_str = UncolorHandlerData.event_str,
        .handle = UncolorHandlerData.handle,
        .listener = self,
    };
    const uncolor_id = try self.cmd_ref.?.addHandler(uncolor_handler);
    try self.handlers_ids.append(uncolor_id);
}

pub fn unsubscribeHandlersFromCmd(self: *Output) void {
    std.debug.assert(self.cmd_ref != null);

    for (self.handlers_ids.items) |id| {
        self.cmd_ref.?.removeHandler(id);
    }

    self.cmd_ref = null;
}

fn copyBuffer(self: *const Output, alloc: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
    return self.nonowned_process_buffer.copyFilteredBuffer(alloc);
}

fn copyUnfiltedBuffer(self: *const Output, alloc: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
    // TODO
    self.nonowned_process_buffer.copy(alloc);
}

test "folding text" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var process_buffer = try ProcessBuffer.init(alloc);
    var output = Output.init(alloc, process_buffer);
    defer process_buffer.deinit();
    defer output.deinit();

    try process_buffer.append(
        \\line 1: apples
        \\line 2: carrots
        \\line 3: carrots
        \\line 4: apples
        \\line 5: carrots
        \\line 6: apples
        \\line 7: carrots
    );

    const fold_args = "apples";
    try Output.handleFoldCmd(fold_args, &output);
    const buffer = try output.copyBuffer(alloc);
    defer alloc.free(buffer);

    try testing.expectEqualStrings(
        \\line 1: apples
        \\line 4: apples
        \\line 6: apples
    , buffer);
}

// TODO test the color arg parsing
// TODO test using the pipeline with color reviewers
// TODO test coloring in multistyletext...
//   there seems to be an off by 1 due to newlines

test "coloring text" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var process_buffer = try ProcessBuffer.init(alloc);
    var output = Output.init(alloc, process_buffer);
    defer process_buffer.deinit();
    defer output.deinit();

    try process_buffer.append(
        \\line 1: apples
        \\line 2: carrots
        \\line 3: carrots
        \\line 4: apples
        \\line 5: carrots
        \\line 6: apples
        \\line 7: carrots
    );
    const apple_len: comptime_int = "apples".len;
    const apple_line_len: comptime_int = "line 1: apples\n".len;
    const carrots_line_len: comptime_int = "line 1: carrots\n".len;
    const prefix_len: comptime_int = "line 1: ".len;

    const color_args = "apples red";
    try Output.handleColorCmd(color_args, &output);
    const buffer = try output.copyBuffer(alloc);
    defer alloc.free(buffer);

    var expected_list = Output.StyleList.init(alloc);
    defer expected_list.deinit();
    try expected_list.append(vaxis.Style{ .fg = .{ .rgb = .{ 255, 0, 0 } } });

    var expected_map = Output.StyleMap.init(alloc);
    defer expected_map.deinit();

    for (prefix_len..prefix_len + apple_len) |i| {
        try expected_map.put(i, 0);
    }

    const starting_ofs = apple_line_len + carrots_line_len * 2 + prefix_len; // add 3 bytes for newlines
    for (starting_ofs..starting_ofs + apple_len) |i| {
        try expected_map.put(i, 0);
    }

    const starting_ofs2 = apple_line_len * 2 + carrots_line_len * 3 + prefix_len; // add 5 bytes for newlines
    for (starting_ofs2..starting_ofs2 + apple_len) |i| {
        try expected_map.put(i, 0);
    }

    errdefer {
        std.debug.print("expected...\n", .{});
        var expected_it = expected_map.iterator();
        while (expected_it.next()) |entry| {
            std.debug.print("map key: {d} value: {d}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        std.debug.print("actual...\n", .{});
        var actual_it = output.style_map.iterator();
        while (actual_it.next()) |entry| {
            std.debug.print("map key: {d} value: {d}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }

    try testing.expectEqualDeep(expected_list, output.style_list);

    try testing.expectEqual(expected_map.count(), output.style_map.count());
    var it = expected_map.iterator();
    while (it.next()) |entry| {
        const actual_value = output.style_map.get(entry.key_ptr.*) orelse return error.MissingKey;
        try testing.expectEqual(entry.value_ptr.*, actual_value);
    }
}
