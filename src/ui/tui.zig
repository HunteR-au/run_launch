const std = @import("std");
const builtin = @import("builtin");
pub const vaxis = @import("vaxis");
pub const uiconfig = @import("uiconfig");
pub const view = @import("tui/view.zig");
pub const mutiStyleText = @import("tui/multistyletext.zig");
pub const cmdwidget = @import("tui/cmdwidget.zig");

pub const OutputView = view.OutputView;
pub const vxfw = vaxis.vxfw;
const Unicode = vaxis.Unicode;
const graphemedata = vaxis.grapheme.GraphemeData;
pub const OutputWidget = view.OutputWidget;
pub const ProcessBuffer = view.output_view_mod.ProcessBuffer;
/// Our main application state
// const Model = struct {
//     /// State of the counter
//     count: u32 = 0,
//     /// The button. This widget is stateful and must live between frames
//     button: vxfw.Button,

//     /// Helper function to return a vxfw.Widget struct
//     pub fn widget(self: *Model) vxfw.Widget {
//         return .{
//             .userdata = self,
//             .eventHandler = Model.typeErasedEventHandler,
//             .drawFn = Model.typeErasedDrawFn,
//         };
//     }

//     /// This function will be called from the vxfw runtime.
//     fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
//         const self: *Model = @ptrCast(@alignCast(ptr));
//         switch (event) {
//             // The root widget is always sent an init event as the first event. Users of the
//             // library can also send this event to other widgets they create if they need to do
//             // some initialization.
//             .init => return ctx.requestFocus(self.button.widget()),
//             .key_press => |key| {
//                 if (key.matches('c', .{ .ctrl = true })) {
//                     ctx.quit = true;
//                     return;
//                 }
//             },
//             // We can request a specific widget gets focus. In this case, we always want to focus
//             // our button. Having focus means that key events will be sent up the widget tree to
//             // the focused widget, and then bubble back down the tree to the root. Users can tell
//             // the runtime the event was handled and the capture or bubble phase will stop
//             .focus_in => return ctx.requestFocus(self.button.widget()),
//             else => {},
//         }
//     }

//     /// This function is called from the vxfw runtime. It will be called on a regular interval, and
//     /// only when any event handler has marked the redraw flag in EventContext as true. By
//     /// explicitly requiring setting the redraw flag, vxfw can prevent excessive redraws for events
//     /// which don't change state (ie mouse motion, unhandled key events, etc)
//     fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
//         const self: *Model = @ptrCast(@alignCast(ptr));
//         // The DrawContext is inspired from Flutter. Each widget will receive a minimum and maximum
//         // constraint. The minimum constraint will always be set, even if it is set to 0x0. The
//         // maximum constraint can have null width and/or height - meaning there is no constraint in
//         // that direction and the widget should take up as much space as it needs. By calling size()
//         // on the max, we assert that it has some constrained size. This is *always* the case for
//         // the root widget - the maximum size will always be the size of the terminal screen.
//         const max_size = ctx.max.size();

//         // The DrawContext also contains an arena allocator that can be used for each frame. The
//         // lifetime of this allocation is until the next time we draw a frame. This is useful for
//         // temporary allocations such as the one below: we have an integer we want to print as text.
//         // We can safely allocate this with the ctx arena since we only need it for this frame.
//         const count_text = try std.fmt.allocPrint(ctx.arena, "{d}", .{self.count});
//         const text: vxfw.Text = .{ .text = count_text };

//         // Each widget returns a Surface from its draw function. A Surface contains the rectangular
//         // area of the widget, as well as some information about the surface or widget: can we focus
//         // it? does it handle the mouse?
//         //
//         // It DOES NOT contain the location it should be within its parent. Only the parent can set
//         // this via a SubSurface. Here, we will return a Surface for the root widget (Model), which
//         // has two SubSurfaces: one for the text and one for the button. A SubSurface is a Surface
//         // with an offset and a z-index - the offset can be negative. This lets a parent draw a
//         // child and place it within itself
//         const text_child: vxfw.SubSurface = .{
//             .origin = .{ .row = 0, .col = 0 },
//             .surface = try text.draw(ctx),
//         };

