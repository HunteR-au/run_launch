const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const utils = @import("utils");
const config_ = @import("config");
const pump_ = @import("pump");
const argv_ = @import("argv.zig");

pub const Configuration = config_.Configuration;
const Process = config_.Process;
const Target = config_.Target;

pub const Pump = pump_.Pump;
pub const ProcIngest = pump_.reader.ProcIngest;
pub const Term = pump_.Term;

const uuid = utils.uuid;
const UUID = uuid.UUID;

/// How long `killAll` waits for a terminated process' readers to reach EOF before
/// cancelling them (a grandchild may be holding the pipes open).
const shutdown_grace: Io.Duration = .fromSeconds(2);

pub const RunnerContext = struct {
    /// Every process this runner has launched. Entries are stable heap pointers.
    procs: std.ArrayList(*ProcIngest),
};

/// Handle over what one `run`/`runStartup`/`runPostTasks` call started.
pub const WorkHandle = struct {
    _alloc: std.mem.Allocator,
    /// what the call spawned right away: pre tasks and processes without one
    children: std.ArrayList(*ProcIngest),
    /// the target's processes' buffer ids in configuration order, whether spawned already or
    /// still waiting for a pre task (`ConfiguredRunner.startReady` spawns those later)
    ids: std.ArrayList(UUID) = .empty,
    results: ?std.ArrayList(?Term) = null,

    /// Blocks until every spawned child has been reaped and records their exit terms.
    pub fn wait(self: *WorkHandle, io: Io) !void {
        if (self.results) |*r| r.clearRetainingCapacity() else self.results = try .initCapacity(self._alloc, self.children.items.len);

        for (self.children.items) |ing| {
            try ing.exited.wait(io);
            try self.results.?.append(self._alloc, ing.term);
        }
    }

    /// Blocks until every spawned child has been reaped AND its output fully read into the pump.
    pub fn waitAllDone(self: *WorkHandle, io: Io) !void {
        for (self.children.items) |ing| {
            try ing.all_done.wait(io);
        }
    }

    /// The view a `start` should land on: the target's last process, once it has one.
    pub fn focusId(self: *const WorkHandle) ?UUID {
        if (self.ids.items.len == 0) return null;
        return self.ids.items[self.ids.items.len - 1];
    }

    pub fn deinit(self: *WorkHandle) void {
        self.children.deinit(self._alloc);
        self.ids.deinit(self._alloc);
        if (self.results) |*r| r.deinit(self._alloc);
    }
};

