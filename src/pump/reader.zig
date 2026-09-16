//! Per-process ingest: spawn a child with piped stdout/stderr, read both pipes into the
//! pump, and reap the process. Readers own their pipe handles; the child's `wait`/`kill`
//! cleanup therefore never closes a handle a reader is blocked on.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const utils = @import("utils");

const msg = @import("msg.zig");
const Pump = @import("pump.zig").Pump;

pub const UUID = msg.UUID;
pub const Term = msg.Term;
pub const Stream = msg.Stream;

pub const chunk_size: usize = 4096;

/// Everything the pump needs to know about one spawned process. Heap allocated so the
/// `Child` and the events have stable addresses for the tasks that reference them.
pub const ProcIngest = struct {
    alloc: Allocator,
    id: UUID,
    child: std.process.Child,
    /// Copy of the process id/handle taken at spawn, used by `terminate`.
    raw_id: std.process.Child.Id,
    /// stdout reader, stderr reader, waiter
    group: Io.Group = .init,
    tasks_remaining: std.atomic.Value(u8) = .init(3),
    /// set when all three tasks have returned
    all_done: Io.Event = .unset,
    /// set when `wait` has returned (the process is reaped)
    exited: Io.Event = .unset,
    term: ?Term = null,

    fn taskFinished(self: *ProcIngest, io: Io) void {
        if (self.tasks_remaining.fetchSub(1, .acq_rel) == 1) {
            self.all_done.set(io);
        }
    }

    /// Asks the OS to kill the process. Signal only: the waiter task does the single
    /// `wait` + cleanup. Idempotent, ignores errors, no-op once the process has been reaped.
    pub fn terminate(self: *ProcIngest) void {
        if (self.exited.isSet()) return;
        switch (builtin.os.tag) {
            .windows => {
                _ = std.os.windows.ntdll.NtTerminateProcess(self.raw_id, @enumFromInt(1));
            },
            .wasi => {},
            else => {
                std.posix.kill(self.raw_id, .KILL) catch {};
            },
        }
    }

    /// Terminates the process, gives the readers `grace` to drain to EOF, then cancels any
    /// task still blocked (a grandchild may be holding the pipe open) and joins all three.
    /// Never hangs.
    pub fn shutdown(self: *ProcIngest, io: Io, grace: Io.Duration) void {
        self.terminate();
        self.all_done.waitTimeout(io, .{ .duration = .{ .raw = grace, .clock = .awake } }) catch {};
        self.group.cancel(io);
    }

    /// Only valid after `shutdown` or once `all_done` is set.
    pub fn destroy(self: *ProcIngest) void {
        std.debug.assert(self.all_done.isSet());
        self.alloc.destroy(self);
    }
};

