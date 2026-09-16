const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const utils = @import("utils");
const helpers = @import("helpers.zig");
const debug_ui = @import("debug_ui");

const process_buffer_mod = @import("pipeline/processbuffer.zig");
const ingeststore = @import("pipeline/ingeststore.zig");
const search = @import("pipeline/search.zig");
const cmd_mod = @import("cmd/cmd.zig");
const actions = @import("actions/actions.zig");
const transforms = @import("pipeline/transforms.zig");

// ui data structures
const vaxis = @import("vaxis");
const OutputWidget = @import("outputwidget.zig").OutputWidget;
const uiconfig_mod = @import("uiconfig");
pub const UiConfig = uiconfig_mod.UiConfig;
pub const ProcessConfig = uiconfig_mod.ProcessConfig;
pub const ColorRule = uiconfig_mod.ColorRule;

pub const Output = @This();
const Regex = @import("regex").Regex;
pub const ProcessBuffer = process_buffer_mod.ProcessBuffer;
pub const WindowSnapshot = process_buffer_mod.WindowSnapshot;
pub const IngestStore = ingeststore.IngestStore;
pub const PumpCommand = ingeststore.PumpCommand;
pub const Filter = process_buffer_mod.Filter;
pub const Pipeline = process_buffer_mod.Pipeline;
pub const Reviewer = process_buffer_mod.Reviewer;
pub const Cmd = cmd_mod.Cmd;
const Handler = cmd_mod.Handler;

/// Live search state for `find`/`next`/`prev`. The highlight is an overlay applied at draw
/// time and is only shown while the searcher's copy matches the buffer's version.
const SearchState = struct {
    searcher: search.Searcher,
    current: ?search.Match = null,
    highlight_style: vaxis.Style = .{ .bg = .{ .rgb = .{ 255, 255, 255 } }, .fg = .{ .rgb = .{ 0, 0, 0 } } },
};

pub const Highlight = struct { start: usize, end: usize, style: vaxis.Style };

arena: std.heap.ArenaAllocator,
_alloc: std.mem.Allocator,
/// pump-owned; read only through snapshots, mutated only via `store` commands
nonowned_process_buffer: *ProcessBuffer,
store: *IngestStore,
cmd_ref: ?*Cmd = null,
widget_ref: ?*OutputWidget = null,
search_state: ?SearchState = null,
handlers_ids: std.ArrayList(cmd_mod.HandleId),
filter_ids: std.ArrayList(Filter.HandleId),
reviewer_ids: std.ArrayList(Reviewer.HandleId),
is_focused: bool = false,
show_lines: bool = true,

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
const ShowLinesHandlerData = .{
    .event_str = "lines",
    .arg_description = "{--all on|off}",
    .handle = handleShowLinesCmd,
};
const DumpBufferHandlerData = .{
    .event_str = "dump",
    .arg_description = "{--all | -a} {--filtered | -f}",
    .handle = handleDumpCmd,
};

pub fn init(alloc: std.mem.Allocator, process_buf: *ProcessBuffer, store: *IngestStore) !Output {
    return .{
        .arena = std.heap.ArenaAllocator.init(alloc),
        ._alloc = alloc,
        .handlers_ids = try std.ArrayList(cmd_mod.HandleId).initCapacity(alloc, 10),
        .filter_ids = try std.ArrayList(Filter.HandleId).initCapacity(alloc, 10),
        .reviewer_ids = try std.ArrayList(Reviewer.HandleId).initCapacity(alloc, 10),
        .nonowned_process_buffer = process_buf,
        .store = store,
    };
}

/// Posts the removal of every filter/reviewer this output installed. The removals are
/// queued behind anything already in flight, so they always apply before a later
/// `remove_buffer`.
pub fn deinit(self: *Output, io: Io) void {
    _ = io;
    if (self.cmd_ref != null) {
        self.unsubscribeHandlersFromCmd();
    }
    self.handlers_ids.deinit(self._alloc);
    const id = self.bufferId();
    for (self.filter_ids.items) |fId| {
        self.store.post(.{ .remove_filter = .{ .id = id, .fid = fId } }) catch {};
    }
    self.filter_ids.deinit(self._alloc);
    for (self.reviewer_ids.items) |rId| {
        self.store.post(.{ .remove_reviewer = .{ .id = id, .rid = rId } }) catch {};
    }
    self.reviewer_ids.deinit(self._alloc);
    if (self.search_state) |*s| s.searcher.deinit();
    self.arena.deinit();
}

