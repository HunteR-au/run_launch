const std = @import("std");
const utils = @import("../utils.zig");
const Launch = @import("../launch.zig");
const Task = @import("../task.zig");
const debugpy = @import("pydebug.zig");
const native = @import("native.zig");

pub const RunnerConfig = union(enum) {
    config: Launch.Configuration,
    compound: Launch.Compound,
};

pub const Runner = struct {
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
    createviewprocessfn: fn ([]const u8) void,
) !Runner {
    const match = launchconfig.find_by_name(name) orelse {
        return error.NoConfigWithName;
    };

    var runnerif = Runner{
        .children = std.ArrayList(std.process.Child).init(alloc),
        .config = match,
        .launch = launchconfig,
        .tasks = tasks,
    };

    switch (match) {
        .config => |config| {
            // check if there is a preLaunchTask to run
            try runPreLaunchTask(alloc, *const Launch.Configuration, config, tasks);
            // if (config.preLaunchTask != null) {
            //     try findRunTask(alloc, config.preLaunchTask.?, tasks);
            // }

            // assume that type is set
            const runnertype = std.meta.stringToEnum(RunnerType, config.type.?) orelse {
                return error.InvalidChoice;
            };
            try runRunnerType(alloc, runnertype, config, &runnerif, createviewprocessfn);

            // check if there is a post debug task to run
            try runPostLaunchTask(alloc, *const Launch.Configuration, config, tasks);
            // if (config.postDebugTask != null) {
            //     try findRunTask(alloc, config.postDebugTask.?, tasks);
            // }
        },
        .compound => |compound| {
            try runPreLaunchTask(alloc, *const Launch.Compound, compound, tasks);

            for (compound.configurations.?) |configname| {
                const configmatch = launchconfig.find_config_by_name(configname);
                if (configmatch) |config| {
                    std.debug.print("Running config: {s}\n", .{configname});

                    // TODO - we probably want to run each config's pre/post tasks

                    const runnertype = std.meta.stringToEnum(RunnerType, config.type.?) orelse {
                        return error.InvalidChoice;
                    };
                    const child = try runRunnerTypeNonBlocking(alloc, runnertype, config, &runnerif, createviewprocessfn);
                    try runnerif.children.append(child);
                }
            }

            // wait for each child process
            //try writer.print("Waiting for each process to finish...\n", .{});
            for (runnerif.children.items) |*child| {
                _ = try child.wait();
            }

            try runPostLaunchTask(alloc, *const Launch.Compound, compound, tasks);
        },
    }
    // not even sure if returning runner interface makes sense...
    // we are returning after
    return runnerif;
}

fn runPreLaunchTask(alloc: std.mem.Allocator, T: type, launchdata: T, tasks: ?Task.TaskJson) !void {
    if (launchdata.preLaunchTask != null) {
        try findRunTask(alloc, launchdata.preLaunchTask.?, tasks);
    }
}

fn runPostLaunchTask(alloc: std.mem.Allocator, T: type, launchdata: T, tasks: ?Task.TaskJson) !void {
    if (launchdata.postDebugTask != null) {
        try findRunTask(alloc, launchdata.postDebugTask.?, tasks);
    }
}

fn findRunTask(alloc: std.mem.Allocator, taskname: []const u8, tasks: ?Task.TaskJson) !void {
    if (tasks != null) {
        if (tasks.?.find_by_label(taskname)) |task| {
            try task.run_task(alloc);
        }
    }
}

fn runRunnerType(
    alloc: std.mem.Allocator,
    runtype: RunnerType,
    config: *const Launch.Configuration,
    runnerif: *Runner,
    createviewprocessfn: fn ([]const u8) void,
) !void {
    switch (runtype) {
        .debugpy => {
            // work out if we need to run a module or script...
            try debugpy.run(alloc, config, runnerif, createviewprocessfn);
        },
        .python => {
            try debugpy.run(alloc, config, runnerif, createviewprocessfn);
        },
        .cppdbg => {
            try native.run(alloc, config, runnerif, createviewprocessfn);
        },
        .cppvsdbg => {
            try native.run(alloc, config, runnerif, createviewprocessfn);
        },
    }
}

fn runRunnerTypeNonBlocking(
    alloc: std.mem.Allocator,
    runtype: RunnerType,
    config: *const Launch.Configuration,
    runnerif: *Runner,
    createviewprocessfn: fn ([]const u8) void,
) !std.process.Child {
    switch (runtype) {
        .debugpy => {
            // work out if we need to run a module or script...
            return debugpy.runNonBlocking(alloc, config, runnerif, createviewprocessfn);
        },
        .python => {
            return debugpy.runNonBlocking(alloc, config, runnerif, createviewprocessfn);
        },
        .cppdbg => {
            return native.runNonBlocking(alloc, config, runnerif, createviewprocessfn);
        },
        .cppvsdbg => {
            return native.runNonBlocking(alloc, config, runnerif, createviewprocessfn);
        },
    }
}