pub const ConfiguredRunner = struct {
    _alloc: std.mem.Allocator,
    _context: RunnerContext,
    pump: *Pump,
    config: Configuration,
    m: std.Io.Mutex = .init,
    /// every process launched from the configuration, by buffer id (scripts are looked up
    /// by the id the UI reports, since a name may belong to a merged view too)
    launched: std.ArrayList(Launched) = .empty,
    /// group/startup scripts waiting for every one of their buffers to get a view
    pending_scripts: std.ArrayList(PendingScript) = .empty,
    /// processes waiting for a pre task to finish; `startReady` spawns them
    deferred: std.ArrayList(Deferred) = .empty,

    const Launched = struct { id: UUID, process: *const Process, ing: *ProcIngest };
    const PendingScript = struct { script: []const u8, pending: std.ArrayList(UUID) };
    const Deferred = struct {
        /// the process' buffer id, minted before it exists and kept across stages
        id: UUID,
        process: *const Process,
        /// the pre task it waits for (named when that task fails)
        task: *const Process,
        after: *ProcIngest,
        /// a group member: once the group's task is done its own pre task still has to run
        own_task_next: bool,
    };
    /// What stands between a process and its spawn.
    const Gate = union(enum) {
        none,
        after: struct { task: *const Process, ing: *ProcIngest },
        /// the pre task could not be spawned (its own buffer says why)
        failed: *const Process,
    };
    /// Within one start a task shared by several processes is spawned once.
    const GateMemo = std.ArrayList(struct { task: *const Process, gate: Gate });
    const ExecType = enum { blocking, nonBlocking };

    pub fn init(
        alloc: std.mem.Allocator,
        config: Configuration,
        pump: *Pump,
    ) !*ConfiguredRunner {
        const runner = try alloc.create(ConfiguredRunner);
        errdefer alloc.destroy(runner);

        runner.* = .{
            ._alloc = alloc,
            ._context = .{
                .procs = try .initCapacity(alloc, 1),
            },
            .pump = pump,
            .config = config,
        };
        return runner;
    }

    /// Must be called after `killAll`, when no other thread can touch the runner.
    pub fn deinit(self: *ConfiguredRunner, io: Io) void {
        _ = io;
        for (self._context.procs.items) |ing| ing.destroy();
        self._context.procs.deinit(self._alloc);
        self.launched.deinit(self._alloc);
        for (self.pending_scripts.items) |*ps| ps.pending.deinit(self._alloc);
        self.pending_scripts.deinit(self._alloc);
        self.deferred.deinit(self._alloc);
        self.config.deinit();
        self._alloc.destroy(self);
    }

    /// `name`, or with none the file's `default:`, or everything (see `Configuration.resolve`).
    fn resolve(self: *const ConfiguredRunner, name: ?[]const u8) !Target {
        return self.config.resolve(name) orelse error.NoConfigWithName;
    }

    /// Starts the process or group called `name` (what the `start` command does). Pre tasks
    /// are spawned now; a process behind one is spawned by `startReady` once that task has
    /// exited with code 0. The handle already holds every process' buffer id.
    pub fn run(self: *ConfiguredRunner, io: Io, name: []const u8) !WorkHandle {
        return self.launch(io, name, false);
    }

    /// Starts what the command line asked for: `name`, or with none the file's `default:`,
    /// or everything. The file's global script waits for these processes' views.
    pub fn runStartup(self: *ConfiguredRunner, io: Io, name: ?[]const u8) !WorkHandle {
        return self.launch(io, name, true);
    }

    fn launch(self: *ConfiguredRunner, io: Io, name: ?[]const u8, startup: bool) !WorkHandle {
        self.m.lockUncancelable(io);
        defer self.m.unlock(io);

        const target = try self.resolve(name);

        var handle: WorkHandle = .{ ._alloc = self._alloc, .children = try .initCapacity(self._alloc, 1) };
        errdefer handle.deinit();
        var memo: GateMemo = .empty;
        defer memo.deinit(self._alloc);

        switch (target) {
            .process => |p| {
                const gate = try self.gateFor(io, &memo, &handle, p.pre_task);
                try self.startGated(io, &handle, p, gate, false);
            },
            .group => |g| {
                // the group's task first; then every member behind its own (which `startReady`
                // starts once the group's task is done)
                const gate = try self.gateFor(io, &memo, &handle, g.pre_task);
                for (g.members) |p| {
                    switch (gate) {
                        .none => try self.startGated(io, &handle, p, try self.gateFor(io, &memo, &handle, p.pre_task), false),
                        .after, .failed => try self.startGated(io, &handle, p, gate, true),
                    }
                }
                if (g.script) |script| try self.armScript(script, handle.ids.items);
            },
            .all => |processes| {
                for (processes) |p| {
                    const gate = try self.gateFor(io, &memo, &handle, p.pre_task);
                    try self.startGated(io, &handle, p, gate, false);
                }
            },
        }
        if (startup) {
            if (self.config.script) |script| try self.armScript(script, handle.ids.items);
        }
        return handle;
    }

    /// The gate for a process whose pre task is `task` (null: none). A task shared by
    /// several processes of one start is spawned once (`memo`). A task that cannot be
    /// spawned gives `.failed`: its buffer already says why, and the processes behind it
    /// are announced instead of started.
    fn gateFor(self: *ConfiguredRunner, io: Io, memo: *GateMemo, handle: ?*WorkHandle, task: ?*const Process) !Gate {
        const t = task orelse return .none;
        for (memo.items) |entry| {
            if (entry.task == t) return entry.gate;
        }

        const gate: Gate = if (self.launchProcess(io, t, uuid.newV4(io))) |ing| blk: {
            if (handle) |h| try h.children.append(h._alloc, ing);
            break :blk .{ .after = .{ .task = t, .ing = ing } };
        } else |err| switch (err) {
            error.OutOfMemory, error.Closed, error.Canceled => return err,
            else => Gate{ .failed = t },
        };
        try memo.append(self._alloc, .{ .task = t, .gate = gate });
        return gate;
    }

    /// Spawns `p` now, or records it behind its gate. Its buffer id is minted here so the
    /// caller, the scripts and the focus request can hold it before the process exists.
    fn startGated(self: *ConfiguredRunner, io: Io, handle: *WorkHandle, p: *const Process, gate: Gate, own_task_next: bool) !void {
        const id = uuid.newV4(io);
        try handle.ids.append(handle._alloc, id);
        switch (gate) {
            .none => {
                const ing = try self.launchProcess(io, p, id);
                try handle.children.append(handle._alloc, ing);
            },
            .after => |a| try self.deferred.append(self._alloc, .{
                .id = id,
                .process = p,
                .task = a.task,
                .after = a.ing,
                .own_task_next = own_task_next,
            }),
            .failed => |task| try self.announceNotStarted(io, id, p, task, "could not be started"),
        }
    }

    /// Spawns `p` under its own name with buffer id `id` and starts its pump readers.
    fn launchProcess(self: *ConfiguredRunner, io: Io, p: *const Process, id: UUID) !*ProcIngest {
        var argv = try argv_.build(self._alloc, p);
        defer argv.deinit(self._alloc);

        var envmap: ?std.process.Environ.Map = null;
        defer if (envmap) |*m| m.deinit();
        if (p.env.len > 0) envmap = try utils.create_env_map(self._alloc, p.env);
        const envmap_ptr: ?*std.process.Environ.Map = if (envmap) |*m| m else null;

        const ing = try pump_.reader.launchWithId(io, self._alloc, self.pump, id, p.name, argv.items, envmap_ptr);
        try self._context.procs.append(self._alloc, ing);
        try self.launched.append(self._alloc, .{ .id = id, .process = p, .ing = ing });
        return ing;
    }

    /// The process gets a view under its own name whose only line says why it was not started.
    fn announceNotStarted(self: *ConfiguredRunner, io: Io, id: UUID, p: *const Process, task: *const Process, reason: []const u8) !void {
        pump_.reader.announceFailure(io, self.pump, id, p.name, "!!! {s} not started: preTask \"{s}\" {s} !!!\n", .{ p.name, task.name, reason }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => std.log.warn("{s}: could not report that it was not started: {t}", .{ p.name, err }),
        };
    }

    /// `script` runs once every id in `ids` has a view (nothing to wait for: never).
    fn armScript(self: *ConfiguredRunner, script: []const u8, ids: []const UUID) !void {
        if (ids.len == 0) return;
        var pending: std.ArrayList(UUID) = try .initCapacity(self._alloc, ids.len);
        errdefer pending.deinit(self._alloc);
        pending.appendSliceAssumeCapacity(ids);
        try self.pending_scripts.append(self._alloc, .{ .script = script, .pending = pending });
    }

    fn exitedOk(term: ?Term) bool {
        const t = term orelse return false;
        return switch (t) {
            .exited => |code| code == 0,
            else => false,
        };
    }

    /// Why a pre task does not count as done (the signal type is `void` on Windows, so
    /// signals are not spelled out).
    fn describeTerm(buf: []u8, term: ?Term) []const u8 {
        const t = term orelse return "could not be reaped";
        return switch (t) {
            .exited => |code| std.fmt.bufPrint(buf, "exited with code {d}", .{code}) catch "exited with an error",
            .signal => "was killed by a signal",
            .stopped => "was stopped by a signal",
            .unknown => |status| std.fmt.bufPrint(buf, "ended with status {d}", .{status}) catch "ended",
        };
    }

    /// A group member's own pre task, unless it is the task that just finished.
    fn ownTaskAfter(d: Deferred) ?*const Process {
        const own = d.process.pre_task orelse return null;
        return if (own == d.task) null else own;
    }

    /// Spawns every waiting process whose pre task has exited with code 0 and announces the
    /// ones whose task failed. The UI calls this every tick; tests call it directly. Never
    /// blocks. Returns the last process it spawned, for the UI to focus.
    pub fn startReady(self: *ConfiguredRunner, io: Io) !?UUID {
        self.m.lockUncancelable(io);
        defer self.m.unlock(io);

        var memo: GateMemo = .empty;
        defer memo.deinit(self._alloc);
        var focus: ?UUID = null;

        var i: usize = 0;
        while (i < self.deferred.items.len) {
            if (!self.deferred.items[i].after.exited.isSet()) {
                i += 1;
                continue;
            }
            // handled once, whatever happens next
            const d = self.deferred.orderedRemove(i);

            if (!exitedOk(d.after.term)) {
                var buf: [96]u8 = undefined;
                try self.announceNotStarted(io, d.id, d.process, d.task, describeTerm(&buf, d.after.term));
                continue;
            }

            if (d.own_task_next) {
                if (ownTaskAfter(d)) |own| {
                    switch (try self.gateFor(io, &memo, null, own)) {
                        .none => unreachable,
                        .after => |a| try self.deferred.append(self._alloc, .{
                            .id = d.id,
                            .process = d.process,
                            .task = a.task,
                            .after = a.ing,
                            .own_task_next = false,
                        }),
                        .failed => |task| try self.announceNotStarted(io, d.id, d.process, task, "could not be started"),
                    }
                    continue;
                }
            }

            _ = self.launchProcess(io, d.process, d.id) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    // the spawn failure is already in the process' buffer
                    std.log.warn("{s}: not started: {t}", .{ d.process.name, err });
                    continue;
                },
            };
            focus = d.id;
        }
        return focus;
    }

    /// The UI reports that buffer `id` now has a view. Returns the scripts to run now: the
    /// process' own, then every group/startup script whose last awaited view this was.
    /// The caller frees the slice; the strings belong to the configuration.
    pub fn viewCreated(self: *ConfiguredRunner, io: Io, alloc: std.mem.Allocator, id: UUID) std.mem.Allocator.Error![]const []const u8 {
        self.m.lockUncancelable(io);
        defer self.m.unlock(io);

        var out: std.ArrayList([]const u8) = .empty;
        errdefer out.deinit(alloc);

        for (self.launched.items) |l| {
            if (!std.meta.eql(l.id, id)) continue;
            if (l.process.script) |script| try out.append(alloc, script);
            break;
        }

        var i: usize = 0;
        while (i < self.pending_scripts.items.len) {
            const ps = &self.pending_scripts.items[i];
            for (ps.pending.items, 0..) |pending_id, j| {
                if (std.meta.eql(pending_id, id)) {
                    _ = ps.pending.swapRemove(j);
                    break;
                }
            }
            if (ps.pending.items.len == 0) {
                try out.append(alloc, ps.script);
                ps.pending.deinit(self._alloc);
                _ = self.pending_scripts.orderedRemove(i);
            } else {
                i += 1;
            }
        }
        return out.toOwnedSlice(alloc);
    }

    /// The post task(s) of what `name` refers to, spawned right away (a task's own pre/post
    /// tasks are not run): a process' own; a group's and each member's; for "everything"
    /// each process' own. A task shared by several entries starts once.
    pub fn runPostTasks(self: *ConfiguredRunner, io: Io, name: ?[]const u8, exec_type: ExecType) !WorkHandle {
        self.m.lockUncancelable(io);
        defer self.m.unlock(io);

        const target = try self.resolve(name);

        var handle: WorkHandle = .{ ._alloc = self._alloc, .children = try .initCapacity(self._alloc, 1) };
        errdefer handle.deinit();
        var seen: std.ArrayList(*const Process) = .empty;
        defer seen.deinit(self._alloc);

        switch (target) {
            .process => |p| try self.startPostTask(io, &handle, &seen, p.post_task),
            .group => |g| {
                try self.startPostTask(io, &handle, &seen, g.post_task);
                for (g.members) |p| try self.startPostTask(io, &handle, &seen, p.post_task);
            },
            .all => |processes| {
                for (processes) |p| try self.startPostTask(io, &handle, &seen, p.post_task);
            },
        }

        switch (exec_type) {
            .blocking => try handle.wait(io),
            .nonBlocking => {},
        }
        return handle;
    }

    fn startPostTask(self: *ConfiguredRunner, io: Io, handle: *WorkHandle, seen: *std.ArrayList(*const Process), task: ?*const Process) !void {
        const t = task orelse return;
        for (seen.items) |s| {
            if (s == t) return;
        }
        try seen.append(self._alloc, t);
        const ing = self.launchProcess(io, t, uuid.newV4(io)) catch |err| switch (err) {
            error.OutOfMemory, error.Closed, error.Canceled => return err,
            else => {
                // the spawn failure is in the task's buffer; the other tasks still run
                std.log.warn("post task {s}: not started: {t}", .{ t.name, err });
                return;
            },
        };
        try handle.children.append(handle._alloc, ing);
    }

    /// Asks the OS to kill the process whose output buffer is `id` (the `stop` command).
    /// Signal only, never blocks: the process' waiter task reaps it and its readers drain
    /// the pipes as usual. Returns false when no launched process owns that buffer (a
    /// merged/help buffer, or a process still waiting for its pre task) - nothing to do then.
    pub fn terminateProcess(self: *ConfiguredRunner, io: Io, id: uuid.UUID) bool {
        self.m.lockUncancelable(io);
        defer self.m.unlock(io);

        for (self._context.procs.items) |ing| {
            if (std.meta.eql(ing.id, id)) {
                ing.terminate();
                return true;
            }
        }
        return false;
    }

    /// Terminates every launched process and joins its reader/waiter tasks; processes still
    /// waiting for a pre task are dropped, so nothing starts after this. Never hangs.
    pub fn killAll(self: *ConfiguredRunner, io: Io) !void {
        self.m.lockUncancelable(io);
        defer self.m.unlock(io);

        self.deferred.clearRetainingCapacity();
        for (self._context.procs.items) |ing| {
            ing.shutdown(io, shutdown_grace);
        }
    }
};

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

