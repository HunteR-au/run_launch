// This file captures the methods that create and look up process views (widgets).
//
// Buffers are created by the pump (see pipeline/ingeststore.zig); the UI thread creates the
// widget for a buffer when the pump announces it through the inbox. Everything here runs on
// the UI thread only.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const AppModel = @import("AppModel.zig");
const OutputWidget = @import("outputwidget.zig").OutputWidget;
const OutputView = @import("outputview.zig").OutputView;
const utils = @import("utils");

const View = AppModel.View;
const ProcessBuffer = AppModel.ProcessBuffer;

const uuid = utils.uuid;

pub const PBufferAndId = struct {
    id: uuid.UUID,
    buffer: *ProcessBuffer,
};

const StrIdCounter = struct {
    counter: usize = 0,

    pub fn new_id(self: *StrIdCounter) usize {
        const id = self.counter;
        self.counter += 1;
        return id;
    }
};

var counter = StrIdCounter{};

/// Creates the widget for an announced buffer and adds it to the first output view.
pub fn create_processview(
    io: Io,
    alloc: Allocator,
    app_model: *AppModel,
    name: []const u8,
    buffer_tuple: PBufferAndId,
) !*OutputWidget {
    const p_output = try OutputWidget.init(
        alloc,
        name,
        buffer_tuple.id,
        buffer_tuple.buffer,
        app_model.store,
    );
    p_output.strid = counter.new_id();

    errdefer p_output.deinit(io);

    // Set the UI config for the Output Widget
    if (app_model.uiconfig) |config| {
        try p_output.setupViaUiconfig(config);
    }

    // Add a reference to the cmd
    try p_output.output.subscribeHandlersToCmd(app_model.cmd);

    // create an outputview if none exist
    if (app_model.model_view.outputviews.items.len == 0) {
        const output_view = try OutputView.init(alloc);

        const view_position = 0;
        app_model.model_view
            .add_outputview(output_view, view_position) catch |err| switch (err) {
            error.OutOfMemory => |e| {
                // bubble up alloc errors
                return e;
            },
            error.InvalidArg, error.OutputNotFound => |e| {
                // we currently don't support returning other errors, so just panic!
                std.debug.panic("create_processview critically failed.\n error: {any}", .{e});
            },
        };
    }

    // we can assume there is at least one active view
    try app_model.model_view.outputviews.items[0].add_output(p_output);
    return p_output;
}

pub fn parse_strid(strid: []const u8) !usize {
    if (strid.len <= 1) return error.InvalidStrId;
    if (strid[0] != '~') return error.InvalidStrId;

    // parse integer
    return std.fmt.parseInt(usize, strid[1..strid.len], 10) catch error.InvalidStrId;
}

pub fn get_via_strid(app_model: *AppModel, strid: []const u8) ?*OutputWidget {
    const id = parse_strid(strid) catch return null;

    for (app_model.model_view.outputviews.items) |outputviews| {
        for (outputviews.outputs.items) |*output_widget| {
            if (output_widget.*.strid == id) {
                return output_widget.*;
            }
        }
    }

    return null;
}

pub const Located = struct { view: *OutputView, widget: *OutputWidget };

/// Finds the widget showing buffer `id` and the output view containing it.
pub fn find_by_buffer_id(app_model: *AppModel, id: uuid.UUID) ?Located {
    for (app_model.model_view.outputviews.items) |ov| {
        for (ov.outputs.items) |ow| {
            if (std.meta.eql(ow.id, id)) return .{ .view = ov, .widget = ow };
        }
    }
    return null;
}

/// Finds the output view that contains `widget`.
pub fn locate_widget(app_model: *AppModel, widget: *OutputWidget) ?Located {
    for (app_model.model_view.outputviews.items) |ov| {
        for (ov.outputs.items) |ow| {
            if (ow == widget) return .{ .view = ov, .widget = ow };
        }
    }
    return null;
}

