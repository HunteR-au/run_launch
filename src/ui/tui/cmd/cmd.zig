const std = @import("std");
const Io = std.Io;
const utils = @import("utils");
const Output = @import("../outputwidget.zig").Output;
const CmdWidget = @import("../cmd//cmdwidget.zig").CmdWidget;
const CmdHinter = @import("cmdhints.zig").CommandHinter;
const CmdAutomation = @import("cmdautomation.zig");
const cmdevents = @import("cmdevents.zig");

const vxfw = @import("vaxis").vxfw;

const StaticRingBuffer = utils.ringbuffers.StaticRingBuffer;

pub const Handler = struct {
    listener: *anyopaque,
    handle: HandleFn,
    event_str: []const u8,
    arg_description: ?[]const u8 = null,
};

const HandlerRef = struct {
    handler: Handler,
    id: HandleId,
};

pub const HandleEventFn = fn (ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void;
pub const HandleRawFn = fn (io: Io, args: []const u8, listener: *anyopaque, info: DispatchInfo) std.mem.Allocator.Error!void;
pub const HandleId = usize;

pub const HandleFn = union(enum) {
    regular_fn: *const HandleRawFn,
    event_fn: *const HandleEventFn,
};

pub const Scope = enum { focused, all };

// Used to express the intent of the command being broadcasted. The handler can use
// this to decided how to act.
pub const DispatchInfo = struct {
    // .focused: only the focused output should action the command
    // .all: every output should action the command
    scope: Scope = .focused,
};

pub const Cmd = struct {
    pub const Info = DispatchInfo;
    // what does this do
    // needs to process a command
    // --- pub/sub model
    // --- subscribe to events with an handler
    // --- --- publish an event
    const max_history: comptime_int = 20;

    alloc: std.mem.Allocator,
    handlers: std.ArrayList(HandlerRef),
    lastHandleId: usize = 0,
    history: StaticRingBuffer([]u8, max_history),
    hinter: CmdHinter,

    view: CmdWidget,

    pub fn init(alloc: std.mem.Allocator) !*Cmd {
        const self = try alloc.create(Cmd);
        self.* = .{
            .handlers = try .initCapacity(alloc, 10),
            .history = .init(),
            .alloc = alloc,
            .view = try .init(alloc, self),
            .hinter = try .init(alloc),
        };
        return self;
    }

    pub fn deinit(self: *Cmd) void {
        self.view.deinit();
        self.hinter.deinit();
        self.handlers.deinit(self.alloc);
        var iter = self.history.iterator();
        while (iter.next()) |i| self.alloc.free(i);
        self.alloc.destroy(self);
    }

    /// Runs a script (see `cmdautomation.parse_line` for the line format). Each line is
    /// dispatched exactly as if it had been typed in the command bar: a `~n:`/`name:` select
    /// step becomes a `view` command first, a `_:` step is delivered with `.scope = .all`.
    pub fn run_script(self: *const Cmd, io: Io, script: []const u8, ctx: *vxfw.EventContext) !void {
        const autos = try CmdAutomation.parse_script(self.alloc, script);
        defer {
            for (autos) |a| a.deinit(self.alloc);
            self.alloc.free(autos);
        }

        for (autos) |step| {
            switch (step.select) {
                .str => |target| {
                    // select the output, then run the cmd on it
                    const select_cmd = try std.fmt.allocPrint(self.alloc, "view {s}", .{target});
                    defer self.alloc.free(select_cmd);
                    try self.dispatch(io, select_cmd, ctx, .{});
                    try self.dispatch(io, step.cmd, ctx, .{});
                },
                .skip => try self.dispatch(io, step.cmd, ctx, .{}),
                .all => try self.dispatch(io, step.cmd, ctx, .{ .scope = .all }),
            }
        }
    }

    /// Delivers one command line with the same `run_cmd` event the command bar sends, so
    /// event handlers (`q`, `merge`, `stop`, `view`, ...) read their arguments from it.
    fn dispatch(self: *const Cmd, io: Io, cmd_str: []u8, ctx: *vxfw.EventContext, info: Info) !void {
        // the event only has to outlive this synchronous call
        const run_event = cmdevents.CmdEvent{ .run_cmd = .{ .cmd_str = cmd_str } };
        try self.handleCmd(io, cmd_str, info, ctx, cmdevents.makeEvent(&run_event));
    }

    pub fn handleCmd(self: *const Cmd, io: Io, buffer: []const u8, info: Cmd.Info, ctx: *vxfw.EventContext, event: vxfw.Event) !void {
        const index = findFirstChar(buffer, ' ');

        // parse the key/args
        var key: []const u8 = undefined;
        var args: []const u8 = undefined;
        if (index) |idx| {
            key = buffer[0..idx];
            args = buffer[idx + 1 ..];
        } else {
            key = buffer;
            args = "";
        }

        // find all matching handlers
        var matches: std.ArrayList(HandlerRef) = try .initCapacity(self.alloc, 10);
        defer matches.deinit(self.alloc);
        for (self.handlers.items) |obj| {
            if (std.mem.eql(u8, key, obj.handler.event_str)) {
                try matches.append(self.alloc, obj);
            }
        }

        // run matched handlers
        for (matches.items) |*match| {
            const h = match.handler;
            switch (h.handle) {
                .regular_fn => |func| try func(io, args, h.listener, info),
                .event_fn => |func| try func(h.listener, ctx, event),
            }
        }
    }

    pub fn addHandler(self: *Cmd, handler: Handler) !HandleId {
        self.lastHandleId = self.lastHandleId +| 1;
        try self.handlers.append(self.alloc, .{ .handler = handler, .id = self.lastHandleId });
        try self.hinter.addCommandInfo(.{
            .commandName = handler.event_str,
            .argumentDescription = handler.arg_description,
        });
        return self.lastHandleId;
    }

    pub fn removeHandler(self: *Cmd, id: HandleId) void {
        for (self.handlers.items, 0..) |*h, i| {
            if (h.id == id) {
                _ = self.handlers.swapRemove(i);
                break;
            }
        }
    }

    pub fn addHistory(self: *Cmd, buffer: []const u8) !void {
        // the ring overwrites the oldest entry when full; free it first
        if (self.history.isFull()) self.alloc.free(try self.history.pop());
        try self.history.push(try self.alloc.dupe(u8, buffer), true);
    }

    pub fn getHistory(self: *Cmd, idx: usize) ?[]const u8 {
        const history_count = self.history.count();
        if (idx >= history_count) {
            return null;
        }

        return self.history.get(idx) catch {
            std.debug.panic(
                "getHistory OOB error - index: {d} capacity: {d} ",
                .{ idx, history_count },
            );
        };
    }

    fn findFirstChar(s: []const u8, token: u8) ?usize {
        for (s, 0..) |c, i| {
            if (c == token) return i;
        }
        return null;
    }
};

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

const testing = std.testing;

/// Records the `run_cmd` event every dispatched command line arrives with.
const EventProbe = struct {
    alloc: std.mem.Allocator,
    seen: std.ArrayList([]u8) = .empty,

    fn handle(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        _ = ctx;
        const self: *EventProbe = @ptrCast(@alignCast(ptr));
        const cmd_event = cmdevents.getCmdEvent(event.app) orelse return error.NotACmdEvent;
        const run = switch (cmd_event.*) {
            .run_cmd => |r| r,
            else => return error.NotARunCmd,
        };
        try self.seen.append(self.alloc, try self.alloc.dupe(u8, run.cmd_str));
    }

    fn deinit(self: *EventProbe) void {
        for (self.seen.items) |s| self.alloc.free(s);
        self.seen.deinit(self.alloc);
    }
};

test "run_script hands event handlers a run_cmd event and selects views first" {
    const alloc = testing.allocator;
    const io = testing.io;

    const cmd = try Cmd.init(alloc);
    defer cmd.deinit();

    var probe: EventProbe = .{ .alloc = alloc };
    defer probe.deinit();
    for ([_][]const u8{ "view", "probe" }) |name| {
        _ = try cmd.addHandler(.{
            .listener = &probe,
            .handle = .{ .event_fn = EventProbe.handle },
            .event_str = name,
        });
    }

    var ctx: vxfw.EventContext = .{ .io = io, .alloc = alloc, .cmds = .empty };
    try cmd.run_script(io, ": probe one\n~1: probe two\nPrint: probe three\n", &ctx);

    const expected = [_][]const u8{ "probe one", "view ~1", "probe two", "view Print", "probe three" };
    try testing.expectEqual(expected.len, probe.seen.items.len);
    for (expected, probe.seen.items) |want, got| try testing.expectEqualStrings(want, got);
}
