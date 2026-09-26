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

/// Handle over the processes started by one `run`/`runPreTasks`/`runPostTasks` call.
pub const WorkHandle = struct {
    _alloc: std.mem.Allocator,
    children: std.ArrayList(*ProcIngest),
    results: ?std.ArrayList(?Term) = null,

    /// Blocks until every process has been reaped and records their exit terms.
    pub fn wait(self: *WorkHandle, io: Io) !void {
        if (self.results) |*r| r.clearRetainingCapacity() else self.results = try .initCapacity(self._alloc, self.children.items.len);

        for (self.children.items) |ing| {
            try ing.exited.wait(io);
            try self.results.?.append(self._alloc, ing.term);
        }
    }

    /// Blocks until every process has been reaped AND its output fully read into the pump.
    pub fn waitAllDone(self: *WorkHandle, io: Io) !void {
        for (self.children.items) |ing| {
            try ing.all_done.wait(io);
        }
    }

    pub fn deinit(self: *WorkHandle) void {
        self.children.deinit(self._alloc);
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

    const Launched = struct { id: UUID, process: *const Process };
    const PendingScript = struct { script: []const u8, pending: std.ArrayList(UUID) };
    const ExecType = enum { blocking, nonBlocking };
    const TaskKind = enum { pre, post };

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
        self.config.deinit();
        self._alloc.destroy(self);
    }

    fn track(self: *ConfiguredRunner, handle: *WorkHandle, ing: *ProcIngest) !void {
        try self._context.procs.append(self._alloc, ing);
        try handle.children.append(handle._alloc, ing);
    }

    /// `name`, or with none the file's `default:`, or everything (see `Configuration.resolve`).
    fn resolve(self: *const ConfiguredRunner, name: ?[]const u8) !Target {
        return self.config.resolve(name) orelse error.NoConfigWithName;
    }

    /// Starts the process or group called `name` (what the `start` command does).
    pub fn run(self: *ConfiguredRunner, io: Io, name: []const u8, exec_type: ExecType) !?WorkHandle {
        return self.launch(io, name, exec_type, false);
    }

    /// Starts what the command line asked for: `name`, or with none the file's `default:`,
    /// or everything. The file's global script waits for these processes' views.
    pub fn runStartup(self: *ConfiguredRunner, io: Io, name: ?[]const u8, exec_type: ExecType) !?WorkHandle {
        return self.launch(io, name, exec_type, true);
    }

    fn launch(self: *ConfiguredRunner, io: Io, name: ?[]const u8, exec_type: ExecType, startup: bool) !?WorkHandle {
        self.m.lockUncancelable(io);
        defer self.m.unlock(io);

        const target = try self.resolve(name);

        var handle: WorkHandle = .{ ._alloc = self._alloc, .children = try .initCapacity(self._alloc, 1) };
        errdefer handle.deinit();

        switch (target) {
            .process => |p| try self.launchProcess(io, &handle, p),
            .group => |g| {
                for (g.members) |p| try self.launchProcess(io, &handle, p);
                if (g.script) |script| try self.armScript(script, handle.children.items);
            },
            .all => |processes| {
                for (processes) |p| try self.launchProcess(io, &handle, p);
            },
        }
        if (startup) {
            if (self.config.script) |script| try self.armScript(script, handle.children.items);
        }

        switch (exec_type) {
            .blocking => try handle.wait(io),
            .nonBlocking => {},
        }
        return handle;
    }

    /// Spawns `p` under its own name and starts its pump readers.
    fn launchProcess(self: *ConfiguredRunner, io: Io, handle: *WorkHandle, p: *const Process) !void {
        var argv = try argv_.build(self._alloc, p);
        defer argv.deinit(self._alloc);

        var envmap: ?std.process.Environ.Map = null;
        defer if (envmap) |*m| m.deinit();
        if (p.env.len > 0) envmap = try utils.create_env_map(self._alloc, p.env);
        const envmap_ptr: ?*std.process.Environ.Map = if (envmap) |*m| m else null;

        const ing = try pump_.reader.launch(io, self._alloc, self.pump, p.name, argv.items, envmap_ptr);
        try self.track(handle, ing);
        try self.launched.append(self._alloc, .{ .id = ing.id, .process = p });
    }

    /// `script` runs once every process in `procs` has a view (nothing to wait for: never).
    fn armScript(self: *ConfiguredRunner, script: []const u8, procs: []const *ProcIngest) !void {
        if (procs.len == 0) return;
        var pending: std.ArrayList(UUID) = try .initCapacity(self._alloc, procs.len);
        errdefer pending.deinit(self._alloc);
        for (procs) |ing| pending.appendAssumeCapacity(ing.id);
        try self.pending_scripts.append(self._alloc, .{ .script = script, .pending = pending });
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

    pub fn runPreTasks(self: *ConfiguredRunner, io: Io, name: ?[]const u8, exec_type: ExecType) !?WorkHandle {
        return self.runTasksOf(io, name, exec_type, .pre);
    }

    pub fn runPostTasks(self: *ConfiguredRunner, io: Io, name: ?[]const u8, exec_type: ExecType) !?WorkHandle {
        return self.runTasksOf(io, name, exec_type, .post);
    }

    fn taskOf(entry: anytype, which: TaskKind) ?*const Process {
        return if (which == .pre) entry.pre_task else entry.post_task;
    }

    /// The pre/post task of what `name` refers to. For "everything" that is each process'
    /// own task, each started once even when several processes share it.
    fn runTasksOf(self: *ConfiguredRunner, io: Io, name: ?[]const u8, exec_type: ExecType, which: TaskKind) !?WorkHandle {
        self.m.lockUncancelable(io);
        defer self.m.unlock(io);

        const target = try self.resolve(name);

        var handle: WorkHandle = .{ ._alloc = self._alloc, .children = try .initCapacity(self._alloc, 1) };
        errdefer handle.deinit();

        switch (target) {
            .process => |p| if (taskOf(p, which)) |task| try self.launchProcess(io, &handle, task),
            .group => |g| if (taskOf(g, which)) |task| try self.launchProcess(io, &handle, task),
            .all => |processes| {
                for (processes, 0..) |p, i| {
                    const task = taskOf(p, which) orelse continue;
                    const seen = for (processes[0..i]) |q| {
                        if (taskOf(q, which) == task) break true;
                    } else false;
                    if (!seen) try self.launchProcess(io, &handle, task);
                }
            },
        }

        switch (exec_type) {
            .blocking => try handle.wait(io),
            .nonBlocking => {},
        }
        return handle;
    }

    /// Asks the OS to kill the process whose output buffer is `id` (the `stop` command).
    /// Signal only, never blocks: the process' waiter task reaps it and its readers drain
    /// the pipes as usual. Returns false when no launched process owns that buffer (a
    /// merged/help buffer) - nothing to do then.
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

    /// Terminates every launched process and joins its reader/waiter tasks. Never hangs.
    pub fn killAll(self: *ConfiguredRunner, io: Io) !void {
        self.m.lockUncancelable(io);
        defer self.m.unlock(io);

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

test "run/runStartup/pre tasks: targets resolve and scripts fire once their views exist" {
    const alloc = testing.allocator;
    const io = testing.io;

    var sink: NullSink = .{};
    const pump = try Pump.init(alloc, io, sink.sink(), .{});
    defer pump.deinit();
    try pump.start();

    // `type: shell` so `echo` exists on every platform
    var diag: config_.Diagnostics = .{};
    const config = config_.parse(io, alloc,
        \\default: g
        \\processes:
        \\  a: echo a
        \\  b: echo b
        \\  c: echo c
        \\  d: echo d
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
        \\  - name: d
        \\    type: shell
        \\  - name: g
        \\    script: ['_: wrap on']
        \\script: ['_: color x red']
    , &diag) catch |err| {
        std.debug.print("config: {s}\n", .{diag.message()});
        return err;
    };
    const runner = try ConfiguredRunner.init(alloc, config, pump);
    defer runner.deinit(io);

    try testing.expectError(error.NoConfigWithName, runner.run(io, "nope", .nonBlocking));
    try testing.expectError(error.NoConfigWithName, runner.runPreTasks(io, "nope", .nonBlocking));

    // startup with no name: the default group, so a and b
    var startup = (try runner.runStartup(io, null, .nonBlocking)).?;
    defer startup.deinit();
    try testing.expectEqual(2, startup.children.items.len);
    const id_a = startup.children.items[0].id;
    const id_b = startup.children.items[1].id;
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

    // a named start does not re-arm the file's script; c has no script of its own
    var named = (try runner.run(io, "c", .nonBlocking)).?;
    defer named.deinit();
    try testing.expectEqual(1, named.children.items.len);
    try testing.expectEqual(0, runner.pending_scripts.items.len);
    const third = try runner.viewCreated(io, alloc, named.children.items[0].id);
    defer alloc.free(third);
    try testing.expectEqual(0, third.len);

    // starting the group again arms its script again
    var again = (try runner.run(io, "g", .nonBlocking)).?;
    defer again.deinit();
    try testing.expectEqual(1, runner.pending_scripts.items.len);

    // pre tasks: c's is d; the default group has none; "everything" (a b c) has c's once
    var pre_c = (try runner.runPreTasks(io, "c", .nonBlocking)).?;
    defer pre_c.deinit();
    try testing.expectEqual(1, pre_c.children.items.len);
    var pre_default = (try runner.runPreTasks(io, null, .nonBlocking)).?;
    defer pre_default.deinit();
    try testing.expectEqual(0, pre_default.children.items.len);
    try testing.expectEqual(3, runner.config.run_all.len);
    var post_c = (try runner.runPostTasks(io, "c", .blocking)).?;
    defer post_c.deinit();
    try testing.expectEqual(0, post_c.children.items.len);

    try runner.killAll(io);
    pump.stop();
}
