//! The data pump: one queue, one consumer thread, one `Sink` that owns all the buffers.
//!
//! Producers (reader tasks, the runner, the UI) submit `Msg`s; the pump thread drains them
//! in FIFO order and hands each to the sink. Backpressure is natural: a full queue blocks
//! the producer, which for a reader task means the child's pipe fills and the child blocks.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const msg = @import("msg.zig");
pub const reader = @import("reader.zig");
pub const Msg = msg.Msg;
pub const Command = msg.Command;
pub const Stream = msg.Stream;
pub const Term = msg.Term;
pub const UUID = msg.UUID;

/// What the pump feeds. All callbacks run on the pump thread, one at a time.
pub const Sink = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        createBuffer: *const fn (ctx: *anyopaque, id: UUID, name: []const u8) void,
        bytes: *const fn (ctx: *anyopaque, id: UUID, stream: Stream, data: []const u8) void,
        streamEof: *const fn (ctx: *anyopaque, id: UUID, stream: Stream, err: ?anyerror) void,
        processExited: *const fn (ctx: *anyopaque, id: UUID, term: ?Term) void,
        /// Called once after every drained batch.
        endBatch: *const fn (ctx: *anyopaque) void,
        /// Called once, after the queue has been closed and fully drained.
        shutdown: *const fn (ctx: *anyopaque) void,
    };
};

