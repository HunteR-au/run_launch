const std = @import("std");
const utils = @import("utils");
const AppModel = @import("../AppModel.zig");
const processviewmgr = @import("../processviewmgr.zig");

const UUID = utils.uuid.UUID;

pub fn mergeProcessBuffers(
    alloc: std.mem.Allocator,
    app_model: *AppModel,
    args: []const []const u8,
) !void {
    if (args.len < 2) {
        return error.MergeCmdNotEnoughArgs;
    }

    // check if --all is present
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--all")) {
            var process_buffer_keys = try std.ArrayList(UUID).initCapacity(alloc, 0);
            defer process_buffer_keys.deinit(alloc);

            {
                app_model.buffers.process_buffers.m.lock();
                defer app_model.buffers.process_buffers.m.unlock();

                // get all non-virtual processs buffer keys
                var map_iter = app_model.buffers
                    .process_buffers
                    .map.iterator();
                while (map_iter.next()) |entry| {
                    try process_buffer_keys.append(alloc, entry.key_ptr.*);
                }
            }

            try processviewmgr.create_virtual_process_view(
                alloc,
                app_model,
                args[0],
                process_buffer_keys.items,
            );

            return;
        }
    }

    var buffer_keys = try std.ArrayList(UUID).initCapacity(alloc, 10);
    defer buffer_keys.deinit(alloc);

    for (args[1..args.len]) |arg| {
        const output_widget =
            processviewmgr.get_via_strid(app_model, arg) orelse return;
        try buffer_keys.append(alloc, output_widget.output.nonowned_process_buffer.id.?);
    }

    try processviewmgr.create_virtual_process_view(
        alloc,
        app_model,
        args[0],
        buffer_keys.items,
    );

    return;
}