fn bufferId(self: *const Output) utils.uuid.UUID {
    return self.nonowned_process_buffer.id orelse .{ .bytes = [_]u8{0} ** 16 };
}

/// Compiles every argument as a regex into `alloc`; invalid patterns are skipped.
fn compileRegexList(alloc: std.mem.Allocator, arguments: []const []const u8) std.mem.Allocator.Error![]Regex {
    var regex_list = try std.ArrayList(Regex).initCapacity(alloc, arguments.len);
    for (arguments) |arg| {
        const re = Regex.compile(alloc, arg) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                std.log.warn("ignoring invalid regex \"{s}\": {t}", .{ arg, err });
                continue;
            },
        };
        try regex_list.append(alloc, re);
    }
    return try regex_list.toOwnedSlice(alloc);
}

fn parseArgs(self: *Output, args: []const u8) std.mem.Allocator.Error![]const []const u8 {
    return utils.parseArgsLineWithQuoteGroups(self.arena.allocator(), args);
}

fn freeArgs(self: *Output, arguments: []const []const u8) void {
    const alloc = self.arena.allocator();
    for (arguments) |s| alloc.free(s);
    alloc.free(arguments);
}

fn installLineFilter(
    self: *Output,
    arguments: []const []const u8,
    transform_fn: Filter.TransformLineFn,
) std.mem.Allocator.Error!void {
    var filter = try Filter.init(self._alloc, transform_fn);
    errdefer filter.deinit();
    const owned = filter.ownedAllocator();

    const filter_data = try owned.create(transforms.FoldFilterData);
    filter_data.* = .{ .regexs = try compileRegexList(owned, arguments) };
    filter.data = filter_data;

    try self.filter_ids.append(self._alloc, filter.id);
    // ownership of `filter` transfers to the pump (post frees it on failure)
    self.store.post(.{ .add_filter = .{ .id = self.bufferId(), .filter = filter } }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.log.warn("could not install filter: {t}", .{err}),
    };
}

fn handleFoldCmd(_: Io, args: []const u8, listener: *anyopaque) std.mem.Allocator.Error!void {
    const self: *Output = @ptrCast(@alignCast(listener));
    if (!self.is_focused) return;

    const arguments = try self.parseArgs(args);
    defer self.freeArgs(arguments);

    try self.installLineFilter(arguments, transforms.fold);
}

fn handlePruneCmd(_: Io, args: []const u8, listener: *anyopaque) std.mem.Allocator.Error!void {
    const self: *Output = @ptrCast(@alignCast(listener));
    if (!self.is_focused) return;

    const arguments = try self.parseArgs(args);
    defer self.freeArgs(arguments);

    try self.installLineFilter(arguments, transforms.prune);
}

fn handleReplaceCmd(_: Io, args: []const u8, listener: *anyopaque) std.mem.Allocator.Error!void {
    const self: *Output = @ptrCast(@alignCast(listener));
    if (!self.is_focused) return;

    const arg_array = try self.parseArgs(args);
    defer self.freeArgs(arg_array);

    if (arg_array.len % 2 != 0) {
        // don't parse any arguments if the full line is invalid
        return;
    }

    var filter = try Filter.init(self._alloc, transforms.replace);
    errdefer filter.deinit();
    const owned = filter.ownedAllocator();

    // each pair comes in the form of `search_str` `replace_str`
    var replace_patterns = try std.ArrayList(transforms.ReplacePattern).initCapacity(owned, arg_array.len / 2);
    for (0..arg_array.len / 2) |i| {
        const search_arg = arg_array[i * 2];
        const replace_arg = arg_array[i * 2 + 1];

        const re = Regex.compile(owned, search_arg) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                std.log.warn("ignoring invalid regex \"{s}\": {t}", .{ search_arg, err });
                continue;
            },
        };
        try replace_patterns.append(owned, .{ .regex = re, .replace_str = try owned.dupe(u8, replace_arg) });
    }

    const filter_data = try owned.create(transforms.ReplaceFilterData);
    filter_data.* = .{ .replace_patterns = try replace_patterns.toOwnedSlice(owned) };
    filter.data = filter_data;

    try self.filter_ids.append(self._alloc, filter.id);
    self.store.post(.{ .add_filter = .{ .id = self.bufferId(), .filter = filter } }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.log.warn("could not install filter: {t}", .{err}),
    };
}

