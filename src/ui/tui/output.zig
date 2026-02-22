const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils");
const helpers = @import("helpers.zig");
const debug_ui = @import("debug_ui");

const process_buffer_mod = @import("pipeline/processbuffer.zig");
const search = @import("pipeline/search.zig");
const cmd_mod = @import("cmd/cmd.zig");
const transforms = @import("pipeline/transforms.zig");

// ui data structures
const vaxis = @import("vaxis");
const OutputWidget = @import("outputwidget.zig").OutputWidget;
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

const SearchInfo = struct {
    const ResultCache = struct {
        result: search.ProcessBufferSearchIterator.Result,
        cached_style: ?[]?vaxis.Style = null,
    };

    iterator: search.ProcessBufferSearchIterator,
    regex: *Regex,
    result_cache: ?ResultCache = null,
    highlight_style: vaxis.Style = .{ .bg = .{ .rgb = .{ 255, 255, 255 } } },

    pub fn deinit(self: *SearchInfo, alloc: std.mem.Allocator) void {
        if (self.result_cache) |cache| {
            alloc.free(cache.result.str);
            if (cache.cached_style) |style_slice| {
                alloc.free(style_slice);
            }
        }
        self.regex.deinit();
        alloc.destroy(self.regex);
        self.iterator.deinit();
    }

    pub fn setCache(
        self: *SearchInfo,
        alloc: std.mem.Allocator,
        result: *const search.ProcessBufferSearchIterator.Result,
    ) !void {
        if (self.result_cache != null) clearCache(self, alloc);

        self.result_cache = .{
            .result = .{
                .str = try alloc.dupe(u8, result.str),
                .lowerBound = result.lowerBound,
                .upperBound = result.upperBound,
            },
        };
    }

    pub fn clearCache(self: *SearchInfo, alloc: std.mem.Allocator) void {
        if (self.result_cache == null) return;
        alloc.free(self.result_cache.?.result.str);
        if (self.result_cache.?.cached_style) |cached_style| {
            alloc.free(cached_style);
        }
        self.result_cache = null;
    }

    pub fn cacheStyle(self: *SearchInfo, alloc: std.mem.Allocator, style_map: *const StyleMap, style_list: *const StyleList) !void {
        if (self.result_cache == null) return;

        const upperBound = self.result_cache.?.result.upperBound;
        const lowerBound = self.result_cache.?.result.lowerBound;

        // cache the existing styles into a slice using the current result
        var array = try std.ArrayListUnmanaged(?vaxis.Style).initCapacity(alloc, upperBound - lowerBound);
        for (lowerBound..upperBound) |i| {
            const style_idx = style_map.get(i);
            if (style_idx) |idx| {
                try array.append(alloc, style_list.items[idx]);
            } else {
                try array.append(alloc, null);
            }
        }
        self.result_cache.?.cached_style = try array.toOwnedSlice(alloc);
    }
};

arena: std.heap.ArenaAllocator,
_alloc: std.mem.Allocator,
nonowned_process_buffer: *ProcessBuffer,
cmd_ref: ?*Cmd = null,
widget_ref: ?*OutputWidget = null,
search_info: ?SearchInfo = null,
handlers_ids: std.ArrayList(cmd_mod.HandleId),
filter_ids: std.ArrayList(Filter.HandleId),
reviewer_ids: std.ArrayList(Reviewer.HandleId),
is_focused: bool = false,

style_list: StyleList,
style_map: StyleMap,

