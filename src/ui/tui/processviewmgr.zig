// This file captures the methods that can create a process view
// A process view can be backed by various structs
// including a raw stdout/stderr read/write loop OR a list of parent process_buffers

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
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
    m: std.Io.Mutex = .init,
    counter: usize = 0,

    pub fn new_id(self: *StrIdCounter, io: Io) usize {
        self.m.lockUncancelable(io);
        const id = self.counter;
        self.counter = self.counter + 1;
        self.m.unlock(io);
        return id;
    }
};

var counter = StrIdCounter{};

pub fn create_process_view(
    io: Io,
    alloc: Allocator,
    app_model: *AppModel,
    processname: []const u8,
) !uuid.UUID {
    // Create the ProcesssBuffer
    const buffer_tuple = try app_model
        .buffers
        .create_process_buffer(io, alloc);
    errdefer {
        app_model.buffers.remove_buffer(io, buffer_tuple.id);
    }

    try create_processview(
        io,
        alloc,
        app_model,
        processname,
        buffer_tuple,
    );
    return buffer_tuple.id;
}

// TODO: we should have errdefers for removing processviews

pub fn create_virtual_process_view(
    io: Io,
    alloc: Allocator,
    app_model: *AppModel,
    view_name: []const u8,
    parents: []uuid.UUID,
) !void {
    const buffer_tuple = try app_model
        .buffers
        .create_virtual_process_buffer(io, alloc, parents);
    errdefer {
        app_model.buffers.remove_buffer(io, buffer_tuple.id);
    }

    try create_processview(
        io,
        alloc,
        app_model,
        view_name,
        buffer_tuple,
    );
}

fn create_processview(
    io: Io,
    alloc: Allocator,
    app_model: *AppModel,
    name: []const u8,
    buffer_tuple: PBufferAndId,
) !void {
    // This function is called from main when the program is spooling up. From then
    // on it is expected to only be called in the TUI thread. It isn't threadsafe
    // and should be protected by a mutex

    const p_output = try OutputWidget.init(
        alloc,
        name,
        buffer_tuple.id,
        buffer_tuple.buffer,
    );
    p_output.strid = counter.new_id(io);

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