const testing = std.testing;

/// The runner only produces; for these tests the pump can drop everything.
const NullSink = struct {
    fn sink(self: *NullSink) pump_.Sink {
        return .{ .ctx = self, .vtable = &vtable };
    }
    const vtable: pump_.Sink.VTable = .{
        .createBuffer = struct {
            fn f(_: *anyopaque, _: uuid.UUID, _: []const u8) void {}
        }.f,
        .bytes = struct {
            fn f(_: *anyopaque, _: uuid.UUID, _: pump_.Stream, _: []const u8) void {}
        }.f,
        .streamEof = struct {
            fn f(_: *anyopaque, _: uuid.UUID, _: pump_.Stream, _: ?anyerror) void {}
        }.f,
        .processExited = struct {
            fn f(_: *anyopaque, _: uuid.UUID, _: ?Term) void {}
        }.f,
        .endBatch = struct {
            fn f(_: *anyopaque) void {}
        }.f,
        .shutdown = struct {
            fn f(_: *anyopaque) void {}
        }.f,
    };
};

/// Records buffer announcements and stderr lines. Read it only after `pump.stop()`, which
/// joins the pump thread (the same rule reader.zig's CaptureSink follows).
const RecordingSink = struct {
    alloc: std.mem.Allocator,
    buffers: std.ArrayList(struct { id: UUID, name: []u8 }) = .empty,
    lines: std.ArrayList(struct { id: UUID, text: []u8 }) = .empty,

    fn sink(self: *RecordingSink) pump_.Sink {
        return .{ .ctx = self, .vtable = &vtable };
    }
    const vtable: pump_.Sink.VTable = .{
        .createBuffer = createBuffer,
        .bytes = bytes,
        .streamEof = struct {
            fn f(_: *anyopaque, _: uuid.UUID, _: pump_.Stream, _: ?anyerror) void {}
        }.f,
        .processExited = struct {
            fn f(_: *anyopaque, _: uuid.UUID, _: ?Term) void {}
        }.f,
        .endBatch = struct {
            fn f(_: *anyopaque) void {}
        }.f,
        .shutdown = struct {
            fn f(_: *anyopaque) void {}
        }.f,
    };

    fn createBuffer(ctx: *anyopaque, id: uuid.UUID, name: []const u8) void {
        const self: *RecordingSink = @ptrCast(@alignCast(ctx));
        const copy = self.alloc.dupe(u8, name) catch return;
        self.buffers.append(self.alloc, .{ .id = id, .name = copy }) catch self.alloc.free(copy);
    }

    fn bytes(ctx: *anyopaque, id: uuid.UUID, stream: pump_.Stream, data: []const u8) void {
        if (stream != .stderr) return;
        const self: *RecordingSink = @ptrCast(@alignCast(ctx));
        const copy = self.alloc.dupe(u8, data) catch return;
        self.lines.append(self.alloc, .{ .id = id, .text = copy }) catch self.alloc.free(copy);
    }

    fn deinit(self: *RecordingSink) void {
        for (self.buffers.items) |b| self.alloc.free(b.name);
        self.buffers.deinit(self.alloc);
        for (self.lines.items) |l| self.alloc.free(l.text);
        self.lines.deinit(self.alloc);
    }

    fn bufferName(self: *const RecordingSink, id: UUID) ?[]const u8 {
        for (self.buffers.items) |b| {
            if (std.meta.eql(b.id, id)) return b.name;
        }
        return null;
    }

    /// True when some stderr line of buffer `id` contains `needle`.
    fn stderrMentions(self: *const RecordingSink, id: UUID, needle: []const u8) bool {
        for (self.lines.items) |l| {
            if (std.meta.eql(l.id, id) and std.mem.find(u8, l.text, needle) != null) return true;
        }
        return false;
    }
};

