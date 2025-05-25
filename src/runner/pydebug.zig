const std = @import("std");
const utils = @import("../utils.zig");
const runner = @import("runner.zig");
const launch = @import("../launch.zig");

pub fn run(
    alloc: std.mem.Allocator,
    config: *const launch.Configuration,
    _: *runner.Runner,
    createprocessview: fn ([]const u8) void,
) !void {
    if (config.module) |*module| {
        if (config.args) |*args| {
            createprocessview(module.*);
            return try run_python_module(alloc, module.*, args.*);
        } else {
            const empty: []const []const u8 = &[_][]const u8{};
            createprocessview(module.*);
            return try run_python_module(alloc, module.*, empty);
        }
    }
    if (config.program) |*program| {
        if (config.args) |*args| {
            createprocessview(program.*);
            return try run_python_script(alloc, program.*, args.*);
        } else {
            std.debug.print("WHATTHEFUCK\n", .{});
            const empty: []const []const u8 = &[_][]const u8{};
            createprocessview(program.*);
            return try run_python_script(alloc, program.*, empty);
        }
    } else {
        return error.MissingConfigurationFields;
    }
}

pub fn runNonBlocking(
    alloc: std.mem.Allocator,
    config: *const launch.Configuration,
    _: *runner.Runner,
    createprocessview: fn ([]const u8) void,
) !std.process.Child {
    if (config.module) |*module| {
        if (config.args) |*args| {
            createprocessview((module.*));
            return try run_python_module_nowait(alloc, module.*, args.*);
        } else {
            const empty: []const []const u8 = &[_][]const u8{};
            createprocessview((module.*));
            std.debug.print("WHATTHEFUCK\n", .{});
            return try run_python_module_nowait(alloc, module.*, empty);
        }
    }
    if (config.program) |*program| {
        if (config.args) |*args| {
            createprocessview((program.*));
            return try run_python_script_nowait(alloc, program.*, args.*);
        } else {
            const empty: []const []const u8 = &[_][]const u8{};
            createprocessview((program.*));
            return try run_python_script_nowait(alloc, program.*, empty);
        }
    } else {
        return error.MissingConfigurationFields;
    }
}

pub fn run_python_script_nowait(allocator: std.mem.Allocator, script: []const u8, args: []const []const u8) !std.process.Child {
    const num_prefix_args = 3;
    var argv: [][]const u8 = try allocator.alloc([]const u8, args.len + num_prefix_args);
    defer allocator.free(argv);
    argv[0] = "py";
    argv[1] = "-u"; // don't buffer stdout/stderr
    argv[2] = script;
    for (args, num_prefix_args..argv.len) |arg, i| {
        argv[i] = arg;
    }

    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = std.process.Child.StdIo.Pipe;
    child.stderr_behavior = std.process.Child.StdIo.Pipe;

    try child.spawn();
    std.debug.print("Spawning child process: {d}\n", .{child.id});

    _ = try std.Thread.spawn(.{}, utils.pullpushLoop, .{ allocator, child, script });
    return child;
}

pub fn run_python_script(allocator: std.mem.Allocator, script: []const u8, args: []const []const u8) !void {
    const num_prefix_args = 3;
    var argv: [][]const u8 = try allocator.alloc([]const u8, args.len + num_prefix_args);
    defer allocator.free(argv);
    argv[0] = "py";
    argv[1] = "-u";
    argv[2] = script;
    for (args, num_prefix_args..argv.len) |arg, i| {
        argv[i] = arg;
    }

    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = std.process.Child.StdIo.Pipe;
    child.stderr_behavior = std.process.Child.StdIo.Pipe;
    child.spawn() catch |e| {
        std.debug.print("Spawning module {any} failed.\n", .{e});
        return e;
    };

    _ = try std.Thread.spawn(.{}, utils.pullpushLoop, .{ allocator, child, script });

    const term = child.wait() catch |e| {
        std.debug.print("Waiting for child {any} failed.\n", .{e});
        return e;
    };

    switch (term) {
        .Exited => |v| {
            std.debug.print("Python exited with code {d}\n", .{v});
        },
        .Signal => |v| {
            std.debug.print("Python signaled with code {d}\n", .{v});
        },
        .Stopped => |v| {
            std.debug.print("Python stopped with code: {d}\n", .{v});
        },
        .Unknown => |v| {
            std.debug.print("Unknown process error: {d}\n", .{v});
        },
    }
}

pub fn run_python_module_nowait(
    allocator: std.mem.Allocator,
    module: []const u8,
    args: []const []const u8,
) !std.process.Child {
    const num_prefix_args = 4;
    var argv: [][]const u8 = try allocator.alloc([]const u8, args.len + num_prefix_args);
    defer allocator.free(argv);
    argv[0] = "py";
    argv[1] = "-u";
    argv[2] = "-m";
    argv[3] = module;
    for (args, num_prefix_args..argv.len) |arg, i| {
        argv[i] = arg;
    }

    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = std.process.Child.StdIo.Pipe;
    child.stderr_behavior = std.process.Child.StdIo.Pipe;

    try child.spawn();
    std.debug.print("Spawning child process: {d}\n", .{child.id});

    _ = try std.Thread.spawn(.{}, utils.pullpushLoop, .{ allocator, child, module });
    return child;
}

pub fn run_python_module(allocator: std.mem.Allocator, module: []const u8, args: []const []const u8) !void {
    const num_prefix_args = 4;
    var argv: [][]const u8 = try allocator.alloc([]const u8, args.len + num_prefix_args);
    defer allocator.free(argv);
    argv[0] = "py";
    argv[1] = "-u";
    argv[2] = "-m";
    argv[3] = module;
    for (args, num_prefix_args..argv.len) |arg, i| {
        argv[i] = arg;
    }

    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = std.process.Child.StdIo.Pipe;
    child.stderr_behavior = std.process.Child.StdIo.Pipe;
    child.spawn() catch |e| {
        std.debug.print("Spawning module {any} failed.\n", .{e});
        return e;
    };

    _ = try std.Thread.spawn(.{}, utils.pullpushLoop, .{ allocator, child, module });

    const term = child.wait() catch |e| {
        std.debug.print("Waiting for child {any} failed.\n", .{e});
        return e;
    };

    switch (term) {
        .Exited => |v| {
            std.debug.print("Python exited with code {d}\n", .{v});
        },
        .Signal => |v| {
            std.debug.print("Python signaled with code {d}\n", .{v});
        },
        .Stopped => |v| {
            std.debug.print("Python stopped with code: {d}\n", .{v});
        },
        .Unknown => |v| {
            std.debug.print("Unknown process error: {d}\n", .{v});
        },
    }
}