const UnfoldHandlerData = .{
    .event_str = "unfilter",
    .arg_description = null,
    .handle = handleUnfoldCmd,
};
const FoldHandlerData = .{
    .event_str = "keep",
    .arg_description = "str1 str2 ... strn",
    .handle = handleFoldCmd,
};
const PruneHandlerData = .{
    .event_str = "hide",
    .arg_description = "str1 str2 ... strn",
    .handle = handlePruneCmd,
};
const UnreplaceHandlerData = .{
    .event_str = "unreplace",
    .arg_description = null,
    .handle = handleUnreplaceCmd,
};
const ReplaceHandlerData = .{
    .event_str = "replace",
    .arg_description = "{str1 str2} ... {strn-1 strn}",
    .handle = handleReplaceCmd,
};
const FindHandlerData = .{
    .event_str = "find",
    .arg_description = "str",
    .handle = handleFindCmd,
};
const NextHandlerData = .{
    .event_str = "next",
    .arg_description = null,
    .handle = handleFindNextCmd,
};
const PrevHandlerData = .{
    .event_str = "prev",
    .arg_description = null,
    .handle = handleFindPrevCmd,
};
const JumpHandlerData = .{
    .event_str = "j",
    .arg_description = "str",
    .handle = handleJumpCmd,
};
const InfoHandlerData = .{
    .event_str = "s",
    .arg_description = null,
    .handle = handleInfoCmd,
};
const UncolorHandlerData = .{
    .event_str = "uncolor",
    .arg_description = null,
    .handle = handleUncolorCmd,
};
const ColorHandlerData = .{
    .event_str = "color",
    .arg_description = "pattern fg:color:bg:color:line",
    .handle = handleColorCmd,
};

pub fn init(alloc: std.mem.Allocator, process_buf: *ProcessBuffer) !Output {
    return .{
        .arena = std.heap.ArenaAllocator.init(alloc),
        ._alloc = alloc,
        .handlers_ids = try std.ArrayList(cmd_mod.HandleId).initCapacity(alloc, 10),
        .filter_ids = try std.ArrayList(Filter.HandleId).initCapacity(alloc, 10),
        .reviewer_ids = try std.ArrayList(Reviewer.HandleId).initCapacity(alloc, 10),
        .nonowned_process_buffer = process_buf,
        .style_list = try StyleList.initCapacity(alloc, 10),
        .style_map = StyleMap.init(alloc),
    };
}

pub fn deinit(self: *Output) void {
    if (self.cmd_ref != null) {
        self.unsubscribeHandlersFromCmd();
    }
    self.handlers_ids.deinit(self._alloc);
    for (self.filter_ids.items) |fId| {
        var filter = self.nonowned_process_buffer.pipeline.removeFilter(fId);
        if (filter) |*f| {
            f.deinit();
        }
    }
    self.filter_ids.deinit(self._alloc);
    for (self.reviewer_ids.items) |rId| {
        var reviewer = self.nonowned_process_buffer.pipeline.removeReviewer(rId);
        if (reviewer) |*r| {
            r.deinit();
        }
    }
    if (self.search_info) |*info| {
        info.deinit(self.widget_ref.?.alloc);
    }
    self.reviewer_ids.deinit(self._alloc);
    self.style_map.deinit();
    self.style_list.deinit(self._alloc);
    self.arena.deinit();
}

fn handleFoldCmd(args: []const u8, listener: *anyopaque) std.mem.Allocator.Error!void {
    const self: *Output = @ptrCast(@alignCast(listener));

    if (!self.is_focused) return;

    const alloc = self.arena.allocator();

    // parse the arguments
    const arguments = try utils.parseArgsLineWithQuoteGroups(alloc, args);
    defer {
        for (arguments) |s| alloc.free(s);
        alloc.free(arguments);
    }

    // create a list of compiled regex objects
    var regex_list = try std.ArrayList(Regex).initCapacity(alloc, arguments.len);
    for (arguments) |arg| {
        const re = Regex.compile(alloc, arg) catch {
            continue;
        };
        try regex_list.append(alloc, re);
    }

    const filter_data = try alloc.create(transforms.FoldFilterData);
    filter_data.* = .{ .regexs = try regex_list.toOwnedSlice(alloc) };

    // we need to recalculate the color styles
    self.clearStyle();

    // Create the filter and add to the pipeline
    const filter = try Filter.init(self.arena.allocator(), filter_data, transforms.fold);
    try self.filter_ids.append(self._alloc, filter.id);
    try self.nonowned_process_buffer.addFilter(filter);
}

