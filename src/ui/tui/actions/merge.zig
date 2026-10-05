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

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

const testing = std.testing;
const pump_mod = @import("pump");
const view_mod = @import("../view.zig");
const UiInbox = @import("../pipeline/ingeststore.zig").UiInbox;

/// A running pump and store with three process buffers (!0, !1, !2) and an output view
/// showing the first two as views ~10 and ~11. View and buffer numbers differ on purpose:
/// `~` must resolve through the views, `!` through the buffers.
const Fixture = struct {
    alloc: Allocator,
    io: Io,
    pump: *pump_mod.Pump,
    app_model: AppModel,
    ids: [3]UUID,

    fn init(alloc: Allocator, io: Io) !*Fixture {
        const self = try alloc.create(Fixture);
        errdefer alloc.destroy(self);
        const store = try AppModel.IngestStore.init(alloc, io);
        const pump = try pump_mod.Pump.init(alloc, io, store.sink(), .{});
        store.attach(pump);
        try pump.start();

        self.* = .{
            .alloc = alloc,
            .io = io,
            .pump = pump,
            .app_model = .{
                .model_view = try view_mod.View.init(alloc),
                .uiconfig = null,
                .store = store,
                .executor = undefined,
                .cmd = undefined,
                .entity_viewer = undefined,
            },
            .ids = undefined,
        };
        for (&self.ids, 0..) |*id, i| {
            const name = try std.fmt.allocPrint(alloc, "p{d}", .{i});
            defer alloc.free(name);
            id.* = try store.createBufferAsync(name);
            self.barrier();
            const pb = store.lookup(id.*).?;
            try self.app_model.buffer_infos.append(alloc, .{ .id = id.*, .strid = pb.strid, .name = try alloc.dupe(u8, name), .pb = pb });
        }
        const ov = try view_mod.OutputView.init(alloc);
        try self.app_model.model_view.add_outputview(ov, 0);
        for (self.ids[0..2], 0..) |id, i| {
            const ow = try view_mod.OutputWidget.init(alloc, "view", id, store.lookup(id).?, store);
            ow.strid = 10 + i;
            try ov.add_output(ow);
        }
        self.drainEvents();
        return self;
    }

    fn deinit(self: *Fixture) void {
        self.app_model.model_view.deinit(self.io);
        self.app_model.deinitBufferInfos(self.alloc);
        self.pump.stop();
        self.pump.deinit();
        self.app_model.store.deinit();
        self.alloc.destroy(self);
    }

    /// Returns once the pump has run everything posted before it.
    fn barrier(self: *Fixture) void {
        self.app_model.store.call(.{ .remove_all_filters = .{ .id = .{ .bytes = [_]u8{0xff} ** 16 } } }) catch unreachable;
    }

    fn drainEvents(self: *Fixture) void {
        const store = self.app_model.store;
        var events = store.inbox.drain();
        defer events.deinit(store.alloc);
        for (events.items) |ev| UiInbox.freeEvent(store.alloc, ev);
    }

    fn bufferCount(self: *Fixture) usize {
        const store = self.app_model.store;
        store.m.lockUncancelable(self.io);
        defer store.m.unlock(self.io);
        return store.map.count();
    }
};

/// What `merge` should do with `args`, worked out independently of the action: fail with
/// an error, or ask the pump for a merge of these parents.
const Expected = union(enum) {
    fail: anyerror,
    merge: struct { parents: [8]UUID = undefined, len: usize = 0 },
};

fn expectedOutcome(f: *Fixture, args: []const []const u8) Expected {
    if (args.len < 2) return .{ .fail = error.MergeCmdNotEnoughArgs };
    var out: Expected = .{ .merge = .{} };
    for (args[1..]) |arg| {
        if (!std.mem.eql(u8, arg, "--all")) continue;
        for (f.app_model.buffer_infos.items) |info| {
            out.merge.parents[out.merge.len] = info.id;
            out.merge.len += 1;
        }
        return out;
    }
    for (args[1..]) |arg| {
        if (arg.len < 2) return .{ .fail = error.InvalidBufferId };
        const n = std.fmt.parseInt(usize, arg[1..], 10) catch return .{ .fail = error.InvalidBufferId };
        const id: UUID = switch (arg[0]) {
            '~' => if (n == 10 or n == 11) f.ids[n - 10] else return .{ .fail = error.InvalidBufferId },
            '!' => blk: {
                for (f.app_model.buffer_infos.items) |info| {
                    if (info.strid == n) break :blk info.id;
                }
                return .{ .fail = error.InvalidBufferId };
            },
            else => return .{ .fail = error.InvalidBufferId },
        };
        out.merge.parents[out.merge.len] = id;
        out.merge.len += 1;
    }
    return out;
}

