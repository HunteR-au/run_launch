const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const utils = @import("utils");
pub const vaxis = @import("vaxis");
pub const uiconfig = @import("uiconfig");
pub const view = @import("tui/view.zig");
pub const cmdwidget = @import("tui/cmd/cmdwidget.zig");
pub const EntityViewer = @import("tui/widgets/entity_viewer.zig");
pub const Cmd = @import("tui/cmd/cmd.zig").Cmd;
pub const help = @import("tui/help/help.zig");
pub const runner = @import("runner");
pub const pump_mod = @import("pump");
pub const Pump = pump_mod.Pump;
pub const ingeststore = @import("tui/pipeline/ingeststore.zig");
pub const IngestStore = ingeststore.IngestStore;
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

const uuid = utils.uuid;

const ModelState = enum { main, cmdview, jsonview, objview };

pub const TUISignal = struct {
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    isClosing: bool = false,
};

const Key = struct {
    cp: u21,
    mod: vaxis.Key.Modifiers,
};

pub const Action = enum {
    FocusCmdWindow,
    FocusObjViewerWindow,
    Escape,
    ShowHelp,
    FastQuit,
    OutputViewPrev,
    OutputViewNext,
    ViewPrev,
    ViewNext,
    MoveOutputViewLeft,
    MoveOutputViewRight,
    SplitOutputViewLeft,
    SplitOutputViewRight,
    RefreshScreen,
};

const Bindings = struct {
    const BindType = struct { action: Action, key: Key };
    const list = [_]BindType{
        .{ .action = Action.FocusObjViewerWindow, .key = Key{ .cp = vaxis.Key.f1, .mod = .{} } },
        .{ .action = Action.FocusCmdWindow, .key = Key{ .cp = '/', .mod = .{} } },
        .{ .action = Action.Escape, .key = Key{ .cp = vaxis.Key.escape, .mod = .{} } },
        .{ .action = Action.ShowHelp, .key = Key{ .cp = vaxis.Key.f2, .mod = .{} } },
        .{ .action = Action.FastQuit, .key = Key{ .cp = 'c', .mod = .{ .ctrl = false } } },
        .{ .action = Action.OutputViewPrev, .key = Key{ .cp = 'w', .mod = .{ .shift = true } } },
        .{ .action = Action.OutputViewPrev, .key = Key{ .cp = vaxis.Key.tab, .mod = .{ .shift = true } } },
        .{ .action = Action.OutputViewNext, .key = Key{ .cp = 'e', .mod = .{ .shift = true } } },
        .{ .action = Action.OutputViewNext, .key = Key{ .cp = vaxis.Key.tab, .mod = .{} } },
        .{ .action = Action.ViewPrev, .key = Key{ .cp = 'w', .mod = .{ .shift = false } } },
        .{ .action = Action.ViewNext, .key = Key{ .cp = 'e', .mod = .{ .shift = false } } },
        .{ .action = Action.MoveOutputViewLeft, .key = Key{ .cp = 's', .mod = .{} } },
        .{ .action = Action.MoveOutputViewRight, .key = Key{ .cp = 'd', .mod = .{} } },
        .{ .action = Action.SplitOutputViewLeft, .key = Key{ .cp = 's', .mod = .{ .shift = true } } },
        .{ .action = Action.SplitOutputViewRight, .key = Key{ .cp = 'd', .mod = .{ .shift = true } } },
        .{ .action = Action.RefreshScreen, .key = Key{ .cp = 'q', .mod = .{} } },
    };

    pub fn matches(key: vaxis.Key) ?Action {
        for (Bindings.list) |bind| {
            if (key.matches(bind.key.cp, bind.key.mod)) {
                return bind.action;
            }
        }

        return null;
    }
};