fn removeAllFilters(self: *Output) std.mem.Allocator.Error!void {
    self.store.post(.{ .remove_all_filters = .{ .id = self.bufferId() } }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.log.warn("could not remove filters: {t}", .{err}),
    };
    self.filter_ids.clearAndFree(self._alloc);
}

fn handleUnfoldCmd(_: Io, _: []const u8, listener: *anyopaque) std.mem.Allocator.Error!void {
    const self: *Output = @ptrCast(@alignCast(listener));
    if (!self.is_focused) return;

    // TODO: only remove fold commands
    try self.removeAllFilters();
}

fn handleUnreplaceCmd(_: Io, _: []const u8, listener: *anyopaque) std.mem.Allocator.Error!void {
    const self: *Output = @ptrCast(@alignCast(listener));
    if (!self.is_focused) return;

    // TODO: only remove replace commands
    try self.removeAllFilters();
}

fn handleFindCmd(io: Io, args: []const u8, listener: *anyopaque) std.mem.Allocator.Error!void {
    const self: *Output = @ptrCast(@alignCast(listener));
    if (!self.is_focused) return;

    const arguments = try self.parseArgs(args);
    defer self.freeArgs(arguments);

    if (arguments.len < 1) return;

    const start_from_line = self.widget_ref.?.window.last_draw.top_line;
    self.searchStr(io, arguments[0], start_from_line) catch return;
}

fn handleFindNextCmd(io: Io, _: []const u8, listener: *anyopaque) std.mem.Allocator.Error!void {
    const self: *Output = @ptrCast(@alignCast(listener));
    if (!self.is_focused) return;
    self.searchNext(io);
}

fn handleFindPrevCmd(io: Io, _: []const u8, listener: *anyopaque) std.mem.Allocator.Error!void {
    const self: *Output = @ptrCast(@alignCast(listener));
    if (!self.is_focused) return;
    self.searchPrev(io);
}

fn handleJumpCmd(_: Io, arg: []const u8, listener: *anyopaque) std.mem.Allocator.Error!void {
    const self: *Output = @ptrCast(@alignCast(listener));
    if (!self.is_focused) return;

    const line_num: usize = std.fmt.parseInt(usize, arg, 10) catch return;
    self.jumpToLine(line_num);
}

fn handleInfoCmd(_: Io, _: []const u8, listener: *anyopaque) std.mem.Allocator.Error!void {
    const self: *Output = @ptrCast(@alignCast(listener));
    if (!self.is_focused) return;

    self.debuginfo();
}

fn handleUncolorCmd(_: Io, _: []const u8, listener: *anyopaque) std.mem.Allocator.Error!void {
    const self: *Output = @ptrCast(@alignCast(listener));
    if (!self.is_focused) return;
    self.store.post(.{ .remove_all_reviewers = .{ .id = self.bufferId() } }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.log.warn("could not remove reviewers: {t}", .{err}),
    };
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
    const named: ?vaxis.Color = blk: {
        if (std.mem.eql(u8, arg, "red")) break :blk Red;
        if (std.mem.eql(u8, arg, "green")) break :blk Green;
        if (std.mem.eql(u8, arg, "yellow")) break :blk Yellow;
        if (std.mem.eql(u8, arg, "blue")) break :blk Blue;
        if (std.mem.eql(u8, arg, "magenta")) break :blk Magenta;
        if (std.mem.eql(u8, arg, "cyan")) break :blk Cyan;
        if (std.mem.eql(u8, arg, "white")) break :blk White;
        if (std.mem.eql(u8, arg, "black")) break :blk Black;
        break :blk null;
    };

    const color: vaxis.Color = named orelse blk: {
        const parts = utils.parseTripleInt(arg) catch {
            // invalid RGB code
            return error.InvalidRGBFormat;
        };

        // check if each part is within range
        for (parts) |part| {
            if (part > 255) return error.InvalidRGBFormat;
        }

        break :blk .{ .rgb = .{
            @intCast(parts[0]),
            @intCast(parts[1]),
            @intCast(parts[2]),
        } };
    };

    return switch (ground) {
        .Bg => vaxis.Style{ .bg = color },
        .Fg => vaxis.Style{ .fg = color },
    };
}