fn handlePruneCmd(args: []const u8, listener: *anyopaque) std.mem.Allocator.Error!void {
    const self: *Output = @ptrCast(@alignCast(listener));

    if (!self.is_focused) return;

    const alloc = self.arena.allocator();

    // parse the arguments
    const arguments = try utils.parseArgsLineWithQuoteGroups(alloc, args);
    defer {
        for (arguments) |s| alloc.free(s);
        alloc.free(arguments);
    }

    // create a list of compiled regex objects
    var regex_list = try std.ArrayList(Regex).initCapacity(alloc, arguments.len);
    for (arguments) |arg| {
        const re = Regex.compile(alloc, arg) catch {
            continue;
        };
        try regex_list.append(alloc, re);
    }

    const filter_data = try alloc.create(transforms.PruneFilterData);
    filter_data.* = .{ .regexs = try regex_list.toOwnedSlice(alloc) };

    // we need to recalculate the color styles
    self.clearStyle();

    // Create the filter and add to the pipeline
    const filter = try Filter.init(self.arena.allocator(), filter_data, transforms.prune);
    try self.filter_ids.append(self._alloc, filter.id);
    try self.nonowned_process_buffer.addFilter(filter);
}

fn handleReplaceCmd(args: []const u8, listener: *anyopaque) std.mem.Allocator.Error!void {
    const self: *Output = @ptrCast(@alignCast(listener));
    const alloc = self.arena.allocator();

    if (!self.is_focused) return;

    // parse the arguments for the replace command
    const arg_array = try utils.parseArgsLineWithQuoteGroups(alloc, args);
    defer {
        for (arg_array) |s| alloc.free(s);
        alloc.free(arg_array);
    }

    if (arg_array.len % 2 != 0) {
        // don't parse any arguments if the full line is invalid
        return;
    }

    // each pair comes in the form of `search_str` `replace_str`
    var replace_patterns = try std.ArrayList(transforms.ReplacePattern).initCapacity(
        alloc,
        arg_array.len / 2,
    );
    for (0..arg_array.len / 2) |i| {
        const search_arg = arg_array[i * 2];
        const replace_arg = arg_array[i * 2 + 1];

        const re = Regex.compile(alloc, search_arg) catch {
            continue;
        };
        try replace_patterns.append(
            alloc,
            .{ .regex = re, .replace_str = try alloc.dupe(u8, replace_arg) },
        );
    }

    // Create the data object for the replaceReviewer
    const reviewer_data = try alloc.create(transforms.ReplaceFilterData);
    reviewer_data.* = .{
        .replace_patterns = try replace_patterns.toOwnedSlice(alloc),
    };

    // we need to recalculate the color styles
    self.clearStyle();

    const filter = try Filter.init(self.arena.allocator(), reviewer_data, transforms.replace);
    try self.filter_ids.append(self._alloc, filter.id);
    try self.nonowned_process_buffer.addFilter(filter);
}

fn handleUnfoldCmd(_: []const u8, listener: *anyopaque) std.mem.Allocator.Error!void {
    const self: *Output = @ptrCast(@alignCast(listener));

    if (!self.is_focused) return;

    // we need to recalculate the color styles
    self.clearStyle();

    // TODO: only remove fold commands
    try self.nonowned_process_buffer.removeAllFilters();
    self.filter_ids.clearAndFree(self._alloc);
}

fn handleUnreplaceCmd(_: []const u8, listener: *anyopaque) std.mem.Allocator.Error!void {
    const self: *Output = @ptrCast(@alignCast(listener));

    if (!self.is_focused) return;

    // we need to recalculate the color styles
    self.clearStyle();

    // TODO: only remove replace commands
    try self.nonowned_process_buffer.removeAllFilters();
    self.filter_ids.clearAndFree(self._alloc);
}

fn handleFindCmd(args: []const u8, listener: *anyopaque) std.mem.Allocator.Error!void {
    const self: *Output = @ptrCast(@alignCast(listener));
    const alloc = self.arena.allocator();

    if (!self.is_focused) return;

    // parse the arguments
    const arguments = try utils.parseArgsLineWithQuoteGroups(alloc, args);
    defer {
        for (arguments) |s| alloc.free(s);
        alloc.free(arguments);
    }

    if (arguments.len < 1) return;

    const start_from_line = self.widget_ref.?.window.last_draw.top_line;
    //const top_rendered_line_buffer_offset = self.widget_ref.?.get_rendered_line_buffer_offset(.first) catch |e| switch (e) {
    //    error.NoLinesRendered => return,
    //    error.LineNotRendered => return,
    //};

    self.searchStr(arguments[0], start_from_line) catch return;
}

