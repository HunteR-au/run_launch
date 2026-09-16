const AppModel = @This();

// This is to keep the global state of the app and separate the global app widget from its
// top level view of the data structures.

const std = @import("std");
const utils = @import("utils");
const uiconfig_ = @import("uiconfig");
const view = @import("view.zig");
const cmdwidget = @import("cmd/cmdwidget.zig");
const Cmd = @import("cmd/cmd.zig").Cmd;
const ingeststore = @import("pipeline/ingeststore.zig");
const EntityViewer = @import("widgets/entity_viewer.zig");
const runner = @import("runner");

pub const View = view.View;
pub const UiConfig = uiconfig_.UiConfig;
pub const IngestStore = ingeststore.IngestStore;
pub const ProcessBuffer = ingeststore.ProcessBuffer;
pub const ConfiguredRunner = runner.ConfiguredRunner;
pub const UUID = utils.uuid.UUID;

/// UI-thread mirror of the buffers the pump has announced. `name` is owned.
pub const BufferInfo = struct {
    id: UUID,
    strid: usize,
    name: []u8,
    pb: *ProcessBuffer,
};

model_view: *view.View,
uiconfig: ?*UiConfig,
/// pump-owned buffers; the UI only reads snapshots and posts commands
store: *IngestStore,
/// buffers known to the UI, in creation order
buffer_infos: std.ArrayList(BufferInfo) = .empty,
executor: *ConfiguredRunner,
cmd: *Cmd,
entity_viewer: *EntityViewer,

pub fn findBufferInfo(self: *const AppModel, id: UUID) ?*const BufferInfo {
    for (self.buffer_infos.items) |*info| {
        if (std.meta.eql(info.id, id)) return info;
    }
    return null;
}

pub fn findBufferByStrid(self: *const AppModel, strid: usize) ?*const BufferInfo {
    for (self.buffer_infos.items) |*info| {
        if (info.strid == strid) return info;
    }
    return null;
}

pub fn removeBufferInfo(self: *AppModel, alloc: std.mem.Allocator, id: UUID) void {
    for (self.buffer_infos.items, 0..) |info, i| {
        if (std.meta.eql(info.id, id)) {
            alloc.free(info.name);
            _ = self.buffer_infos.orderedRemove(i);
            return;
        }
    }
}

pub fn deinitBufferInfos(self: *AppModel, alloc: std.mem.Allocator) void {
    for (self.buffer_infos.items) |info| alloc.free(info.name);
    self.buffer_infos.deinit(alloc);
}