const ArgStateMachine = enum {
    Empty,
    Fg,
    Bg,
};
fn createStyleFromArg(arg: []const u8) ?transforms.ColorPattern {
    // fg:color:bg:color:line

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
            } else if (std.mem.eql(u8, segment.?, "bg")) {
                if (parsedBg) {
                    // invalid arg, can't have bg twice
                    return null;
                } else {
                    parsedBg = true;
                    continue :state .Bg;
                }
            } else if (std.mem.eql(u8, segment.?, "line") and !is_current_seg_first) {
                color_line = true;
                continue :state .Empty;
            } else if (is_current_seg_first) {
                // if it is the first segment we accept a color and assume fg
                const style = parseColor(segment.?, .Fg) catch { // invalid args
                    return null;
                };
                if (result_style) |*s| {
                    s.fg = style.fg;
                } else {
                    result_style = style;
                }
                continue :state .Empty;
            } else {
                // unknown segment
                return null;
            }
        },
    }
    if (result_style) |res| {
        return transforms.ColorPattern{ .regex = undefined, .full_line = color_line, .style = res };
    } else return null;
}

/// Builds a color reviewer from (regex, style) pairs and installs it on the buffer.
fn installColorReviewer(self: *Output, pairs: []const [2][]const u8) std.mem.Allocator.Error!void {
    var reviewer = try Reviewer.init(self._alloc, transforms.color);
    errdefer reviewer.deinit();
    const owned = reviewer.ownedAllocator();

    var color_patterns = try std.ArrayList(transforms.ColorPattern).initCapacity(owned, pairs.len);
    for (pairs) |pair| {
        const re = Regex.compile(owned, pair[0]) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                std.log.warn("ignoring invalid regex \"{s}\": {t}", .{ pair[0], err });
                continue;
            },
        };
        var color_pattern = createStyleFromArg(pair[1]) orelse {
            std.log.warn("ignoring invalid style \"{s}\"", .{pair[1]});
            continue;
        };
        color_pattern.regex = re;
        try color_patterns.append(owned, color_pattern);
    }

    const reviewer_data = try owned.create(transforms.ColorReviewerData);
    reviewer_data.* = .{ .style_patterns = try color_patterns.toOwnedSlice(owned) };
    reviewer.data = reviewer_data;

    try self.reviewer_ids.append(self._alloc, reviewer.id);
    // ownership of `reviewer` transfers to the pump (post frees it on failure)
    self.store.post(.{ .add_reviewer = .{ .id = self.bufferId(), .reviewer = reviewer } }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.log.warn("could not install color rules: {t}", .{err}),
    };
}

pub fn setupViaUiconfig(
    self: *Output,
    config: *UiConfig,
    ui_name: []const u8,
) std.mem.Allocator.Error!void {
    var scratch_arena = std.heap.ArenaAllocator.init(self._alloc);
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

    // turn every rule into a (pattern, style-arg) pair
    var pairs = try std.ArrayList([2][]const u8).initCapacity(salloc, num_color_rules);
    for (applied_color_rules.items) |c_rule| {
        if (c_rule.background_color == null and c_rule.foreground_color == null) continue;
        if (c_rule.pattern == null) continue;

        var style_args = try std.ArrayList([]const u8).initCapacity(salloc, 5);
        if (c_rule.background_color) |bg_str| {
            try style_args.append(salloc, "bg");
            try style_args.append(salloc, bg_str);
        }
        if (c_rule.foreground_color) |fg_str| {
            try style_args.append(salloc, "fg");
            try style_args.append(salloc, fg_str);
        }
        if (!c_rule.just_pattern) {
            try style_args.append(salloc, "line");
        }
        const style_arg = try std.mem.join(salloc, ":", style_args.items);
        try pairs.append(salloc, .{ c_rule.pattern.?, style_arg });
    }

    try self.installColorReviewer(pairs.items);
}