fn handleFindNextCmd(_: []const u8, listener: *anyopaque) std.mem.Allocator.Error!void {
    const self: *Output = @ptrCast(@alignCast(listener));
    if (!self.is_focused) return;
    self.searchNext();
}

fn handleFindPrevCmd(_: []const u8, listener: *anyopaque) std.mem.Allocator.Error!void {
    const self: *Output = @ptrCast(@alignCast(listener));
    if (!self.is_focused) return;
    self.searchPrev();
}

fn handleJumpCmd(arg: []const u8, listener: *anyopaque) std.mem.Allocator.Error!void {
    const self: *Output = @ptrCast(@alignCast(listener));
    if (!self.is_focused) return;

    const line_num: usize = std.fmt.parseInt(usize, arg, 10) catch return;
    self.jumpToLine(line_num);
}

fn handleInfoCmd(_: []const u8, listener: *anyopaque) std.mem.Allocator.Error!void {
    const self: *Output = @ptrCast(@alignCast(listener));
    if (!self.is_focused) return;

    self.debuginfo();
}

fn handleUncolorCmd(_: []const u8, listener: *anyopaque) std.mem.Allocator.Error!void {
    const self: *Output = @ptrCast(@alignCast(listener));
    if (!self.is_focused) return;
    self.clearStyle();
    try self.nonowned_process_buffer.removeAllReviewers();
    self.reviewer_ids.clearAndFree(self._alloc);
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
fn createStyleFromArg(arg: []const u8) ?transforms.ColorPattern {
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
            if (isFirstSegment) isFirstSegment = false;
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
                std.log.debug("print full line\n", .{});
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
        return transforms.ColorPattern{ .regex = undefined, .full_line = color_line, .style = res };
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
            try applied_color_rules.append(salloc, c_rule);
        }
    }
    if (self_config) |c| {
        for (c.colorRules) |*c_rule| {
            try applied_color_rules.append(salloc, c_rule);
        }
    }

    // parse all color rules
    var patterns = try std.ArrayList(transforms.ColorPattern).initCapacity(alloc, num_color_rules);
    for (applied_color_rules.items) |c_rule| {
        if (c_rule.background_color == null and c_rule.foreground_color == null) continue;
        if (c_rule.pattern == null) continue;

        const re = Regex.compile(alloc, c_rule.pattern.?) catch {
            continue;
        };

        // create style argument
        var style_args = try std.ArrayList([]u8).initCapacity(salloc, 2);
        if (c_rule.background_color) |bg_str| {
            try style_args.append(salloc, try salloc.dupe(u8, "bg"));
            try style_args.append(salloc, try salloc.dupe(u8, bg_str));
        }
        if (c_rule.foreground_color) |fg_str| {
            try style_args.append(salloc, try salloc.dupe(u8, "fg"));
            try style_args.append(salloc, try salloc.dupe(u8, fg_str));
        }
        if (!c_rule.just_pattern) {
            try style_args.append(salloc, try salloc.dupe(u8, "line"));
        }
        const style_arg = try std.mem.join(salloc, ":", style_args.items);

        var color_pattern = createStyleFromArg(style_arg);
        if (color_pattern == null) continue;

        color_pattern.?.regex = re;
        try patterns.append(alloc, color_pattern.?);
    }

    const reviewer_data = try alloc.create(transforms.ColorReviewerData);
    reviewer_data.* = .{
        .output = self,
        .style_patterns = try patterns.toOwnedSlice(alloc),
    };

    // Create and add the reviewer to the process buffer
    const reviewer = try Reviewer.init(self.arena.allocator(), reviewer_data, transforms.color);
    try self.reviewer_ids.append(self._alloc, reviewer.id);
    try self.nonowned_process_buffer.addReviewer(reviewer);
}

