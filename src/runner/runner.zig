const std = @import("std");
const debugpy = @import("pydebug.zig");
const native = @import("native.zig");
const utils = @import("utils");
const config_ = @import("config");

const Launch = config_.Launch;
const Compound = config_.Compound;
const LaunchConfiguration = config_.LaunchConfiguration;
const Task = config_.Task;
const Tasks = config_.Tasks;

const uuid = utils.uuid;

pub const RunnerContext = struct {
    children: std.ArrayList(std.process.Child),
    threads: std.ArrayList(std.Thread),
};

pub const UiFunctions = struct {
    pub const NotifyNewProcessFn = fn (std.mem.Allocator, []const u8) std.mem.Allocator.Error!uuid.UUID;
    pub const PushBytesFn = utils.PushFnProto;

    notifyNewProcess: *const NotifyNewProcessFn,
    pushBytes: *const PushBytesFn,
};

pub const WorkHandle = struct {
    _alloc: std.mem.Allocator,
    children: std.ArrayList(*std.process.Child),
    results: ?std.ArrayList(std.process.Child.Term) = null,

    pub fn wait(self: *WorkHandle) !void {
        if (self.results != null) {
            self.results.?.deinit(self._alloc);
            self.results = null;
        }
        self.results = try .initCapacity(self._alloc, self.children.items.len);

        for (self.children.items) |child| {
            const term = try child.wait();
            self.results.?.appendAssumeCapacity(term);
        }
    }

    pub fn deinit(self: *WorkHandle) void {
        self.children.deinit(self._alloc);
        if (self.results != null) self.results.?.deinit(self._alloc);
    }
};