//         const button_child: vxfw.SubSurface = .{
//             .origin = .{ .row = 2, .col = 0 },
//             .surface = try self.button.draw(ctx.withConstraints(
//                 ctx.min,
//                 // Here we explicitly set a new maximum size constraint for the Button. A Button will
//                 // expand to fill its area and must have some hard limit in the maximum constraint
//                 .{ .width = 16, .height = 3 },
//             )),
//         };

//         // We also can use our arena to allocate the slice for our SubSurfaces. This slice only
//         // needs to live until the next frame, making this safe.
//         const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
//         children[0] = text_child;
//         children[1] = button_child;

//         return .{
//             // A Surface must have a size. Our root widget is the size of the screen
//             .size = max_size,
//             .widget = self.widget(),
//             // We didn't actually need to draw anything for the root. In this case, we can set
//             // buffer to a zero length slice. If this slice is *not zero length*, the runtime will
//             // assert that its length is equal to the size.width * size.height.
//             .buffer = &.{},
//             .children = children,
//         };
//     }

//     /// The onClick callback for our button. This is also called if we press enter while the button
//     /// has focus
//     fn onClick(maybe_ptr: ?*anyopaque, ctx: *vxfw.EventContext) anyerror!void {
//         const ptr = maybe_ptr orelse return;
//         const self: *Model = @ptrCast(@alignCast(ptr));
//         self.count +|= 1;
//         return ctx.consumeAndRedraw();
//     }
// };

const ModelState = enum { main, cmdview, jsonview };

