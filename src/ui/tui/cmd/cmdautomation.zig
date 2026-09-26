const std = @import("std");
const Allocator = std.mem.Allocator;

// View selection types
const SelectStep = union(enum) {
    str: []const u8, // match on a view strid
    skip: void, // skip view selection
    all: void, // match on all views
};

const AutomationCmd = struct {
    select: SelectStep,
    cmd: []u8,

    pub fn deinit(self: AutomationCmd, alloc: Allocator) void {
        switch (self.select) {
            .str => |str| alloc.free(str),
            else => {},
        }
        alloc.free(self.cmd);
    }
};

pub fn parse_script(alloc: Allocator, script: []const u8) ![]AutomationCmd {
    var cmds = try std.ArrayList(AutomationCmd).initCapacity(alloc, 10);
    var iter = std.mem.tokenizeScalar(u8, script, '\n');
    while (iter.next()) |line| {
        const auto_cmd = try parse_line(alloc, line);
        try cmds.append(alloc, auto_cmd);
    }

    return try cmds.toOwnedSlice(alloc);
}

// A script line contains two parts seperated by a ':' char. The select part and then the command part.
// A script must have a ':', and a cmd part that is not zero length
// The select part can be in the form of { "" | "_" | "strid" } where "" means to not change the view selection
// "_" means the command is to be applied to all views and "strid" is to be applied to the relevant view
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
        // a zero length select slice....skip
        return .{
            .select = .skip,
            .cmd = try alloc.dupe(u8, cmd_slice),
        };
    } else if (std.mem.eql(u8, select_slice, "_")) {
        // a "_" means the command is applied to all views
        return .{
            .select = .all,
            .cmd = try alloc.dupe(u8, cmd_slice),
        };
    } else {
        return .{
            .select = .{ .str = try std.fmt.allocPrint(
                alloc,
                "{s}",
                .{select_slice},
            ) },
            .cmd = try alloc.dupe(u8, cmd_slice),
        };
    }
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

const testing = std.testing;

test "parse_line: the select part picks the step kind" {
    const alloc = testing.allocator;

    const skip = try parse_line(alloc, ": keep x");
    defer skip.deinit(alloc);
    try testing.expectEqual(SelectStep.skip, skip.select);
    try testing.expectEqualStrings("keep x", skip.cmd);

    const all = try parse_line(alloc, "  _ :  keep x  ");
    defer all.deinit(alloc);
    try testing.expectEqual(SelectStep.all, all.select);
    try testing.expectEqualStrings("keep x", all.cmd);

    const by_id = try parse_line(alloc, "~2: keep x");
    defer by_id.deinit(alloc);
    try testing.expectEqualStrings("~2", by_id.select.str);

    const by_name = try parse_line(alloc, "Print: hide Warning");
    defer by_name.deinit(alloc);
    try testing.expectEqualStrings("Print", by_name.select.str);
    try testing.expectEqualStrings("hide Warning", by_name.cmd);

    try testing.expectError(error.MissingSeperator, parse_line(alloc, "keep x"));
    try testing.expectError(error.NoCommandStr, parse_line(alloc, "~2:"));
}

test "parse_script: one step per line, blank lines ignored" {
    const alloc = testing.allocator;
    const steps = try parse_script(alloc, "_: color debug red\n\n: merge m --all\nPrint: hide Warning\n");
    defer {
        for (steps) |s| s.deinit(alloc);
        alloc.free(steps);
    }
    try testing.expectEqual(3, steps.len);
    try testing.expectEqual(SelectStep.all, steps[0].select);
    try testing.expectEqual(SelectStep.skip, steps[1].select);
    try testing.expectEqualStrings("Print", steps[2].select.str);
}
