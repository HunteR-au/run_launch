const std = @import("std");
const Io = std.Io;
const debugpy = @import("pydebug.zig");
const native = @import("native.zig");
const utils = @import("utils");
const config_ = @import("config");
const pump_ = @import("pump");

const Launch = config_.Launch;
const Compound = config_.Compound;
const LaunchConfiguration = config_.LaunchConfiguration;
const Task = config_.Task;
const Tasks = config_.Tasks;

pub const Pump = pump_.Pump;
pub const ProcIngest = pump_.reader.ProcIngest;
pub const Term = pump_.Term;

const uuid = utils.uuid;

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
    config: Launch,
    tasks: ?Tasks = null,
    m: std.Io.Mutex = .init,

    const ExecType = enum { blocking, nonBlocking };

    pub fn init(
        alloc: std.mem.Allocator,
        config: Launch,
        tasks: ?Tasks,
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
            .tasks = tasks,
        };
        return runner;
    }

    /// Must be called after `killAll`, when no other thread can touch the runner.
    pub fn deinit(self: *ConfiguredRunner, io: Io) void {
        _ = io;
        for (self._context.procs.items) |ing| ing.destroy();
        self._context.procs.deinit(self._alloc);
        self.config.deinit(self._alloc);
        if (self.tasks) |*tasks| {
            tasks.deinit(self._alloc);
        }
        self._alloc.destroy(self);
    }

    fn track(self: *ConfiguredRunner, handle: *WorkHandle, ing: *ProcIngest) !void {
        try self._context.procs.append(self._alloc, ing);
        try handle.children.append(handle._alloc, ing);
    }

    pub fn run(self: *ConfiguredRunner, io: Io, name: []const u8, exec_type: ExecType) !?WorkHandle {
        self.m.lockUncancelable(io);
        defer self.m.unlock(io);

        const match = self.config.find_by_name(name) orelse {
            return error.NoConfigWithName;
        };

        var handle: WorkHandle = .{ ._alloc = self._alloc, .children = try .initCapacity(self._alloc, 1) };
        errdefer handle.deinit();

        switch (match) {
            .config => |config| {
                const ing = try launchConfig(io, self._alloc, self.pump, config);
                try self.track(&handle, ing);
            },
            .compound => |compound| {
                for (compound.configurations.?) |config_name| {
                    const config = self.config.find_config_by_name(config_name) orelse continue;
                    const ing = try launchConfig(io, self._alloc, self.pump, config);
                    try self.track(&handle, ing);
                }
            },
        }

        switch (exec_type) {
            .blocking => try handle.wait(io),
            .nonBlocking => {},
        }
        return handle;
    }

    pub fn runPreTasks(self: *ConfiguredRunner, io: Io, name: []const u8, exec_type: ExecType) !?WorkHandle {
        return self.runTaskOf(io, name, exec_type, .pre);
    }

    pub fn runPostTasks(self: *ConfiguredRunner, io: Io, name: []const u8, exec_type: ExecType) !?WorkHandle {
        return self.runTaskOf(io, name, exec_type, .post);
    }

    fn runTaskOf(self: *ConfiguredRunner, io: Io, name: []const u8, exec_type: ExecType, which: enum { pre, post }) !?WorkHandle {
        self.m.lockUncancelable(io);
        defer self.m.unlock(io);

        const match = self.config.find_by_name(name) orelse {
            return error.NoConfigWithName;
        };

        const task_name: ?[]const u8 = switch (match) {
            .config => |config| if (which == .pre) config.preLaunchTask else config.postDebugTask,
            .compound => |compound| if (which == .pre) compound.preLaunchTask else compound.postDebugTask,
        };

        var handle: WorkHandle = .{ ._alloc = self._alloc, .children = try .initCapacity(self._alloc, 1) };
        errdefer handle.deinit();

        if (task_name) |tn| {
            if (try self.launchTask(io, tn)) |ing| {
                try self.track(&handle, ing);
            }
        }

        switch (exec_type) {
            .blocking => try handle.wait(io),
            .nonBlocking => {},
        }
        return handle;
    }

    fn launchTask(self: *ConfiguredRunner, io: Io, taskname: []const u8) !?*ProcIngest {
        const tasks = self.tasks orelse return null;
        const task = tasks.find_by_label(taskname) orelse return null;

        const argv = try task.buildArgv(self._alloc);
        defer self._alloc.free(argv);

        return try pump_.reader.launch(io, self._alloc, self.pump, taskname, argv, null);
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

const RunnerType = enum {
    python,
    debugpy,
    cppdbg,
    cppvsdbg,
};

fn launchConfig(
    io: Io,
    alloc: std.mem.Allocator,
    pump: *Pump,
    config: *const LaunchConfiguration,
) !*ProcIngest {
    // assume that the type is set
    const type_name = config.type orelse return error.InvalidChoice;
    const runner_type = std.meta.stringToEnum(RunnerType, type_name) orelse {
        return error.InvalidChoice;
    };

    return switch (runner_type) {
        .debugpy, .python => debugpy.launch(io, alloc, pump, config),
        .cppdbg, .cppvsdbg => native.launch(io, alloc, pump, config),
    };
}