const Model = struct {
    modelview: *view.View,
    uiconfig: ?*uiconfig.UiConfig = null,
    output_view: *OutputView,
    process_buffers: std.StringHashMap(*ProcessBuffer),
    arena: std.heap.ArenaAllocator,
    cmd_view: cmdwidget.CmdWidget,
    mode: ModelState = .main,
    // views: vxfw.Surface,
    // views -> view-group -> tab-group && output-group

    /// Helper function to return a vxfw.Widget struct
    pub fn widget(self: *Model) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = Model.typeErasedEventHandler,
            .captureHandler = Model.typeErasedCaptureHandler,
            .drawFn = Model.typeErasedDrawFn,
        };
    }

    fn typeErasedCaptureHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Model = @ptrCast(@alignCast(ptr));
        return self.handleCapture(ctx, event);
    }

    pub fn handleCapture(self: *Model, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .key_press => |key| {
                if (key.matches('/', .{})) {
                    if (self.mode == .main) {
                        self.mode = .cmdview;
                        try ctx.requestFocus(self.cmd_view.widget());
                        return ctx.consumeAndRedraw();
                    }
                } else if (key.matches(vaxis.Key.escape, .{})) {
                    if (self.mode == .cmdview) {
                        std.debug.print("setting mode back to main\n", .{});
                        self.mode = .main;
                        try ctx.requestFocus(self.widget());
                        return ctx.consumeEvent();
                    }
                }
            },
            else => {},
        }
    }

    /// This function will be called from the vxfw runtime.
    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Model = @ptrCast(@alignCast(ptr));

        // For some reason tick doesn't seem to be triggered
        if (!keep_running.load(.seq_cst)) {
            ctx.quit = true;
            return;
        }

        switch (event) {
            .init => {
                switch (builtin.target.os.tag) {
                    .windows => {},
                    else => {
                        // This is a HACK since the framework doesn't detect capability correctly
                        // for Ubuntu via WSL
                        var colorterm = std.posix.getenv("COLORTERM") orelse "";

                        if (std.mem.eql(u8, colorterm, "truecolor") or
                            std.mem.eql(u8, colorterm, "24bit"))
                        {
                            app.vx.caps.rgb = true;
                        }

                        colorterm = std.posix.getenv("TERM") orelse "";

                        if (std.mem.eql(u8, colorterm, "xterm-256color") or
                            std.mem.eql(u8, colorterm, "screen"))
                        {
                            app.vx.sgr = .legacy;
                            app.vx.caps.rgb = true;
                        }
                    },
                }

                try self.output_view.eventHandler(ctx, event);
                try self.output_view.focused_output.?.handleEvent(ctx, event);
            },
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = false })) {
                    // This will current kill the tui but not kill the program...
                    ctx.quit = true;
                    return;
                } else if (key.matches('w', .{})) {
                    const output_view = self.modelview.get_focused();
                    if (output_view) |ov| {
                        const output = ov.focus_prev();
                        if (output) |o| {
                            try ctx.requestFocus(o.widget());
                            return ctx.consumeAndRedraw();
                        }
                    }
                    return;
                } else if (key.matches('w', .{ .shift = true })) {
                    _ = self.modelview.focus_prev();
                    return ctx.consumeAndRedraw();
                } else if (key.matches('e', .{ .shift = true })) {
                    _ = self.modelview.focus_next();
                    return ctx.consumeAndRedraw();
                } else if (key.matches('e', .{})) {
                    const output_view = self.modelview.get_focused();
                    if (output_view) |ov| {
                        const output = ov.focus_next();
                        if (output) |o| {
                            try ctx.requestFocus(o.widget());
                            return ctx.consumeAndRedraw();
                        }
                    }
                    return;
                } else if (key.matches('s', .{})) {
                    const output_view = self.modelview.get_focused();
                    if (output_view) |ov| {
                        const output = ov.focused_output;
                        if (output) |o| {
                            const from = try self.modelview.get_position(ov);
                            self.modelview.move_output(o, from, from -| 1) catch |err|
                                switch (err) {
                                    view.View.ViewErrors.InvalidArg => {
                                        return;
                                    },
                                    else => {
                                        return err;
                                    },
                                };
                            try ctx.requestFocus(o.widget());
                            return ctx.consumeAndRedraw();
                        }
                    }
                } else if (key.matches('s', .{ .shift = true })) {
                    const output_view = self.modelview.get_focused();
                    if (output_view) |ov| {
                        const output = ov.focused_output;
                        if (output) |o| {
                            const from = try self.modelview.get_position(ov);
                            try self.modelview.split_output(o, from, view.Direction.left);
                            try ctx.requestFocus(o.widget());
                            return ctx.consumeAndRedraw();
                        }
                    }
                } else if (key.matches('d', .{})) {
                    const output_view = self.modelview.get_focused();
                    if (output_view) |ov| {
                        const output = ov.focused_output;
                        if (output) |o| {
                            const from = try self.modelview.get_position(ov);
                            self.modelview.move_output(o, from, from +| 1) catch |err|
                                switch (err) {
                                    view.View.ViewErrors.InvalidArg => {
                                        return;
                                    },
                                    else => {
                                        return err;
                                    },
                                };
                            try ctx.requestFocus(o.widget());
                            return ctx.consumeAndRedraw();
                        }
                    }
                } else if (key.matches('d', .{ .shift = true })) {
                    const output_view = self.modelview.get_focused();
                    if (output_view) |ov| {
                        const output = ov.focused_output;
                        if (output) |o| {
                            const from = try self.modelview.get_position(ov);
                            try self.modelview.split_output(o, from, view.Direction.right);
                            try ctx.requestFocus(o.widget());
                            return ctx.consumeAndRedraw();
                        }
                    }
                } else if (key.matches('q', .{})) {
                    try ctx.addCmd(.queue_refresh);
                }
            },
            .mouse => |mouse| {
                std.debug.print("model: mouse type {?}\n", .{mouse.type});
                std.debug.print("mouse x {?}\n", .{mouse.col});
                std.debug.print("mouse y {?}\n", .{mouse.row});
            },
            .focus_in => {
                return ctx.requestFocus(self.widget());
            },
            else => {},
        }
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Model = @ptrCast(@alignCast(ptr));
        const max_size = ctx.max.size();

        //const child_ctx = ctx.withConstraints(ctx.min, .{
        //    .width = 150,
        //    .height = 100,
        //});

        var children: []vxfw.SubSurface = undefined;

        switch (self.mode) {
            .main => {
                children = try ctx.arena.alloc(vxfw.SubSurface, 1);
                const output_child: vxfw.SubSurface = .{
                    .origin = .{ .row = 1, .col = 1 },
                    .surface = try self.modelview.draw(ctx),
                };

                children[0] = output_child;
            },
            .cmdview => {
                children = try ctx.arena.alloc(vxfw.SubSurface, 2);
                const output_child: vxfw.SubSurface = .{
                    .origin = .{ .row = 1, .col = 1 },
                    .surface = try self.modelview.draw(ctx),
                };

                const cmdwidget_child: vxfw.SubSurface = .{
                    .origin = .{ .row = max_size.height - 3, .col = 0 },
                    .surface = try self.cmd_view.draw(ctx),
                };

                children[0] = output_child;
                children[1] = cmdwidget_child;
            },
            .jsonview => {},
        }

        //return try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), vxfw.Size{ .height = 50, .width = 10 }, children);

        return .{
            // A Surface must have a size. Our root widget is the size of the screen
            .size = max_size,
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }
};