fn handleColorCmd(args: []const u8, listener: *anyopaque) std.mem.Allocator.Error!void {
    const self: *Output = @ptrCast(@alignCast(listener));
    const alloc = self.arena.allocator();

    if (!self.is_focused) return;

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
    var color_patterns = try std.ArrayList(transforms.ColorPattern).initCapacity(alloc, arg_array.len / 2);
    for (0..arg_array.len / 2) |i| {
        const regex_arg = arg_array[i * 2];
        const style_arg = arg_array[i * 2 + 1];

        const re = Regex.compile(alloc, regex_arg) catch {
            continue;
        };
        var color_pattern = createStyleFromArg(style_arg);
        if (color_pattern == null) continue;

        color_pattern.?.regex = re;
        try color_patterns.append(alloc, color_pattern.?);
    }

    // Create the data object for the colorReviewer
    const reviewer_data = try alloc.create(transforms.ColorReviewerData);
    reviewer_data.* = .{
        .output = self,
        .style_patterns = try color_patterns.toOwnedSlice(alloc),
    };

    // Create and add the reviewer to the process buffer
    const reviewer = try Reviewer.init(self.arena.allocator(), reviewer_data, transforms.color);
    try self.reviewer_ids.append(self._alloc, reviewer.id);
    try self.nonowned_process_buffer.addReviewer(reviewer);
}

pub fn removeSearch(self: *Output) !void {
    const alloc = self.widget_ref.?.alloc;

    // unhighlight previous match
    if (self.search_info) |*sinfo| {
        if (sinfo.result_cache) |*prev_result| {
            if (prev_result.cached_style) |style_range| {
                self.updateStyleWithRange(
                    style_range,
                    prev_result.result.lowerBound,
                ) catch return;
            }
        }

        // remove the search info
        sinfo.deinit(alloc);
        self.search_info = null;
    }
}

// TODO: handle errors properly
pub fn searchStr(self: *Output, search_str: []const u8, start_search_line: usize) !void {
    var alloc = self.widget_ref.?.alloc;

    // unhighlight and remove previous match
    try self.removeSearch();

    // create regex
    var re = try alloc.create(Regex);
    re.* = try Regex.compile(alloc, search_str);
    errdefer alloc.destroy(re);

    // start our two attempts at finding the match starting at the start_serach_line and looping
    // around to the start of the buffer
    var secondAttempt = false;
    while (true) : (secondAttempt = true) {
        var start_searching_line: usize = 0;
        if (secondAttempt == false) {
            start_searching_line = start_search_line;
        }

        // if start_searching_line is 0 on our first attempt, we don't search twice
        if (start_searching_line == 0 and secondAttempt == false) secondAttempt = true;

        var search_iter = search.startSearchFrom(
            alloc,
            self.nonowned_process_buffer,
            re,
            start_searching_line,
        ) catch return;

        const match = try search_iter.next();

        if (match) |*m| {
            // jump to the line containing the start of the match
            self.widget_ref.?.jump_output_to_line(
                self.nonowned_process_buffer.filtered_buffer.getLineIndexFromOffset(m.lowerBound).?,
            ) catch return;

            // free previous search_info and save new one
            if (self.search_info) |*info| {
                info.clearCache(alloc);
                info.deinit(alloc);
            }

            // cache the new search info
            self.search_info = .{ .iterator = search_iter, .regex = re };
            self.search_info.?.setCache(alloc, m) catch return;
            self.search_info.?.cacheStyle(
                alloc,
                &self.style_map,
                &self.style_list,
            ) catch return;

            // highlight the found match
            self.updateStyle(&self.search_info.?.highlight_style, m.lowerBound, m.upperBound) catch return;
            break;
        }

        if (secondAttempt) {
            // We failed to find a match
            search_iter.deinit();
            re.deinit();
            alloc.destroy(re);
            break;
        }
    }
}

