const std = @import("std");
pub const vaxis = @import("vaxis");
//pub const mutiStyleText = @import("tui/multistyletext.zig");
pub const output_view_mod = @import("outputview.zig");

pub const vxfw = vaxis.vxfw;
pub const OutputView = output_view_mod.OutputView;
pub const Output = output_view_mod.Output;

pub const OutputViewList = std.ArrayList(OutputViewTuple);

const Direction = enum {
    left,
    right,
};

const OutputViewTuple = struct {
    outputview: *OutputView,
    flexitex: vxfw.FlexItem,
};

pub const View = struct {
    alloc: std.mem.Allocator,
    outputviews: OutputViewList,
    flexcol: vxfw.FlexColumn,

    pub fn init(alloc: std.mem.Allocator) std.mem.Allocator.Error!*View {
        const v = try alloc.create(View);
        v.* = .{
            .alloc = alloc,
            .outputviews = OutputViewList.init(alloc),
            .flexcol = .{ .children = &[_]vxfw.FlexItem{} },
        };
        return v;
    }

    pub fn deinit(self: *View) void {
        // free any outputviews this view contains
        for (self.outputviews.items) |t| {
            t.outputview.deinit();
            self.alloc.destroy(t.flexitex);
        }
        self.outputviews.deinit();
        self.alloc.destroy(self);
    }

    pub fn add_outputview(self: *View, outputview: *OutputView, pos: usize) std.mem.Allocator.Error!void {
        const flexitem = try self.alloc.create(vxfw.FlexItem);
        flexitem.* = .{
            .widget = outputview.widget(),
        };
        try self.outputviews.insert(pos, .{ .outputview = outputview, .flexitex = flexitem });
    }

    pub fn remove_outputview(self: *View, pos: usize) OutputView {
        const tuple = self.outputviews.orderedRemove(pos);
        self.alloc.destroy(tuple.flexitex);
        return tuple.outputview;
    }

    pub fn split_output(self: *View, output: *Output, from_pos: usize, dir: Direction) !void {
        if (from_pos >= self.outputviews.items.len) {
            // TODO: raise error
            return;
        }

        // check that the output is actually from the correct group
        var target_output: ?*Output = null;
        for (self.outputviews.items[from_pos].outputview.outputs.items) |o| {
            if (output == o) {
                target_output = o;
            }
        }
        if (target_output == null) {
            // TODO: raise error
            return;
        }

        const new_outputview = try OutputView.init(self.alloc);
        const from_outputview = self.outputviews.items[from_pos].outputview;

        switch (dir) {
            .left => {
                self.add_outputview(new_outputview, from_pos);
            },
            .right => {
                self.add_outputview(new_outputview, from_pos + 1);
            },
        }

        try new_outputview.add_output(output);
        from_outputview.remove_output(output);
    }

    pub fn move_output(self: *View, output: *Output, from_pos: usize, to_pos: usize) !void {
        if (from_pos >= self.outputviews.items.len or to_pos >= self.outputviews.items.len) {
            // TODO: raise error
            return;
        }

        // check that the output is actually from the correct group
        var target_output: ?*Output = null;
        for (self.outputviews.items[from_pos].outputview.outputs.items) |o| {
            if (output == o) {
                target_output = o;
            }
        }
        if (target_output == null) {
            // TODO: raise error
            return;
        }

        // add, remove, set focus
        try self.outputviews.items[to_pos].outputview.add_output(target_output.?);
        self.outputviews.items[from_pos].outputview.remove_output(target_output.?);
        try self.outputviews.items[to_pos].outputview.focus_output(target_output.?);
    }

    pub fn widget(self: *View) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = View.typeErasedEventHandler,
            .drawFn = View.typeErasedDrawFn,
        };
    }

    pub fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        var self: *View = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    pub fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        var self: *View = @ptrCast(@alignCast(ptr));
        return self.eventHandler(ctx, event);
    }

    pub fn eventHandler(self: *View, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        _ = self;
        _ = ctx;
        _ = event;
    }

    pub fn draw(self: *View, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const max_size = ctx.max.size();

        // TODO: I should split outputview and flexitem into two arrays
        // so that I can get the children

        const outputview_child: vxfw.SubSurface = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try self.flexcol.draw(ctx),
        };
        const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = outputview_child;

        return try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), max_size, children);
    }
};