/// Mints a buffer id, announces it to the pump, spawns the process and starts its tasks.
/// On spawn failure the error is reported into the (already announced) buffer and returned.
pub fn launch(
    io: Io,
    alloc: Allocator,
    pump: *Pump,
    name: []const u8,
    argv: []const []const u8,
    environ_map: ?*std.process.Environ.Map,
) !*ProcIngest {
    const id = utils.uuid.newV4(io);

    const name_copy = try pump.alloc.dupe(u8, name);
    pump.submit(io, .{ .create_buffer = .{ .id = id, .name = name_copy } }) catch |err| {
        pump.alloc.free(name_copy);
        return err;
    };

    const child = std.process.spawn(io, .{
        .argv = argv,
        .environ_map = environ_map,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| {
        const text = std.fmt.allocPrint(pump.alloc, "!!! failed to spawn \"{s}\": {t} !!!\n", .{ argv[0], err }) catch return err;
        pump.submit(io, .{ .bytes = .{ .id = id, .stream = .stderr, .data = text } }) catch pump.alloc.free(text);
        return err;
    };

    const ing = try alloc.create(ProcIngest);
    errdefer alloc.destroy(ing);
    ing.* = .{
        .alloc = alloc,
        .id = id,
        .child = child,
        .raw_id = child.id.?,
    };

    // Take ownership of the pipe handles so wait/kill cleanup cannot close them.
    const out = ing.child.stdout.?;
    ing.child.stdout = null;
    const err_pipe = ing.child.stderr.?;
    ing.child.stderr = null;

    try startTasks(io, pump, ing, out, err_pipe);
    return ing;
}

fn startTasks(io: Io, pump: *Pump, ing: *ProcIngest, out: Io.File, err_pipe: Io.File) Io.ConcurrentError!void {
    ing.group.concurrent(io, readPipe, .{ io, pump, ing, .stdout, out }) catch |e| {
        // nothing started: close the pipes ourselves, reap the child
        out.close(io);
        err_pipe.close(io);
        ing.child.kill(io);
        return e;
    };
    ing.group.concurrent(io, readPipe, .{ io, pump, ing, .stderr, err_pipe }) catch |e| {
        err_pipe.close(io);
        ing.child.kill(io);
        ing.group.cancel(io);
        return e;
    };
    ing.group.concurrent(io, waitChild, .{ io, pump, ing }) catch |e| {
        ing.child.kill(io);
        ing.group.cancel(io);
        return e;
    };
}

/// Reads one pipe to EOF, forwarding every chunk to the pump. Always posts exactly one
/// `stream_eof` on the way out and closes the pipe. If the pump has been closed the pipe is
/// still drained so the child never blocks on a full pipe.
fn readPipe(io: Io, pump: *Pump, ing: *ProcIngest, stream: Stream, file: Io.File) Io.Cancelable!void {
    defer ing.taskFinished(io);
    defer file.close(io);

    var buf: [chunk_size]u8 = undefined;
    var end_err: ?anyerror = null;
    var canceled = false;
    var discard = false;

    while (true) {
        const n = file.readStreaming(io, &.{&buf}) catch |err| switch (err) {
            error.EndOfStream => break,
            error.Canceled => {
                canceled = true;
                break;
            },
            else => {
                end_err = err;
                break;
            },
        };
        if (n == 0) continue; // legal short read, not EOF
        if (discard) continue;

        const copy = pump.alloc.dupe(u8, buf[0..n]) catch {
            end_err = error.OutOfMemory;
            break;
        };
        pump.submit(io, .{ .bytes = .{ .id = ing.id, .stream = stream, .data = copy } }) catch |err| switch (err) {
            error.Closed => {
                pump.alloc.free(copy);
                discard = true; // keep draining so the child can finish
            },
            error.Canceled => {
                pump.alloc.free(copy);
                canceled = true;
                break;
            },
        };
    }

    pump.submitUncancelable(io, .{ .stream_eof = .{ .id = ing.id, .stream = stream, .err = end_err } }) catch {};
    if (canceled) return error.Canceled;
}

/// The single designated caller of `Child.wait`.
fn waitChild(io: Io, pump: *Pump, ing: *ProcIngest) Io.Cancelable!void {
    defer ing.taskFinished(io);

    const term: ?Term = ing.child.wait(io) catch |err| switch (err) {
        error.Canceled => {
            // The process may still be running; make sure it is not left behind.
            ing.terminate();
            ing.term = ing.child.wait(io) catch null;
            ing.exited.set(io);
            pump.submitUncancelable(io, .{ .process_exited = .{ .id = ing.id, .term = ing.term } }) catch {};
            return error.Canceled;
        },
        else => null,
    };
    ing.term = term;
    ing.exited.set(io);
    pump.submitUncancelable(io, .{ .process_exited = .{ .id = ing.id, .term = term } }) catch {};
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

const testing = std.testing;
const Pump_ = @import("pump.zig");

const CaptureSink = struct {
    alloc: Allocator,
    stdout: std.ArrayList(u8) = .empty,
    stderr: std.ArrayList(u8) = .empty,
    eofs: [2]usize = .{ 0, 0 },
    exits: usize = 0,
    term: ?Term = null,
    created: usize = 0,

    fn sink(self: *CaptureSink) Pump_.Sink {
        return .{ .ctx = self, .vtable = &vtable };
    }
    const vtable: Pump_.Sink.VTable = .{
        .createBuffer = createBuffer,
        .bytes = bytes,
        .streamEof = streamEof,
        .processExited = processExited,
        .endBatch = endBatch,
        .shutdown = shutdown,
    };
    fn createBuffer(ctx: *anyopaque, _: UUID, _: []const u8) void {
        const self: *CaptureSink = @ptrCast(@alignCast(ctx));
        self.created += 1;
    }
    fn bytes(ctx: *anyopaque, _: UUID, stream: Stream, data: []const u8) void {
        const self: *CaptureSink = @ptrCast(@alignCast(ctx));
        const list = switch (stream) {
            .stdout => &self.stdout,
            .stderr => &self.stderr,
        };
        list.appendSlice(self.alloc, data) catch unreachable;
    }
    fn streamEof(ctx: *anyopaque, _: UUID, stream: Stream, _: ?anyerror) void {
        const self: *CaptureSink = @ptrCast(@alignCast(ctx));
        self.eofs[@intFromEnum(stream)] += 1;
    }
    fn processExited(ctx: *anyopaque, _: UUID, term: ?Term) void {
        const self: *CaptureSink = @ptrCast(@alignCast(ctx));
        self.exits += 1;
        self.term = term;
    }
    fn endBatch(_: *anyopaque) void {}
    fn shutdown(_: *anyopaque) void {}
    fn deinit(self: *CaptureSink) void {
        self.stdout.deinit(self.alloc);
        self.stderr.deinit(self.alloc);
    }
};

fn shellArgv(comptime script: []const u8) []const []const u8 {
    return switch (builtin.os.tag) {
        .windows => &.{ "cmd.exe", "/c", script },
        else => &.{ "sh", "-c", script },
    };
}

test "reader: both streams captured, one eof each, one exit with the process' code" {
    const alloc = testing.allocator;
    const io = testing.io;

    var sink: CaptureSink = .{ .alloc = alloc };
    defer sink.deinit();
    const pump = try Pump.init(alloc, io, sink.sink(), .{});
    defer pump.deinit();
    try pump.start();

    const argv = switch (builtin.os.tag) {
        .windows => shellArgv("echo out & echo err 1>&2 & exit 3"),
        else => shellArgv("echo out; echo err 1>&2; exit 3"),
    };
    const ing = try launch(io, alloc, pump, "test", argv, null);
    defer ing.destroy();

    try ing.all_done.wait(io);
    pump.stop();

    try testing.expectEqual(1, sink.created);
    try testing.expect(std.mem.indexOf(u8, sink.stdout.items, "out") != null);
    try testing.expect(std.mem.indexOf(u8, sink.stderr.items, "err") != null);
    try testing.expectEqual(1, sink.eofs[0]);
    try testing.expectEqual(1, sink.eofs[1]);
    try testing.expectEqual(1, sink.exits);
    try testing.expectEqual(Term{ .exited = 3 }, sink.term.?);
}

test "reader: backpressure through a tiny queue loses nothing" {
    const alloc = testing.allocator;
    const io = testing.io;

    var sink: CaptureSink = .{ .alloc = alloc };
    defer sink.deinit();
    const pump = try Pump.init(alloc, io, sink.sink(), .{ .queue_len = 4, .batch_len = 2 });
    defer pump.deinit();
    try pump.start();

    const lines = 5000;
    const argv = switch (builtin.os.tag) {
        .windows => shellArgv("for /L %i in (1,1,5000) do @echo line %i"),
        else => shellArgv("i=0; while [ $i -lt 5000 ]; do echo line $i; i=$((i+1)); done"),
    };
    const ing = try launch(io, alloc, pump, "test", argv, null);
    defer ing.destroy();

    try ing.all_done.wait(io);
    pump.stop();

    try testing.expectEqual(lines, std.mem.count(u8, sink.stdout.items, "\n"));
}

test "reader: shutdown of a sleeping child returns promptly" {
    const alloc = testing.allocator;
    const io = testing.io;

    var sink: CaptureSink = .{ .alloc = alloc };
    defer sink.deinit();
    const pump = try Pump.init(alloc, io, sink.sink(), .{});
    defer pump.deinit();
    try pump.start();

    const argv = switch (builtin.os.tag) {
        .windows => shellArgv("ping -n 30 127.0.0.1 > nul"),
        else => shellArgv("sleep 30"),
    };
    const ing = try launch(io, alloc, pump, "sleeper", argv, null);
    defer ing.destroy();

    const start = Io.Timestamp.now(io, .awake);
    ing.shutdown(io, .fromMilliseconds(500));
    const elapsed = start.durationTo(Io.Timestamp.now(io, .awake));
    try testing.expect(elapsed.toSeconds() < 5);
    try testing.expect(ing.all_done.isSet());
    try testing.expect(ing.exited.isSet());

    pump.stop();
    try testing.expectEqual(1, sink.eofs[0]);
    try testing.expectEqual(1, sink.eofs[1]);
    try testing.expectEqual(1, sink.exits);
}