fn handleShowLinesCmd(_: Io, args: []const u8, listener: *anyopaque) std.mem.Allocator.Error!void {
    const self: *Output = @ptrCast(@alignCast(listener));

    const arg_array = try self.parseArgs(args);
    defer self.freeArgs(arg_array);

    var b_all_flag = false;
    var requested: ?bool = null;
    for (arg_array) |arg| {
        if (std.mem.eql(u8, arg, "--all")) {
            b_all_flag = true;
        } else if (std.mem.eql(u8, arg, "on")) {
            requested = true;
        } else if (std.mem.eql(u8, arg, "off")) {
            requested = false;
        } else {
            // an invalid argument
            return;
        }
    }

    // Without --all only the focused output changes
    if (!b_all_flag and !self.is_focused) return;

    if (requested) |value| {
        self.show_lines = value;
    } else {
        self.show_lines = !self.show_lines;
    }
}

fn handleDumpCmd(_: Io, args: []const u8, listener: *anyopaque) std.mem.Allocator.Error!void {
    const self: *Output = @ptrCast(@alignCast(listener));

    var isAll = false;
    var isFiltered = false;

    const arg_array = try self.parseArgs(args);
    defer self.freeArgs(arg_array);
    for (arg_array) |arg| {
        if (std.mem.eql(u8, arg, "--all") or std.mem.eql(u8, arg, "-a")) {
            isAll = true;
        } else if (std.mem.eql(u8, arg, "--filtered") or std.mem.eql(u8, arg, "-f")) {
            isFiltered = true;
        }
    }

    if (!isAll and !self.is_focused) return;

    // the pump writes the file from its own copy of the buffer, so the UI never blocks on disk
    self.dump(if (isFiltered) .Filtered else .Raw, .async) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.log.warn("could not dump buffer: {t}", .{err}),
    };
}

/// Asks the pump to write this output's buffer to disk. `.sync` blocks until the file is
/// written (used when quitting).
pub fn dump(self: *Output, backing: ProcessBuffer.BufferBacking, mode: enum { async, sync }) IngestStore.PostError!void {
    const cmd: PumpCommand = .{ .dump = .{ .id = self.bufferId(), .backing = backing } };
    switch (mode) {
        .async => try self.store.post(cmd),
        .sync => try self.store.call(cmd),
    }
}

fn handleColorCmd(_: Io, args: []const u8, listener: *anyopaque) std.mem.Allocator.Error!void {
    const self: *Output = @ptrCast(@alignCast(listener));
    if (!self.is_focused) return;

    const arg_array = try self.parseArgs(args);
    defer self.freeArgs(arg_array);

    if (arg_array.len % 2 != 0) {
        // don't parse any arguments if the full line is invalid
        return;
    }

    // each pair comes in the form of `regex` `style`
    var pairs = try std.ArrayList([2][]const u8).initCapacity(self.arena.allocator(), arg_array.len / 2);
    defer pairs.deinit(self.arena.allocator());
    for (0..arg_array.len / 2) |i| {
        try pairs.append(self.arena.allocator(), .{ arg_array[i * 2], arg_array[i * 2 + 1] });
    }

    try self.installColorReviewer(pairs.items);
}

// ------------------------------------------------------------------
// Search
// ------------------------------------------------------------------

pub fn removeSearch(self: *Output, io: Io) !void {
    _ = io;
    if (self.search_state) |*s| {
        s.searcher.deinit();
        self.search_state = null;
    }
}