pub const ConfiguredRunner = struct {
    _alloc: std.mem.Allocator,
    _context: RunnerContext,
    _ui_funcs: UiFunctions,
    config: Launch,
    tasks: ?Tasks = null,
    m: std.Thread.Mutex = std.Thread.Mutex{},

    const ExecType = enum { blocking, nonBlocking };

    pub fn init(
        alloc: std.mem.Allocator,
        config: Launch,
        tasks: ?Tasks,
        comptime ui_funcs: UiFunctions,
    ) !*ConfiguredRunner {
        const runner = try alloc.create(ConfiguredRunner);
        errdefer alloc.destroy(runner);

        runner.* = .{
            ._alloc = alloc,
            ._context = .{
                .threads = try .initCapacity(alloc, 1),
                .children = try .initCapacity(alloc, 1),
            },
            ._ui_funcs = ui_funcs,
            .config = config,
            .tasks = tasks,
        };
        return runner;
    }

    pub fn deinit(self: *ConfiguredRunner) void {
        self.m.lock();
        defer self.m.unlock();

        self._context.children.deinit(self._alloc);
        self._context.threads.deinit(self._alloc);
        self.config.deinit(self._alloc);
        if (self.tasks) |*tasks| {
            //if (tasks.tasks) |*tasks_| {
            //    for (tasks_.*) |*task| task.deinit(self._alloc);
            //}
            tasks.deinit(self._alloc);
        }
        self._alloc.destroy(self);
    }

    pub fn run(self: *ConfiguredRunner, name: []const u8, exec_type: ExecType) !?WorkHandle {
        self.m.lock();
        defer self.m.unlock();

        const match = self.config.find_by_name(name) orelse {
            return error.NoConfigWithName;
        };

        switch (match) {
            .config => |config| {
                // assume that the type is set
                const runner_type = std.meta.stringToEnum(RunnerType, config.type.?) orelse {
                    return error.InvalidChoice;
                };

                const child = try runRunnerTypeNonBlocking(
                    self._alloc,
                    runner_type,
                    config,
                    &self._context,
                    self._ui_funcs.notifyNewProcess,
                    self._ui_funcs.pushBytes,
                );

                // add the child
                try self._context.children.append(self._alloc, child);

                // return the work handle
                var handle: WorkHandle = .{ ._alloc = self._alloc, .children = try .initCapacity(self._alloc, 1) };
                try handle.children.append(handle._alloc, &self._context.children.items[0]);

                switch (exec_type) {
                    .blocking => try handle.wait(),
                    .nonBlocking => {},
                }

                return handle;
            },
            .compound => |compound| {
                // create a work handle for all children created
                var handle: WorkHandle = .{ ._alloc = self._alloc, .children = try .initCapacity(self._alloc, 1) };
                errdefer handle.deinit();

                for (compound.configurations.?) |config_name| {
                    const configmatch = self.config.find_config_by_name(config_name);
                    if (configmatch) |config| {
                        const runner_type = std.meta.stringToEnum(RunnerType, config.type.?) orelse {
                            return error.InvalidChoice;
                        };
                        const child = try runRunnerTypeNonBlocking(
                            self._alloc,
                            runner_type,
                            config,
                            &self._context,
                            self._ui_funcs.notifyNewProcess,
                            self._ui_funcs.pushBytes,
                        );

                        // add the child
                        try self._context.children.append(self._alloc, child);

                        // add the child to the work handle
                        try handle.children.append(handle._alloc, &self._context.children.items[0]);
                    }
                }

                switch (exec_type) {
                    .blocking => try handle.wait(),
                    .nonBlocking => {},
                }
                return handle;
            },
        }
    }

    pub fn runPreTasks(self: *ConfiguredRunner, name: []const u8, exec_type: ExecType) !?WorkHandle {
        self.m.lock();
        defer self.m.unlock();
        const match = self.config.find_by_name(name) orelse {
            return error.NoConfigWithName;
        };

        var child: ?std.process.Child = null;

        switch (match) {
            .config => |config| {
                // TODO - change this to be non-blocking
                child = try runPreLaunchTask(
                    self._alloc,
                    *const LaunchConfiguration,
                    config,
                    self.tasks,
                    self._ui_funcs.notifyNewProcess,
                    self._ui_funcs.pushBytes,
                );
            },
            .compound => |compound| {
                // TODO - change this to be non-blocking
                child = try runPreLaunchTask(
                    self._alloc,
                    *const Compound,
                    compound,
                    self.tasks,
                    self._ui_funcs.notifyNewProcess,
                    self._ui_funcs.pushBytes,
                );
            },
        }

        var handle: WorkHandle = undefined;
        if (child) |c| {
            handle = .{ ._alloc = self._alloc, .children = try .initCapacity(self._alloc, 1) };
            // add the child
            try self._context.children.append(self._alloc, c);
            // create the work handle
            try handle.children.append(handle._alloc, &self._context.children.items[0]);
        } else {
            handle = .{ ._alloc = self._alloc, .children = try .initCapacity(self._alloc, 0) };
        }

        switch (exec_type) {
            .blocking => try handle.wait(),
            .nonBlocking => {},
        }

        return handle;
    }

    pub fn runPostTasks(self: *ConfiguredRunner, name: []const u8, exec_type: ExecType) !?WorkHandle {
        self.m.lock();
        defer self.m.unlock();

        const match = self.config.find_by_name(name) orelse {
            return error.NoConfigWithName;
        };

        var child: ?std.process.Child = null;

        switch (match) {
            .config => |config| {
                // TODO - change this to be non-blocking
                child = try runPostLaunchTask(
                    self._alloc,
                    *const LaunchConfiguration,
                    config,
                    self.tasks,
                    self._ui_funcs.pushBytes,
                );
            },
            .compound => |compound| {
                // TODO - change this to be non-blocking
                child = try runPostLaunchTask(
                    self._alloc,
                    *const Compound,
                    compound,
                    self.tasks,
                    self._ui_funcs.pushBytes,
                );
            },
        }

        var handle: WorkHandle = undefined;
        if (child) |c| {
            handle = .{ ._alloc = self._alloc, .children = try .initCapacity(self._alloc, 1) };
            // add the child
            try self._context.children.append(self._alloc, c);
            // create the work handle
            try handle.children.append(handle._alloc, &self._context.children.items[0]);
        } else {
            handle = .{ ._alloc = self._alloc, .children = try .initCapacity(self._alloc, 0) };
        }

        switch (exec_type) {
            .blocking => try handle.wait(),
            .nonBlocking => {},
        }

        return handle;
    }

    pub fn killAll(self: *ConfiguredRunner) !void {
        self.m.lock();
        defer self.m.unlock();

        for (self._context.children.items) |*child| {
            _ = child.kill() catch |err| switch (err) {
                error.AlreadyTerminated => {},
                else => {
                    return err;
                },
            };
        }
    }
};

const RunnerType = enum {
    python,
    debugpy,
    cppdbg,
    cppvsdbg,
};

