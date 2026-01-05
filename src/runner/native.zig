const std = @import("std");
const utils = @import("utils");
const runner = @import("runner.zig");
const launch = @import("config").Launch;

pub fn run(
    alloc: std.mem.Allocator,
    pushfn: *const utils.PushFnProto,
    config: *const launch.Configuration,
    _: *runner.RunnerContext,
    createprocessview: *const runner.UiFunctions.NotifyNewProcessFn,
) !void {
    var envmap: ?std.process.EnvMap = null;
    if (config.env) |envs| {
        envmap = try utils.create_env_map(alloc, envs);
    }
    defer {
        if (envmap) |*p| {
            p.deinit();
        }
    }

    if (config.program) |*program| {
        if (config.args) |*args| {
            const id = try createprocessview(alloc, program.*);
            return try run_native(alloc, pushfn, id, program.*, args.*, envmap);
        } else {
            const empty: []const []const u8 = &[_][]const u8{};
            const id = try createprocessview(alloc, program.*);
            return try run_native(alloc, pushfn, id, program.*, empty, envmap);
        }
    } else {
        return error.MissingConfigurationFields;
    }
}

pub fn runNonBlocking(
    alloc: std.mem.Allocator,
    pushfn: *const utils.PushFnProto,
    config: *const launch.Configuration,
    _: *runner.RunnerContext,
    createprocessview: *const runner.UiFunctions.NotifyNewProcessFn,
) !std.process.Child {
    var envmap: ?std.process.EnvMap = null;
    if (config.env) |envs| {
        envmap = try utils.create_env_map(alloc, envs);
    }
    defer {
        if (envmap) |*p| {
            p.deinit();
        }
    }

    if (config.program) |*program| {
        if (config.args) |*args| {
            const id = try createprocessview(alloc, program.*);
            return try run_native_nowait(alloc, pushfn, id, program.*, args.*, envmap);
        } else {
            const empty: []const []const u8 = &[_][]const u8{};
            const id = try createprocessview(alloc, program.*);
            return try run_native_nowait(alloc, pushfn, id, program.*, empty, envmap);
        }
    } else {
        return error.MissingConfigurationFields;
    }
}

fn run_native_nowait(
    allocator: std.mem.Allocator,
    pushfn: *const utils.PushFnProto,
    id: utils.uuid.UUID,
    program: []const u8,
    args: []const []const u8,
    envs: ?std.process.EnvMap,
) !std.process.Child {
    const num_prefix_args = 1;
    var argv: [][]const u8 = try allocator.alloc([]const u8, args.len + num_prefix_args);
    defer allocator.free(argv);
    argv[0] = program;
    for (args, num_prefix_args..argv.len) |arg, i| {
        argv[i] = arg;
    }

    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = std.process.Child.StdIo.Pipe;
    child.stderr_behavior = std.process.Child.StdIo.Pipe;
    if (envs) |*e| {
        child.env_map = e;
    }

    try child.spawn();
    //std.debug.print("Spawning child process: {d}\n", .{child.id});

    _ = try std.Thread.spawn(.{}, utils.pullpushLoop, .{ allocator, pushfn, child, id });
    return child;
}

fn run_native(
    allocator: std.mem.Allocator,
    pushfn: *const utils.PushFnProto,
    id: utils.uuid.UUID,
    program: []const u8,
    args: []const []const u8,
    envs: ?std.process.EnvMap,
) !void {
    const num_prefix_args = 1;
    var argv: [][]const u8 = try allocator.alloc([]const u8, args.len + num_prefix_args);
    defer allocator.free(argv);
    argv[1] = program;
    for (args, num_prefix_args..argv.len) |arg, i| {
        argv[i] = arg;
    }

    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = std.process.Child.StdIo.Pipe;
    child.stderr_behavior = std.process.Child.StdIo.Pipe;
    if (envs) |*e| {
        child.env_map = e;
    }
    child.spawn() catch |e| {
        //std.debug.print("Spawning module {any} failed.\n", .{e});
        return e;
    };

    _ = try std.Thread.spawn(.{}, utils.pullpushLoop, .{ allocator, pushfn, child, id });

    _ = child.wait() catch |e| {
        //std.debug.print("Waiting for child {any} failed.\n", .{e});
        return e;
    };

    //switch (term) {
    //    .Exited => |v| {
    //        //std.debug.print("Python exited with code {d}\n", .{v});
    //    },
    //    .Signal => |v| {
    //        //std.debug.print("Python signaled with code {d}\n", .{v});
    //    },
    //    .Stopped => |v| {
    //        //std.debug.print("Python stopped with code: {d}\n", .{v});
    //    },
    //    .Unknown => |v| {
    //        //std.debug.print("Unknown process error: {d}\n", .{v});
    //    },
    //}
}
