const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const utils = @import("utils");
const AppModel = @import("../AppModel.zig");
const processviewmgr = @import("../processviewmgr.zig");

const UUID = utils.uuid.UUID;

/// `merge <name> --all` or `merge <name> {~N | !N}...` : asks the pump to create a merged
/// buffer of the given views (`~N`) / buffers (`!N`). The merged view appears through the
/// inbox once the pump has built it.
pub fn mergeProcessBuffers(
    io: Io,
    alloc: Allocator,
    app_model: *AppModel,
    args: []const []const u8,
) !void {
    if (args.len < 2) {
        return error.MergeCmdNotEnoughArgs;
    }

    const store = app_model.store;
    const pump_alloc = (store.pump orelse return error.NoPump).alloc;

    var parents = try std.ArrayList(UUID).initCapacity(pump_alloc, args.len - 1);
    errdefer parents.deinit(pump_alloc);

    var all = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--all")) all = true;
    }

    if (all) {
        for (app_model.buffer_infos.items) |info| {
            try parents.append(pump_alloc, info.id);
        }
    } else {
        for (args[1..]) |arg| {
            if (arg.len < 2) return error.InvalidBufferId;
            const n = std.fmt.parseInt(usize, arg[1..], 10) catch return error.InvalidBufferId;
            const id: UUID = switch (arg[0]) {
                // a view: resolve through its widget's buffer
                '~' => blk: {
                    const ow = processviewmgr.get_via_strid(app_model, arg) orelse return error.InvalidBufferId;
                    break :blk ow.output.nonowned_process_buffer.id orelse return error.InvalidBufferId;
                },
                // a buffer
                '!' => (app_model.findBufferByStrid(n) orelse return error.InvalidBufferId).id,
                else => return error.InvalidBufferId,
            };
            try parents.append(pump_alloc, id);
        }
    }

    if (parents.items.len == 0) return error.MergeCmdNotEnoughArgs;

    const name = try pump_alloc.dupe(u8, args[0]);
    errdefer pump_alloc.free(name);
    const parent_slice = try parents.toOwnedSlice(pump_alloc);

    // ownership of name/parent_slice transfers to the command (post frees them on failure)
    try store.post(.{ .create_merge = .{
        .id = utils.uuid.newV4(io),
        .name = name,
        .parents = parent_slice,
    } });
    _ = alloc;
}
