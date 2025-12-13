const std = @import("std");
pub const vaxis = @import("vaxis");
pub const output_view_mod = @import("outputview.zig");

pub const vxfw = vaxis.vxfw;
pub const OutputView = output_view_mod.OutputView;
pub const OutputWidget = output_view_mod.OutputWidget;

pub const OutputViewList = std.ArrayList(*OutputView);
pub const FlexItemList = std.ArrayList(vxfw.FlexItem);

pub const Direction = enum {
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
    flexitems: FlexItemList,
    flexrow: vxfw.FlexRow,
    //focused_outputview_pos: usize = 0,
    focused_outputview: ?*OutputView = null,

    pub const ViewErrors = error{
        InvalidArg,
        OutputNotFound,
    };

    pub fn init(alloc: std.mem.Allocator) std.mem.Allocator.Error!*View {
        const v = try alloc.create(View);
        v.* = .{
            .alloc = alloc,
            .outputviews = try OutputViewList.initCapacity(alloc, 1),
            .flexitems = try FlexItemList.initCapacity(alloc, 1),
            .flexrow = .{ .children = &[_]vxfw.FlexItem{} },
        };
        return v;
    }

    pub fn deinit(self: *View) void {
        // free any outputviews this view contains
        for (self.outputviews.items) |t| {
            t.deinit();
        }
        self.outputviews.deinit(self.alloc);
        self.flexitems.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    pub fn focus_outputview_by_idx(self: *View, pos: usize) !void {
        if (pos >= self.outputviews.items.len) {
            //std.debug.print("view.move_output: from_pos {d}\n", .{pos});
            return ViewErrors.InvalidArg;
        }

        // unfocus previous focused_outputview if it exists
        if (self.focused_outputview) |f_ov| {
            f_ov.unfocus_self();
        }

        self.focused_outputview = self.outputviews.items[pos];
        self.focused_outputview.?.focus_self();
    }

    fn focus_move(
        self: *View,
        dir: Direction,
    ) ?*OutputView {
        if (self.outputviews.items.len == 0) {
            return null;
        } else if (self.focused_outputview == null) {
            self.focused_outputview = self.outputviews.items[0];
            self.focused_outputview.?.focus_self();
            return self.focused_outputview;
        }

        // find the curent idx
        var idx = blk: {
            for (self.outputviews.items, 0..) |o, i| {
                if (o == self.focused_outputview.?) {
                    break :blk i;
                }
            }
            unreachable;
        };

        switch (dir) {
            .right => {
                if (idx == self.outputviews.items.len - 1) {
                    idx = 0;
                } else {
                    idx += 1;
                }
            },
            .left => {
                if (idx == 0) {
                    idx = self.outputviews.items.len - 1;
                } else {
                    idx -= 1;
                }
            },
        }

        self.focus_outputview_by_idx(idx) catch {
            unreachable;
        };
        return self.focused_outputview;
    }

    pub fn focus_prev(self: *View) ?*OutputView {
        return self.focus_move(Direction.left);
    }

    pub fn focus_next(self: *View) ?*OutputView {
        return self.focus_move(Direction.right);
    }

    pub fn get_focused(self: *View) ?*OutputView {
        return self.focused_outputview;
    }

    pub fn get_focused_output_widget(self: *View) ?*OutputWidget {
        if (self.focused_outputview) |ov| {
            if (ov.focused_ow) |o| return o else return null;
        }
        return null;
    }

    pub fn get_position(self: *View, outputview: *OutputView) !usize {
        for (self.outputviews.items, 0..) |o, i| {
            if (outputview == o) {
                return i;
            }
        }

        return ViewErrors.OutputNotFound;
    }

    pub fn add_outputview(self: *View, outputview: *OutputView, pos: usize) !void {
        try self.outputviews.insert(self.alloc, pos, outputview);
        try self.flexitems.insert(self.alloc, pos, .{ .widget = outputview.widget() });

        //std.debug.print("view: add_outputview -> {d}\n", .{self.outputviews.items.len});
        if (self.outputviews.items.len == 1) {
            try self.focus_outputview_by_idx(0);
        }
    }

    pub fn remove_outputview(self: *View, pos: usize) *OutputView {
        std.debug.assert(pos < self.outputviews.items.len);

        _ = self.flexitems.orderedRemove(pos);
        const outputview = self.outputviews.orderedRemove(pos);
        if (outputview == self.focused_outputview) {
            self.focused_outputview = null;
        }
        return outputview;
    }

    pub fn split_output(self: *View, output: *OutputWidget, from_pos: usize, dir: Direction) !void {
        if (from_pos >= self.outputviews.items.len) {
            //std.debug.print("view.split_output: from_pos {d} items.len {d}\n", .{ from_pos, self.outputviews.items.len });
            return ViewErrors.InvalidArg;
        }

        const from_outputview = self.outputviews.items[from_pos];

        // check that the output is actually from the correct group
        var target_output: ?*OutputWidget = null;
        for (from_outputview.outputs.items) |o| {
            if (output == o) {
                target_output = o;
            }
        }
        if (target_output == null) {
            return ViewErrors.OutputNotFound;
        }

        // don't split if the from outputview has only 1 group
        if (from_outputview.outputs.items.len == 1) {
            return;
        }

        const new_outputview = try OutputView.init(self.alloc);
        var to_pos: usize = undefined;
        var new_from_pos: usize = undefined;
        switch (dir) {
            .left => {
                to_pos = from_pos;
                new_from_pos = from_pos +| 1;
            },
            .right => {
                to_pos = from_pos +| 1;
                new_from_pos = from_pos;
            },
        }

        try self.add_outputview(new_outputview, to_pos);
        try new_outputview.add_output(output);
        from_outputview.remove_output(output);

        // set focus to outputview output moved to
        try self.focus_outputview_by_idx(to_pos);

        // remove outputview moved from if it has no outputs
        if (self.outputviews.items[new_from_pos].outputs.items.len == 0) {
            var ov_to_del = self.remove_outputview(new_from_pos);
            ov_to_del.deinit();
        }
    }

    pub fn move_output(self: *View, output: *OutputWidget, from_pos: usize, to_pos: usize) !void {
        if (from_pos >= self.outputviews.items.len or to_pos >= self.outputviews.items.len) {
            //std.debug.print("view.move_output: from_pos {d} to_pos {d} items.len {d}\n", .{ from_pos, to_pos, self.outputviews.items.len });
            return ViewErrors.InvalidArg;
        }

        // check that the output is actually from the correct group
        var target_output: ?*OutputWidget = null;
        for (self.outputviews.items[from_pos].outputs.items) |o| {
            if (output == o) {
                target_output = o;
            }
        }
        if (target_output == null) {
            return ViewErrors.OutputNotFound;
        }

        // add, remove, set outputview focus
        try self.outputviews.items[to_pos].add_output(target_output.?);
        self.outputviews.items[from_pos].remove_output(target_output.?);
        self.outputviews.items[to_pos].focus_output(target_output.?);

        // set focus to outputview output moved to
        try self.focus_outputview_by_idx(to_pos);

        // remove outputview moved from if it has no outputs
        if (self.outputviews.items[from_pos].outputs.items.len == 0) {
            var ov_to_del = self.remove_outputview(from_pos);
            ov_to_del.deinit();
        }
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

        self.flexrow.children = self.flexitems.items;

        const outputview_child: vxfw.SubSurface = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try self.flexrow.draw(
                ctx.withConstraints(
                    ctx.min,
                    .{ .width = max_size.width -| 1, .height = max_size.height -| 1 },
                ),
            ),
        };
        const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = outputview_child;

        return try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), max_size, children);
    }
};
