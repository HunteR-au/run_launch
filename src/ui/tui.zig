const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils");
pub const vaxis = @import("vaxis");
pub const uiconfig = @import("uiconfig");
pub const view = @import("tui/view.zig");
pub const cmdwidget = @import("tui/cmd/cmdwidget.zig");
pub const Cmd = @import("tui/cmd/cmd.zig").Cmd;
pub const help = @import("tui/help/help.zig");
pub const runner = @import("runner");
pub const buffermgr = @import("tui/buffermanager.zig");
pub const processviewmgr = @import("tui/processviewmgr.zig");

const AppModel = @import("tui/AppModel.zig");

const cmdevents = @import("tui/cmd/cmdevents.zig");
const actions = @import("tui/actions/actions.zig");

pub const ConfiguredRunner = runner.ConfiguredRunner;
pub const OutputView = view.OutputView;
pub const vxfw = vaxis.vxfw;
const Unicode = vaxis.unicode;
const graphemedata = vaxis.grapheme.GraphemeData;
pub const OutputWidget = view.OutputWidget;
pub const ProcessBuffer = view.output_view_mod.ProcessBuffer;
pub const Handler = cmdwidget.Cmd.Handler;
pub const BufferMgr = buffermgr.BufferMgr;

const uuid = utils.uuid;

const ProcessBuffersMap = struct {
    m: std.Thread.Mutex,
    map: std.AutoHashMapUnmanaged(uuid.UUID, *ProcessBuffer),
};

const ModelState = enum { main, cmdview, jsonview };

pub const TUISignal = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    isClosing: bool = false,
};

const Key = struct {
    cp: u21,
    mod: vaxis.Key.Modifiers,
};

const TuiBindings = struct {
    pub const FocusCmdWindow = Key{ .cp = '/', .mod = .{} };
    pub const Escape = Key{ .cp = vaxis.Key.escape, .mod = .{} };
    pub const ShowHelp = Key{ .cp = vaxis.Key.f2, .mod = .{} };
    pub const FastQuit = Key{ .cp = 'c', .mod = .{ .ctrl = false } };
    pub const OutputViewPrev1 = Key{ .cp = 'w', .mod = .{ .shift = true } };
    pub const OutputViewPrev2 = Key{ .cp = vaxis.Key.tab, .mod = .{ .shift = true } };
    pub const OutputViewNext1 = Key{ .cp = 'e', .mod = .{ .shift = true } };
    pub const OutputViewNext2 = Key{ .cp = vaxis.Key.tab, .mod = .{} };
    pub const ViewPrev = Key{ .cp = 'w', .mod = .{ .shift = false } };
    pub const ViewNext = Key{ .cp = 'e', .mod = .{ .shift = false } };
    pub const MoveOutputViewLeft = Key{ .cp = 's', .mod = .{} };
    pub const MoveOutputViewRight = Key{ .cp = 'd', .mod = .{} };
    pub const SplitOutputViewLeft = Key{ .cp = 's', .mod = .{ .shift = true } };
    pub const SplitOutputViewRight = Key{ .cp = 'd', .mod = .{ .shift = true } };
};