fn parseConfig(io: Io, alloc: std.mem.Allocator, source: []const u8) !Configuration {
    var diag: config_.Diagnostics = .{};
    return config_.parse(io, alloc, source, &diag) catch |err| {
        std.debug.print("config: {s}\n", .{diag.message()});
        return err;
    };
}

fn launchedCount(runner: *const ConfiguredRunner, name: []const u8) usize {
    var n: usize = 0;
    for (runner.launched.items) |l| {
        if (std.mem.eql(u8, l.process.name, name)) n += 1;
    }
    return n;
}

fn isLaunched(runner: *const ConfiguredRunner, id: UUID) bool {
    for (runner.launched.items) |l| {
        if (std.meta.eql(l.id, id)) return true;
    }
    return false;
}

/// The shutdown sequence (kill the children, stop the pump), run exactly once: explicitly
/// when a test wants to read its sink afterwards, or from the `defer` when an assertion
/// fails first. That keeps a failed assertion a readable failure rather than a crash in
/// `pump.deinit`/`ing.destroy`. Declare it after `defer runner.deinit(io)`.
const Cleanup = struct {
    runner: *ConfiguredRunner,
    pump: *Pump,
    io: Io,
    done: bool = false,

    fn run(self: *Cleanup) void {
        if (self.done) return;
        self.done = true;
        self.runner.killAll(self.io) catch {};
        self.pump.stop();
    }
};

