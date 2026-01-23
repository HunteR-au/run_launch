const std = @import("std");
const vaxis = @import("vaxis");

const vxfw = vaxis.vxfw;
const UserEvent = vxfw.UserEvent;

pub fn getCmdEvent(event: UserEvent) ?*const CmdEvent {
    inline for (@typeInfo(CmdEvent).@"union".fields) |field| {
        // Get the type of each field in the union
        const Payload = field.type;

        // check if it has the field name
        if (@hasDecl(Payload, "name")) {
            // Get the value of the field name
            const payload_name = @field(Payload, "name");

            if (std.mem.eql(u8, event.name, payload_name)) {
                if (event.data == null) {
                    return null;
                } else {
                    const cmd_event: ?*const CmdEvent = @ptrCast(@alignCast(event.data.?));
                    return cmd_event;
                }
            }
        }
    }
    // An invalid event
    return null;
}

pub fn makeEvent(event: *const CmdEvent) vxfw.Event {
    inline for (@typeInfo(CmdEvent).@"union".fields) |field| {
        const Payload = field.type;
        const name = @field(Payload, "name");

        const match: []const u8 = switch (event.*) {
            inline else => |payload| @field(@TypeOf(payload), "name"),
        };

        if (std.mem.eql(u8, name, match)) {
            return vxfw.Event{ .app = .{
                .name = name,
                .data = event,
            } };
        }
    }
    unreachable;
}

// Each tag in the union must have the field name
pub const CmdEvent = union(enum) {
    history_update: HistoryUpdateEvt,
    select_history: SelectHistoryEvt,
    cmdbar_change: CmdBarBufferChange,
};

pub const CmdBarBufferChange = struct {
    const name: []const u8 = "cmdbar_change";

    cmd_str: []const u8,
};

pub const HistoryUpdateEvt = struct {
    const name: []const u8 = "history_update";

    cmd_str: []u8,
    success: bool,
};

pub const SelectHistoryEvt = struct {
    const name: []const u8 = "select_history";

    cmd_str: []const u8,
    history_idx: u16,
};
