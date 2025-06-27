const std = @import("std");
pub const vaxis = @import("vaxis");
//pub const mutiStyleText = @import("tui/multistyletext.zig");
pub const Output = @import("output.zig").Output;

pub const vxfw = vaxis.vxfw;
pub const OutputList = std.ArrayList(*Output);

pub const OutputView = struct {
    alloc: std.mem.Allocator,
    outputs: OutputList,
    focused_output: ?*Output = null,

    // TODO: create a tab group

    // init, deinint
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
            .outputs = OutputList.init(alloc),
        };
        return p;
    }

    pub fn deinit(self: *OutputView) void {
        // free any outputs that this outputview owns
        for (self.outputs.items) |o| {
            o.deinit();
        }
        self.outputs.deinit();
        self.alloc.destroy(self);
    }

    pub fn add_output(self: *OutputView, output: *Output) std.mem.Allocator.Error!void {
        // TODO: create a tab for the corresponding output
        try self.outputs.append(output);

        if (self.outputs.items.len == 1) {
            self.focused_output = output;
        }
    }

    pub fn remove_output(self: *OutputView, output: *Output) void {
        // TODO: remove the tab for the corresponding output
        for (self.outputs.items, 0..) |o, i| {
            if (o == output) {
                _ = self.outputs.swapRemove(i);

                if (o == self.focused_output and self.outputs.items.len > 0) {
                    self.focused_output = self.outputs.items[0];
                } else if (self.outputs.items.len == 0) {
                    self.focused_output = null;
                }
            }
        }
    }

    pub fn get_output(self: *OutputView, processname: []const u8) ?*Output {
        for (self.outputs.items) |o| {
            if (std.mem.eql(u8, processname, o.process_name)) {
                return o;
            }
        }
        return null;
    }

    pub fn focus_output(self: *OutputView, output: *Output) void {
        for (self.outputs.items) |o| {
            if (o == output) {
                self.focused_output = o;
                // TODO set the correct tab to be focused
            }
        }
    }

    const Direction = enum {
        forward,
        backward,
    };

    fn focus_move(
        self: *OutputView,
        dir: Direction,
    ) void {
        if (self.outputs.items.len == 0) {
            return;
        } else if (self.focused_output == null) {
            self.focused_output = self.outputs.items[0];
        }

        // find the current idx
        var idx = blk: {
            for (self.outputs.items, 0..) |o, i| {
                if (o == self.focused_output.?) {
                    break :blk i;
                }
            }
            unreachable;
        };

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

        self.focused_output = self.outputs.items[idx];
    }

    pub fn focus_prev(self: *OutputView) void {
        self.focus_move(Direction.backward);
    }

    pub fn focus_next(self: *OutputView) void {
        self.focus_move(Direction.forward);
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
                try ctx.tick(16, self.widget());
                try ctx.requestFocus(self.widget());
                return;
            },
            .tick => {
                // reset tick
                try ctx.tick(16, self.widget());
                // can change this to if buffer has been changed
                ctx.redraw = true;
            },
            .key_press => {},
            .focus_in => {
                std.debug.print("FOCUS?????outputview\n", .{});
            },
            .mouse_enter => {
                std.debug.print("mouse enter outputview\n", .{});
            },
            .mouse_leave => {
                std.debug.print("mouse leave outputview\n", .{});
            },
            .mouse => |mouse| {
                std.debug.print("outputview: mouse type {?}\n", .{mouse.type});
            },
            else => {},
        }
    }

    pub fn draw(self: *OutputView, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const max_size = ctx.max.size();

        const height = if (max_size.height < 20) max_size.height else 20;
        const width = if (max_size.width < 100) max_size.height else 100;

        const self_ctx = ctx.withConstraints(
            .{},
            .{ .width = width, .height = height },
        );

        // TODO: draw tab group

        var output_child: vxfw.SubSurface = undefined;
        if (self.focused_output) |focused| {
            output_child = .{
                .origin = .{ .row = 0, .col = 0 },
                .surface = try focused.draw(self_ctx),
            };
        } else unreachable;

        const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = output_child;

        return .{
            .size = .{ .height = height, .width = width },
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }
};