/// Takes a widget off the screen: it stops receiving commands, leaves its output view and,
/// when that view is now empty, the view leaves the layout too (focus moves to a neighbour).
/// Nothing is freed here, so a widget/view still referenced by the current frame is safe to
/// hit until the caller deinits them after the next redraw. Returns the emptied view, if any.
pub fn detach_processview(model_view: *View, located: Located) !?*OutputView {
    if (located.widget.output.cmd_ref != null) located.widget.output.unsubscribeHandlersFromCmd();
    located.view.remove_output(located.widget);
    if (located.view.outputs.items.len != 0) return null;

    const pos = try model_view.get_position(located.view);
    const emptied = model_view.remove_outputview(pos);
    const remaining = model_view.outputviews.items.len;
    if (remaining != 0 and model_view.focused_outputview == null) {
        try model_view.focus_outputview_by_idx(@min(pos, remaining - 1));
    }
    return emptied;
}

const ViewIterator = struct {
    outer: []const *OutputView,
    outer_index: usize = 0,
    inner_index: usize = 0,

    pub fn next(self: *ViewIterator) ?*OutputWidget {
        while (self.outer_index < self.outer.len) : (self.outer_index += 1) {
            const inner = self.outer[self.outer_index].outputs.items;
            if (self.inner_index < inner.len) {
                const item = inner[self.inner_index];
                self.inner_index += 1;
                return item;
            }
            self.inner_index = 0;
        }
        return null;
    }
};

