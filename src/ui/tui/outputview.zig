const std = @import("std");
const Io = std.Io;
pub const vaxis = @import("vaxis");
//pub const mutiStyleText = @import("tui/multistyletext.zig");
pub const outputmod = @import("outputwidget.zig");
pub const OutputWidget = outputmod.OutputWidget;
pub const ProcessBuffer = outputmod.ProcessBuffer;

pub const vxfw = vaxis.vxfw;
pub const OutputList = std.ArrayList(*OutputWidget);

pub const OutputView = struct {
    alloc: std.mem.Allocator,
    outputs: OutputList,
    /// Outputs in the order they were last shown, most recent last. When the displayed
    /// output leaves the column, the previous entry takes its place. Never longer than
    /// `outputs`, and `add_output` reserves that much, so `touch` cannot fail.
    history: OutputList = .empty,
    focused_ow: ?*OutputWidget = null,
    is_focused: bool = false,

    // TODO: create a tab group

    // add process
    // remove process
    // get process
    // switch group focus(self, processname)

    // view -> outputview -> {tab-group (widgets), list(output)}
    // outputview renders -> tab-group and 1 output

    pub fn init(alloc: std.mem.Allocator) std.mem.Allocator.Error!*OutputView {
        const p = try alloc.create(OutputView);
        errdefer alloc.destroy(p);
        p.* = .{
            .alloc = alloc,
            .outputs = try OutputList.initCapacity(alloc, 1),
        };
        return p;
    }

    pub fn deinit(self: *OutputView, io: Io) void {
        // free any outputs that this outputview owns
        for (self.outputs.items) |o| {
            o.deinit(io);
        }
        self.outputs.deinit(self.alloc);
        self.history.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    pub fn add_output(self: *OutputView, output: *OutputWidget) std.mem.Allocator.Error!void {
        // TODO: create a tab for the corresponding output
        try self.outputs.append(self.alloc, output);
        try self.history.ensureTotalCapacity(self.alloc, self.outputs.items.len);

        if (self.outputs.items.len == 1) {
            self.focused_ow = output;
            self.focused_ow.?.output.is_focused = self.is_focused;
            self.touch(output);
        }
    }

    pub fn remove_output(self: *OutputView, output: *OutputWidget) void {
        // TODO: remove the tab for the corresponding output
        const idx = self.indexOf(output) orelse return;
        output.output.is_focused = false;
        // ordered: Tab keeps cycling the remaining outputs in the same order
        _ = self.outputs.orderedRemove(idx);
        self.forget(output);

        if (output != self.focused_ow) return;
        if (self.outputs.items.len == 0) {
            self.focused_ow = null;
            return;
        }
        // back to what this column showed before `output`
        self.focused_ow = self.history.getLastOrNull() orelse self.outputs.items[0];
        self.focused_ow.?.output.is_focused = self.is_focused;
    }

    fn indexOf(self: *const OutputView, output: *OutputWidget) ?usize {
        for (self.outputs.items, 0..) |o, i| {
            if (o == output) return i;
        }
        return null;
    }

    /// Marks `output` as the most recently shown output of this column.
    fn touch(self: *OutputView, output: *OutputWidget) void {
        self.forget(output);
        self.history.appendAssumeCapacity(output);
    }

    fn forget(self: *OutputView, output: *OutputWidget) void {
        for (self.history.items, 0..) |o, i| {
            if (o == output) {
                _ = self.history.orderedRemove(i);
                return;
            }
        }
    }

    pub fn get_output(self: *OutputView, processname: []const u8) ?*OutputWidget {
        for (self.outputs.items) |o| {
            if (std.mem.eql(u8, processname, o.process_name)) {
                return o;
            }
        }
        return null;
    }

    pub fn focus_output(self: *OutputView, output: *OutputWidget) void {
        for (self.outputs.items) |o| {
            if (o == output) {
                // unfocus the previous output
                if (self.focused_ow) |fo| {
                    fo.output.is_focused = false;
                }

                self.focused_ow = o;

                // if the current outputview is focused we want to render
                // the output as focused
                self.focused_ow.?.output.is_focused = self.is_focused;
                self.touch(o);
            }
        }
    }

    const Direction = enum {
        forward,
        backward,
    };

    pub fn focus_self(self: *OutputView) void {
        self.is_focused = true;
        if (self.focused_ow) |o| {
            o.output.is_focused = true;
        }
    }

    pub fn unfocus_self(self: *OutputView) void {
        self.is_focused = false;
        if (self.focused_ow) |o| {
            o.output.is_focused = false;
        }
    }

    fn focus_move(
        self: *OutputView,
        dir: Direction,
    ) ?*OutputWidget {
        if (self.outputs.items.len == 0) {
            return null;
        } else if (self.focused_ow == null) {
            self.focused_ow = self.outputs.items[0];
            self.focused_ow.?.output.is_focused = self.is_focused;
            self.touch(self.focused_ow.?);
            return self.focused_ow;
        }

        // find the current idx
        var idx = blk: {
            for (self.outputs.items, 0..) |o, i| {
                if (o == self.focused_ow.?) {
                    break :blk i;
                }
            }
            unreachable;
        };

        self.focused_ow.?.output.is_focused = false;

        switch (dir) {
            .forward => {
                if (idx == self.outputs.items.len - 1) {
                    idx = 0;
                } else {
                    idx += 1;
                }
            },
            .backward => {
                if (idx == 0) {
                    idx = self.outputs.items.len - 1;
                } else {
                    idx -= 1;
                }
            },
        }

        self.focused_ow = self.outputs.items[idx];
        self.focused_ow.?.output.is_focused = self.is_focused;
        self.touch(self.focused_ow.?);
        return self.focused_ow;
    }

    pub fn focus_prev(self: *OutputView) ?*OutputWidget {
        return self.focus_move(Direction.backward);
    }

    pub fn focus_next(self: *OutputView) ?*OutputWidget {
        return self.focus_move(Direction.forward);
    }

    pub fn widget(self: *OutputView) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = OutputView.typeErasedEventHandler,
            .drawFn = OutputView.typeErasedDrawFn,
        };
    }

    pub fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        var self: *OutputView = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    pub fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        var self: *OutputView = @ptrCast(@alignCast(ptr));
        return self.eventHandler(ctx, event);
    }

    pub fn eventHandler(self: *OutputView, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        //std.debug.print("** OutputView event handler called\n", .{});

        switch (event) {
            .init => {
                try ctx.requestFocus(self.widget());
                return;
            },
            .key_press => {},
            .focus_in => {
                //std.debug.print("FOCUS?????outputview\n", .{});
            },
            .mouse_enter => {
                //std.debug.print("mouse enter outputview\n", .{});
            },
            .mouse_leave => {
                //std.debug.print("mouse leave outputview\n", .{});
            },
            .mouse => |mouse| {
                _ = mouse;
                //std.debug.print("outputview: mouse type {?}\n", .{mouse.type});
            },
            else => {},
        }
    }

    pub fn draw(self: *OutputView, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const max_size = ctx.max;

        var height: u16 = undefined;
        var width: u16 = undefined;
        if (max_size.height) |h| {
            //height = if (h < 20) h else 50;
            height = h;
        } else {
            height = 50;
        }
        if (max_size.width) |w| {
            //width = if (w < 100) w else 100;
            width = w;
        } else {
            width = 100;
        }

        const self_ctx = ctx.withConstraints(
            .{},
            .{ .width = width, .height = height },
        );

        // TODO: draw tab group

        var output_child: vxfw.SubSurface = undefined;
        var children: []vxfw.SubSurface = undefined;
        if (self.focused_ow) |focused| {
            output_child = .{
                .origin = .{ .row = 0, .col = 0 },
                .surface = try focused.draw(self_ctx),
            };
            children = try ctx.arena.alloc(vxfw.SubSurface, 1);
            children[0] = output_child;
        } else {
            children = &.{};
        }

        return .{
            .size = .{ .height = height, .width = width },
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }
};