const TuiApp = struct {
    app_model: AppModel,
    /// Heap allocated so `_alloc` (its allocator) stays valid for the life of the model.
    arena: *std.heap.ArenaAllocator,
    _alloc: std.mem.Allocator,
    cmd_view: cmdwidget.CmdWidget,
    // cmd: *Cmd,
    handlers_ids: std.ArrayList(cmdwidget.Cmd.HandleId),
    help_id: ?uuid.UUID = null,
    /// buffer whose view should take focus as soon as the pump announces it
    pending_focus_id: ?uuid.UUID = null,
    mode: ModelState = .main,
    prev_mode: ModelState = .main,
    start_script: ?[]const u8 = null,
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

    /// Asks the pump for a help buffer; its view is created and focused when the inbox
    /// announces it.
    fn show_help(self: *TuiApp) !void {
        const store = self.app_model.store;
        const id = try store.createBufferAsync("help");
        try store.writeText(id, help.getHelpString());
        self.help_id = id;
        self.pending_focus_id = id;
    }

    /// Focuses the view showing buffer `id`, if it exists yet.
    fn focusBuffer(self: *TuiApp, ctx: *vxfw.EventContext, id: uuid.UUID) !bool {
        const found = processviewmgr.find_by_buffer_id(&self.app_model, id) orelse return false;
        const pos = try self.app_model.model_view.get_position(found.view);
        try self.app_model.model_view.focus_outputview_by_idx(pos);
        found.view.focus_output(found.widget);
        try ctx.requestFocus(found.widget.widget());
        return true;
    }

    /// Applies what the pump reported since the last tick: creates widgets for new buffers,
    /// drops removed ones, logs failed commands.
    fn drainInbox(self: *TuiApp, ctx: *vxfw.EventContext) !void {
        const store = self.app_model.store;
        var events = store.inbox.drain();
        defer events.deinit(store.alloc);

        for (events.items) |ev| {
            switch (ev) {
                .buffer_created => |c| {
                    ctx.redraw = true;
                    _ = processviewmgr.create_processview(
                        ctx.io,
                        model_alloc_root,
                        &self.app_model,
                        c.name,
                        .{ .id = c.id, .buffer = c.pb },
                    ) catch |err| {
                        std.log.err("could not create view \"{s}\": {t}", .{ c.name, err });
                        store.alloc.free(c.name);
                        continue;
                    };
                    // the mirror takes ownership of the name (same allocator as the store)
                    self.app_model.buffer_infos.append(model_alloc_root, .{
                        .id = c.id,
                        .strid = c.strid,
                        .name = c.name,
                        .pb = c.pb,
                    }) catch store.alloc.free(c.name);

                    if (self.pending_focus_id) |want| {
                        if (std.meta.eql(want, c.id)) {
                            self.pending_focus_id = null;
                            _ = try self.focusBuffer(ctx, c.id);
                        }
                    }
                },
                .buffer_removed => |r| {
                    self.app_model.removeBufferInfo(model_alloc_root, r.id);
                    ctx.redraw = true;
                },
                .command_failed => |f| {
                    std.log.warn("command failed: {s}", .{f.what});
                    store.alloc.free(f.what);
                },
            }
        }
    }

    pub fn handleCapture(self: *TuiApp, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .key_press => |key| {
                const opt_result = Bindings.matches(key);
                if (opt_result) |result| switch (result) {
                    .FocusCmdWindow => {
                        if (self.mode == .main) {
                            self.mode = .cmdview;
                            try ctx.requestFocus(self.app_model.cmd.view.widget());
                            return ctx.consumeAndRedraw();
                        }
                    },
                    .FocusObjViewerWindow => {
                        var is_rendering = false;

                        switch (self.mode) {
                            .main => {
                                self.prev_mode = .main;
                                self.mode = .objview;
                                is_rendering = true;
                            },
                            .cmdview => {
                                // we need to save the prev state
                                self.prev_mode = .cmdview;
                                self.mode = .objview;
                                is_rendering = true;
                            },
                            else => {},
                        }

                        if (is_rendering) {
                            try self.app_model.entity_viewer.update_objects(
                                self._alloc,
                                try EntityViewer.create_objects(self._alloc, &self.app_model, ctx.io),
                            );
                            try ctx.requestFocus(self.app_model.entity_viewer.widget());
                            return ctx.consumeAndRedraw();
                        }
                    },
                    .Escape => {
                        if (self.mode == .cmdview or self.mode == .objview) {
                            switch (self.prev_mode) {
                                .cmdview => {
                                    self.mode = .cmdview;
                                    self.prev_mode = .main;
                                    try ctx.requestFocus(self.app_model.cmd.view.widget());
                                },
                                .main => {
                                    self.mode = .main;
                                    try self.focus_on_main(ctx);
                                },
                                else => unreachable,
                            }
                            return ctx.consumeEvent();
                        }
                    },
                    .ShowHelp => {
                        if (self.mode == .main) {
                            if (self.help_id) |id| {
                                // already created (or still on its way): focus it
                                if (!try self.focusBuffer(ctx, id)) self.pending_focus_id = id;
                            } else {
                                self.show_help() catch |err| std.log.err("could not open help: {t}", .{err});
                            }
                            return ctx.consumeAndRedraw();
                        }
                    },
                    else => {},
                };
            },
            .focus_in => {
                switch (self.mode) {
                    .cmdview => {
                        try ctx.requestFocus(self.app_model.cmd.view.widget());
                        return ctx.consumeEvent();
                    },
                    .main => {
                        try self.focus_on_main(ctx);
                        return ctx.consumeEvent();
                    },
                    .objview => {
                        try ctx.requestFocus(self.app_model.entity_viewer.widget());
                        return ctx.consumeEvent();
                    },
                    else => {},
                }
            },
            .init => {
                if (self.start_script) |script| {
                    // TODO: probably should have some user output for errors
                    self.app_model.cmd.run_script(ctx.io, script, ctx, event) catch {};
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

                // The root tick is the only periodic timer: it redraws when a buffer changed
                try ctx.tick(tick_ms, self.widget());
            },
            .tick => {
                try ctx.tick(tick_ms, self.widget());
                try self.drainInbox(ctx);
                if (self.anyOutputChanged()) ctx.redraw = true;
            },
            .key_press => |key| {
                const opt_result = Bindings.matches(key);
                if (opt_result) |result| switch (result) {
                    .FastQuit => {
                        std.log.info("tui: fast quit requested", .{});
                        requestQuit(ctx);
                        return;
                    },
                    .OutputViewPrev => {
                        const output_view = self.app_model.model_view.get_focused();
                        if (output_view) |ov| {
                            const output = ov.focus_prev();
                            if (output) |o| {
                                try ctx.requestFocus(o.widget());
                                return ctx.consumeAndRedraw();
                            }
                        }
                        return;
                    },
                    .OutputViewNext => {
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
                    },
                    .ViewPrev => {
                        if (self.app_model.model_view.focus_prev()) |ov| {
                            if (ov.focused_ow) |o| try ctx.requestFocus(o.widget());
                        }
                        return ctx.consumeAndRedraw();
                    },
                    .ViewNext => {
                        if (self.app_model.model_view.focus_next()) |ov| {
                            if (ov.focused_ow) |o| try ctx.requestFocus(o.widget());
                        }
                        return ctx.consumeAndRedraw();
                    },
                    .MoveOutputViewLeft => {
                        const output_view = self.app_model.model_view.get_focused();
                        if (output_view) |ov| {
                            const output = ov.focused_ow;
                            if (output) |o| {
                                const from = try self.app_model.model_view.get_position(ov);
                                self.app_model.model_view.move_output(ctx.io, o, from, from -| 1) catch |err|
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
                    },
                    .MoveOutputViewRight => {
                        const output_view = self.app_model.model_view.get_focused();
                        if (output_view) |ov| {
                            const output = ov.focused_ow;
                            if (output) |o| {
                                const from = try self.app_model.model_view.get_position(ov);
                                self.app_model.model_view.move_output(ctx.io, o, from, from +| 1) catch |err|
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
                    },
                    .SplitOutputViewLeft => {
                        const output_view = self.app_model.model_view.get_focused();
                        if (output_view) |ov| {
                            const output = ov.focused_ow;
                            if (output) |o| {
                                const from = try self.app_model.model_view.get_position(ov);
                                try self.app_model.model_view.split_output(ctx.io, o, from, view.Direction.left);
                                try ctx.requestFocus(o.widget());
                                return ctx.consumeAndRedraw();
                            }
                        }
                    },
                    .SplitOutputViewRight => {
                        const output_view = self.app_model.model_view.get_focused();
                        if (output_view) |ov| {
                            const output = ov.focused_ow;
                            if (output) |o| {
                                const from = try self.app_model.model_view.get_position(ov);
                                try self.app_model.model_view.split_output(ctx.io, o, from, view.Direction.right);
                                try ctx.requestFocus(o.widget());
                                return ctx.consumeAndRedraw();
                            }
                        }
                    },
                    .RefreshScreen => {
                        try ctx.addCmd(.queue_refresh);
                        return;
                    },
                    else => {},
                };
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
                            std.log.info("tui: quit command received", .{});
                            requestQuit(ctx);
                            return;
                        } else if (std.mem.eql(u8, cmd_name, QuitSaveHandlerData.event_str)) {
                            // save then quit
                            try self.dumpAllOutputs(ctx.io);
                            requestQuit(ctx);
                            return;
                        } else if (std.mem.eql(u8, cmd_name, MergeViewsData.event_str)) {
                            // process merge command
                            const args = cmd.get_args(self._alloc) catch return error.UnexpectedParseError;

                            actions.mergeProcessBuffers(
                                ctx.io,
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

    const tick_ms: u32 = 16;

    /// True when any visible output widget's buffer has published a change since it was
    /// last drawn.
    fn anyOutputChanged(self: *TuiApp) bool {
        for (self.app_model.model_view.outputviews.items) |ov| {
            if (ov.focused_ow) |ow| {
                if (ow.needsRedraw()) return true;
            }
        }
        return false;
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
            .objview => {
                if (self.prev_mode == .cmdview) {
                    children = try ctx.arena.alloc(vxfw.SubSurface, 3);
                    const output_child: vxfw.SubSurface = .{
                        .origin = .{ .row = 0, .col = 0 },
                        .surface = try self.app_model.model_view.draw(ctx),
                    };

                    const entity_viewer_child: vxfw.SubSurface = .{
                        .origin = .{ .row = 0, .col = 0 },
                        .surface = try self.app_model.entity_viewer.draw(ctx),
                    };

                    const cmdwidget_child: vxfw.SubSurface = .{
                        .origin = .{ .row = 0, .col = 0 },
                        .surface = try self.app_model.cmd.view.draw(ctx),
                    };

                    children[0] = output_child;
                    children[1] = entity_viewer_child;
                    children[2] = cmdwidget_child;
                } else {
                    children = try ctx.arena.alloc(vxfw.SubSurface, 2);
                    const output_child: vxfw.SubSurface = .{
                        .origin = .{ .row = 0, .col = 0 },
                        .surface = try self.app_model.model_view.draw(ctx),
                    };

                    const entity_viewer_child: vxfw.SubSurface = .{
                        .origin = .{ .row = 0, .col = 0 },
                        .surface = try self.app_model.entity_viewer.draw(ctx),
                    };

                    children[0] = output_child;
                    children[1] = entity_viewer_child;
                }
            },
        }

        return .{
            // A Surface must have a size. Our root widget is the size of the screen
            .size = max_size,
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }

    fn handleStartCmd(io: Io, args: []const u8, listener: *anyopaque) std.mem.Allocator.Error!void {
        const self: *TuiApp = @ptrCast(@alignCast(listener));

        var handle = self.app_model.executor.run(io, args, .nonBlocking) catch {
            return;
        };
        if (handle) |*h| h.deinit();
    }

    /// Dumps every output's raw buffer to disk. Synchronous: used right before quitting.
    fn dumpAllOutputs(self: *TuiApp, io: Io) !void {
        _ = io;
        for (self.app_model.model_view.outputviews.items) |outputview| {
            for (outputview.outputs.items) |output| {
                output.output.dump(.Raw, .sync) catch |err| {
                    std.log.err("dump of \"{s}\" failed: {t}", .{ output.process_name, err });
                };
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

    pub fn focus_on_main(self: *TuiApp, ctx: *vxfw.EventContext) !void {
        if (self.app_model.model_view.get_focused_output_widget()) |ow| {
            try ctx.requestFocus(ow.widget());
        } else {
            try ctx.requestFocus(self.widget());
        }
    }
};

var model: *TuiApp = undefined;
var ui_config: uiconfig.UiConfig = undefined;
var model_alloc_root: std.mem.Allocator = undefined;
var pump_ptr: *Pump = undefined;
var store_ptr: *IngestStore = undefined;

var keep_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var tui_signal = TUISignal{};
var tui_started: std.Io.Event = .unset;
var tui_start_err: ?anyerror = null;
var tui_loop_exited: std.atomic.Value(bool) = .init(false);
var thread: ?std.Thread = null;
var app: vxfw.App = undefined;

/// Asks the vaxis event loop to exit. On Windows also starts a helper that wakes the
/// blocked console reader, see `wakeInputThread`.
fn requestQuit(ctx: *vxfw.EventContext) void {
    keep_running.store(false, .seq_cst);
    ctx.quit = true;
    if (builtin.os.tag == .windows) {
        const t = std.Thread.spawn(.{}, wakeInputThread, .{}) catch return;
        t.detach();
    }
}

const WinConsole = if (builtin.os.tag == .windows) struct {
    const windows = std.os.windows;
    extern "kernel32" fn WriteConsoleInputW(
        hConsoleInput: windows.HANDLE,
        lpBuffer: *const vaxis.Tty.INPUT_RECORD,
        nLength: windows.DWORD,
        lpNumberOfEventsWritten: *windows.DWORD,
    ) callconv(.winapi) windows.BOOL;
} else struct {};

/// vaxis's `Loop.stop` unblocks its `ReadConsoleInputW` thread by asking the terminal for a
/// device status report and waiting for the reply. Under ConPTY that query is not reliably
/// answered, which leaves the loop stuck forever. Injecting a harmless key-release record
/// into the console input wakes the reader so it can observe `should_quit`.
fn wakeInputThread() void {
    if (builtin.os.tag != .windows) return;
    var record: vaxis.Tty.INPUT_RECORD = std.mem.zeroes(vaxis.Tty.INPUT_RECORD);
    record.EventType = 0x0001; // KEY_EVENT
    record.Event.KeyEvent = .{
        .bKeyDown = .FALSE,
        .wRepeatCount = 1,
        .wVirtualKeyCode = 0x41, // 'A'
        .wVirtualScanCode = 0,
        .uChar = .{ .UnicodeChar = 'a' },
        .dwControlKeyState = 0,
    };

    var attempts: usize = 0;
    while (!tui_loop_exited.load(.acquire) and attempts < 250) : (attempts += 1) {
        var written: std.os.windows.DWORD = 0;
        _ = WinConsole.WriteConsoleInputW(app.tty.stdin, &record, 1, &written);
        std.Io.sleep(pump_ptr.io, .fromMilliseconds(20), .awake) catch return;
    }
}

fn run_tui(io: Io, alloc: std.mem.Allocator, executor: *runner.ConfiguredRunner, env_map: *std.process.Environ.Map) !void {
    // Whatever happens, main must be released from waitForTUIClose.
    defer setTUIClose(io);
    // ... and from start_tui, with the error if we never got going.
    errdefer |err| {
        tui_start_err = err;
        tui_started.set(io);
    }

    ui_config = try uiconfig.parseConfigs(io, alloc);

    var buffer: [1024]u8 = undefined;
    app = try vxfw.App.init(io, alloc, env_map, &buffer);
    defer app.deinit();

    if (builtin.target.os.tag == .windows) {
        app.vx.enable_workarounds = true;
    }

    app.vx.refresh = true;

    const arena = try alloc.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(alloc);
    const model_alloc = arena.allocator();
    model_alloc_root = alloc;

    model = try alloc.create(TuiApp);
    model.* = .{
        .app_model = .{
            .model_view = try view.View.init(alloc),
            .uiconfig = &ui_config,
            .store = store_ptr,
            .executor = executor,
            .cmd = try .init(alloc),
            .entity_viewer = try .init(alloc, null),
        },
        .cmd_view = undefined,
        .arena = arena,
        ._alloc = model_alloc,
        .handlers_ids = try .initCapacity(model_alloc, 1),
    };
    model.cmd_view = try .init(alloc, model.app_model.cmd);

    if (builtin.mode == .Debug) {
        // Ask the pump for a couple of scratch buffers; their views appear on the first tick
        _ = try store_ptr.createBufferAsync("default_output");
        _ = try store_ptr.createBufferAsync("default_output2");
    }

    try model.subscribeHandlersToCmd();

    // The model is ready: the pump and the runner may start using it.
    keep_running.store(true, .seq_cst);
    tui_started.set(io);

    app.vx.setMouseMode(&app.tty.tty_writer.interface, true) catch {};
    tui_loop_exited.store(false, .release);
    app.run(model.widget(), .{}) catch |err| {
        std.log.err("tui event loop exited with error: {t}", .{err});
    };
    tui_loop_exited.store(true, .release);
    std.log.info("tui: event loop returned", .{});

    model.unsubscribeHandlersFromCmd();
    keep_running.store(false, .seq_cst);
    // The model, buffers and views are torn down by `stop_tui` on the main thread once the
    // pump has been stopped, so nothing can touch them while they are freed.
}

/// Frees the model. Called by `stop_tui` after the TUI thread has been joined.
fn teardownModel(io: Io) void {
    const alloc = model_alloc_root;
    model.app_model.model_view.deinit(io);
    model.app_model.deinitBufferInfos(alloc);
    model.arena.deinit();
    alloc.destroy(model.arena);
    alloc.destroy(model);
    ui_config.deinit();
}

pub fn start_tui(
    io: Io,
    alloc: std.mem.Allocator,
    executor: *ConfiguredRunner,
    pump: *Pump,
    store: *IngestStore,
    env_map: *std.process.Environ.Map,
) !void {
    pump_ptr = pump;
    store_ptr = store;
    thread = try std.Thread.spawn(
        .{ .allocator = alloc },
        run_tui,
        .{ io, alloc, executor, env_map },
    );

    // wait till the tui app has started (or failed to)
    tui_started.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } }) catch {
        return error.TuiStartTimeout;
    };
    if (tui_start_err) |err| return err;
}

/// Joins the TUI thread and frees the model. Call from the main thread after the pump has
/// been stopped (nothing may write into the buffers while they are freed).
pub fn stop_tui(io: Io) void {
    if (thread) |t| {
        t.join();
        thread = null;
        if (tui_start_err == null) teardownModel(io);
    }
}

pub fn setTUIClose(io: Io) void {
    tui_signal.mutex.lockUncancelable(io);
    defer tui_signal.mutex.unlock(io);

    tui_signal.isClosing = true;
    tui_signal.cond.signal(io);
}

pub fn waitForTUIClose(io: Io) !void {
    tui_signal.mutex.lockUncancelable(io);
    defer tui_signal.mutex.unlock(io);

    while (!tui_signal.isClosing) {
        try tui_signal.cond.wait(io, &tui_signal.mutex);
    }
}

pub fn setUIConfig(alloc: std.mem.Allocator, jsonStr: []const u8) std.mem.Allocator.Error!void {
    _ = alloc;
    _ = jsonStr;
}

// TODOs

// ---- priority list for now ----

// 1) update config and config structs to my system
// 2) wire in the scripting system
// 5) match line mode where waits for some process condition (exit 0) or string match on last line or any line and exits if success
// 6) be able to remove merged views,
//      - needs to be expressed via the !n notation (ie kill !0)
// 7) kill/hide views backed by a process
//      - I want a cmd called stop which stops the child process
//      - I want a cmd called del which deletes the view (and if a non-merged view, stops the child process)

// 3) normalize newlines for merge keep/hide bug (done)
// 4) wrapped line mode (done)
// 0) consider what to do about character controls....not sure atm but I need to do something. They can kill the program!!!! (done)
//  - I want the stored data in ingest to store the original input
//  - I want to have a mode to see the raw data to help with debugging
//  - I want to have a default that is pretty and respects what the program wanted the user to see
//      - This adds some complications in how flipping states from raw to terminal will work
//      - It will also impact how features that use regex over the ingest data work. Pattern matching over hidden data is a problem
//          - Ideally a user would write regexes over what they see and it matches

// think about workflows. this should be quick to turn on/off and powerfull with configuration set up

// config that runs mutiple programs
// script system for config

// //// SCRIPTING INPUT SYSTEM ///// (DONE)
// GLOBAL: color my_pattern red:line
// Print: keep yes no apple
// ~0: keep yes
// : merge test ~0 ~1
// test:
// TODO - I don't have the ability to run a cmd on ALL yet

// TODO - write logic for postTask. I'm thinking post tasks should be outputted to the main tty
// question is what if I kill a single output, or it dies
// should postTasks wait... that would make restart harder

// create a panel in the middle of the screen to list all buffers/view
// design: create a widget around optionPicker
//  optionPicker should be the base abstraction (done)
//  BUG: merge cannot ref views (only buffers)
//  BUG: buffer should show program
//  BUG: view should show title
//  BUG: the viewer can lose focus
//  IDEA: allow viewer to be shown when cmd up (maybe a stack for the tui mode...)
//  TODO: need to think how to display views and buffers a little more

// create a script system to run cmds when run_launch starts

// update the config + executor to allow for multiple programs to run
// I want a simple config + complex config
// - complex should have pre/posts
// - simple just cmdlines, envs, script

// create option to render the tail
//  - this is going to be kinda complicated

// ADD reference to the executor to the TUI so that:
//      - can call run on config names (DONE)
//      - can call run on custom commands
//          - with features such as addding env or exec path
//      - control running post tasks with UI still running

// TODO: cmd error feedback
// TODO color title for selected outputview
// TODO: report errors when processes die
//
// TODO: paste (mouse text selection + copy is done: drag to select, Y re-copies, Esc clears)
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

// ScrollBars now has a bug in handleCapture new_view_cl_start: u32 = @intFromFloat(@ceil(new_view_col_start_f))

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
// some config with an extension as .rl
// -- runs a series of programs
// -- should be able to run cmds
// -- should be able to set envs for programs

// FEATURE: grid views
// IDEA:

// cmd ideas
// fold +string -string2 (both prune and include)
//
// pipeline visulizer
// kill process/runner (refactor runner/child_processes to make it easier for interaction with UI)
// start cmd

// !!advanced ideas!!
// split into virtual buffers
//  split (ie if in rule b1 else b2)
// OR tee (ie if in rule b1 and b2 ELSE b1)
// counter for a regex match

// how do to splitting -- not sure
// need childProcessBuffers which use the same base buffer
// but clone filter rules and grandfather them in
