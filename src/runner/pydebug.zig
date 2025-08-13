const std = @import("std");
const utils = @import("utils");
const runner = @import("runner.zig");
const launch = @import("../launch.zig");
const builtin = @import("builtin");

const python_default_path = switch (builtin.target.os.tag) {
    .windows => "py",
    else => "python3",
};

pub fn run(
    alloc: std.mem.Allocator,
    pushfn: utils.PushFnProto,
    config: *const launch.Configuration,
    _: *runner.Runner,
    createprocessview: fn (std.mem.Allocator, []const u8) std.mem.Allocator.Error!void,
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

    if (config.module) |*module| {
        if (config.args) |*args| {
            try createprocessview(alloc, module.*);
            return try run_python_module(alloc, pushfn, config, module.*, args.*, envmap);
        } else {
            const empty: []const []const u8 = &[_][]const u8{};
            try createprocessview(alloc, module.*);
            return try run_python_module(alloc, pushfn, config, module.*, empty, envmap);
        }
    }
    if (config.program) |*program| {
        if (config.args) |*args| {
            try createprocessview(alloc, program.*);
            return try run_python_script(alloc, pushfn, config, program.*, args.*, envmap);
        } else {
            const empty: []const []const u8 = &[_][]const u8{};
            try createprocessview(alloc, program.*);
            return try run_python_script(alloc, pushfn, config, program.*, empty, envmap);
        }
    } else {
        return error.MissingConfigurationFields;
    }
}

pub fn runNonBlocking(
    alloc: std.mem.Allocator,
    pushfn: utils.PushFnProto,
    config: *const launch.Configuration,
    _: *runner.Runner,
    createprocessview: fn (std.mem.Allocator, []const u8) std.mem.Allocator.Error!void,
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

    // TODO - if module and program set (program points to the python exe to run)
    if (config.module) |*module| {
        if (config.args) |*args| {
            try createprocessview(alloc, module.*);
            return try run_python_module_nowait(alloc, pushfn, config, module.*, args.*, envmap);
        } else {
            const empty: []const []const u8 = &[_][]const u8{};
            try createprocessview(alloc, module.*);
            return try run_python_module_nowait(alloc, pushfn, config, module.*, empty, envmap);
        }
    }
    if (config.program) |*program| {
        if (config.args) |*args| {
            try createprocessview(alloc, program.*);
            return try run_python_script_nowait(alloc, pushfn, config, program.*, args.*, envmap);
        } else {
            const empty: []const []const u8 = &[_][]const u8{};
            try createprocessview(alloc, program.*);
            return try run_python_script_nowait(alloc, pushfn, config, program.*, empty, envmap);
        }
    } else {
        return error.MissingConfigurationFields;
    }
}

fn run_python_script_nowait(
    allocator: std.mem.Allocator,
    pushfn: utils.PushFnProto,
    config: *const launch.Configuration,
    script: []const u8,
    args: []const []const u8,
    envs: ?std.process.EnvMap,
) !std.process.Child {
    const num_prefix_args = 3;
    var argv: [][]const u8 = try allocator.alloc([]const u8, args.len + num_prefix_args);
    defer allocator.free(argv);
    argv[0] = python_default_path;
    argv[1] = "-u"; // don't buffer stdout/stderr
    argv[2] = script;
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

    const dbgview_name = if (config.consoleTitle != null) config.consoleTitle.? else script;
    _ = try std.Thread.spawn(.{}, utils.pullpushLoop, .{ allocator, pushfn, child, dbgview_name });
    return child;
}

fn run_python_script(
    allocator: std.mem.Allocator,
    pushfn: utils.PushFnProto,
    config: *const launch.Configuration,
    script: []const u8,
    args: []const []const u8,
    envs: ?std.process.EnvMap,
) !void {
    const num_prefix_args = 3;
    var argv: [][]const u8 = try allocator.alloc([]const u8, args.len + num_prefix_args);
    defer allocator.free(argv);
    argv[0] = python_default_path;
    argv[1] = "-u";
    argv[2] = script;
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

    const dbgview_name = if (config.consoleTitle != null) config.consoleTitle.? else script;
    _ = try std.Thread.spawn(.{}, utils.pullpushLoop, .{ allocator, pushfn, child, dbgview_name });

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

pub fn run_python_module_nowait(
    allocator: std.mem.Allocator,
    pushfn: utils.PushFnProto,
    config: *const launch.Configuration,
    module: []const u8,
    args: []const []const u8,
    envs: ?std.process.EnvMap,
) !std.process.Child {
    const num_prefix_args = 4;
    var argv: [][]const u8 = try allocator.alloc([]const u8, args.len + num_prefix_args);
    defer allocator.free(argv);
    if (config.program != null) {
        argv[0] = config.program.?;
    } else {
        argv[0] = python_default_path;
    }
    argv[1] = "-u";
    argv[2] = "-m";
    argv[3] = module;
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

    const dbgview_name = if (config.consoleTitle != null) config.consoleTitle.? else module;
    _ = try std.Thread.spawn(.{}, utils.pullpushLoop, .{ allocator, pushfn, child, dbgview_name });
    return child;
}

pub fn run_python_module(
    allocator: std.mem.Allocator,
    pushfn: utils.PushFnProto,
    config: *const launch.Configuration,
    module: []const u8,
    args: []const []const u8,
    envs: ?std.process.EnvMap,
) !void {
    const num_prefix_args = 4;
    var argv: [][]const u8 = try allocator.alloc([]const u8, args.len + num_prefix_args);
    defer allocator.free(argv);
    if (config.program != null) {
        argv[0] = config.program.?;
    } else {
        argv[0] = python_default_path;
    }
    argv[1] = "-u";
    argv[2] = "-m";
    argv[3] = module;
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

    const dbgview_name = if (config.consoleTitle != null) config.consoleTitle.? else module;
    _ = try std.Thread.spawn(.{}, utils.pullpushLoop, .{ allocator, pushfn, child, dbgview_name });

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
