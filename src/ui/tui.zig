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

pub const ConfiguredRunner = runner.ConfiguredRunner;
pub const OutputView = view.OutputView;
pub const vxfw = vaxis.vxfw;
const Unicode = vaxis.unicode;
const graphemedata = vaxis.grapheme.GraphemeData;
pub const OutputWidget = view.OutputWidget;
pub const ProcessBuffer = view.output_view_mod.ProcessBuffer;
pub const Handler = cmdwidget.Cmd.Handler;

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

const Model = struct {
    modelview: *view.View,
    uiconfig: ?*uiconfig.UiConfig = null,
    process_buffers: ProcessBuffersMap,
    executor: *ConfiguredRunner,
    arena: std.heap.ArenaAllocator,
    _alloc: std.mem.Allocator,
    //cmd_view: cmdwidget.CmdWidget,
    cmd: *Cmd,
    handlers_ids: std.ArrayList(cmdwidget.Cmd.HandleId),
    help_id: ?uuid.UUID = null,
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

    fn show_help(self: *Model, alloc: std.mem.Allocator) !void {
        const id = try createProcessView(alloc, "help");
        try pushLogging(alloc, id, help.getHelpString());
        self.help_id = id;
    }

    pub fn handleCapture(self: *Model, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .key_press => |key| {
                if (key.matches('/', .{})) {
                    if (self.mode == .main) {
                        self.mode = .cmdview;
                        try ctx.requestFocus(self.cmd.view.widget());
                        return ctx.consumeAndRedraw();
                    }
                } else if (key.matches(vaxis.Key.escape, .{})) {
                    if (self.mode == .cmdview) {
                        self.mode = .main;
                        if (self.modelview.get_focused_output_widget()) |ow| {
                            try ctx.requestFocus(ow.widget());
                        } else {
                            try ctx.requestFocus(self.widget());
                        }
                        return ctx.consumeEvent();
                    }
                } else if (key.matches(vaxis.Key.f2, .{})) {
                    if (self.mode == .main) {
                        const does_help_exist = self.help_id != null;

                        //{
                        //    // check if a help output already exists
                        //    self.process_buffers.m.lock();
                        //    defer self.process_buffers.m.unlock();
                        //    var iter = self.process_buffers.map.keyIterator();
                        //    while (iter.next()) |map_key| {
                        //        if (std.mem.eql(u8, &map_key.*.bytes, &self.help_id.bytes)) {
                        //            does_help_exist = true;
                        //            break;
                        //        }
                        //    }
                        //}

                        if (!does_help_exist) {
                            try self.show_help(self.arena.allocator());
                        }

                        // find the outputview that contain's help
                        for (self.modelview.outputviews.items) |ov| {
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
                    try ctx.requestFocus(self.cmd.view.widget());
                    //try ctx.requestFocus(self.cmd_view.widget());
                    return ctx.consumeEvent();
                } else if (self.mode == .main) {
                    if (self.modelview.get_focused_output_widget()) |ow| {
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

                // if there output views in the model - focus
                if (self.modelview.outputviews.items.len != 0) {
                    const output_view = self.modelview.outputviews.items[0];
                    try self.modelview.focus_outputview_by_idx(0);
                    try output_view.eventHandler(ctx, event);
                }

                //try self.output_view.eventHandler(ctx, event);
                //try self.output_view.focused_ow.?.handleEvent(ctx, event);
            },
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = false })) {
                    // This will current kill the tui but not kill the program...
                    ctx.quit = true;
                    return;
                } else if (key.matches('w', .{ .shift = true }) or
                    key.matches(vaxis.Key.tab, .{ .shift = true }))
                {
                    const output_view = self.modelview.get_focused();
                    if (output_view) |ov| {
                        const output = ov.focus_prev();
                        if (output) |o| {
                            try ctx.requestFocus(o.widget());
                            return ctx.consumeAndRedraw();
                        }
                    }
                    return;
                } else if (key.matches('w', .{ .shift = false })) {
                    if (self.modelview.focus_prev()) |ov| {
                        if (ov.focused_ow) |o| try ctx.requestFocus(o.widget());
                    }
                    return ctx.consumeAndRedraw();
                } else if (key.matches('e', .{ .shift = false })) {
                    if (self.modelview.focus_next()) |ov| {
                        if (ov.focused_ow) |o| try ctx.requestFocus(o.widget());
                    }
                    return ctx.consumeAndRedraw();
                } else if (key.matches('e', .{ .shift = true }) or
                    key.matches(vaxis.Key.tab, .{}))
                {
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
                        const output = ov.focused_ow;
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
                        const output = ov.focused_ow;
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
                        const output = ov.focused_ow;
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
                        const output = ov.focused_ow;
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
                _ = mouse;
                //std.debug.print("model: mouse type {?}\n", .{mouse.type});
                //std.debug.print("mouse x {?}\n", .{mouse.col});
                //std.debug.print("mouse y {?}\n", .{mouse.row});
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
                    .origin = .{ .row = 0, .col = 0 },
                    .surface = try self.modelview.draw(ctx),
                };

                children[0] = output_child;
            },
            .cmdview => {
                children = try ctx.arena.alloc(vxfw.SubSurface, 2);
                const output_child: vxfw.SubSurface = .{
                    .origin = .{ .row = 0, .col = 0 },
                    .surface = try self.modelview.draw(ctx),
                };

                const cmdwidget_child: vxfw.SubSurface = .{
                    .origin = .{ .row = 0, .col = 0 },
                    .surface = try self.cmd.view.draw(ctx),
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

    fn handleStartCmd(args: []const u8, listener: *anyopaque) std.mem.Allocator.Error!void {
        const self: *Model = @ptrCast(@alignCast(listener));

        var handle = self.executor.run(args, .nonBlocking) catch {
            return;
        };
        if (handle) |*h| h.deinit();
    }

    const StartHandlerData = .{ .event_str = "start", .handle = handleStartCmd };

    pub fn subscribeHandlersToCmd(self: *Model) !void {
        const hander_data = comptime .{
            &StartHandlerData,
        };

        inline for (hander_data) |data| {
            const handler: Handler = .{
                .event_str = data.event_str,
                .handle = data.handle,
                .listener = self,
            };
            const id = try self.cmd.addHandler(handler);
            try self.handlers_ids.append(self._alloc, id);
        }
    }

    pub fn unsubscribeHandlersFromCmd(self: *Model) void {
        for (self.handlers_ids.items) |id| {
            self.cmd.removeHandler(id);
        }
        self.handlers_ids.clearAndFree(self._alloc);
    }
};

var model: *Model = undefined;

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

    const model_view = try view.View.init(alloc);

    var arena = std.heap.ArenaAllocator.init(alloc);
    const model_alloc = arena.allocator();

    model = try alloc.create(Model);
    model.* = .{
        //.output_view = output_view,
        .uiconfig = &config,
        .modelview = model_view,
        .process_buffers = .{
            .m = .{},
            .map = .{},
        },
        .executor = executor,
        .cmd = try .init(alloc),
        .arena = arena,
        ._alloc = model_alloc,
        .handlers_ids = try .initCapacity(model_alloc, 1),
    };
    defer alloc.destroy(model);
    keep_running.store(true, .seq_cst);

    if (builtin.mode == .Debug) {
        // Set up output views and process buffers for debugging
        const output_view = try OutputView.init(alloc);
        const output_view2 = try OutputView.init(alloc);
        try model_view.add_outputview(output_view, 0);
        try model_view.add_outputview(output_view2, 1);

        const id1 = uuid.newV4();
        const id2 = uuid.newV4();

        const buf = try ProcessBuffer.init(alloc);
        const buf2 = try ProcessBuffer.init(alloc);
        try output_view.add_output(try OutputWidget.init(alloc, "default_output", id1, buf));
        try output_view2.add_output(try OutputWidget.init(alloc, "default_output2", id2, buf2));

        model.process_buffers.m.lock();
        try model.process_buffers.map.put(alloc, id1, buf);
        try model.process_buffers.map.put(alloc, id2, buf2);
        model.process_buffers.m.unlock();
    }

    // this code here is a problem
    defer arena.deinit();
    defer model.process_buffers.map.deinit(alloc);
    defer {
        model.process_buffers.m.lock();
        var iter = model.process_buffers.map.iterator();
        while (iter.next()) |i| {
            i.value_ptr.*.deinit();
        }
        model.process_buffers.m.unlock();
    }
    defer model_view.deinit();

    //std.debug.print("color_scheme_updates : {?}\n", .{app.vx.caps.color_scheme_updates});
    //std.debug.print("explicit_width : {?}\n", .{app.vx.caps.explicit_width});
    //std.debug.print("kitty_graphics : {?}\n", .{app.vx.caps.kitty_graphics});
    //std.debug.print("kitty_keyboard : {?}\n", .{app.vx.caps.kitty_keyboard});
    //std.debug.print("rgb : {?}\n", .{app.vx.caps.rgb});
    //std.debug.print("scaled_text : {?}\n", .{app.vx.caps.scaled_text});
    //std.debug.print("sgr_pixels : {?}\n", .{app.vx.caps.sgr_pixels});

    //std.debug.print("width: {d}\n", .{app.vx.screen.width});
    //std.debug.print("height: {d}\n", .{app.vx.screen.height});

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
    const process_id = uuid.newV4();
    if (keep_running.load(.seq_cst)) {
        //const aa = model.arena.allocator();

        // check that a process with the same name doesn't exist
        const buf = try ProcessBuffer.init(alloc);
        // TODO: this line is failing inside with a lock(). Probably need to put a
        // mutex around it
        model.process_buffers.m.lock();
        try model.process_buffers.map.put(alloc, process_id, buf);
        model.process_buffers.m.unlock();
        errdefer {
            model.process_buffers.m.lock();
            const keyvalue = model.process_buffers.map.fetchRemove(process_id);
            if (keyvalue) |kv| {
                kv.value.deinit();
            }
            model.process_buffers.m.unlock();
        }

        const p_output = try OutputWidget.init(
            alloc,
            processname,
            process_id,
            buf,
        );
        errdefer p_output.deinit();

        if (model.uiconfig) |config| {
            try p_output.setupViaUiconfig(config);
        }

        // Add a reference to the cmd
        try p_output.output.subscribeHandlersToCmd(model.cmd);

        // create an outputview if none exist
        if (model.modelview.outputviews.items.len == 0) {
            const output_view = try OutputView.init(alloc);

            const view_position = 0;
            model.modelview
                .add_outputview(output_view, view_position) catch |err| switch (err) {
                error.OutOfMemory => |e| {
                    // bubble up alloc errors
                    return e;
                },
                error.InvalidArg, error.OutputNotFound => |e| {
                    // we currently don't support returning other errors, so just panic!
                    std.debug.panic("createProcessView critically failed.\n error: {any}", .{e});
                },
            };
        }

        // we can assume there is at least one active view
        try model.modelview.outputviews.items[0].add_output(p_output);

        app.vx.setMouseMode(&app.tty.tty_writer.interface, true) catch {};
    }
    return process_id;
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
        model.process_buffers.m.lock();
        const target_buffer = model.process_buffers.map.get(process_id);

        if (target_buffer) |output| {
            try output.append(buffer);
        }
        model.process_buffers.m.unlock();
    }
}

// TODOs

// create option to render the tail
//  - this is going to be kinda complicated

// historywidget - keep history scroll relative to bottom
// - fix the clean up management around processbuffers
// - I think its time the model has a init and deinit

// ADD reference to the executor to the TUI so that:
//      - can call run on config names (DONE)
//      - can call run on custom commands
//          - with features such as addding env or exec path
//      - control running post tasks with UI still running

// TODO color title for selected outputview
// TODO make tabs
// TODO: report errors when processes die
//
// TODO: get text selection, copy, paste working
// TODO: create a command to run another process
// TODO: be able to grow/shrink outputviews
// TODO: be able to set on/off/hover line numbers
// TODO: select a view group with the mouse
// TODO: dump logs using the configuration name OR the task's label
// TODO: cursor on cmd bar is not showing

// BUGS:

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

// cmd ideas
// prune ... (done)
// change fold to keep (done)
// fold +string -string2 (both prune and include)
// replace ... (done)
// dump buffers to disk (done)
//
// pipeline visulizer
// remove find (done)
// jump ie j (done)
// color (done)
// expand (ie expand a fold)
// kill process/runner (refactor runner/child_processes to make it easier for interaction with UI)
// start cmd
//

// !!advanced ideas!!
// combine two buffers
// split into virtual buffers
//  split (ie if in rule b1 else b2)
// OR tee (ie if in rule b1 and b2 ELSE b1)

// how do to splitting -- not sure
// need childProcessBuffers which use the same base buffer
// but clone filter rules and grandfather them in

// Segmentation fault at address 0xffffffffffffffff
// C:\_\zig\p\uucode-0.1.0-ZZjBPj96QADXyt5sqwBJUnhaDYs_qBeeKijZvlRa0eqM\src\grapheme.zig:32:44: 0x7ff6f8187ea6 in init (run_launch_zcu.obj)
//             const next_cp = next_cp_it.next();
//                                            ^
// C:\_\zig\p\vaxis-0.5.1-BWNV_GMyCQBtxcEkSAEb_EXbm8A24FWJFC7fXiWUVx9Y\src\unicode.zig:24:73: 0x7ff6f81d278c in init (run_launch_zcu.obj)
//             .inner = uucode.grapheme.Iterator(uucode.utf8.Iterator).init(.init(str)),
//                                                                         ^
// C:\_\zig\p\vaxis-0.5.1-BWNV_GMyCQBtxcEkSAEb_EXbm8A24FWJFC7fXiWUVx9Y\src\unicode.zig:63:33: 0x7ff6f81b039d in graphemeIterator (run_launch_zcu.obj)
//     return GraphemeIterator.init(str);
//                                 ^
// C:\_\zig\p\vaxis-0.5.1-BWNV_GMyCQBtxcEkSAEb_EXbm8A24FWJFC7fXiWUVx9Y\src\vxfw\TextField.zig:137:40: 0x7ff6f81ea32f in insertSliceAtCursor (run_launch_zcu.obj)
//     var iter = unicode.graphemeIterator(data);
//                                        ^
// C:\_\zig\p\vaxis-0.5.1-BWNV_GMyCQBtxcEkSAEb_EXbm8A24FWJFC7fXiWUVx9Y\src\vxfw\TextField.zig:115:45: 0x7ff6f81de685 in handleEvent (run_launch_zcu.obj)
//                 try self.insertSliceAtCursor(text);
//                                             ^
// C:\dev\run_launch\src\ui\tui\cmdwidget.zig:102:49: 0x7ff6f81dd6af in eventHandler (run_launch_zcu.obj)
//                     try self.textBox.handleEvent(ctx, event);
//                                                 ^
// C:\dev\run_launch\src\ui\tui\cmdwidget.zig:61:37: 0x7ff6f81bde3e in typeErasedEventHandler (run_launch_zcu.obj)
//         return try self.eventHandler(ctx, event);
//                                     ^
// C:\_\zig\p\vaxis-0.5.1-BWNV_GMyCQBtxcEkSAEb_EXbm8A24FWJFC7fXiWUVx9Y\src\vxfw\vxfw.zig:283:26: 0x7ff6f8184382 in handleEvent (run_launch_zcu.obj)
//             return handle(self.userdata, ctx, event);
//                          ^
// C:\_\zig\p\vaxis-0.5.1-BWNV_GMyCQBtxcEkSAEb_EXbm8A24FWJFC7fXiWUVx9Y\src\vxfw\App.zig:592:31: 0x7ff6f80ccca2 in handleEvent (run_launch_zcu.obj)
//         try target.handleEvent(ctx, event);
//                               ^
// C:\_\zig\p\vaxis-0.5.1-BWNV_GMyCQBtxcEkSAEb_EXbm8A24FWJFC7fXiWUVx9Y\src\vxfw\App.zig:137:54: 0x7ff6f808b899 in run (run_launch_zcu.obj)
//                         try focus_handler.handleEvent(&ctx, event);
//                                                      ^
// C:\dev\run_launch\src\ui\tui.zig:485:16: 0x7ff6f808a2c5 in run_tui (run_launch_zcu.obj)
//     try app.run(model.widget(), .{});
//                ^
// C:\_\Microsoft\WinGet\Packages\zig.zig_Microsoft.Winget.Source_8wekyb3d8bbwe\zig-x86_64-windows-0.15.2\lib\std\Thread.zig:528:21: 0x7ff6f8048585 in callFn__anon_41297 (run_launch_zcu.obj)
//                     @call(.auto, f, args) catch |err| {
//                     ^
// C:\_\Microsoft\WinGet\Packages\zig.zig_Microsoft.Winget.Source_8wekyb3d8bbwe\zig-x86_64-windows-0.15.2\lib\std\Thread.zig:622:30: 0x7ff6f802e4d4 in entryFn (run_launch_zcu.obj)
//                 return callFn(f, self.fn_args);
//                              ^
// ???:?:?: 0x7ffe643fe8d6 in ??? (KERNEL32.DLL)
// ???:?:?: 0x7ffe653ac53b in ??? (ntdll.dll)