// TODO: handle errors properly
pub fn searchNext(self: *Output) void {
    if (self.search_info) |*sinfo| {
        if (sinfo.iterator.next() catch return) |*match| {
            // jump to the line containing the start of the match
            self.widget_ref.?.jump_output_to_line(
                self.nonowned_process_buffer.filtered_buffer.getLineIndexFromOffset(match.lowerBound).?,
            ) catch return;

            // unhighlight previous match
            if (sinfo.result_cache) |*prev_result| {
                if (prev_result.cached_style) |style_range| {
                    self.updateStyleWithRange(
                        style_range,
                        prev_result.result.lowerBound,
                    ) catch return;
                }
            }

            // save the search results
            sinfo.setCache(self.widget_ref.?.alloc, match) catch return;
            sinfo.cacheStyle(self.widget_ref.?.alloc, &self.style_map, &self.style_list) catch return;

            // highlight new match
            self.updateStyle(&self.search_info.?.highlight_style, match.lowerBound, match.upperBound) catch return;
        } else {
            // the iterator got to the end, attempt to back off to the last match
            _ = sinfo.iterator.prev() catch {};
        }
    }
}

// TODO: handle errors properly
pub fn searchPrev(self: *Output) void {
    if (self.search_info) |*sinfo| {
        if (sinfo.iterator.prev() catch return) |*match| {
            // jump to the line container the  start of the match
            self.widget_ref.?.jump_output_to_line(
                self.nonowned_process_buffer.filtered_buffer.getLineIndexFromOffset(match.lowerBound).?,
            ) catch return;

            // unhighlight previous match
            if (sinfo.result_cache) |*prev_result| {
                if (prev_result.cached_style) |style_range| {
                    self.updateStyleWithRange(
                        style_range,
                        prev_result.result.lowerBound,
                    ) catch return;
                }
            }

            // save the search results
            sinfo.setCache(self.widget_ref.?.alloc, match) catch return;
            sinfo.cacheStyle(self.widget_ref.?.alloc, &self.style_map, &self.style_list) catch return;

            // highlight new match
            self.updateStyle(&self.search_info.?.highlight_style, match.lowerBound, match.upperBound) catch return;
        } else {
            // the iterator got to the start, attempt to back off to the first match
            _ = sinfo.iterator.next() catch {};
        }
    }
}

pub fn debuginfo(self: *Output) void {
    if (builtin.mode == .Debug) {
        debug_ui.print("output {s}\n", .{self.widget_ref.?.process_name}) catch {};
        debug_ui.print("top_line {d}\n", .{self.widget_ref.?.window.last_draw.top_line}) catch {};
        debug_ui.print("is focused {any}\n", .{self.is_focused}) catch {};
        debug_ui.print("window: ...\n", .{}) catch {};
        debug_ui.print("window: top_line {d}\n", .{self.widget_ref.?.window.top_line}) catch {};
        debug_ui.print("window: num_lines {d}\n", .{self.widget_ref.?.window.num_lines}) catch {};
    }
}

pub fn jumpToLine(self: *Output, line_num: usize) void {
    self.widget_ref.?.jump_output_to_line(line_num) catch return;
}

pub fn clearStyle(self: *Output) void {
    self.style_list.clearAndFree(self._alloc);
    self.style_map.clearAndFree();
}

/// Update the style structures in the output style_map and style_list
pub fn updateStyle(self: *Output, style: *const vaxis.Style, begin_offset: usize, end_offset: usize) !void {
    const style_index = blk: {
        for (self.style_list.items, 0..) |s, i| {
            if (std.meta.eql(s, style.*)) {
                break :blk i;
            }
        }
        try self.style_list.append(self._alloc, style.*);
        break :blk self.style_list.items.len - 1;
    };
    for (begin_offset..end_offset) |i| {
        try self.style_map.put(i, style_index);
    }
}

pub fn updateStyleWithRange(self: *Output, style_range: []?vaxis.Style, begin_offset: usize) !void {
    const end_offset: usize = begin_offset + style_range.len;

    for (begin_offset..end_offset, 0..) |offset, range_idx| {
        const current_style = style_range[range_idx];

        // find style offset, create if it doesn't exist
        if (current_style) |style| {
            const style_index = blk: {
                for (self.style_list.items, 0..) |s, i| {
                    if (std.meta.eql(s, style)) {
                        break :blk i;
                    }
                }
                try self.style_list.append(self._alloc, style);
                break :blk self.style_list.items.len - 1;
            };
            try self.style_map.put(offset, style_index);
        } else {
            // there previously wasn't a style for this index
            _ = self.style_map.remove(offset);
        }
    }
}