/// A native command line (no shell in between: Ubuntu's `sh -c` forks the command, so a kill
/// would only reach the shell) that takes about a second. Gates that must still be running
/// when a test looks use it: `echo` under a shell can exit and be reaped within the same
/// `startReady` pass on Linux.
const slow_cmd = switch (builtin.os.tag) {
    .windows => "ping -n 2 127.0.0.1",
    else => "sleep 1",
};
/// ... and one that runs until it is killed.
const forever_cmd = switch (builtin.os.tag) {
    .windows => "ping -n 60 127.0.0.1",
    else => "sleep 60",
};

test "terminateProcess: kills the process behind a buffer id promptly, ignores unknown ids" {
    const alloc = testing.allocator;
    const io = testing.io;

    var sink: NullSink = .{};
    const pump = try Pump.init(alloc, io, sink.sink(), .{});
    defer pump.deinit();
    try pump.start();

    // A runner with no configuration: `terminateProcess` only looks at the launched processes.
    var runner: ConfiguredRunner = .{
        ._alloc = alloc,
        ._context = .{ .procs = .empty },
        .pump = pump,
        .config = undefined,
    };
    defer runner._context.procs.deinit(alloc);

    // No shell in between: the killed process is the one holding the pipes, so the readers
    // see EOF right away (what `stop` relies on for a launched program).
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .windows => &.{ "ping", "-n", "30", "127.0.0.1" },
        else => &.{ "sleep", "30" },
    };
    const ing = try pump_.reader.launch(io, alloc, pump, "sleeper", argv, null);
    defer ing.destroy();
    try runner._context.procs.append(alloc, ing);

    const unknown: uuid.UUID = .{ .bytes = [_]u8{0xAB} ** 16 };
    try testing.expect(!runner.terminateProcess(io, unknown));
    try testing.expect(!ing.exited.isSet());

    const start = Io.Timestamp.now(io, .awake);
    try testing.expect(runner.terminateProcess(io, ing.id));
    try ing.all_done.wait(io);
    const elapsed = start.durationTo(Io.Timestamp.now(io, .awake));
    try testing.expect(elapsed.toSeconds() < 5);
    try testing.expect(ing.exited.isSet());

    // idempotent once the process is gone
    try testing.expect(runner.terminateProcess(io, ing.id));

    pump.stop();
}

test "run/runStartup: targets resolve, a pre task gates its process, scripts fire once views exist" {
    const alloc = testing.allocator;
    const io = testing.io;

    var sink: NullSink = .{};
    const pump = try Pump.init(alloc, io, sink.sink(), .{});
    defer pump.deinit();
    try pump.start();

    // `type: shell` so `echo` exists on every platform; d (a gate) is a slow native process
    const source = try std.fmt.allocPrint(alloc,
        \\default: g
        \\processes:
        \\  a: echo a
        \\  b: echo b
        \\  c: echo c
        \\  d: {s}
        \\groups:
        \\  g: [a, b]
        \\configs:
        \\  - name: a
        \\    type: shell
        \\    script: ['a: keep x']
        \\  - name: b
        \\    type: shell
        \\  - name: c
        \\    type: shell
        \\    preTask: d
        \\  - name: g
        \\    script: ['_: wrap on']
        \\script: ['_: color x red']
    , .{slow_cmd});
    defer alloc.free(source);
    const config = try parseConfig(io, alloc, source);
    const runner = try ConfiguredRunner.init(alloc, config, pump);
    defer runner.deinit(io);
    var cleanup: Cleanup = .{ .runner = runner, .pump = pump, .io = io };
    defer cleanup.run();

    try testing.expectError(error.NoConfigWithName, runner.run(io, "nope"));
    try testing.expectError(error.NoConfigWithName, runner.runPostTasks(io, "nope", .nonBlocking));

    // startup with no name: the default group, so a and b, neither behind a pre task
    var startup = try runner.runStartup(io, null);
    defer startup.deinit();
    try testing.expectEqual(2, startup.ids.items.len);
    try testing.expectEqual(2, startup.children.items.len);
    try testing.expectEqual(0, runner.deferred.items.len);
    const id_a = startup.ids.items[0];
    const id_b = startup.ids.items[1];
    try testing.expectEqual(id_a, startup.children.items[0].id);
    try testing.expectEqual(id_b, startup.focusId().?);
    try testing.expectEqual(2, runner.pending_scripts.items.len); // the group's and the file's

    // b's view: b has no script and the others still wait for a
    const first = try runner.viewCreated(io, alloc, id_b);
    defer alloc.free(first);
    try testing.expectEqual(0, first.len);

    // a's view: a's own script, then the group's, then the file's
    const second = try runner.viewCreated(io, alloc, id_a);
    defer alloc.free(second);
    try testing.expectEqual(3, second.len);
    try testing.expectEqualStrings("a: keep x", second[0]);
    try testing.expectEqualStrings("_: wrap on", second[1]);
    try testing.expectEqualStrings("_: color x red", second[2]);
    try testing.expectEqual(0, runner.pending_scripts.items.len);

    // a named start of c: its pre task d is spawned now, c waits for it
    var named = try runner.run(io, "c");
    defer named.deinit();
    try testing.expectEqual(1, named.children.items.len); // d
    try testing.expectEqual(1, named.ids.items.len); // c
    const id_c = named.ids.items[0];
    try testing.expectEqual(id_c, named.focusId().?);
    try testing.expectEqual(1, runner.deferred.items.len);
    try testing.expect(!isLaunched(runner, id_c));
    try testing.expectEqual(0, runner.pending_scripts.items.len); // a named start does not re-arm the file's script

    // nothing happens before d is done ...
    try testing.expectEqual(null, try runner.startReady(io));
    // ... and once it is, c starts under the id everyone was told about
    try named.children.items[0].exited.wait(io);
    try testing.expectEqual(id_c, (try runner.startReady(io)).?);
    try testing.expectEqual(0, runner.deferred.items.len);
    try testing.expect(isLaunched(runner, id_c));
    try testing.expectEqual(null, try runner.startReady(io)); // once only
    const third = try runner.viewCreated(io, alloc, id_c);
    defer alloc.free(third);
    try testing.expectEqual(0, third.len); // c has no script of its own

    // starting the group again arms its script again
    var again = try runner.run(io, "g");
    defer again.deinit();
    try testing.expectEqual(1, runner.pending_scripts.items.len);

    // post tasks: nobody has one here
    var post_c = try runner.runPostTasks(io, "c", .blocking);
    defer post_c.deinit();
    try testing.expectEqual(0, post_c.children.items.len);
    var post_default = try runner.runPostTasks(io, null, .nonBlocking);
    defer post_default.deinit();
    try testing.expectEqual(0, post_default.children.items.len);
    try testing.expectEqual(3, runner.config.run_all.len);
}

