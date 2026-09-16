//! The pump-side owner of every ProcessBuffer.
//!
//! Implements `pump.Sink`: raw chunks, stream EOFs and process exits arrive here on the pump
//! thread and are applied to the buffers, propagated into merge children and run through
//! the pipelines. The UI never mutates buffers; it posts `PumpCommand`s which execute here,
//! and it learns about new/removed buffers through the `UiInbox`.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const utils = @import("utils");
const pump_ = @import("pump");

const processbuffer = @import("processbuffer.zig");
const Graph = @import("buffer/acyclicgraph.zig");
const merge = @import("buffer/merge.zig");
const dumpbuffer = @import("../actions/dumpbuffer.zig");

pub const ProcessBuffer = processbuffer.ProcessBuffer;
pub const Filter = processbuffer.Filter;
pub const Reviewer = processbuffer.Reviewer;
pub const BufferGraph = Graph.AcyclicGraph(ProcessBuffer);
pub const GraphHandle = Graph.Handle;
pub const Pump = pump_.Pump;
pub const Stream = pump_.Stream;
pub const Term = pump_.Term;
pub const UUID = utils.uuid.UUID;

/// Work the UI asks the pump to do. Payload slices are allocated by the poster from the
/// pump allocator and owned by the command once posted.
pub const PumpCommand = union(enum) {
    remove_buffer: struct { id: UUID },
    add_filter: struct { id: UUID, filter: Filter },
    remove_filter: struct { id: UUID, fid: Filter.HandleId },
    remove_all_filters: struct { id: UUID },
    add_reviewer: struct { id: UUID, reviewer: Reviewer },
    remove_reviewer: struct { id: UUID, rid: Reviewer.HandleId },
    remove_all_reviewers: struct { id: UUID },
    reset_pipeline: struct { id: UUID },
    /// Creates a merged buffer `id` named `name` whose lines are the parents' lines in
    /// sequence order, kept live as the parents grow.
    create_merge: struct { id: UUID, name: []u8, parents: []UUID },
    dump: struct { id: UUID, backing: ProcessBuffer.BufferBacking },
};

/// Events the pump reports to the UI thread. Payload slices are owned by the event; the UI
/// takes ownership when it drains the inbox.
pub const UiEvent = union(enum) {
    buffer_created: struct { id: UUID, strid: usize, name: []u8, pb: *ProcessBuffer },
    buffer_removed: struct { id: UUID },
    command_failed: struct { id: ?UUID, what: []u8 },
};

/// Mutex-protected list the pump pushes into and the UI swaps out on its tick, so the pump
/// never blocks on the UI.
pub const UiInbox = struct {
    io: Io,
    alloc: Allocator,
    m: std.Io.Mutex = .init,
    events: std.ArrayList(UiEvent) = .empty,

    pub fn push(self: *UiInbox, ev: UiEvent) void {
        self.m.lockUncancelable(self.io);
        defer self.m.unlock(self.io);
        self.events.append(self.alloc, ev) catch {
            std.log.err("ui inbox: dropping event, out of memory", .{});
            freeEvent(self.alloc, ev);
        };
    }

    /// Returns and clears the pending events. The caller owns the list and its payloads.
    pub fn drain(self: *UiInbox) std.ArrayList(UiEvent) {
        self.m.lockUncancelable(self.io);
        defer self.m.unlock(self.io);
        const out = self.events;
        self.events = .empty;
        return out;
    }

    pub fn freeEvent(alloc: Allocator, ev: UiEvent) void {
        switch (ev) {
            .buffer_created => |c| alloc.free(c.name),
            .command_failed => |f| alloc.free(f.what),
            .buffer_removed => {},
        }
    }

    pub fn deinit(self: *UiInbox) void {
        for (self.events.items) |ev| freeEvent(self.alloc, ev);
        self.events.deinit(self.alloc);
    }
};

