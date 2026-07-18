const AppModel = @This();

// This is to keep the global state of the app and separate the global app widget from its
// top level view of the data structures.

const std = @import("std");
const uiconfig_ = @import("uiconfig");
const view = @import("view.zig");
const cmdwidget = @import("cmd/cmdwidget.zig");
const Cmd = @import("cmd/cmd.zig").Cmd;
const buffermgr = @import("buffermanager.zig");
const EntityViewer = @import("widgets/entity_viewer.zig");
const runner = @import("runner");

pub const View = view.View;
pub const UiConfig = uiconfig_.UiConfig;
pub const BufferMgr = buffermgr.BufferMgr;
pub const PBufferAndId = buffermgr.PBufferAndId;
pub const ConfiguredRunner = runner.ConfiguredRunner;

model_view: *view.View,
uiconfig: ?*UiConfig,
buffers: *BufferMgr,
executor: *ConfiguredRunner,
cmd: *Cmd,
entity_viewer: *EntityViewer,