test "run: a failing pre task leaves its process unstarted, its view says why, pending scripts still complete" {
    const alloc = testing.allocator;
    const io = testing.io;

    var sink: RecordingSink = .{ .alloc = alloc };
    defer sink.deinit();
    const pump = try Pump.init(alloc, io, sink.sink(), .{});
    defer pump.deinit();
    try pump.start();

    const config = try parseConfig(io, alloc,
        \\processes:
        \\  pre: exit 3
        \\  c: echo c
        \\groups:
        \\  g: [c]
        \\configs:
        \\  - name: pre
        \\    type: shell
        \\  - name: c
        \\    type: shell
        \\    preTask: pre
        \\    script: ['c: keep y']
        \\  - name: g
        \\    script: ['_: wrap on']
    );
    const runner = try ConfiguredRunner.init(alloc, config, pump);
    defer runner.deinit(io);
    var cleanup: Cleanup = .{ .runner = runner, .pump = pump, .io = io };
    defer cleanup.run();

    var handle = try runner.run(io, "g");
    defer handle.deinit();
    try testing.expectEqual(1, handle.children.items.len); // pre
    try testing.expectEqual(1, handle.ids.items.len); // c
    const id_c = handle.ids.items[0];
    try testing.expectEqual(1, runner.deferred.items.len);

    try handle.children.items[0].exited.wait(io);
    try testing.expectEqual(null, try runner.startReady(io));
    try testing.expectEqual(0, runner.deferred.items.len);
    try testing.expect(!isLaunched(runner, id_c));
    try testing.expectEqual(1, runner._context.procs.items.len);

    // the notice gives c's id a view: the group's script completes, c's own does not run
    const scripts = try runner.viewCreated(io, alloc, id_c);
    defer alloc.free(scripts);
    try testing.expectEqual(1, scripts.len);
    try testing.expectEqualStrings("_: wrap on", scripts[0]);

    cleanup.run(); // the sink is read only once the pump thread is joined
    try testing.expectEqualStrings("c", sink.bufferName(id_c).?);
    try testing.expect(sink.stderrMentions(id_c, "c not started"));
    try testing.expect(sink.stderrMentions(id_c, "preTask \"pre\" exited with code 3"));
}

test "run: a group's pre task gates every member, then each member waits for its own" {
    const alloc = testing.allocator;
    const io = testing.io;

    var sink: NullSink = .{};
    const pump = try Pump.init(alloc, io, sink.sink(), .{});
    defer pump.deinit();
    try pump.start();

    // T gates the group; a and b then wait for s (shared: once); c has no task; e names T
    // itself, which just finished, so it starts right away. Both gates are slow native
    // processes so each stage is observable before the next one happens.
    const source = try std.fmt.allocPrint(alloc,
        \\processes:
        \\  T: {s}
        \\  s: {s}
        \\  a: echo a
        \\  b: echo b
        \\  c: echo c
        \\  e: echo e
        \\groups:
        \\  g: [a, b, c, e]
        \\configs:
        \\  - name: a
        \\    type: shell
        \\    preTask: s
        \\  - name: b
        \\    type: shell
        \\    preTask: s
        \\  - name: c
        \\    type: shell
        \\  - name: e
        \\    type: shell
        \\    preTask: T
        \\  - name: g
        \\    preTask: T
        \\    script: ['_: lines on']
    , .{ slow_cmd, slow_cmd });
    defer alloc.free(source);
    const config = try parseConfig(io, alloc, source);
    const runner = try ConfiguredRunner.init(alloc, config, pump);
    defer runner.deinit(io);
    var cleanup: Cleanup = .{ .runner = runner, .pump = pump, .io = io };
    defer cleanup.run();

    var handle = try runner.run(io, "g");
    defer handle.deinit();
    try testing.expectEqual(1, handle.children.items.len); // T
    try testing.expectEqual(4, handle.ids.items.len);
    try testing.expectEqual(4, runner.deferred.items.len);
    for (runner.deferred.items) |d| {
        try testing.expectEqual(handle.children.items[0], d.after);
        try testing.expect(d.own_task_next);
    }
    try testing.expectEqual(1, runner.pending_scripts.items.len);
    try testing.expectEqual(4, runner.pending_scripts.items[0].pending.items.len);

    // T done: s starts (once), c and e start, a and b now wait for s
    try handle.children.items[0].exited.wait(io);
    const focus = (try runner.startReady(io)).?;
    try testing.expectEqual(handle.ids.items[3], focus); // e, the last one spawned
    try testing.expectEqual(2, runner.deferred.items.len);
    try testing.expectEqual(1, launchedCount(runner, "T"));
    try testing.expectEqual(1, launchedCount(runner, "s"));
    try testing.expectEqual(1, launchedCount(runner, "c"));
    try testing.expectEqual(1, launchedCount(runner, "e"));
    try testing.expectEqual(0, launchedCount(runner, "a"));
    const s_ing = runner.deferred.items[0].after;
    try testing.expectEqual(s_ing, runner.deferred.items[1].after);
    try testing.expectEqualStrings("s", runner.deferred.items[0].task.name);
    try testing.expect(!runner.deferred.items[0].own_task_next);

    // s done: a and b start
    try s_ing.exited.wait(io);
    try testing.expectEqual(handle.ids.items[1], (try runner.startReady(io)).?);
    try testing.expectEqual(0, runner.deferred.items.len);
    try testing.expectEqual(1, launchedCount(runner, "a"));
    try testing.expectEqual(1, launchedCount(runner, "b"));
    try testing.expectEqual(6, runner._context.procs.items.len);

    // the group's script fires once, on the last member's view
    var fired: usize = 0;
    for (handle.ids.items) |id| {
        const scripts = try runner.viewCreated(io, alloc, id);
        defer alloc.free(scripts);
        fired += scripts.len;
    }
    try testing.expectEqual(1, fired);
}

