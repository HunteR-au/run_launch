const std = @import("std");
const Io = std.Io;
const utils = @import("utils");
const AppModel = @import("../AppModel.zig");
const processviewmgr = @import("../processviewmgr.zig");
const OutputWidget = @import("../outputwidget.zig").OutputWidget;
const OutputView = @import("../outputview.zig").OutputView;

const UUID = utils.uuid.UUID;

pub const StopError = error{
    /// not `~N` / `!N`
    InvalidId,
    /// `~N` parsed but no view on screen has that id
    NoSuchView,
    /// `!N` parsed but the pump has announced no buffer with that id
    NoSuchBuffer,
} || std.mem.Allocator.Error || AppModel.View.ViewErrors;

/// What a `stop` argument names. Titles are not unique, so only these ids are accepted.
pub const Target = union(enum) {
    /// `~N`: a view on screen
    view: usize,
    /// `!N`: a buffer owned by the pump
    buffer: usize,
};

pub fn parseTarget(arg: []const u8) error{InvalidId}!Target {
    if (arg.len < 2) return error.InvalidId;
    const n = std.fmt.parseInt(usize, arg[1..], 10) catch return error.InvalidId;
    return switch (arg[0]) {
        '~' => .{ .view = n },
        '!' => .{ .buffer = n },
        else => error.InvalidId,
    };
}

/// What `stopView` took off the screen. The widget (and the view it emptied, if any) are
/// still allocated: free them with `finish` once the event loop has redrawn without them.
pub const Detached = struct {
    id: UUID,
    widget: *OutputWidget,
    emptied_view: ?*OutputView,
    /// true when a launched child process owned the buffer and has been asked to exit
    process_terminated: bool,
};

/// `stop ~N`: removes view N and the buffer behind it.
///
/// A view backed by a child process also gets its process killed (with no view there is
/// nowhere for its output to go); a merged view is simply unlinked from its parents (merges
/// built on top of it keep what they have). The buffer is removed from the pump in `finish`.
pub fn stopView(io: Io, app_model: *AppModel, strid: usize) StopError!Detached {
    const located = locateView(app_model, strid) orelse return error.NoSuchView;
    const id = located.widget.id;

    // Signal only: the waiter/readers report exit and EOF for a buffer we are about to
    // remove, which the store drops. Merged/help buffers have no process: nothing to do.
    const terminated = app_model.executor.terminateProcess(io, id);

    const emptied = try processviewmgr.detach_processview(app_model.model_view, located);
    return .{
        .id = id,
        .widget = located.widget,
        .emptied_view = emptied,
        .process_terminated = terminated,
    };
}

/// `stop !N`: kills the child process behind buffer N and nothing else. The view and the
/// buffer stay; the store appends its end-of-process marker once the process is reaped, so
/// the user sees the result in the view. Returns false when no launched process owns the
/// buffer (a merged/help buffer, or a process that already exited).
pub fn stopProcess(io: Io, app_model: *AppModel, strid: usize) StopError!bool {
    const info = app_model.findBufferByStrid(strid) orelse return error.NoSuchBuffer;
    return app_model.executor.terminateProcess(io, info.id);
}

/// Frees what `stopView` detached and asks the pump to drop the buffer. The widget's
/// filter/reviewer removals are posted first (by its deinit), the buffer removal after:
/// FIFO on the pump keeps that order.
pub fn finish(io: Io, app_model: *AppModel, d: Detached) void {
    d.widget.deinit(io);
    if (d.emptied_view) |v| v.deinit(io);
    app_model.store.post(.{ .remove_buffer = .{ .id = d.id } }) catch |err| {
        std.log.warn("stop: could not remove buffer from the pump: {t}", .{err});
    };
}

fn locateView(app_model: *AppModel, strid: usize) ?processviewmgr.Located {
    for (app_model.model_view.outputviews.items) |ov| {
        for (ov.outputs.items) |ow| {
            if (ow.strid == strid) return .{ .view = ov, .widget = ow };
        }
    }
    return null;
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

const testing = std.testing;

test "parseTarget: ~N is a view, !N a buffer, anything else is rejected" {
    try testing.expectEqual(Target{ .view = 3 }, try parseTarget("~3"));
    try testing.expectEqual(Target{ .buffer = 0 }, try parseTarget("!0"));
    try testing.expectEqual(Target{ .view = 12 }, try parseTarget("~12"));

    try testing.expectError(error.InvalidId, parseTarget(""));
    try testing.expectError(error.InvalidId, parseTarget("~"));
    try testing.expectError(error.InvalidId, parseTarget("!"));
    try testing.expectError(error.InvalidId, parseTarget("x1"));
    try testing.expectError(error.InvalidId, parseTarget("~a"));
    try testing.expectError(error.InvalidId, parseTarget("~-1"));
    try testing.expectError(error.InvalidId, parseTarget("Print"));
}
