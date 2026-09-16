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