pub const IngestStore = struct {
    alloc: Allocator,
    io: Io,
    /// Guards `map` for the UI's `lookup`; everything else is pump-thread-only.
    m: std.Io.Mutex = .init,
    map: std.AutoHashMapUnmanaged(UUID, *ProcessBuffer) = .empty,
    graph: BufferGraph,
    next_seq: u64 = 0,
    strid_counter: usize = 0,
    inbox: UiInbox,
    pump: ?*Pump = null,

    pub fn init(alloc: Allocator, io: Io) !*IngestStore {
        const self = try alloc.create(IngestStore);
        errdefer alloc.destroy(self);
        self.* = .{
            .alloc = alloc,
            .io = io,
            .graph = try .init(alloc),
            .inbox = .{ .io = io, .alloc = alloc },
        };
        return self;
    }

    /// Call after the pump has been stopped: frees every buffer and the graph.
    pub fn deinit(self: *IngestStore) void {
        var it = self.map.valueIterator();
        while (it.next()) |pb| pb.*.deinit();
        self.map.deinit(self.alloc);
        self.graph.deinit();
        self.inbox.deinit();
        self.alloc.destroy(self);
    }

    pub fn sink(self: *IngestStore) pump_.Sink {
        return .{ .ctx = self, .vtable = &sink_vtable };
    }

    /// The pump this store posts commands to. Must be set before `post`/`createBufferAsync`.
    pub fn attach(self: *IngestStore, p: *Pump) void {
        self.pump = p;
    }

    // ------------------------------------------------------------------
    // UI-side API
    // ------------------------------------------------------------------

    pub const PostError = error{ Closed, OutOfMemory, NoPump };

    /// Fire-and-forget: executes `cmd` on the pump thread. Ownership of the command's
    /// payload transfers on success; on failure the payload is freed here.
    pub fn post(self: *IngestStore, cmd: PumpCommand) PostError!void {
        const p = self.pump orelse {
            freeCommandPayload(self.alloc, cmd);
            return error.NoPump;
        };
        const boxed = p.alloc.create(PumpCommand) catch {
            freeCommandPayload(self.alloc, cmd);
            return error.OutOfMemory;
        };
        boxed.* = cmd;
        p.postCommand(self.io, .{ .run = runCommand, .ctx = self, .payload = boxed }) catch |err| {
            freeCommandPayload(self.alloc, cmd);
            p.alloc.destroy(boxed);
            return err;
        };
    }

    /// Like `post` but blocks until the command has executed.
    pub fn call(self: *IngestStore, cmd: PumpCommand) PostError!void {
        const p = self.pump orelse {
            freeCommandPayload(self.alloc, cmd);
            return error.NoPump;
        };
        const boxed = p.alloc.create(PumpCommand) catch {
            freeCommandPayload(self.alloc, cmd);
            return error.OutOfMemory;
        };
        boxed.* = cmd;
        p.callCommand(self.io, .{ .run = runCommand, .ctx = self, .payload = boxed }) catch |err| {
            freeCommandPayload(self.alloc, cmd);
            p.alloc.destroy(boxed);
            return err;
        };
    }

    /// Mints an id and asks the pump to create a buffer for it. The UI learns about the
    /// buffer (and creates its view) through the inbox.
    pub fn createBufferAsync(self: *IngestStore, name: []const u8) PostError!UUID {
        const p = self.pump orelse return error.NoPump;
        const id = utils.uuid.newV4(self.io);
        const copy = try p.alloc.dupe(u8, name);
        p.submitUncancelable(self.io, .{ .create_buffer = .{ .id = id, .name = copy } }) catch |err| {
            p.alloc.free(copy);
            return err;
        };
        return id;
    }

    /// Appends text to a buffer as if a process had written it (help text, notices).
    pub fn writeText(self: *IngestStore, id: UUID, text: []const u8) PostError!void {
        const p = self.pump orelse return error.NoPump;
        const copy = try p.alloc.dupe(u8, text);
        p.submitUncancelable(self.io, .{ .bytes = .{ .id = id, .stream = .stdout, .data = copy } }) catch |err| {
            p.alloc.free(copy);
            return err;
        };
    }

    /// UI-callable lookup. The returned pointer stays valid until the UI itself posts
    /// `remove_buffer` for it.
    pub fn lookup(self: *IngestStore, id: UUID) ?*ProcessBuffer {
        self.m.lockUncancelable(self.io);
        defer self.m.unlock(self.io);
        return self.map.get(id);
    }

    // ------------------------------------------------------------------
    // Sink implementation (pump thread)
    // ------------------------------------------------------------------

    const sink_vtable: pump_.Sink.VTable = .{
        .createBuffer = sinkCreateBuffer,
        .bytes = sinkBytes,
        .streamEof = sinkStreamEof,
        .processExited = sinkProcessExited,
        .endBatch = sinkEndBatch,
        .shutdown = sinkShutdown,
    };

    fn fromCtx(ctx: *anyopaque) *IngestStore {
        return @ptrCast(@alignCast(ctx));
    }

    fn sinkCreateBuffer(ctx: *anyopaque, id: UUID, name: []const u8) void {
        const self = fromCtx(ctx);
        if (self.map.get(id)) |pb| {
            // bytes arrived before the announcement; just name the buffer
            pb.setName(name) catch {};
            return;
        }
        _ = self.createBuffer(id, name) catch |err| {
            std.log.err("could not create buffer \"{s}\": {t}", .{ name, err });
        };
    }

    fn sinkBytes(ctx: *anyopaque, id: UUID, stream: Stream, data: []const u8) void {
        const self = fromCtx(ctx);
        _ = stream;
        const pb = self.getOrCreate(id) orelse return;
        self.ingest(pb, data) catch |err| std.log.err("ingest failed: {t}", .{err});
    }

    fn sinkStreamEof(ctx: *anyopaque, id: UUID, stream: Stream, err: ?anyerror) void {
        const self = fromCtx(ctx);
        const pb = self.map.get(id) orelse return;
        if (err) |e| {
            var buf: [128]u8 = undefined;
            if (std.fmt.bufPrint(&buf, "!!! {t} read error: {t} !!!\n", .{ stream, e })) |line| {
                self.ingest(pb, line) catch {};
            } else |_| {}
        }
        pb.end_state.eof[@intFromEnum(stream)] = true;
        self.maybeEnd(pb);
    }

    fn sinkProcessExited(ctx: *anyopaque, id: UUID, term: ?Term) void {
        const self = fromCtx(ctx);
        const pb = self.map.get(id) orelse return;
        pb.end_state.exited = true;
        pb.end_state.term = term;
        self.maybeEnd(pb);
    }

    fn sinkEndBatch(_: *anyopaque) void {}

    fn sinkShutdown(_: *anyopaque) void {}

    // ------------------------------------------------------------------
    // Pump-thread internals
    // ------------------------------------------------------------------

    fn createBuffer(self: *IngestStore, id: UUID, name: []const u8) !*ProcessBuffer {
        const pb = try ProcessBuffer.init(self.io, self.alloc);
        errdefer pb.deinit();

        pb.id = id;
        pb.strid = self.strid_counter;
        self.strid_counter += 1;
        try pb.setName(name);
        pb.handle = try self.graph.createNode(pb);
        errdefer self.graph.removeNode(pb.handle.?);

        {
            self.m.lockUncancelable(self.io);
            defer self.m.unlock(self.io);
            try self.map.put(self.alloc, id, pb);
        }

        const ui_name = try self.alloc.dupe(u8, name);
        self.inbox.push(.{ .buffer_created = .{ .id = id, .strid = pb.strid, .name = ui_name, .pb = pb } });
        return pb;
    }

    fn getOrCreate(self: *IngestStore, id: UUID) ?*ProcessBuffer {
        if (self.map.get(id)) |pb| return pb;
        return self.createBuffer(id, "?") catch |err| {
            std.log.err("could not create buffer for unknown id: {t}", .{err});
            return null;
        };
    }

    /// Appends a chunk, propagates the new lines into merge children and runs the pipelines.
    fn ingest(self: *IngestStore, pb: *ProcessBuffer, data: []const u8) Allocator.Error!void {
        const nl = try pb.appendChunk(data, &self.next_seq);
        try self.propagate(pb, nl);
        try pb.processPipeline();
    }

    fn propagate(self: *IngestStore, parent: *ProcessBuffer, nl: NewLines) Allocator.Error!void {
        if (nl.count == 0) return;
        const handle = parent.handle orelse return;
        var it = self.graph.children(handle) orelse return;
        while (it.next()) |child_handle| {
            const child = self.graph.getObject(child_handle) orelse continue; // stale: skip
            const cnl = try child.appendLinesWithSeq(parent.linesRange(nl), parent.seqsRange(nl));
            try self.propagate(child, cnl);
            try child.processPipeline();
        }
    }

    const NewLines = processbuffer.NewLines;

    /// Appends the single end-of-process marker once both streams have hit EOF and the
    /// process has been reaped, regardless of the order those three events arrived in.
    fn maybeEnd(self: *IngestStore, pb: *ProcessBuffer) void {
        const s = &pb.end_state;
        if (s.ended or !s.exited or !s.eof[0] or !s.eof[1]) return;
        s.ended = true;

        var buf: [128]u8 = undefined;
        const line = if (s.term) |term| switch (term) {
            .exited => |code| std.fmt.bufPrint(&buf, "--- process exited: code {d} ---\n", .{code}),
            .signal => |sig| std.fmt.bufPrint(&buf, "--- process killed by signal {t} ---\n", .{sig}),
            .stopped => |sig| std.fmt.bufPrint(&buf, "--- process stopped by signal {t} ---\n", .{sig}),
            .unknown => |v| std.fmt.bufPrint(&buf, "--- process ended: unknown status {d} ---\n", .{v}),
        } else std.fmt.bufPrint(&buf, "--- process ended: wait failed ---\n", .{});
        self.ingest(pb, line catch return) catch {};
    }

    fn fail(self: *IngestStore, id: ?UUID, comptime fmt: []const u8, args: anytype) void {
        const what = std.fmt.allocPrint(self.alloc, fmt, args) catch return;
        std.log.warn("pump command failed: {s}", .{what});
        self.inbox.push(.{ .command_failed = .{ .id = id, .what = what } });
    }

    fn freeCommandPayload(alloc: Allocator, cmd: PumpCommand) void {
        switch (cmd) {
            .add_filter => |c| {
                var f = c.filter;
                f.deinit();
            },
            .add_reviewer => |c| {
                var r = c.reviewer;
                r.deinit();
            },
            .create_merge => |c| {
                alloc.free(c.name);
                alloc.free(c.parents);
            },
            else => {},
        }
    }

    fn runCommand(ctx: *anyopaque, payload: ?*anyopaque) void {
        const self = fromCtx(ctx);
        const boxed: *PumpCommand = @ptrCast(@alignCast(payload.?));
        defer if (self.pump) |p| p.alloc.destroy(boxed);
        self.execute(boxed.*) catch |err| std.log.err("pump command failed: {t}", .{err});
    }

    fn execute(self: *IngestStore, cmd: PumpCommand) Allocator.Error!void {
        switch (cmd) {
            .remove_buffer => |c| self.removeBuffer(c.id),
            .add_filter => |c| {
                const pb = self.map.get(c.id) orelse {
                    freeCommandPayload(self.alloc, cmd);
                    return self.fail(c.id, "add_filter: unknown buffer", .{});
                };
                try pb.addFilter(c.filter);
            },
            .remove_filter => |c| if (self.map.get(c.id)) |pb| try pb.removeFilter(c.fid),
            .remove_all_filters => |c| if (self.map.get(c.id)) |pb| try pb.removeAllFilters(),
            .add_reviewer => |c| {
                const pb = self.map.get(c.id) orelse {
                    freeCommandPayload(self.alloc, cmd);
                    return self.fail(c.id, "add_reviewer: unknown buffer", .{});
                };
                try pb.addReviewer(c.reviewer);
            },
            .remove_reviewer => |c| if (self.map.get(c.id)) |pb| try pb.removeReviewer(c.rid),
            .remove_all_reviewers => |c| if (self.map.get(c.id)) |pb| try pb.removeAllReviewers(),
            .reset_pipeline => |c| if (self.map.get(c.id)) |pb| try pb.resetPipeline(),
            .create_merge => |c| {
                defer {
                    const p_alloc = if (self.pump) |p| p.alloc else self.alloc;
                    p_alloc.free(c.name);
                    p_alloc.free(c.parents);
                }
                try self.createMerge(c.id, c.name, c.parents);
            },
            .dump => |c| {
                const pb = self.map.get(c.id) orelse return;
                dumpbuffer.dumpOutputBuffer(self.io, self.alloc, pb.rawBytes(c.backing), c.id, pb.displayName()) catch |err| {
                    self.fail(c.id, "dump failed: {t}", .{err});
                };
            },
        }
    }

    fn removeBuffer(self: *IngestStore, id: UUID) void {
        const pb = blk: {
            self.m.lockUncancelable(self.io);
            defer self.m.unlock(self.io);
            const kv = self.map.fetchRemove(id) orelse return;
            break :blk kv.value;
        };
        if (pb.handle) |h| self.graph.removeNode(h);
        pb.deinit();
        self.inbox.push(.{ .buffer_removed = .{ .id = id } });
    }

    /// Builds a merged buffer from `parents` in one pump step. No parent locks are needed:
    /// the pump is the only writer, so the snapshot is complete and every later propagation
    /// carries strictly newer sequence numbers.
    fn createMerge(self: *IngestStore, id: UUID, name: []const u8, parent_ids: []const UUID) Allocator.Error!void {
        if (self.map.contains(id)) return self.fail(id, "merge: id already exists", .{});

        var parents = try std.ArrayList(*ProcessBuffer).initCapacity(self.alloc, parent_ids.len);
        defer parents.deinit(self.alloc);
        for (parent_ids) |pid| {
            const pb = self.map.get(pid) orelse return self.fail(id, "merge: unknown parent buffer", .{});
            for (parents.items) |existing| {
                if (existing == pb) return self.fail(id, "merge: duplicate parent", .{});
            }
            parents.appendAssumeCapacity(pb);
        }
        if (parents.items.len == 0) return self.fail(id, "merge: no parents", .{});

        const child = try ProcessBuffer.init(self.io, self.alloc);
        errdefer child.deinit();
        child.id = id;
        child.strid = self.strid_counter;
        self.strid_counter += 1;
        try child.setName(name);
        child.handle = try self.graph.createNode(child);
        errdefer self.graph.removeNode(child.handle.?);

        try merge.mergeBySeq(self.alloc, parents.items, &child.buffer, &child.line_seqs);

        for (parents.items) |parent| {
            self.graph.addChild(parent.handle.?, child.handle.?) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return self.fail(id, "merge: {t}", .{err}),
            };
        }

        try child.processPipeline();

        {
            self.m.lockUncancelable(self.io);
            defer self.m.unlock(self.io);
            try self.map.put(self.alloc, id, child);
        }
        const ui_name = try self.alloc.dupe(u8, name);
        self.inbox.push(.{ .buffer_created = .{ .id = id, .strid = child.strid, .name = ui_name, .pb = child } });
    }
};

