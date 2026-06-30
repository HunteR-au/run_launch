// This file captures the methods that can create a process view
// A process view can be backed by various structs
// including a raw stdout/stderr read/write loop OR a list of parent process_buffers

const std = @import("std");
const AppModel = @import("AppModel.zig");
const OutputWidget = @import("outputwidget.zig").OutputWidget;
const OutputView = @import("outputview.zig").OutputView;
const utils = @import("utils");

const View = AppModel.View;
const BufferMgr = AppModel.BufferMgr;
const PBufferAndId = AppModel.PBufferAndId;
const UiConfig = AppModel.UiConfig;

const uuid = utils.uuid;

pub const ViewType = enum { process, virtual };

const StrIdCounter = struct {
    m: std.Thread.Mutex = .{},
    counter: usize = 0,

    pub fn new_id(self: *StrIdCounter) usize {
        self.m.lock();
        const id = self.counter;
        self.counter = self.counter + 1;
        self.m.unlock();
        return id;
    }
};

var counter = StrIdCounter{};

pub fn create_process_view(
    alloc: std.mem.Allocator,
    app_model: *AppModel,
    processname: []const u8,
) !uuid.UUID {
    // Create the ProcesssBuffer
    const buffer_tuple = try app_model
        .buffers
        .create_process_buffer(alloc);
    errdefer {
        app_model.buffers.remove_buffer(buffer_tuple.id);
    }

    try create_processview(
        alloc,
        app_model,
        processname,
        buffer_tuple,
    );
    return buffer_tuple.id;
}

// TODO: we should have errdefers for removing processviews

pub fn create_virtual_process_view(
    alloc: std.mem.Allocator,
    app_model: *AppModel,
    view_name: []const u8,
    parents: []uuid.UUID,
) !void {
    const buffer_tuple = try app_model
        .buffers
        .create_virtual_process_buffer(alloc, parents);
    errdefer {
        app_model.buffers.remove_buffer(buffer_tuple.id);
    }

    try create_processview(
        alloc,
        app_model,
        view_name,
        buffer_tuple,
    );
}

fn create_processview(
    alloc: std.mem.Allocator,
    app_model: *AppModel,
    name: []const u8,
    buffer_tuple: PBufferAndId,
) !void {
    const p_output = try OutputWidget.init(
        alloc,
        name,
        buffer_tuple.id,
        buffer_tuple.buffer,
    );
    p_output.strid = counter.new_id();

    errdefer p_output.deinit();

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
                std.debug.panic("createProcessView critically failed.\n error: {any}", .{e});
            },
        };
    }

    // we can assume there is at least one active view
    try app_model.model_view.outputviews.items[0].add_output(p_output);
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