pub fn subscribeHandlersToCmd(self: *Output, cmd: *Cmd) !void {
    std.debug.assert(self.cmd_ref == null);

    self.cmd_ref = cmd;

    const handler_data = comptime .{
        &FoldHandlerData,
        &UnfoldHandlerData,
        &PruneHandlerData,
        &ReplaceHandlerData,
        &UnreplaceHandlerData,
        &ColorHandlerData,
        &UncolorHandlerData,
        &FindHandlerData,
        &NextHandlerData,
        &PrevHandlerData,
        &JumpHandlerData,
        &InfoHandlerData,
    };

    inline for (handler_data) |data| {
        const handler: Handler = .{
            .event_str = data.event_str,
            .arg_description = data.arg_description,
            .handle = data.handle,
            .listener = self,
        };
        const id = try self.cmd_ref.?.addHandler(handler);
        try self.handlers_ids.append(self._alloc, id);
    }
}

pub fn unsubscribeHandlersFromCmd(self: *Output) void {
    std.debug.assert(self.cmd_ref != null);

    for (self.handlers_ids.items) |id| {
        self.cmd_ref.?.removeHandler(id);
    }
    self.handlers_ids.clearAndFree(self._alloc);

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
    var output = try Output.init(alloc, process_buffer);
    defer process_buffer.deinit();
    defer output.deinit();

    std.debug.print("process_buffer.lastNewLine = {d}\n", .{process_buffer.lastNewLine});
    try process_buffer.append(
        \\line 1: apples
        \\line 2: carrots
        \\line 3: carrots
        \\line 4: apples
        \\line 5: carrots
        \\line 6: apples
        \\line 7: carrots
        \\
    );
    std.debug.print("process_buffer.lastNewLine = {d}\n", .{process_buffer.lastNewLine});

    // set focus to make sure the command works
    output.is_focused = true;

    const fold_args = "apples";
    try Output.handleFoldCmd(fold_args, &output);
    const buffer = try output.copyBuffer(alloc);
    defer alloc.free(buffer);

    std.debug.print("process_buffer.lastNewLine = {d}\n", .{process_buffer.lastNewLine});

    try testing.expectEqualStrings(
        \\line 1: apples
        \\line 4: apples
        \\line 6: apples
    , buffer);

    // Add another line to be filtered
    try process_buffer.append("line 8: carrots\n");
    std.debug.print("process_buffer.lastNewLine = {d}\n", .{process_buffer.lastNewLine});

    const buffer2 = try output.copyBuffer(alloc);
    defer alloc.free(buffer2);

    try testing.expectEqualStrings(
        \\line 1: apples
        \\line 4: apples
        \\line 6: apples
    , buffer2);

    // BUG: might be due to lastNewLine not being updated....
    // Add another line which should be included
    try process_buffer.append("line 9: apples\n");
    std.debug.print("process_buffer.lastNewLine = {d}\n", .{process_buffer.lastNewLine});

    const buffer3 = try output.copyBuffer(alloc);
    defer alloc.free(buffer3);

    try testing.expectEqualStrings(
        \\line 1: apples
        \\line 4: apples
        \\line 6: apples
        \\line 9: apples
    , buffer3);
}

// TODO test the color arg parsing
// TODO test using the pipeline with color reviewers
// TODO test coloring in multistyletext...
//   there seems to be an off by 1 due to newlines

test "coloring text" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var process_buffer = try ProcessBuffer.init(alloc);
    var output = try Output.init(alloc, process_buffer);
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

    var expected_list = try Output.StyleList.initCapacity(alloc, 7);
    defer expected_list.deinit(alloc);
    try expected_list.append(alloc, vaxis.Style{ .fg = .{ .rgb = .{ 255, 0, 0 } } });

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
        std.log.debug("expected...\n", .{});
        var expected_it = expected_map.iterator();
        while (expected_it.next()) |entry| {
            std.log.debug("map key: {d} value: {d}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        std.log.debug("actual...\n", .{});
        var actual_it = output.style_map.iterator();
        while (actual_it.next()) |entry| {
            std.log.debug("map key: {d} value: {d}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
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