// ------------------------------------------------------------------
// Tests: drive the store directly (no pump thread) through its sink vtable
// ------------------------------------------------------------------

const testing = std.testing;

fn idFrom(n: u8) UUID {
    return .{ .bytes = [_]u8{n} ** 16 };
}

fn drainAndFree(store: *IngestStore) usize {
    var events = store.inbox.drain();
    defer events.deinit(store.alloc);
    for (events.items) |ev| UiInbox.freeEvent(store.alloc, ev);
    return events.items.len;
}

test "store: CRLF across chunks, sequence numbers across buffers, end marker once" {
    const alloc = testing.allocator;
    const io = testing.io;
    const store = try IngestStore.init(alloc, io);
    defer store.deinit();
    const s = store.sink();

    s.vtable.createBuffer(s.ctx, idFrom(1), "a");
    s.vtable.createBuffer(s.ctx, idFrom(2), "b");
    try testing.expectEqual(2, drainAndFree(store));

    s.vtable.bytes(s.ctx, idFrom(1), .stdout, "a\r\nb\r");
    s.vtable.bytes(s.ctx, idFrom(2), .stdout, "x\n");
    s.vtable.bytes(s.ctx, idFrom(1), .stdout, "\nc");

    const a = store.map.get(idFrom(1)).?;
    const b = store.map.get(idFrom(2)).?;
    try testing.expectEqualStrings("a\nb\nc", a.buffer.buf.items);
    try testing.expectEqualSlices(u64, &.{ 1, 3 }, a.line_seqs.items);
    try testing.expectEqualSlices(u64, &.{2}, b.line_seqs.items);

    // end marker only after both eofs and the exit, in any order
    s.vtable.processExited(s.ctx, idFrom(1), .{ .exited = 0 });
    s.vtable.streamEof(s.ctx, idFrom(1), .stderr, null);
    try testing.expect(std.mem.indexOf(u8, a.buffer.buf.items, "process exited") == null);
    s.vtable.streamEof(s.ctx, idFrom(1), .stdout, null);
    try testing.expectEqual(1, std.mem.count(u8, a.buffer.buf.items, "--- process exited: code 0 ---"));
    // duplicates do not add a second marker
    s.vtable.streamEof(s.ctx, idFrom(1), .stdout, null);
    try testing.expectEqual(1, std.mem.count(u8, a.buffer.buf.items, "--- process exited"));
}