var model: *Model = undefined;
var unicode: *Unicode = undefined;

var keep_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var thread: ?std.Thread = null;
var app: vxfw.App = undefined;
fn run_tui(alloc: std.mem.Allocator) !void {
    // parse the ui config
    var config = try uiconfig.parseConfigs(alloc);
    defer config.deinit();

    app = try vxfw.App.init(alloc);
    defer app.deinit();

    app.vx.refresh = true;
    unicode = &app.vx.unicode;

    const model_view = try view.View.init(alloc);
    defer model_view.deinit();

    const output_view = try OutputView.init(alloc);
    const output_view2 = try OutputView.init(alloc);
    try model_view.add_outputview(output_view, 0);
    try model_view.add_outputview(output_view2, 1);

    const buf = try ProcessBuffer.init(alloc);
    defer buf.deinit();
    const buf2 = try ProcessBuffer.init(alloc);
    defer buf2.deinit();

    try output_view.add_output(try OutputWidget.init(alloc, "default_output", buf, unicode));
    try output_view2.add_output(try OutputWidget.init(alloc, "default_output2", buf2, unicode));

    model = try alloc.create(Model);
    model.* = .{
        .output_view = output_view,
        .uiconfig = &config,
        .modelview = model_view,
        .process_buffers = std.StringHashMap(*ProcessBuffer).init(alloc),
        .cmd_view = try cmdwidget.CmdWidget.init(alloc, unicode),
        .arena = std.heap.ArenaAllocator.init(alloc),
    };
    defer alloc.destroy(model);
    keep_running.store(true, .seq_cst);

    try model.process_buffers.put("default_output", buf);
    try model.process_buffers.put("default_output2", buf);
    defer model.process_buffers.deinit();
    defer model.arena.deinit();

    //vxfw.DrawContext.init(unicode, .unicode);
    std.debug.print("color_scheme_updates : {?}\n", .{app.vx.caps.color_scheme_updates});
    std.debug.print("explicit_width : {?}\n", .{app.vx.caps.explicit_width});
    std.debug.print("kitty_graphics : {?}\n", .{app.vx.caps.kitty_graphics});
    std.debug.print("kitty_keyboard : {?}\n", .{app.vx.caps.kitty_keyboard});
    std.debug.print("rgb : {?}\n", .{app.vx.caps.rgb});
    std.debug.print("scaled_text : {?}\n", .{app.vx.caps.scaled_text});
    std.debug.print("sgr_pixels : {?}\n", .{app.vx.caps.sgr_pixels});

    std.debug.print("width: {d}\n", .{app.vx.screen.width});
    std.debug.print("height: {d}\n", .{app.vx.screen.height});

    //switch (builtin.target.os.tag) {
    //    .windows => {},
    //    else => {
    //        const colorterm = std.posix.getenv("COLORTERM") orelse "";
    //        if (std.mem.eql(u8, colorterm, "truecolor") or
    //            std.mem.eql(u8, colorterm, "24bit"))
    //        {
    //            if (@hasField(vxfw.Event, "cap_rgb")) {
    //                vaxis.Vaxis. .postEvent(.cap_rgb);
    //            }
    //        }
    //    },
    //}

    try app.vx.setMouseMode(app.tty.anyWriter(), true);
    try app.run(model.widget(), .{});
    keep_running.store(false, .seq_cst);
    std.debug.print("APP FINISHED!\n", .{});
}