test "run: a failing group pre task announces every member" {
    const alloc = testing.allocator;
    const io = testing.io;

    var sink: RecordingSink = .{ .alloc = alloc };
    defer sink.deinit();
    const pump = try Pump.init(alloc, io, sink.sink(), .{});
    defer pump.deinit();
    try pump.start();

    const config = try parseConfig(io, alloc,
        \\processes:
        \\  T: exit 2
        \\  a: echo a
        \\  b: echo b
        \\groups:
        \\  g: [a, b]
        \\configs:
        \\  - name: T
        \\    type: shell
        \\  - name: a
        \\    type: shell
        \\  - name: b
        \\    type: shell
        \\  - name: g
        \\    preTask: T
    );
    const runner = try ConfiguredRunner.init(alloc, config, pump);
    defer runner.deinit(io);
    var cleanup: Cleanup = .{ .runner = runner, .pump = pump, .io = io };
    defer cleanup.run();

    var handle = try runner.run(io, "g");
    defer handle.deinit();
    try testing.expectEqual(2, runner.deferred.items.len);
    try handle.children.items[0].exited.wait(io);
    try testing.expectEqual(null, try runner.startReady(io));
    try testing.expectEqual(0, runner.deferred.items.len);
    try testing.expectEqual(1, runner._context.procs.items.len);

    cleanup.run();
    try testing.expectEqualStrings("a", sink.bufferName(handle.ids.items[0]).?);
    try testing.expectEqualStrings("b", sink.bufferName(handle.ids.items[1]).?);
    try testing.expect(sink.stderrMentions(handle.ids.items[0], "preTask \"T\" exited with code 2"));
    try testing.expect(sink.stderrMentions(handle.ids.items[1], "preTask \"T\" exited with code 2"));
}

test "runStartup: everything runs a shared pre task once, each process waits for its own" {
    const alloc = testing.allocator;
    const io = testing.io;

    var sink: NullSink = .{};
    const pump = try Pump.init(alloc, io, sink.sink(), .{});
    defer pump.deinit();
    try pump.start();

    const config = try parseConfig(io, alloc,
        \\processes:
        \\  t: echo t
        \\  a: echo a
        \\  b: echo b
        \\  c: echo c
        \\configs:
        \\  - name: t
        \\    type: shell
        \\  - name: a
        \\    type: shell
        \\    preTask: t
        \\  - name: b
        \\    type: shell
        \\    preTask: t
        \\  - name: c
        \\    type: shell
        \\script: ['_: wrap on']
    );
    const runner = try ConfiguredRunner.init(alloc, config, pump);
    defer runner.deinit(io);
    var cleanup: Cleanup = .{ .runner = runner, .pump = pump, .io = io };
    defer cleanup.run();

    var handle = try runner.runStartup(io, null);
    defer handle.deinit();
    try testing.expectEqual(2, handle.children.items.len); // t and c, right away
    try testing.expectEqual(3, handle.ids.items.len); // a, b, c
    try testing.expectEqual(2, runner.deferred.items.len);
    try testing.expectEqual(runner.deferred.items[0].after, runner.deferred.items[1].after);
    try testing.expectEqual(1, launchedCount(runner, "t"));
    try testing.expectEqual(1, runner.pending_scripts.items.len);
    try testing.expectEqual(3, runner.pending_scripts.items[0].pending.items.len);

    try runner.deferred.items[0].after.exited.wait(io);
    try testing.expectEqual(handle.ids.items[1], (try runner.startReady(io)).?);
    try testing.expectEqual(0, runner.deferred.items.len);
    try testing.expectEqual(1, launchedCount(runner, "t"));
    try testing.expectEqual(4, runner._context.procs.items.len);

    var fired: usize = 0;
    for (handle.ids.items) |id| {
        const scripts = try runner.viewCreated(io, alloc, id);
        defer alloc.free(scripts);
        fired += scripts.len;
    }
    try testing.expectEqual(1, fired);
}