const TuiApp = struct {
    app_model: AppModel,
    // modelview: *view.View,
    // uiconfig: ?*uiconfig.UiConfig = null,
    // process_buffers: ProcessBuffersMap,
    // buffers: *BufferMgr,
    // executor: *ConfiguredRunner,
    arena: std.heap.ArenaAllocator,
    _alloc: std.mem.Allocator,
    cmd_view: cmdwidget.CmdWidget,
    // cmd: *Cmd,
    handlers_ids: std.ArrayList(cmdwidget.Cmd.HandleId),
    help_id: ?uuid.UUID = null,
    mode: ModelState = .main,
    // views: vxfw.Surface,
    // views -> view-group -> tab-group && output-group

    /// Helper function to return a vxfw.Widget struct
    pub fn widget(self: *TuiApp) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = TuiApp.typeErasedEventHandler,
            .captureHandler = TuiApp.typeErasedCaptureHandler,
            .drawFn = TuiApp.typeErasedDrawFn,
        };
    }

    pub fn typeErasedCaptureHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *TuiApp = @ptrCast(@alignCast(ptr));
        return self.handleCapture(ctx, event);
    }

    fn show_help(self: *TuiApp, alloc: std.mem.Allocator) !void {
        const id = try createProcessView(alloc, "help");
        try pushLogging(alloc, id, help.getHelpString());
        self.help_id = id;
    }

    pub fn handleCapture(self: *TuiApp, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .key_press => |key| {
                if (key.matches(TuiBindings.FocusCmdWindow.cp, TuiBindings.FocusCmdWindow.mod)) {
                    if (self.mode == .main) {
                        self.mode = .cmdview;
                        try ctx.requestFocus(self.app_model.cmd.view.widget());
                        return ctx.consumeAndRedraw();
                    }
                } else if (key.matches(TuiBindings.Escape.cp, TuiBindings.Escape.mod)) {
                    if (self.mode == .cmdview) {
                        self.mode = .main;
                        if (self.app_model.model_view.get_focused_output_widget()) |ow| {
                            try ctx.requestFocus(ow.widget());
                        } else {
                            try ctx.requestFocus(self.widget());
                        }
                        return ctx.consumeEvent();
                    }
                } else if (key.matches(TuiBindings.ShowHelp.cp, TuiBindings.ShowHelp.mod)) {
                    if (self.mode == .main) {
                        const does_help_exist = self.help_id != null;

                        if (!does_help_exist) {
                            try self.show_help(self.arena.allocator());
                        }

                        // find the outputview that contain's help
                        for (self.app_model.model_view.outputviews.items) |ov| {
                            for (ov.outputs.items) |o| {
                                if (std.mem.eql(u8, o.process_name, "help")) {
                                    // focus the help's output widget
                                    ov.focus_output(o);
                                    try ctx.requestFocus(o.widget());
                                }
                            }
                        }
                        return ctx.consumeEvent();
                    }
                }
            },
            .focus_in => {
                if (self.mode == .cmdview) {
                    try ctx.requestFocus(self.app_model.cmd.view.widget());
                    //try ctx.requestFocus(self.cmd_view.widget());
                    return ctx.consumeEvent();
                } else if (self.mode == .main) {
                    if (self.app_model.model_view.get_focused_output_widget()) |ow| {
                        try ctx.requestFocus(ow.widget());
                    } else {
                        try ctx.requestFocus(self.widget());
                    }
                    return ctx.consumeEvent();
                }
            },
            else => {},
        }
    }

    /// This function will be called from the vxfw runtime.
    pub fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *TuiApp = @ptrCast(@alignCast(ptr));

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

                // if there output views in the model - focus
                if (self.app_model.model_view.outputviews.items.len != 0) {
                    const output_view = self.app_model.model_view.outputviews.items[0];
                    try self.app_model.model_view.focus_outputview_by_idx(0);
                    try output_view.eventHandler(ctx, event);
                }
            },
            .key_press => |key| {
                if (key.matches(TuiBindings.FastQuit.cp, TuiBindings.FastQuit.mod)) {
                    // This will current kill the tui but not kill the program...
                    ctx.quit = true;
                    return;
                } else if (key.matches(TuiBindings.OutputViewPrev1.cp, TuiBindings.OutputViewPrev1.mod) or
                    key.matches(TuiBindings.OutputViewPrev2.cp, TuiBindings.OutputViewPrev2.mod))
                {
                    const output_view = self.app_model.model_view.get_focused();
                    if (output_view) |ov| {
                        const output = ov.focus_prev();
                        if (output) |o| {
                            try ctx.requestFocus(o.widget());
                            return ctx.consumeAndRedraw();
                        }
                    }
                    return;
                } else if (key.matches(TuiBindings.ViewPrev.cp, TuiBindings.ViewPrev.mod)) {
                    if (self.app_model.model_view.focus_prev()) |ov| {
                        if (ov.focused_ow) |o| try ctx.requestFocus(o.widget());
                    }
                    return ctx.consumeAndRedraw();
                } else if (key.matches(TuiBindings.ViewNext.cp, TuiBindings.ViewNext.mod)) {
                    if (self.app_model.model_view.focus_next()) |ov| {
                        if (ov.focused_ow) |o| try ctx.requestFocus(o.widget());
                    }
                    return ctx.consumeAndRedraw();
                } else if (key.matches(
                    TuiBindings.OutputViewNext1.cp,
                    TuiBindings.OutputViewNext1.mod,
                ) or
                    key.matches(
                        TuiBindings.OutputViewNext2.cp,
                        TuiBindings.OutputViewNext2.mod,
                    ))
                {
                    // Only switch outputs in the main mode
                    if (self.mode == .main) {
                        const output_view = self.app_model.model_view.get_focused();
                        if (output_view) |ov| {
                            const output = ov.focus_next();
                            if (output) |o| {
                                try ctx.requestFocus(o.widget());
                                return ctx.consumeAndRedraw();
                            }
                        }
                        return;
                    }
                } else if (key.matches(
                    TuiBindings.MoveOutputViewLeft.cp,
                    TuiBindings.MoveOutputViewLeft.mod,
                )) {
                    const output_view = self.app_model.model_view.get_focused();
                    if (output_view) |ov| {
                        const output = ov.focused_ow;
                        if (output) |o| {
                            const from = try self.app_model.model_view.get_position(ov);
                            self.app_model.model_view.move_output(o, from, from -| 1) catch |err|
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
                } else if (key.matches(
                    TuiBindings.SplitOutputViewLeft.cp,
                    TuiBindings.SplitOutputViewLeft.mod,
                )) {
                    const output_view = self.app_model.model_view.get_focused();
                    if (output_view) |ov| {
                        const output = ov.focused_ow;
                        if (output) |o| {
                            const from = try self.app_model.model_view.get_position(ov);
                            try self.app_model.model_view.split_output(o, from, view.Direction.left);
                            try ctx.requestFocus(o.widget());
                            return ctx.consumeAndRedraw();
                        }
                    }
                } else if (key.matches(
                    TuiBindings.MoveOutputViewRight.cp,
                    TuiBindings.MoveOutputViewRight.mod,
                )) {
                    const output_view = self.app_model.model_view.get_focused();
                    if (output_view) |ov| {
                        const output = ov.focused_ow;
                        if (output) |o| {
                            const from = try self.app_model.model_view.get_position(ov);
                            self.app_model.model_view.move_output(o, from, from +| 1) catch |err|
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
                } else if (key.matches(TuiBindings.SplitOutputViewRight.cp, TuiBindings.SplitOutputViewRight.mod)) {
                    const output_view = self.app_model.model_view.get_focused();
                    if (output_view) |ov| {
                        const output = ov.focused_ow;
                        if (output) |o| {
                            const from = try self.app_model.model_view.get_position(ov);
                            try self.app_model.model_view.split_output(o, from, view.Direction.right);
                            try ctx.requestFocus(o.widget());
                            return ctx.consumeAndRedraw();
                        }
                    }
                } else if (key.matches('q', .{})) {
                    try ctx.addCmd(.queue_refresh);
                }
            },
            .mouse => |mouse| {
                _ = mouse;
            },
            .focus_in => {
                return ctx.requestFocus(self.widget());
            },
            .app => |appevent| {
                const cmdevent = cmdevents.getCmdEvent(appevent);
                if (cmdevent) |e| switch (e.*) {
                    // Respond to commands from the cmd_widget we care about
                    .run_cmd => |cmd| {
                        const cmd_name = cmd.get_cmd() orelse return;
                        if (std.mem.eql(u8, cmd_name, QuitHandlerData.event_str)) {
                            // quit the app
                            keep_running.store(false, .seq_cst);
                            ctx.quit = true;
                            return;
                        } else if (std.mem.eql(u8, cmd_name, QuitSaveHandlerData.event_str)) {
                            // save then quit
                            try self.dumpAllOutputs();
                            keep_running.store(false, .seq_cst);
                            ctx.quit = true;
                            return;
                        } else if (std.mem.eql(u8, cmd_name, MergeViewsData.event_str)) {
                            // process merge command
                            const args = cmd.get_args(self._alloc) catch return error.UnexpectedParseError;

                            actions.mergeProcessBuffers(
                                self._alloc,
                                &self.app_model,
                                args,
                            ) catch |err| switch (err) {
                                error.MergeCmdNotEnoughArgs => {},
                                else => return err,
                            };

                            // TODO:
                            // - match args to process views
                            // - create a list of UUID of parent process views
                            // - create name of merged view
                            // - merge view1 p1 p2 p3

                            // TESTING CODE
                            // for now - just merge all views
                        }
                    },
                    else => {},
                };
            },
            else => {},
        }
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *TuiApp = @ptrCast(@alignCast(ptr));
        const max_size = ctx.max.size();

        var children: []vxfw.SubSurface = undefined;

        switch (self.mode) {
            .main => {
                children = try ctx.arena.alloc(vxfw.SubSurface, 1);
                const output_child: vxfw.SubSurface = .{
                    .origin = .{ .row = 0, .col = 0 },
                    .surface = try self.app_model.model_view.draw(ctx),
                };

                children[0] = output_child;
            },
            .cmdview => {
                children = try ctx.arena.alloc(vxfw.SubSurface, 2);
                const output_child: vxfw.SubSurface = .{
                    .origin = .{ .row = 0, .col = 0 },
                    .surface = try self.app_model.model_view.draw(ctx),
                };

                const cmdwidget_child: vxfw.SubSurface = .{
                    .origin = .{ .row = 0, .col = 0 },
                    .surface = try self.app_model.cmd.view.draw(ctx),
                };

                children[0] = output_child;
                children[1] = cmdwidget_child;
            },
            .jsonview => {},
        }

        return .{
            // A Surface must have a size. Our root widget is the size of the screen
            .size = max_size,
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }

    fn handleStartCmd(args: []const u8, listener: *anyopaque) std.mem.Allocator.Error!void {
        const self: *TuiApp = @ptrCast(@alignCast(listener));

        var handle = self.app_model.executor.run(args, .nonBlocking) catch {
            return;
        };
        if (handle) |*h| h.deinit();
    }

    fn dumpAllOutputs(self: *TuiApp) !void {
        // Dump all output buffers to disk
        for (self.app_model.model_view.outputviews.items) |outputview| {
            for (outputview.outputs.items) |output| {
                try actions.dumpOutputBuffer(
                    self._alloc,
                    try output.output.nonowned_process_buffer.copyUnfilteredBuffer(self._alloc),
                    output.id,
                    output.process_name,
                );
            }
        }
    }

    const StartHandlerData = .{
        .event_str = "start",
        .handle = handleStartCmd,
        .arg_description = "cmd_str",
    };
    const QuitHandlerData = .{
        .event_str = "q",
        .arg_description = null,
    };
    const QuitSaveHandlerData = .{
        .event_str = "qw",
        .arg_description = null,
    };
    const MergeViewsData = .{
        .event_str = "merge",
        .arg_description = "view_name { --all | { !|~m ... !|~m } }",
    };

    pub fn subscribeHandlersToCmd(self: *TuiApp) !void {
        const hander_data = comptime .{
            &StartHandlerData,
        };

        const evented_handler_data = comptime .{
            &QuitHandlerData,
            &QuitSaveHandlerData,
            &MergeViewsData,
        };

        inline for (hander_data) |data| {
            const handler: Handler = .{
                .event_str = data.event_str,
                .arg_description = data.arg_description,
                .handle = .{ .regular_fn = data.handle },
                .listener = self,
            };
            const id = try self.app_model.cmd.addHandler(handler);
            try self.handlers_ids.append(self._alloc, id);
        }

        inline for (evented_handler_data) |data| {
            const handler: Handler = .{
                .event_str = data.event_str,
                .arg_description = data.arg_description,
                .handle = .{ .event_fn = TuiApp.typeErasedEventHandler },
                .listener = self,
            };
            const id = try self.app_model.cmd.addHandler(handler);
            try self.handlers_ids.append(self._alloc, id);
        }
    }

    pub fn unsubscribeHandlersFromCmd(self: *TuiApp) void {
        for (self.handlers_ids.items) |id| {
            self.app_model.cmd.removeHandler(id);
        }
        self.handlers_ids.clearAndFree(self._alloc);
    }
};

var model: *TuiApp = undefined;

var keep_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var tui_signal = TUISignal{};
var thread: ?std.Thread = null;
var app: vxfw.App = undefined;
fn run_tui(alloc: std.mem.Allocator, executor: *runner.ConfiguredRunner) !void {
    // parse the ui config
    var config = try uiconfig.parseConfigs(alloc);
    defer config.deinit();

    app = try vxfw.App.init(alloc);
    defer app.deinit();

    if (builtin.target.os.tag == .windows) {
        app.vx.enable_workarounds = true;
    }

    app.vx.refresh = true;

    var arena = std.heap.ArenaAllocator.init(alloc);
    const model_alloc = arena.allocator();

    model = try alloc.create(TuiApp);
    model.* = .{
        .app_model = .{
            .model_view = try view.View.init(alloc),
            .uiconfig = &config,
            .buffers = try .init(alloc),
            .executor = executor,
            .cmd = try .init(alloc),
        },
        .cmd_view = undefined,
        .arena = arena,
        ._alloc = model_alloc,
        .handlers_ids = try .initCapacity(model_alloc, 1),
    };
    model.cmd_view = try .init(alloc, model.app_model.cmd);
    defer alloc.destroy(model);
    keep_running.store(true, .seq_cst);

    if (builtin.mode == .Debug) {
        // Set up output views and process buffers for debugging
        const output_view = try OutputView.init(alloc);
        const output_view2 = try OutputView.init(alloc);
        try model.app_model.model_view.add_outputview(output_view, 0);
        try model.app_model.model_view.add_outputview(output_view2, 1);

        const b1 = try model.app_model.buffers.create_process_buffer(alloc);
        const b2 = try model.app_model.buffers.create_process_buffer(alloc);
        try output_view.add_output(try OutputWidget.init(
            alloc,
            "default_output",
            b1.id,
            b1.buffer,
        ));
        try output_view.add_output(try OutputWidget.init(
            alloc,
            "default_output2",
            b2.id,
            b2.buffer,
        ));
    }

    defer arena.deinit();
    defer model.app_model.buffers.deinit(alloc);
    defer model.app_model.model_view.deinit();

    try model.subscribeHandlersToCmd();

    try app.vx.setMouseMode(&app.tty.tty_writer.interface, true);
    try app.run(model.widget(), .{});

    model.unsubscribeHandlersFromCmd();
    keep_running.store(false, .seq_cst);
    setTUIClose();
}

pub fn start_tui(alloc: std.mem.Allocator, executor: *ConfiguredRunner) !void {
    thread = try std.Thread.spawn(
        .{ .allocator = alloc },
        run_tui,
        .{ alloc, executor },
    );

    // wait till the tui app has started
    var timer = try std.time.Timer.start();
    while (!keep_running.load(.seq_cst)) {
        if (timer.read() > 10_000_000_000) {
            return;
        }
    }
}

// Do not call this in the UI thread
pub fn stop_tui() void {
    if (thread) |t| {
        keep_running.store(false, .seq_cst); // Signal the thread to stop
        t.join();
        setTUIClose(); // Signal any other threads to stop
    }
}

pub fn setTUIClose() void {
    tui_signal.mutex.lock();
    tui_signal.isClosing = true;
    tui_signal.cond.signal();
    tui_signal.mutex.unlock();
}

pub fn waitForTUIClose() void {
    tui_signal.mutex.lock();
    defer tui_signal.mutex.unlock();

    while (!tui_signal.isClosing) {
        tui_signal.cond.wait(&tui_signal.mutex);
    }
}

pub fn createProcessView(alloc: std.mem.Allocator, processname: []const u8) std.mem.Allocator.Error!uuid.UUID {
    // FIX: terrible hack to avoid a race condition which actually hits on nix
    //std.time.sleep(10_000_000_000);
    //std.debug.print("creating output: {s}\n", .{processname});

    // const id: uuid.UUID = undefined;
    // if (keep_running.load(.seq_cst)) {
    //     const buf = try model.app_model.buffers.create_process_buffer(alloc);
    //     errdefer {
    //         model.app_model.buffers.remove_buffer(buf.id);
    //     }

    //     const p_output = try OutputWidget.init(
    //         alloc,
    //         processname,
    //         buf.id,
    //         buf.buffer.process,
    //     );
    //     errdefer p_output.deinit();

    //     id = buf.id;

    //     if (model.uiconfig) |config| {
    //         try p_output.setupViaUiconfig(config);
    //     }

    //     // Add a reference to the cmd
    //     try p_output.output.subscribeHandlersToCmd(model.app_model.cmd);

    //     // create an outputview if none exist
    //     if (model.app_model.model_view.outputviews.items.len == 0) {
    //         const output_view = try OutputView.init(alloc);

    //         const view_position = 0;
    //         model.app_model.model_view
    //             .add_outputview(output_view, view_position) catch |err| switch (err) {
    //             error.OutOfMemory => |e| {
    //                 // bubble up alloc errors
    //                 return e;
    //             },
    //             error.InvalidArg, error.OutputNotFound => |e| {
    //                 // we currently don't support returning other errors, so just panic!
    //                 std.debug.panic("createProcessView critically failed.\n error: {any}", .{e});
    //             },
    //         };
    //     }

    //     // we can assume there is at least one active view
    //     try model.modelview.modelview.outputviews.items[0].add_output(p_output);

    //     app.vx.setMouseMode(&app.tty.tty_writer.interface, true) catch {};
    // }
    // return id;

    const id = try processviewmgr.create_process_view(alloc, &model.app_model, processname);
    app.vx.setMouseMode(&app.tty.tty_writer.interface, true) catch {};
    return id;
}

pub fn killProcessView(processname: []const u8) void {
    _ = processname;
}

pub fn setUIConfig(alloc: std.mem.Allocator, jsonStr: []const u8) std.mem.Allocator.Error!void {
    _ = alloc;
    _ = jsonStr;
}

pub fn pushLogging(alloc: std.mem.Allocator, process_id: uuid.UUID, buffer: []const u8) std.mem.Allocator.Error!void {
    _ = alloc;

    if (keep_running.load(.seq_cst)) {
        model.app_model.buffers.process_buffers.m.lock();

        const target_buffer = model.app_model
            .buffers
            .process_buffers
            .map.get(process_id);
        if (target_buffer) |output| {
            try output.append(buffer);
        }

        model.app_model.buffers.process_buffers.m.unlock();
    }
}

// TODOs

// create a wrapped line mode

// create option to render the tail
//  - this is going to be kinda complicated

// - fix the clean up management around processbuffers
// - I think its time the model has a init and deinit

// ADD reference to the executor to the TUI so that:
//      - can call run on config names (DONE)
//      - can call run on custom commands
//          - with features such as addding env or exec path
//      - control running post tasks with UI still running

// TODO: f1 to open up a view_picker screen (or generic ui selection screen)
// TODO color title for selected outputview
// TODO make tabs
// TODO: report errors when processes die
//
// TODO: get text selection, copy, paste working
// TODO: create a command to run another process
// TODO: be able to grow/shrink outputviews
// TODO: add grid views instead of columns
// TODO: be able to set on/off/hover line numbers
//  -   set to show on hover (not done)
//  -   show actual lines when filtering (not done)
// TODO: select a view group with the mouse
// TODO: dump logs using the configuration name OR the task's label

// TODO: virtual buffers should receive filtered buffer rules (at time of FORK)

// merging buffers
//  - kill a merged view
//  - work out how to easily reference other views
//      - I like how tmux does it - an int for each view
//  - maybe have a -all flag (done)

// BUGS:

// hide in list example is broken
//  - hide build removes every line :(
//  - same for keep line
//  - FOUND OUT WHY - its because the sep is being treated as \r\n not \n
//          but the render only uses \n

// OOB - looks like a race condition:
// TODO: fix all accesses to filtered_buffer and buffer that skip the mutex call!!
//  in self.line_to_row.callback(...)
//  in outputwidget.getLineNumberViaRow(text_row)
//  in getLinesIndexFromOffset(ofs)
//  in linebuffer.getLines()

// sounds like a corruption bug via a race condition
//      - looks like I'm bypassing the mutex in a process buffer
//      - also looks like its more likely to happen with a merge

// ScrollBars now has a bug in handleCapture new_view_cl_start: u32 = @intFromFloat(@ceil(new_view_col_start_f))

// tasks child.wait() closes pipes
// need to refactor the wait to not close pipes until process closed and piped emptied

// TODO parse ui config in TUI
// ---> options
// ------> when process starts, run color commands
// ------> when matching output starts, run setup function

// new runners
// file based
// remote runners - ie ssh/sftp

// IDEA: have some preconfiguration setups
// logcolors
// justerrors
// noinfo

// IDEA: make a simple file which lists a bunch of cmd lines so that it is easy to use run_launch

// FEATURE: grid views
// IDEA:

// cmd ideas
// fold +string -string2 (both prune and include)
//
// pipeline visulizer
// kill process/runner (refactor runner/child_processes to make it easier for interaction with UI)
// start cmd

// !!advanced ideas!!
// combine two buffers
//  - time stamps for each line
// split into virtual buffers
//  split (ie if in rule b1 else b2)
// OR tee (ie if in rule b1 and b2 ELSE b1)

// how do to splitting -- not sure
// need childProcessBuffers which use the same base buffer
// but clone filter rules and grandfather them in