/// Runs `merge args` and checks the outcome: the error, or the merged buffer the pump built
/// (its name and its parents), or the store refusing a repeated parent.
fn runCase(f: *Fixture, args: []const []const u8) !void {
    const store = f.app_model.store;
    const before = f.bufferCount();
    const expected = expectedOutcome(f, args);
    const result = mergeProcessBuffers(f.io, f.alloc, &f.app_model, args);
    f.barrier();

    var created: ?UUID = null;
    var created_name_ok = false;
    var failed = false;
    {
        var events = store.inbox.drain();
        defer events.deinit(store.alloc);
        defer for (events.items) |ev| UiInbox.freeEvent(store.alloc, ev);
        for (events.items) |ev| switch (ev) {
            .buffer_created => |c| {
                created = c.id;
                created_name_ok = std.mem.eql(u8, c.name, args[0]);
            },
            .command_failed => failed = true,
            .buffer_removed => return error.TestUnexpectedResult,
        };
    }

    switch (expected) {
        .fail => |err| {
            try testing.expectError(err, result);
            try testing.expectEqual(before, f.bufferCount());
            try testing.expect(created == null and !failed);
        },
        .merge => |m| {
            try result;
            const parents = m.parents[0..m.len];
            var repeated = false;
            for (parents, 0..) |p, i| {
                if (containsId(parents[i + 1 ..], p)) repeated = true;
            }
            if (repeated) {
                // the pump refuses a merge that names the same buffer twice
                try testing.expect(failed and created == null);
                try testing.expectEqual(before, f.bufferCount());
                return;
            }
            try testing.expect(!failed);
            const id = created orelse return error.TestUnexpectedResult;
            try testing.expect(created_name_ok);
            const merged = store.lookup(id).?;
            var count: usize = 0;
            var it = store.graph.parents(merged.handle.?).?;
            while (it.next()) |h| {
                count += 1;
                const parent_id = store.graph.getObject(h).?.id.?;
                try testing.expect(containsId(parents, parent_id));
            }
            try testing.expectEqual(parents.len, count);
        },
    }
}

fn containsId(list: []const UUID, id: UUID) bool {
    for (list) |x| {
        if (std.meta.eql(x, id)) return true;
    }
    return false;
}

fn runCasePrinting(f: *Fixture, args: []const []const u8) !void {
    runCase(f, args) catch |err| {
        std.debug.print("\nmerge command case failed:", .{});
        for (args) |a| std.debug.print(" \"{s}\"", .{a});
        std.debug.print("\n", .{});
        return err;
    };
}

test "merge command: arguments resolve to the right buffers, bad ones are refused" {
    // the pump's warnings for the refused merges are expected
    testing.log_level = .err;
    defer testing.log_level = .warn;
    const f = try Fixture.init(testing.allocator, testing.io);
    defer f.deinit();
    const cases = [_][]const []const u8{
        &.{},
        &.{"m"},
        &.{ "m", "~10", "~11" },
        &.{ "m", "!0", "!2" },
        &.{ "m", "--all" },
        &.{ "m", "~11", "--all", "x" }, // --all wins over anything else
        &.{ "m", "~12" }, // no such view
        &.{ "m", "!3" }, // no such buffer
        &.{ "m", "~" },
        &.{ "m", "!" },
        &.{ "m", "" },
        &.{ "m", "x1" },
        &.{ "m", "~x" },
        &.{ "m", "!-1" },
        &.{ "m", "~99999999999999999999999" },
        &.{ "m", "~10", "~10" }, // the same view twice
        &.{ "m", "~10", "!0" }, // a view and the buffer it shows: the same parent twice
    };
    for (cases) |args| try runCasePrinting(f, args);
}

test "merge command: random argument lists end as resolved, never crash or leak" {
    testing.log_level = .err;
    defer testing.log_level = .warn;
    const f = try Fixture.init(testing.allocator, testing.io);
    defer f.deinit();
    const tokens = [_][]const u8{
        "--all", "~10", "~11", "~12", "~0",  "!0",   "!1",                       "!2",   "!3", "~",
        "!",     "",    "x1",  "~x",  "!-1", "~+10", "~99999999999999999999999", "--al", "m",  "!002",
    };
    var prng = std.Random.DefaultPrng.init(0x6d65_7267);
    const r = prng.random();
    var args: [6][]const u8 = undefined;
    for (0..1500) |_| {
        const n = r.intRangeAtMost(usize, 0, args.len);
        for (args[0..n]) |*a| a.* = tokens[r.uintLessThan(usize, tokens.len)];
        try runCasePrinting(f, args[0..n]);
    }
}
