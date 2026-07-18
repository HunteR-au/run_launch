const std = @import("std");

const Allocator = std.mem.Allocator;

const SelectStep = union(enum) {
    str: []const u8,
    skip: void,
    all: void,
};

const AutomationCmd = struct {
    select: SelectStep,
    cmd: []const u8,

    pub fn deinit(self: AutomationCmd, alloc: Allocator) void {
        switch (self.select) {
            .str => |str| alloc.free(str),
            else => {},
        }
        alloc.free(self.cmd);
    }
};

const SelectCmd = "select";

pub fn parse_script(alloc: Allocator, script: []const u8) ![]AutomationCmd {
    var autos = try std.ArrayList(AutomationCmd).initCapacity(alloc, 10);
    var iter = std.mem.tokenizeScalar(u8, script, '\n');
    while (iter.next()) |line| {
        const auto_cmd = try parse_line(alloc, line);
        try autos.append(alloc, auto_cmd);
    }

    return try autos.toOwnedSlice(alloc);
}

pub fn parse_line(alloc: Allocator, line: []const u8) !AutomationCmd {
    const buffer = std.mem.trim(
        u8,
        line,
        &std.ascii.whitespace,
    );

    const sep_position = std.mem.findScalar(
        u8,
        buffer,
        ':',
    ) orelse return error.MissingSeperator;

    if (sep_position == buffer.len - 1) return error.NoCommandStr;

    const select_slice = std.mem.trim(
        u8,
        buffer[0..sep_position],
        &std.ascii.whitespace,
    );
    const cmd_slice = std.mem.trim(
        u8,
        buffer[sep_position + 1 ..],
        &std.ascii.whitespace,
    );

    if (select_slice.len == 0) {
        return .{
            .select = .skip,
            .cmd = try alloc.dupe(u8, cmd_slice),
        };
    } else if (std.mem.eql(u8, select_slice, "_")) {
        return .{
            .select = .all,
            .cmd = try alloc.dupe(u8, cmd_slice),
        };
    } else {
        return .{
            .select = .{ .str = try std.fmt.allocPrint(
                alloc,
                "{s} {s}",
                .{ SelectCmd, select_slice },
            ) },
            .cmd = try alloc.dupe(u8, cmd_slice),
        };
    }
}