pub fn get_view_list_iterator(app_model: *AppModel) ViewIterator {
    return .{
        .outer = app_model.model_view.outputviews.items,
    };
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

const testing = std.testing;
const pump_mod = @import("pump");
const IngestStore = AppModel.IngestStore;

/// Widgets need a buffer to point at; a store with a running pump provides real ones.
const WidgetHarness = struct {
    store: *IngestStore,
    pump: *pump_mod.Pump,

    fn init(alloc: Allocator, io: Io) !WidgetHarness {
        const store = try IngestStore.init(alloc, io);
        errdefer store.deinit();
        const pump = try pump_mod.Pump.init(alloc, io, store.sink(), .{});
        errdefer pump.deinit();
        store.attach(pump);
        try pump.start();
        return .{ .store = store, .pump = pump };
    }

    fn widget(self: *WidgetHarness, alloc: Allocator, name: []const u8) !*OutputWidget {
        const id = try self.store.createBufferAsync(name);
        // FIFO barrier so the buffer exists before we look it up
        self.store.call(.{ .remove_all_filters = .{ .id = .{ .bytes = [_]u8{0xff} ** 16 } } }) catch unreachable;
        const pb = self.store.lookup(id).?;
        const ow = try OutputWidget.init(alloc, name, id, pb, self.store);
        ow.strid = counter.new_id();
        return ow;
    }

    fn deinit(self: *WidgetHarness) void {
        self.pump.stop();
        self.pump.deinit();
        self.store.deinit();
    }
};

test "detach_processview: emptied views leave the layout, focus lands on a neighbour, none left is fine" {
    const alloc = testing.allocator;
    const io = testing.io;

    var h = try WidgetHarness.init(alloc, io);
    defer h.deinit();

    const model_view = try View.init(alloc);
    defer model_view.deinit(io);

    // [ ov0: w0 w1 ] [ ov1: w2 ], ov1 focused
    const ov0 = try OutputView.init(alloc);
    try model_view.add_outputview(ov0, 0);
    const w0 = try h.widget(alloc, "a");
    const w1 = try h.widget(alloc, "a"); // same title on purpose: only ids tell them apart
    try ov0.add_output(w0);
    try ov0.add_output(w1);
    const ov1 = try OutputView.init(alloc);
    try model_view.add_outputview(ov1, 1);
    const w2 = try h.widget(alloc, "b");
    try ov1.add_output(w2);
    try model_view.focus_outputview_by_idx(1);

    // the strid lookups both helpers rely on
    try testing.expectEqual(w1, get_via_strid_view(model_view, w1.strid).?);
    try testing.expectEqual(ov1, locate_in(model_view, w2).?.view);

    // stop w2: ov1 empties and is removed, focus moves to ov0 (the nearest remaining view)
    const emptied1 = try detach_processview(model_view, .{ .view = ov1, .widget = w2 });
    try testing.expectEqual(ov1, emptied1.?);
    try testing.expectEqual(1, model_view.outputviews.items.len);
    try testing.expectEqual(ov0, model_view.get_focused().?);
    try testing.expect(ov0.is_focused);
    emptied1.?.deinit(io);
    w2.deinit(io);

    // stop the focused w0: ov0 stays with w1 focused
    try testing.expectEqual(w0, ov0.focused_ow.?);
    const emptied0 = try detach_processview(model_view, .{ .view = ov0, .widget = w0 });
    try testing.expectEqual(null, emptied0);
    try testing.expectEqual(w1, ov0.focused_ow.?);
    try testing.expect(w1.output.is_focused);
    w0.deinit(io);

    // stop the last one: no views at all, nothing focused, the View itself still draws
    const emptied_last = try detach_processview(model_view, .{ .view = ov0, .widget = w1 });
    try testing.expectEqual(ov0, emptied_last.?);
    try testing.expectEqual(0, model_view.outputviews.items.len);
    try testing.expectEqual(0, model_view.flexitems.items.len);
    try testing.expectEqual(null, model_view.get_focused());
    try testing.expectEqual(null, model_view.get_focused_output_widget());
    emptied_last.?.deinit(io);
    w1.deinit(io);

    // ... and a new view can be added again afterwards (what `start` does through the inbox)
    const ov_new = try OutputView.init(alloc);
    try model_view.add_outputview(ov_new, 0);
    try testing.expectEqual(ov_new, model_view.get_focused().?);
}

test "OutputView: when the shown output leaves, the column falls back to what it showed before" {
    const alloc = testing.allocator;
    const io = testing.io;

    var h = try WidgetHarness.init(alloc, io);
    defer h.deinit();

    const ov = try OutputView.init(alloc);
    defer ov.deinit(io); // frees whatever is still in the column
    ov.focus_self();

    const a = try h.widget(alloc, "a");
    const b = try h.widget(alloc, "b");
    const c = try h.widget(alloc, "c");
    try ov.add_output(a);
    try ov.add_output(b);
    try ov.add_output(c);
    try testing.expectEqual(a, ov.focused_ow.?);

    // the user looked at c, then at b, and now moves b to another column
    ov.focus_output(c);
    ov.focus_output(b);
    ov.remove_output(b);
    try testing.expectEqual(c, ov.focused_ow.?); // not a (index 0)
    try testing.expect(c.output.is_focused);
    try testing.expect(!b.output.is_focused);
    // Tab order is the original order minus b, not shuffled by the removal
    try testing.expectEqualSlices(*OutputWidget, &.{ a, c }, ov.outputs.items);
    b.deinit(io);

    // Tab counts as viewing: Tab to a, then remove a -> back to c
    try testing.expectEqual(a, ov.focus_next().?);
    ov.remove_output(a);
    try testing.expectEqual(c, ov.focused_ow.?);
    a.deinit(io);

    // removing an output that is not on screen changes nothing on screen
    const d = try h.widget(alloc, "d");
    try ov.add_output(d);
    try testing.expectEqual(c, ov.focused_ow.?);
    ov.remove_output(d);
    try testing.expectEqual(c, ov.focused_ow.?);
    d.deinit(io);

    // last one out leaves the column empty
    ov.remove_output(c);
    try testing.expectEqual(null, ov.focused_ow);
    try testing.expectEqual(0, ov.outputs.items.len);
    try testing.expectEqual(0, ov.history.items.len);
    c.deinit(io);
}

/// Test-only twins of `get_via_strid`/`locate_widget` that take the View directly.
fn get_via_strid_view(model_view: *View, strid: usize) ?*OutputWidget {
    for (model_view.outputviews.items) |ov| {
        for (ov.outputs.items) |ow| if (ow.strid == strid) return ow;
    }
    return null;
}

fn locate_in(model_view: *View, widget: *OutputWidget) ?Located {
    for (model_view.outputviews.items) |ov| {
        for (ov.outputs.items) |ow| if (ow == widget) return .{ .view = ov, .widget = ow };
    }
    return null;
}