/// Starts a new search from `start_search_line`, wrapping around to the top of the buffer
/// if nothing is found below.
pub fn searchStr(self: *Output, io: Io, search_str: []const u8, start_search_line: usize) !void {
    try self.removeSearch(io);

    var state: SearchState = .{ .searcher = try search.Searcher.init(self._alloc, search_str) };
    errdefer state.searcher.deinit();

    _ = try state.searcher.refresh(self.nonowned_process_buffer);
    state.searcher.seekLine(start_search_line);
    var match = try state.searcher.next();
    if (match == null and start_search_line > 0) {
        state.searcher.seekLine(0);
        match = try state.searcher.next();
    }

    if (match) |m| {
        state.current = m;
        self.search_state = state;
        self.jumpToLine(m.line);
    } else {
        // nothing found: keep no state, so `next` does nothing until a new `find`
        state.searcher.deinit();
    }
}

fn searchStep(self: *Output, comptime direction: enum { forward, backward }) void {
    const state = &(self.search_state orelse return);
    const refreshed = state.searcher.refresh(self.nonowned_process_buffer) catch return;
    if (refreshed == .rebuilt) state.current = null;

    const found = switch (direction) {
        .forward => state.searcher.next(),
        .backward => state.searcher.prev(),
    } catch return;

    if (found) |m| {
        state.current = m;
        self.jumpToLine(m.line);
    } else {
        // ran off the end: step back onto the last match so the next press in the other
        // direction continues from there
        _ = switch (direction) {
            .forward => state.searcher.prev(),
            .backward => state.searcher.next(),
        } catch return;
    }
}

pub fn searchNext(self: *Output, io: Io) void {
    _ = io;
    self.searchStep(.forward);
}

pub fn searchPrev(self: *Output, io: Io) void {
    _ = io;
    self.searchStep(.backward);
}