pub fn run(
    alloc: std.mem.Allocator,
    name: []const u8,
    launchconfig: Launch,
    tasks: ?Tasks,
    createviewprocessfn: fn (std.mem.Allocator, []const u8) std.mem.Allocator.Error!void,
    pushfn: utils.PushFnProto,
) !RunnerContext {
    const match = launchconfig.find_by_name(name) orelse {
        return error.NoConfigWithName;
    };

    var runnerif = RunnerContext{
        .children = try .initCapacity(alloc, 1),
        .threads = try .initCapacity(alloc, 1),
    };

    switch (match) {
        .config => |config| {
            // check if there is a preLaunchTask to run
            _ = try runPreLaunchTask(alloc, *const LaunchConfiguration, config, tasks, createviewprocessfn, pushfn);
            // if (config.preLaunchTask != null) {
            //     try findRunTask(alloc, config.preLaunchTask.?, tasks);
            // }

            // assume that type is set
            const runnertype = std.meta.stringToEnum(RunnerType, config.type.?) orelse {
                return error.InvalidChoice;
            };
            try runRunnerType(alloc, runnertype, config, &runnerif, createviewprocessfn, pushfn);

            // check if there is a post debug task to run
            _ = try runPostLaunchTask(alloc, *const LaunchConfiguration, config, tasks, pushfn);
            // if (config.postDebugTask != null) {
            //     try findRunTask(alloc, config.postDebugTask.?, tasks);
            // }
        },
        .compound => |compound| {
            _ = try runPreLaunchTask(alloc, *const Compound, compound, tasks, createviewprocessfn, pushfn);

            for (compound.configurations.?) |configname| {
                const configmatch = launchconfig.find_config_by_name(configname);
                if (configmatch) |config| {
                    //std.debug.print("Running config: {s}\n", .{configname});

                    // TODO - we probably want to run each config's pre/post tasks

                    const runnertype = std.meta.stringToEnum(RunnerType, config.type.?) orelse {
                        return error.InvalidChoice;
                    };
                    const child = try runRunnerTypeNonBlocking(alloc, runnertype, config, &runnerif, createviewprocessfn, pushfn);
                    try runnerif.children.append(alloc, child);
                }
            }

            // wait for each child process
            //try writer.print("Waiting for each process to finish...\n", .{});
            for (runnerif.children.items) |*child| {
                _ = try child.wait();
            }

            _ = try runPostLaunchTask(alloc, *const Compound, compound, tasks, pushfn);
        },
    }
    // not even sure if returning runner interface makes sense...
    // we are returning after
    return runnerif;
}

fn runPreLaunchTask(
    alloc: std.mem.Allocator,
    T: type,
    launchdata: T,
    tasks: ?Tasks,
    createviewprocessfn: *const UiFunctions.NotifyNewProcessFn,
    pushfn: *const UiFunctions.PushBytesFn,
) !?std.process.Child {
    if (launchdata.preLaunchTask != null) {
        return try findRunTask(alloc, launchdata.preLaunchTask.?, tasks, createviewprocessfn, pushfn);
    }
    return null;
}

fn runPostLaunchTask(
    alloc: std.mem.Allocator,
    T: type,
    launchdata: T,
    tasks: ?Tasks,
    pushfn: *const UiFunctions.PushBytesFn,
) !?std.process.Child {
    if (launchdata.postDebugTask != null) {
        return try findRunTask(alloc, launchdata.postDebugTask.?, tasks, null, pushfn);
    }
    return null;
}

fn findRunTask(
    alloc: std.mem.Allocator,
    taskname: []const u8,
    tasks: ?Tasks,
    createviewprocessfn: ?*const UiFunctions.NotifyNewProcessFn,
    pushfn: *const utils.PushFnProto,
) !?std.process.Child {
    if (tasks != null) {
        if (tasks.?.find_by_label(taskname)) |task| {
            var id: uuid.UUID = undefined;
            if (createviewprocessfn) |create_fn| {
                id = try create_fn(alloc, taskname);
            } else {
                id = uuid.newV4();
            }
            return try task.run_task(alloc, id, pushfn);
        }
    }
    return null;
}

fn runRunnerType(
    alloc: std.mem.Allocator,
    runtype: RunnerType,
    config: *const LaunchConfiguration,
    runnerif: *RunnerContext,
    createviewprocessfn: *const UiFunctions.NotifyNewProcessFn,
    pushfn: *const UiFunctions.PushBytesFn,
) !void {
    switch (runtype) {
        .debugpy => {
            // work out if we need to run a module or script...
            try debugpy.run(alloc, pushfn, config, runnerif, createviewprocessfn);
        },
        .python => {
            try debugpy.run(alloc, pushfn, config, runnerif, createviewprocessfn);
        },
        .cppdbg => {
            try native.run(alloc, pushfn, config, runnerif, createviewprocessfn);
        },
        .cppvsdbg => {
            try native.run(alloc, pushfn, config, runnerif, createviewprocessfn);
        },
    }
}

fn runRunnerTypeNonBlocking(
    alloc: std.mem.Allocator,
    runtype: RunnerType,
    config: *const LaunchConfiguration,
    runnerif: *RunnerContext,
    createviewprocessfn: *const UiFunctions.NotifyNewProcessFn,
    pushfn: *const UiFunctions.PushBytesFn,
) !std.process.Child {
    switch (runtype) {
        .debugpy => {
            // work out if we need to run a module or script...
            return debugpy.runNonBlocking(alloc, pushfn, config, runnerif, createviewprocessfn);
        },
        .python => {
            return debugpy.runNonBlocking(alloc, pushfn, config, runnerif, createviewprocessfn);
        },
        .cppdbg => {
            return native.runNonBlocking(alloc, pushfn, config, runnerif, createviewprocessfn);
        },
        .cppvsdbg => {
            return native.runNonBlocking(alloc, pushfn, config, runnerif, createviewprocessfn);
        },
    }
}