pub fn start_tui(alloc: std.mem.Allocator) !void {
    thread = try std.Thread.spawn(.{ .allocator = alloc }, run_tui, .{alloc});

    // wait till the tui app has started
    var timer = try std.time.Timer.start();
    while (!keep_running.load(.seq_cst)) {
        if (timer.read() > 10_000_000_000) {
            return;
        }
    }
}

pub fn stop_tui() void {
    if (thread) |t| {
        keep_running.store(false, .seq_cst); // Signal the thread to stop
        t.join();
    }
}

pub fn createProcessView(alloc: std.mem.Allocator, processname: []const u8) std.mem.Allocator.Error!void {
    // FIX: terrible hack to avoid a race condition which actually hits on nix
    //std.time.sleep(10_000_000_000);
    std.debug.print("creating output: {s}\n", .{processname});
    if (keep_running.load(.seq_cst)) {
        const aa = model.arena.allocator();

        // check that a process with the same name doesn't exist
        const buf = try ProcessBuffer.init(alloc);
        try model.process_buffers.put(try aa.dupe(u8, processname), buf);
        errdefer {
            const keyvalue = model.process_buffers.fetchRemove(processname);
            if (keyvalue) |kv| {
                kv.value.deinit();
            }
        }

        const p_output = try OutputWidget.init(
            alloc,
            processname,
            buf,
            unicode,
        );
        errdefer p_output.deinit();

        if (model.uiconfig) |config| {
            try p_output.setupViaUiconfig(config);
        }

        // Add a reference to the cmd
        try p_output.output.subscribeHandlersToCmd(&model.cmd_view.cmd);
        try model.modelview.outputviews.items[0].add_output(p_output);

        app.vx.setMouseMode(app.tty.anyWriter(), true) catch {};
    }
}

pub fn killProcessView(processname: []const u8) void {
    _ = processname;
}

pub fn setUIConfig(alloc: std.mem.Allocator, jsonStr: []const u8) std.mem.Allocator.Error!void {
    _ = alloc;
    _ = jsonStr;
}

pub fn pushLogging(alloc: std.mem.Allocator, processname: []const u8, buffer: []const u8) std.mem.Allocator.Error!void {
    _ = alloc;

    if (keep_running.load(.seq_cst)) {
        const target_buffer = model.process_buffers.get(processname);

        if (target_buffer) |output| {
            try output.append(buffer);
        }
    }
}

// TODOs
// TODO add the uiconfig to the tui:module and enable output to interact with it
// TODO make sure output commands only take effect on selected output
// TODO Windows powershell has rendering errors...
// TODO color title for selected outputview
// TODO make tabs

// TODO find_replace str cmd
// TODO goto top/bottom of buffer
// TODO fast move up/down
// TODO parse ui config in TUI
// ---> options
// ------> when process starts, run color commands
// ------> when matching output starts, run setup function

// TODO BUG - bg colors match space before word