pub const Pump = struct {
    io: Io,
    /// Must be thread safe: producers allocate message payloads with it and the pump frees them.
    alloc: Allocator,
    storage: []Msg,
    queue: Io.Queue(Msg),
    sink: Sink,
    batch_len: usize,
    thread: ?std.Thread = null,
    /// Bumped once per drained batch; a cheap "anything changed" signal for the UI.
    version: std.atomic.Value(u64) = .init(0),
    stopped: std.atomic.Value(bool) = .init(false),

    pub const Options = struct {
        queue_len: usize = 1024,
        batch_len: usize = 64,
    };

    pub const SubmitError = error{ Closed, Canceled };

    pub fn init(alloc: Allocator, io: Io, sink: Sink, opts: Options) Allocator.Error!*Pump {
        const self = try alloc.create(Pump);
        errdefer alloc.destroy(self);
        const storage = try alloc.alloc(Msg, opts.queue_len);
        self.* = .{
            .io = io,
            .alloc = alloc,
            .storage = storage,
            .queue = .init(storage),
            .sink = sink,
            .batch_len = opts.batch_len,
        };
        return self;
    }

    /// Asserts the pump has been stopped (or was never started).
    pub fn deinit(self: *Pump) void {
        std.debug.assert(self.thread == null);
        // Anything still queued was never handed to the sink: free owned payloads.
        var buf: [1]Msg = undefined;
        while (true) {
            const n = self.queue.getUncancelable(self.io, &buf, 0) catch break;
            if (n == 0) break;
            self.freePayload(&buf[0]);
        }
        self.alloc.free(self.storage);
        self.alloc.destroy(self);
    }

    pub fn start(self: *Pump) std.Thread.SpawnError!void {
        std.debug.assert(self.thread == null);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    /// Closes the queue, lets the pump drain everything already accepted, and joins it.
    /// Producers that submit after this get `error.Closed`.
    pub fn stop(self: *Pump) void {
        self.stopped.store(true, .release);
        self.queue.close(self.io);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    pub fn isStopped(self: *const Pump) bool {
        return self.stopped.load(.acquire);
    }

    /// Blocking submit (backpressure). Cancelable.
    pub fn submit(self: *Pump, io: Io, m: Msg) SubmitError!void {
        try self.queue.putOne(io, m);
    }

    /// Blocking submit that is not a cancelation point (for end-of-stream bookkeeping that
    /// must arrive even while the task is being canceled).
    pub fn submitUncancelable(self: *Pump, io: Io, m: Msg) error{Closed}!void {
        try self.queue.putOneUncancelable(io, m);
    }

    /// Non-blocking submit. Returns false when the queue is full.
    pub fn trySubmit(self: *Pump, io: Io, m: Msg) error{Closed}!bool {
        return (try self.queue.putUncancelable(io, &.{m}, 0)) == 1;
    }

    /// Fire-and-forget command executed on the pump thread.
    pub fn postCommand(self: *Pump, io: Io, cmd: Command) error{Closed}!void {
        try self.submitUncancelable(io, .{ .command = cmd });
    }

    /// Runs `cmd` on the pump thread and blocks until it has completed.
    pub fn callCommand(self: *Pump, io: Io, cmd: Command) error{Closed}!void {
        var done: Io.Event = .unset;
        var c = cmd;
        c.done = &done;
        try self.submitUncancelable(io, .{ .command = c });
        done.waitUncancelable(io);
    }

    pub fn changeVersion(self: *const Pump) u64 {
        return self.version.load(.acquire);
    }

    fn freePayload(self: *Pump, m: *const Msg) void {
        switch (m.*) {
            .bytes => |b| self.alloc.free(b.data),
            .create_buffer => |c| self.alloc.free(c.name),
            .command => |c| if (c.done) |d| d.set(self.io),
            else => {},
        }
    }

    fn dispatch(self: *Pump, m: *const Msg) void {
        const s = self.sink;
        switch (m.*) {
            .bytes => |b| {
                s.vtable.bytes(s.ctx, b.id, b.stream, b.data);
                self.alloc.free(b.data);
            },
            .stream_eof => |e| s.vtable.streamEof(s.ctx, e.id, e.stream, e.err),
            .process_exited => |p| s.vtable.processExited(s.ctx, p.id, p.term),
            .create_buffer => |c| {
                s.vtable.createBuffer(s.ctx, c.id, c.name);
                self.alloc.free(c.name);
            },
            .command => |c| {
                c.run(c.ctx, c.payload);
                if (c.done) |d| d.set(self.io);
            },
        }
    }

    fn run(self: *Pump) void {
        const io = self.io;
        const batch = self.alloc.alloc(Msg, self.batch_len) catch {
            std.log.err("pump: could not allocate its batch buffer", .{});
            return;
        };
        defer self.alloc.free(batch);

        while (true) {
            // Blocks until at least one message is available, then takes everything that is
            // already buffered up to `batch_len`. After `close` the remaining items are still
            // delivered before `error.Closed`.
            const n = self.queue.getUncancelable(io, batch, 1) catch |err| switch (err) {
                error.Closed => break,
            };
            for (batch[0..n]) |*m| self.dispatch(m);
            self.sink.vtable.endBatch(self.sink.ctx);
            _ = self.version.fetchAdd(1, .release);
        }
        self.sink.vtable.shutdown(self.sink.ctx);
    }
};

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

const testing = std.testing;

const RecordingSink = struct {
    alloc: Allocator,
    received: std.ArrayList(struct { producer: u8, seq: u32 }) = .empty,
    batches: usize = 0,
    shutdowns: usize = 0,
    created: std.ArrayList([]u8) = .empty,

    fn sink(self: *RecordingSink) Sink {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: Sink.VTable = .{
        .createBuffer = createBuffer,
        .bytes = bytes,
        .streamEof = streamEof,
        .processExited = processExited,
        .endBatch = endBatch,
        .shutdown = shutdown,
    };

    fn createBuffer(ctx: *anyopaque, _: UUID, name: []const u8) void {
        const self: *RecordingSink = @ptrCast(@alignCast(ctx));
        self.created.append(self.alloc, self.alloc.dupe(u8, name) catch unreachable) catch unreachable;
    }
    fn bytes(ctx: *anyopaque, _: UUID, _: Stream, data: []const u8) void {
        const self: *RecordingSink = @ptrCast(@alignCast(ctx));
        // data is "<producer>:<seq>"
        const colon = std.mem.indexOfScalar(u8, data, ':').?;
        const prod = std.fmt.parseInt(u8, data[0..colon], 10) catch unreachable;
        const seq = std.fmt.parseInt(u32, data[colon + 1 ..], 10) catch unreachable;
        self.received.append(self.alloc, .{ .producer = prod, .seq = seq }) catch unreachable;
    }
    fn streamEof(_: *anyopaque, _: UUID, _: Stream, _: ?anyerror) void {}
    fn processExited(_: *anyopaque, _: UUID, _: ?Term) void {}
    fn endBatch(ctx: *anyopaque) void {
        const self: *RecordingSink = @ptrCast(@alignCast(ctx));
        self.batches += 1;
    }
    fn shutdown(ctx: *anyopaque) void {
        const self: *RecordingSink = @ptrCast(@alignCast(ctx));
        self.shutdowns += 1;
    }

    fn deinit(self: *RecordingSink) void {
        for (self.created.items) |n| self.alloc.free(n);
        self.created.deinit(self.alloc);
        self.received.deinit(self.alloc);
    }
};

fn producer(io: Io, pump: *Pump, id: u8, count: u32) Io.Cancelable!void {
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const data = std.fmt.allocPrint(pump.alloc, "{d}:{d}", .{ id, i }) catch return;
        pump.submit(io, .{ .bytes = .{ .id = .{ .bytes = [_]u8{0} ** 16 }, .stream = .stdout, .data = data } }) catch |err| switch (err) {
            error.Canceled => |e| {
                pump.alloc.free(data);
                return e;
            },
            error.Closed => {
                pump.alloc.free(data);
                return;
            },
        };
    }
}

test "pump: fan-in from several producers preserves per-producer order and frees payloads" {
    const alloc = testing.allocator;
    const io = testing.io;

    var sink: RecordingSink = .{ .alloc = alloc };
    defer sink.deinit();

    // a tiny queue forces producers to block on backpressure
    const pump = try Pump.init(alloc, io, sink.sink(), .{ .queue_len = 8, .batch_len = 4 });
    defer pump.deinit();
    try pump.start();

    const producers = 4;
    const per_producer = 500;
    var group: Io.Group = .init;
    var i: u8 = 0;
    while (i < producers) : (i += 1) {
        try group.concurrent(io, producer, .{ io, pump, i, per_producer });
    }
    try group.await(io);

    pump.stop();

    try testing.expectEqual(producers * per_producer, sink.received.items.len);
    var last: [producers]?u32 = .{null} ** producers;
    for (sink.received.items) |r| {
        if (last[r.producer]) |prev| try testing.expect(r.seq == prev + 1) else try testing.expectEqual(0, r.seq);
        last[r.producer] = r.seq;
    }
    try testing.expect(sink.batches >= 1);
    try testing.expectEqual(1, sink.shutdowns);
}

test "pump: commands run on the pump thread and submits after stop are refused" {
    const alloc = testing.allocator;
    const io = testing.io;

    var sink: RecordingSink = .{ .alloc = alloc };
    defer sink.deinit();

    const pump = try Pump.init(alloc, io, sink.sink(), .{});
    defer pump.deinit();
    try pump.start();

    const Ctx = struct {
        ran_on: ?std.Thread.Id = null,
        fn run(ctx: *anyopaque, _: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.ran_on = std.Thread.getCurrentId();
        }
    };
    var ctx: Ctx = .{};
    try pump.callCommand(io, .{ .run = Ctx.run, .ctx = &ctx });
    try testing.expect(ctx.ran_on != null);
    try testing.expect(ctx.ran_on.? != std.Thread.getCurrentId());
    try testing.expectEqual(pump.thread.?.getHandle(), pump.thread.?.getHandle());

    const name = try alloc.dupe(u8, "view");
    try pump.submit(io, .{ .create_buffer = .{ .id = .{ .bytes = [_]u8{1} ** 16 }, .name = name } });

    pump.stop();
    try testing.expectEqual(1, sink.created.items.len);
    try testing.expectEqualStrings("view", sink.created.items[0]);

    try testing.expectError(error.Closed, pump.postCommand(io, .{ .run = Ctx.run, .ctx = &ctx }));
    const late = try alloc.dupe(u8, "late");
    pump.submit(io, .{ .create_buffer = .{ .id = .{ .bytes = [_]u8{2} ** 16 }, .name = late } }) catch |err| {
        try testing.expectEqual(error.Closed, err);
        alloc.free(late);
    };
}

test {
    _ = reader;
}
