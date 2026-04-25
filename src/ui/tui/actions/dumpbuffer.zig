const std = @import("std");
const utils_ = @import("utils");

const uuid = utils_.uuid;

pub fn dumpOutputBuffer(
    alloc: std.mem.Allocator,
    buffer: []const u8,
    output_guid: uuid.UUID,
    output_name: []const u8,
) !void {
    var writer_buf: [2048]u8 = undefined;

    var uuid_str: [36]u8 = undefined;
    output_guid.to_string(&uuid_str);

    var file_name = try std.mem.concat(alloc, u8, &.{ output_name, "-", &uuid_str });
    defer alloc.free(file_name);

    if (@import("builtin").target.os.tag == .windows) {
        const temp_str = file_name;
        file_name = try utils_.makeWindowsSafeFilename(alloc, file_name);
        alloc.free(temp_str);
    }

    const file = try std.fs.cwd().createFile(
        file_name,
        .{ .truncate = true },
    );
    defer file.close();

    var w = file.writer(&writer_buf);
    var writer = &w.interface;

    try writer.writeAll(buffer);

    try writer.flush();
}
