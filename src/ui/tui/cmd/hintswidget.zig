const std = @import("std");
const vaxis = @import("vaxis");
const Cmd = @import("cmd.zig");
const CmdWidget = @import("cmdwidget.zig").CmdWidget;
const cmdevents = @import("cmdevents.zig");
const Hint = @import("cmdhints.zig").Hint;

const vxfw = vaxis.vxfw;

/// Style to draw the HintsWidget with
const base_style: vaxis.Style = .{};

const nonselected = vaxis.Style{ .bg = .default, .fg = .default };
const selected = vaxis.Style{ .bg = .{ .rgb = .{ 100, 100, 100 } }, .fg = .default };

pub const HintsWidget = struct {
    alloc: std.mem.Allocator,
    command_suggestions: []Hint,
    argument_suggestions: []Hint,
    history_suggestions: []Hint,

    pub fn init(alloc: std.mem.Allocator) !*HintsWidget {
        const self = try alloc.create(HintsWidget);
        self.* = .{
            .alloc = alloc,
            .command_suggestions = &.{},
            .argument_suggestions = &.{},
            .history_suggestions = &.{},
        };
        return self;
    }

    pub fn deinit(self: *HintsWidget) void {
        self.clearHints();
        self.alloc.destroy(self);
    }

    pub fn updateHints(self: *HintsWidget, hints: []const Hint) std.mem.Allocator.Error!void {
        self.clearHints();

        var cmdhint_array: std.ArrayList(Hint) = try .initCapacity(self.alloc, 0);
        var arghint_array: std.ArrayList(Hint) = try .initCapacity(self.alloc, 0);
        var historyhint_array: std.ArrayList(Hint) = try .initCapacity(self.alloc, 0);

        for (hints) |hint| switch (hint) {
            .command => try cmdhint_array.append(self.alloc, hint),
            .history => try historyhint_array.append(self.alloc, hint),
            .argument_desc => try arghint_array.append(self.alloc, hint),
        };

        self.command_suggestions = try cmdhint_array.toOwnedSlice(self.alloc);
        self.argument_suggestions = try arghint_array.toOwnedSlice(self.alloc);
        self.history_suggestions = try historyhint_array.toOwnedSlice(self.alloc);
    }

    fn clearHints(self: *HintsWidget) void {
        for (self.command_suggestions) |suggestion| {
            self.alloc.free(suggestion.command);
        }
        for (self.argument_suggestions) |suggestion| {
            self.alloc.free(suggestion.argument_desc);
        }
        for (self.history_suggestions) |suggestion| {
            self.alloc.free(suggestion.history);
        }
        self.alloc.free(self.command_suggestions);
        self.alloc.free(self.argument_suggestions);
        self.alloc.free(self.history_suggestions);
    }

    fn asCommandSlices(out: [][]const u8, hints: []const Hint) void {
        for (hints, 0..) |h, i| {
            out[i] = h.command;
        }
    }

    fn asArgumentDescSlices(out: [][]const u8, hints: []const Hint) void {
        for (hints, 0..) |h, i| {
            out[i] = h.argument_desc;
        }
    }

    fn makeHintString(self: HintsWidget, alloc: std.mem.Allocator) ![]const u8 {
        // For the first attempt, keep it simple
        // "hint_one  |  hint_two  |  hint_three"

        const sep = "  |  ";

        // 1) if any command suggestions, list up to 32
        if (self.command_suggestions.len > 0) {
            const max_cmd_hints = 32;
            var tmp_slices: [32][]const u8 = undefined;
            const cmds = tmp_slices[0..@min(max_cmd_hints, self.command_suggestions.len)];
            asCommandSlices(cmds, self.command_suggestions);
            return try std.mem.join(alloc, sep, cmds);
        }

        // 2) else, check if there are argument suggestions. If so print all descriptions
        if (self.argument_suggestions.len > 0) {
            const max_arg_hints = 32;
            var tmp_slices: [32][]const u8 = undefined;
            const args = tmp_slices[0..@min(max_arg_hints, self.argument_suggestions.len)];
            asArgumentDescSlices(args, self.argument_suggestions);
            return try std.mem.join(alloc, sep, args);
        }

        return "";
    }

    pub fn widget(self: *@This()) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = typeErasedEventHandler,
            .drawFn = typeErasedDrawFn,
        };
    }

    pub fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        var self: *@This() = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    pub fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return try self.eventHandler(ctx, event);
    }

    pub fn eventHandler(self: *@This(), ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        _ = self;
        _ = ctx;
        _ = event;
    }

    pub fn draw(self: *@This(), ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const max_size = ctx.max.size();

        // create the base surface
        var surface = try vxfw.Surface.init(
            ctx.arena,
            self.widget(),
            .{ .width = max_size.width, .height = 1 },
        );

        // Clear the row with the widget's base style
        @memset(surface.buffer, .{ .style = base_style });

        // Create the text widget
        const text: vxfw.Text = .{
            .overflow = .clip,
            .text_align = .center,
            .text = try self.makeHintString(ctx.arena),
        };

        // Alloc and attach the text widget
        const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = vxfw.SubSurface{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try text.draw(ctx.withConstraints(
                surface.size,
                .{ .width = surface.size.width, .height = surface.size.height },
            )),
        };
        surface.children = children;

        return surface;
    }
};