/// Returns the window-relative range to highlight for the current search match, if any.
/// Nothing is highlighted when the match belongs to an older buffer version.
pub fn searchHighlight(self: *Output, snap: *const WindowSnapshot) ?Highlight {
    const state = &(self.search_state orelse return null);
    const m = state.current orelse return null;
    const version = state.searcher.index.version orelse return null;
    if (version != snap.meta.version) return null;

    const window_end = snap.base_offset + snap.text.len;
    if (m.hi <= snap.base_offset or m.lo >= window_end) return null;

    return .{
        .start = @max(m.lo, snap.base_offset) - snap.base_offset,
        .end = @min(m.hi, window_end) - snap.base_offset,
        .style = state.highlight_style,
    };
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
        &ShowLinesHandlerData,
        &DumpBufferHandlerData,
    };

    inline for (handler_data) |data| {
        const handler: Handler = .{
            .event_str = data.event_str,
            .arg_description = data.arg_description,
            .handle = .{ .regular_fn = data.handle },
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

const testing = std.testing;
const pump_mod = @import("pump");

/// A running pump feeding a store: the Output handlers post commands into it.
const Harness = struct {
    store: *IngestStore,
    pump: *pump_mod.Pump,
    pb: *ProcessBuffer,
    id: utils.uuid.UUID,

    fn init(alloc: std.mem.Allocator, io: Io, name: []const u8) !Harness {
        const store = try IngestStore.init(alloc, io);
        errdefer store.deinit();
        const pump = try pump_mod.Pump.init(alloc, io, store.sink(), .{});
        errdefer pump.deinit();
        store.attach(pump);
        try pump.start();

        const id = try store.createBufferAsync(name);
        var h: Harness = .{ .store = store, .pump = pump, .pb = undefined, .id = id };
        h.sync();
        h.pb = store.lookup(id).?;
        return h;
    }

    /// Blocks until everything posted so far has been processed (FIFO barrier).
    fn sync(self: *Harness) void {
        self.store.call(.{ .remove_all_filters = .{ .id = .{ .bytes = [_]u8{0xff} ** 16 } } }) catch unreachable;
    }

    fn write(self: *Harness, text: []const u8) void {
        self.store.writeText(self.id, text) catch unreachable;
        self.sync();
    }

    fn filtered(self: *Harness, alloc: std.mem.Allocator) ![]u8 {
        self.sync();
        return self.pb.copyBuffer(alloc, .Filtered);
    }

    fn deinit(self: *Harness) void {
        self.pump.stop();
        self.pump.deinit();
        self.store.deinit();
    }
};

test "folding text" {
    const alloc = testing.allocator;
    const io = testing.io;

    var h = try Harness.init(alloc, io, "t");
    defer h.deinit();
    var output = try Output.init(alloc, h.pb, h.store);
    defer {
        output.deinit(io);
        h.sync();
    }

    h.write(
        \\line 1: apples
        \\line 2: carrots
        \\line 3: carrots
        \\line 4: apples
        \\line 5: carrots
        \\line 6: apples
        \\line 7: carrots
        \\
    );

    // set focus to make sure the command works
    output.is_focused = true;

    try Output.handleFoldCmd(io, "apples", &output);
    const buffer = try h.filtered(alloc);
    defer alloc.free(buffer);
    try testing.expectEqualStrings(
        \\line 1: apples
        \\line 4: apples
        \\line 6: apples
        \\
    , buffer);

    // Add another line to be filtered
    h.write("line 8: carrots\n");
    const buffer2 = try h.filtered(alloc);
    defer alloc.free(buffer2);
    try testing.expectEqualStrings(
        \\line 1: apples
        \\line 4: apples
        \\line 6: apples
        \\
    , buffer2);

    // Add another line which should be included
    h.write("line 9: apples\n");
    const buffer3 = try h.filtered(alloc);
    defer alloc.free(buffer3);
    try testing.expectEqualStrings(
        \\line 1: apples
        \\line 4: apples
        \\line 6: apples
        \\line 9: apples
        \\
    , buffer3);

    // removing the filter restores everything
    try Output.handleUnfoldCmd(io, "", &output);
    const buffer4 = try h.filtered(alloc);
    defer alloc.free(buffer4);
    try testing.expectEqual(9, std.mem.count(u8, buffer4, "\n"));
}

test "coloring text produces absolute style ranges" {
    const alloc = testing.allocator;
    const io = testing.io;

    var h = try Harness.init(alloc, io, "t");
    defer h.deinit();
    var output = try Output.init(alloc, h.pb, h.store);
    defer {
        output.deinit(io);
        h.sync();
    }
    output.is_focused = true;

    // two batches, including an empty line and a CRLF line, to check offsets don't drift
    h.write("x apples\n\napples\n");
    try Output.handleColorCmd(io, "apples red", &output);
    h.write("apples\r\n");

    // the buffer is quiescent after sync(); read the pump-owned index directly
    const ranges = h.pb.styles.ranges.items;
    try testing.expectEqual(3, ranges.len);
    try testing.expectEqual(2, ranges[0].start);
    try testing.expectEqual(8, ranges[0].end);
    try testing.expectEqual(10, ranges[1].start);
    try testing.expectEqual(16, ranges[1].end);
    try testing.expectEqual(17, ranges[2].start);
    try testing.expectEqual(23, ranges[2].end);
    try testing.expectEqual(vaxis.Style{ .fg = Red }, h.pb.styles.palette.items[ranges[0].style]);

    // a full-line rule paints the whole line
    try Output.handleColorCmd(io, "^x fg:blue:line", &output);
    h.sync();
    const ranges2 = h.pb.styles.ranges.items;
    try testing.expectEqual(0, ranges2[0].start);
    try testing.expectEqual(8, ranges2[0].end);

    // uncolor keeps the filtered text but drops the styles, without bumping version
    const before = h.pb.peek();
    try Output.handleUncolorCmd(io, "", &output);
    h.sync();
    try testing.expectEqual(0, h.pb.styles.ranges.items.len);
    try testing.expectEqual(before.version, h.pb.peek().version);
}

test "parse style args" {
    const p1 = createStyleFromArg("red").?;
    try testing.expectEqual(vaxis.Style{ .fg = Red }, p1.style);
    try testing.expect(!p1.full_line);

    const p2 = createStyleFromArg("fg:red:bg:blue:line").?;
    try testing.expectEqual(vaxis.Style{ .fg = Red, .bg = Blue }, p2.style);
    try testing.expect(p2.full_line);

    const p3 = createStyleFromArg("bg:1,2,3").?;
    try testing.expectEqual(vaxis.Style{ .bg = .{ .rgb = .{ 1, 2, 3 } } }, p3.style);

    try testing.expectEqual(null, createStyleFromArg("fg:red:fg:blue"));
    try testing.expectEqual(null, createStyleFromArg("notacolor"));
}
