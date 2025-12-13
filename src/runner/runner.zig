const std = @import("std");
const utils = @import("utils");
const Launch = @import("../config/launch.zig");
const Task = @import("../config/task.zig");
const debugpy = @import("pydebug.zig");
const native = @import("native.zig");

pub const RunnerConfig = union(enum) {
    config: Launch.Configuration,
    compound: Launch.Compound,
};

pub const Runner = struct {
    _alloc: std.mem.Allocator,
    children: std.ArrayList(std.process.Child),
    config: Launch.Launch.ConfigOrCompound,
    // config: RunnerConfig,
    launch: Launch.Launch,
    tasks: ?Task.TaskJson = null,
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
    launchconfig: Launch.Launch,
    tasks: ?Task.TaskJson,
    createviewprocessfn: fn (std.mem.Allocator, []const u8) std.mem.Allocator.Error!void,
    pushfn: utils.PushFnProto,
) !Runner {
    const match = launchconfig.find_by_name(name) orelse {
        return error.NoConfigWithName;
    };

    var runnerif = Runner{
        .children = try std.ArrayList(std.process.Child).initCapacity(alloc, 10),
        .config = match,
        .launch = launchconfig,
        .tasks = tasks,
        ._alloc = alloc,
    };

    switch (match) {
        .config => |config| {
            // check if there is a preLaunchTask to run
            try runPreLaunchTask(alloc, *const Launch.Configuration, config, tasks, createviewprocessfn, pushfn);
            // if (config.preLaunchTask != null) {
            //     try findRunTask(alloc, config.preLaunchTask.?, tasks);
            // }

            // assume that type is set
            const runnertype = std.meta.stringToEnum(RunnerType, config.type.?) orelse {
                return error.InvalidChoice;
            };
            try runRunnerType(alloc, runnertype, config, &runnerif, createviewprocessfn, pushfn);

            // check if there is a post debug task to run
            try runPostLaunchTask(alloc, *const Launch.Configuration, config, tasks, pushfn);
            // if (config.postDebugTask != null) {
            //     try findRunTask(alloc, config.postDebugTask.?, tasks);
            // }
        },
        .compound => |compound| {
            try runPreLaunchTask(alloc, *const Launch.Compound, compound, tasks, createviewprocessfn, pushfn);

            for (compound.configurations.?) |configname| {
                const configmatch = launchconfig.find_config_by_name(configname);
                if (configmatch) |config| {
                    //std.debug.print("Running config: {s}\n", .{configname});

                    // TODO - we probably want to run each config's pre/post tasks

                    const runnertype = std.meta.stringToEnum(RunnerType, config.type.?) orelse {
                        return error.InvalidChoice;
                    };
                    const child = try runRunnerTypeNonBlocking(alloc, runnertype, config, &runnerif, createviewprocessfn, pushfn);
                    try runnerif.children.append(runnerif._alloc, child);
                }
            }

            // wait for each child process
            //try writer.print("Waiting for each process to finish...\n", .{});
            for (runnerif.children.items) |*child| {
                _ = try child.wait();
            }

            try runPostLaunchTask(alloc, *const Launch.Compound, compound, tasks, pushfn);
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
    tasks: ?Task.TaskJson,
    createviewprocessfn: fn (std.mem.Allocator, []const u8) std.mem.Allocator.Error!void,
    pushfn: utils.PushFnProto,
) !void {
    if (launchdata.preLaunchTask != null) {
        try findRunTask(alloc, launchdata.preLaunchTask.?, tasks, createviewprocessfn, pushfn);
    }
}

fn runPostLaunchTask(
    alloc: std.mem.Allocator,
    T: type,
    launchdata: T,
    tasks: ?Task.TaskJson,
    pushfn: utils.PushFnProto,
) !void {
    if (launchdata.postDebugTask != null) {
        try findRunTask(alloc, launchdata.postDebugTask.?, tasks, null, pushfn);
    }
}

fn findRunTask(
    alloc: std.mem.Allocator,
    taskname: []const u8,
    tasks: ?Task.TaskJson,
    createviewprocessfn: ?fn (std.mem.Allocator, []const u8) std.mem.Allocator.Error!void,
    pushfn: utils.PushFnProto,
) !void {
    if (tasks != null) {
        if (tasks.?.find_by_label(taskname)) |task| {
            if (createviewprocessfn) |create_fn| {
                try create_fn(alloc, taskname);
            }
            try task.run_task(alloc, pushfn);
        }
    }
}

fn runRunnerType(
    alloc: std.mem.Allocator,
    runtype: RunnerType,
    config: *const Launch.Configuration,
    runnerif: *Runner,
    createviewprocessfn: fn (std.mem.Allocator, []const u8) std.mem.Allocator.Error!void,
    pushfn: utils.PushFnProto,
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
    config: *const Launch.Configuration,
    runnerif: *Runner,
    createviewprocessfn: fn (std.mem.Allocator, []const u8) std.mem.Allocator.Error!void,
    pushfn: utils.PushFnProto,
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