test "store: merge orders by sequence, follows live parents and survives parent removal" {
    const alloc = testing.allocator;
    const io = testing.io;
    const store = try IngestStore.init(alloc, io);
    defer store.deinit();
    const s = store.sink();

    s.vtable.createBuffer(s.ctx, idFrom(1), "A");
    s.vtable.createBuffer(s.ctx, idFrom(2), "B");
    s.vtable.bytes(s.ctx, idFrom(1), .stdout, "A1\nA2\n");
    s.vtable.bytes(s.ctx, idFrom(2), .stdout, "B3\n");
    s.vtable.bytes(s.ctx, idFrom(1), .stdout, "A4\n");
    _ = drainAndFree(store);

    const parents = try alloc.dupe(UUID, &.{ idFrom(1), idFrom(2) });
    const name = try alloc.dupe(u8, "M");
    try store.execute(.{ .create_merge = .{ .id = idFrom(9), .name = name, .parents = parents } });

    const m = store.map.get(idFrom(9)).?;
    try testing.expectEqualStrings("A1\nA2\nB3\nA4\n", m.buffer.buf.items);
    try testing.expectEqualStrings("A1\nA2\nB3\nA4\n", m.filtered_buffer.buf.items); // history rendered immediately
    try testing.expectEqualSlices(u64, &.{ 1, 2, 3, 4 }, m.line_seqs.items);
    try testing.expectEqual(1, drainAndFree(store));

    // live appends keep arrival order
    s.vtable.bytes(s.ctx, idFrom(2), .stdout, "B5\n");
    s.vtable.bytes(s.ctx, idFrom(1), .stdout, "A6\n");
    try testing.expectEqualStrings("A1\nA2\nB3\nA4\nB5\nA6\n", m.filtered_buffer.buf.items);

    // removing a parent leaves the child intact and later bytes for it are ignored
    try store.execute(.{ .remove_buffer = .{ .id = idFrom(1) } });
    try testing.expectEqual(null, store.map.get(idFrom(1)));
    s.vtable.bytes(s.ctx, idFrom(2), .stdout, "B7\n");
    try testing.expectEqualStrings("A1\nA2\nB3\nA4\nB5\nA6\nB7\n", m.filtered_buffer.buf.items);
    try testing.expectEqual(1, drainAndFree(store)); // buffer_removed

    // a merge of a merge resolves too
    const parents2 = try alloc.dupe(UUID, &.{ idFrom(9), idFrom(2) });
    const name2 = try alloc.dupe(u8, "MM");
    try store.execute(.{ .create_merge = .{ .id = idFrom(10), .name = name2, .parents = parents2 } });
    try testing.expect(store.map.get(idFrom(10)) != null);
    _ = drainAndFree(store);
}

test "store: unknown parent in merge reports a failure event and creates nothing" {
    const alloc = testing.allocator;
    const io = testing.io;
    // The failure below is expected; keep its warning out of the test output (the build
    // runner shows any stderr from a test binary under a misleading "failed command" line).
    testing.log_level = .err;
    defer testing.log_level = .warn;

    const store = try IngestStore.init(alloc, io);
    defer store.deinit();

    const parents = try alloc.dupe(UUID, &.{idFrom(42)});
    const name = try alloc.dupe(u8, "M");
    try store.execute(.{ .create_merge = .{ .id = idFrom(9), .name = name, .parents = parents } });
    try testing.expectEqual(null, store.map.get(idFrom(9)));

    var events = store.inbox.drain();
    defer events.deinit(alloc);
    defer for (events.items) |ev| UiInbox.freeEvent(alloc, ev);
    try testing.expectEqual(1, events.items.len);
    try testing.expect(events.items[0] == .command_failed);
}