test "run: stopping a pre task cancels the start; killAll drops what is still waiting" {
    const alloc = testing.allocator;
    const io = testing.io;

    var sink: RecordingSink = .{ .alloc = alloc };
    defer sink.deinit();
    const pump = try Pump.init(alloc, io, sink.sink(), .{});
    defer pump.deinit();
    try pump.start();

    // `slow` is native: the kill has to reach the process that holds the pipes
    const source = try std.fmt.allocPrint(alloc,
        \\processes:
        \\  slow: {s}
        \\  a: echo a
        \\  b: echo b
        \\configs:
        \\  - name: a
        \\    type: shell
        \\    preTask: slow
        \\  - name: b
        \\    type: shell
        \\    preTask: slow
    , .{forever_cmd});
    defer alloc.free(source);
    const config = try parseConfig(io, alloc, source);
    const runner = try ConfiguredRunner.init(alloc, config, pump);
    defer runner.deinit(io);
    var cleanup: Cleanup = .{ .runner = runner, .pump = pump, .io = io };
    defer cleanup.run();

    var first = try runner.run(io, "a");
    defer first.deinit();
    const slow = first.children.items[0];
    try testing.expectEqual(1, runner.deferred.items.len);
    try testing.expect(runner.terminateProcess(io, slow.id));
    try slow.exited.wait(io);
    try testing.expectEqual(null, try runner.startReady(io));
    try testing.expectEqual(0, runner.deferred.items.len);
    try testing.expect(!isLaunched(runner, first.ids.items[0]));

    // a second start is independent: its own copy of the task, its own wait
    var second = try runner.run(io, "b");
    defer second.deinit();
    try testing.expectEqual(2, launchedCount(runner, "slow"));
    try testing.expectEqual(1, runner.deferred.items.len);

    // shutdown drops the waiting process; nothing starts afterwards
    cleanup.run();
    try testing.expectEqual(0, runner.deferred.items.len);
    try testing.expectEqual(null, try runner.startReady(io));
    try testing.expect(!isLaunched(runner, second.ids.items[0]));

    try testing.expect(sink.stderrMentions(first.ids.items[0], "a not started"));
    try testing.expectEqual(null, sink.bufferName(second.ids.items[0]));
}

test "run: a pre task that cannot be spawned is announced, the rest of the group still starts" {
    const alloc = testing.allocator;
    const io = testing.io;

    var sink: RecordingSink = .{ .alloc = alloc };
    defer sink.deinit();
    const pump = try Pump.init(alloc, io, sink.sink(), .{});
    defer pump.deinit();
    try pump.start();

    const config = try parseConfig(io, alloc,
        \\processes:
        \\  bad: this_program_does_not_exist_xyz
        \\  a: echo a
        \\  b: echo b
        \\groups:
        \\  g: [a, b]
        \\configs:
        \\  - name: a
        \\    type: shell
        \\    preTask: bad
        \\  - name: b
        \\    type: shell
    );
    const runner = try ConfiguredRunner.init(alloc, config, pump);
    defer runner.deinit(io);
    var cleanup: Cleanup = .{ .runner = runner, .pump = pump, .io = io };
    defer cleanup.run();

    var handle = try runner.run(io, "g"); // no error out of a task that will not spawn
    defer handle.deinit();
    try testing.expectEqual(1, handle.children.items.len); // b
    try testing.expectEqual(2, handle.ids.items.len);
    try testing.expectEqual(0, runner.deferred.items.len);
    try testing.expectEqual(1, runner._context.procs.items.len);
    try testing.expect(!isLaunched(runner, handle.ids.items[0]));
    try testing.expect(isLaunched(runner, handle.ids.items[1]));

    cleanup.run();
    try testing.expect(sink.stderrMentions(handle.ids.items[0], "preTask \"bad\" could not be started"));
    var bad_announced = false;
    for (sink.buffers.items) |b| {
        if (std.mem.eql(u8, b.name, "bad") and sink.stderrMentions(b.id, "failed to spawn")) bad_announced = true;
    }
    try testing.expect(bad_announced);
}

test "runPostTasks: a group's own and its members' post tasks, once each" {
    const alloc = testing.allocator;
    const io = testing.io;

    var sink: NullSink = .{};
    const pump = try Pump.init(alloc, io, sink.sink(), .{});
    defer pump.deinit();
    try pump.start();

    const config = try parseConfig(io, alloc,
        \\processes:
        \\  a: echo a
        \\  b: echo b
        \\  clean: echo clean
        \\  gclean: echo gclean
        \\groups:
        \\  g: [a, b]
        \\configs:
        \\  - name: a
        \\    type: shell
        \\    postTask: clean
        \\  - name: b
        \\    type: shell
        \\    postTask: clean
        \\  - name: clean
        \\    type: shell
        \\  - name: gclean
        \\    type: shell
        \\  - name: g
        \\    postTask: gclean
    );
    const runner = try ConfiguredRunner.init(alloc, config, pump);
    defer runner.deinit(io);
    var cleanup: Cleanup = .{ .runner = runner, .pump = pump, .io = io };
    defer cleanup.run();

    var group = try runner.runPostTasks(io, "g", .blocking);
    defer group.deinit();
    try testing.expectEqual(2, group.children.items.len); // gclean, clean
    try testing.expectEqual(1, launchedCount(runner, "clean"));
    try testing.expectEqual(1, launchedCount(runner, "gclean"));

    var one = try runner.runPostTasks(io, "a", .blocking);
    defer one.deinit();
    try testing.expectEqual(1, one.children.items.len);

    // "everything" is a and b (the tasks are left out): clean once
    var all = try runner.runPostTasks(io, null, .blocking);
    defer all.deinit();
    try testing.expectEqual(1, all.children.items.len);
}
