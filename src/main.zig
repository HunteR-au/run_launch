const std = @import("std");
const clap = @import("clap");

const utils = @import("utils.zig");
const Launch = @import("launch.zig");
const Task = @import("task.zig");
const uiview = @import("ui/uiview.zig");
const runner = @import("runner/runner.zig");

const RunLaunchErrors = error{
    BadPositionals,
    NoConfigWithName,
};

pub fn main() !void {
    const writer = std.io.getStdOut().writer();
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    try uiview.setupWebUI(allocator);

    const params = comptime clap.parseParamsComptime(
        \\-h, --help                    Display this help and exit
        \\-d, --dry-run                 Print out actions without executing them
        \\-t, --tasks    <str>          The path to the tasks.json file
        \\<str>                         The path to the launch.json file
        \\<str>                         The configuration name to run
    );

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0)
        return clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});
    if (res.args.@"dry-run" != 0)
        try writer.print("dry run set\n", .{});
    if (res.positionals[0] == null or res.positionals[1] == null) {
        try writer.print("Invalid format: use \"run_launch.exe path name\"\n", .{});
        return RunLaunchErrors.BadPositionals;
    }

    var tasks: ?Task.TaskJson = null;
    defer {
        if (tasks) |t| {
            t.deinit();
        }
    }
    if (res.args.tasks) |tasks_filepath| {
        tasks = try Task.TaskJson.init(allocator);
        try tasks.?.parse_tasks(tasks_filepath);
    }

    // we have parsed what we need from the arguments...lets go!
    const launchPath = res.positionals[0].?;
    const taskNameToRun: []const u8 = res.positionals[1].?;

    const launchdata = try Launch.parse_json(allocator, launchPath);
    defer launchdata.deinit(allocator);

    try writer.print("first positional arg: {s}\n", .{res.positionals[0].?});
    try writer.print("version: {s}\n", .{launchdata.version});
    try writer.print("first config name: {?s}\n", .{launchdata.configurations[0].name});

    _ = try runner.run(allocator, taskNameToRun, launchdata, tasks, uiview.createProcessView);
    // const nameMatch = launchdata.find_by_name(taskNameToRun) orelse {
    //     return RunLaunchErrors.NoConfigWithName;
    // };

    // switch (nameMatch) {
    //     .config => |config| {
    //         if (tasks != null and config.*.preLaunchTask != null) {
    //             if (tasks.?.find_by_label(config.preLaunchTask.?)) |task| {
    //                 try writer.print("Running task: {s}\n", .{config.preLaunchTask.?});
    //                 uiview.createProcessView(task.label.?);
    //                 try task.run_task(allocator);
    //             }
    //         }

    //         if (config.*.type != null and std.mem.eql(u8, config.*.type.?, "debugpy")) {
    //             if (config.*.module) |m| {
    //                 const empty: []const []const u8 = &[_][]const u8{};
    //                 if (config.*.args) |args| {
    //                     uiview.createProcessView(m);
    //                     try run_python_module(allocator, m, args);
    //                 } else {
    //                     uiview.createProcessView(m);
    //                     try run_python_module(allocator, m, empty);
    //                 }
    //             }
    //         }

    //         if (tasks != null and config.postDebugTask != null) {
    //             if (tasks.?.find_by_label(config.postDebugTask.?)) |task| {
    //                 uiview.createProcessView(task.label.?);
    //                 try task.run_task(allocator);
    //             }
    //         }
    //     },
    //     .compound => |compound| {
    //         if (tasks != null and compound.*.preLaunchTask != null) {
    //             if (tasks.?.find_by_label(compound.*.preLaunchTask.?)) |task| {
    //                 try writer.print("Running task: {s}\n", .{compound.*.preLaunchTask.?});
    //                 uiview.createProcessView(task.label.?);
    //                 try task.run_task(allocator);
    //             }

    //             var childArray = std.ArrayList(std.process.Child).init(allocator);

    //             for (compound.configurations.?) |configname| {
    //                 const config = launchdata.find_config_by_name(configname);

    //                 if (config) |c| {
    //                     std.debug.print("Running config: {s}\n", .{configname});
    //                     if (c.type != null and std.mem.eql(u8, c.type.?, "debugpy")) {
    //                         if (c.module) |m| {
    //                             const empty: []const []const u8 = &[_][]const u8{};
    //                             if (c.args) |args| {
    //                                 uiview.createProcessView(m);
    //                                 const child = try run_python_module_nowait(allocator, m, args);
    //                                 try childArray.append(child);
    //                             } else {
    //                                 uiview.createProcessView(m);
    //                                 const child = try run_python_module_nowait(allocator, m, empty);
    //                                 try childArray.append(child);
    //                             }
    //                         }
    //                     }
    //                 }

    //                 try writer.print("Waiting for each process to finish...\n", .{});
    //                 // Wait for each child process to finish
    //                 for (childArray.items) |*child| {
    //                     _ = try child.wait();
    //                 }
    //             }
    //         }
    //     },
    // }

    uiview.closeWebUI();
}

pub fn run_python_script_nowait(allocator: std.mem.Allocator, script: []const u8, args: []const []const u8) !std.process.Child {
    var argv: [][]const u8 = try allocator.alloc([]u8, args.len + 2);
    defer allocator.free(argv);
    argv[0] = "py";
    argv[1] = script;
    for (args, 2..argv.len) |arg, i| {
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
    var argv: [][]const u8 = try allocator.alloc([]u8, args.len + 2);
    defer allocator.free(argv);
    argv[0] = "py";
    argv[1] = script;
    for (args, 2..argv.len) |arg, i| {
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

pub fn run_python_module_nowait(allocator: std.mem.Allocator, module: []const u8, args: []const []const u8) !std.process.Child {
    var argv: [][]const u8 = try allocator.alloc([]const u8, args.len + 3);
    defer allocator.free(argv);
    argv[0] = "py";
    argv[1] = "-m";
    argv[2] = module;
    for (args, 3..argv.len) |arg, i| {
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
    var argv: [][]const u8 = try allocator.alloc([]const u8, args.len + 3);
    defer allocator.free(argv);
    argv[0] = "py";
    argv[1] = "-m";
    argv[2] = module;
    for (args, 3..argv.len) |arg, i| {
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

// https://code.visualstudio.com/docs/editor/debugging#_launchjson-attributes
// The following are madatory for every launch configuration:
// type, request, name

// Some optional (but available to all configurations)
// presentation, preLaunchTask, postDebugTask, internalConsoleOptions, debugServer, serverReadyAction

// Common options MOST debuggers support
// program, args, env, envFile, cwd, port, stopOnEntry, console

// QUESTIONS: how to do variable substitution... I have no idea. Maybe manually setting env vars + extra args
// QUESTIONS,  can I support compounds?
// TODO: parse and execute tasks

// PYTHON OPTIONS
//
// {
//  "name": "Python Debugger: Attach",
//  "type": "debugpy",
//  "request": "attach",
//  "connect": {
//    "host": "localhost",
//    "port": 5678
//  }
// }

// this would convert to python -m debugpy --listen 5678 ./myscript.py

// TODO: currently can only run python modules!!! We need to be able to run python scripts

// TODO: python - force no debug (ie no debugpy in process execute)
// TODO: python - deal with connect fields
// TODO: Add env dot file arg
// TODO: Add support for dry-run
// TODO: tasks
// TODO: tasks - problemMatcher - pretty complex data and logic...
// TODO: use webUI to print debug output to a brower (have to create a cli prompt in html/js/web-tech :(   )
// TODO: make the main thread tear down if webui clicks exit

// TODO: BUG - current settings don't apply to non-active outputs (need to refresh)
// TODO: add grep notifications to the UI with config (pattern, contification color)
// TODO: add line numbers to each debug view
// TODO: add the ability to jump to a line via js
// TODO: add the ability to fold between lines with a pattern
// TODO: add config on disk to read from user folder or local folder (DONE)
// TODO: create command line at the bottom to do actions such as search, jump, add colorgrep
// TODO: change HR to DIV
// TODO: format process names in some more useful way...
// TODO: expand/collapse settings by clicking on the process headers on the sidebar
// TODO: signal to the UI when a process ends!!!
//
// IDEA: be able to set a target over ssh...might be too hard for such a project :D

// TASK EXAMPLE:
//
//{
//    // See https://go.microsoft.com/fwlink/?LinkId=733558
//    // for the documentation about the tasks.json format
//    "version": "2.0.0",
//    "tasks": [
//        {
//            "label": "build",
//            "type": "shell",
//            "command": "msbuild",
//            "args": [
//                // Ask msbuild to generate full paths for file names.
//                "/property:GenerateFullPaths=true",
//                "/t:build",
//                // Do not generate summary otherwise it leads to duplicate errors in Problems panel
//                "/consoleloggerparameters:NoSummary"
//            ],
//            "group": "build",
//            "presentation": {
//                // Reveal the output only if unrecognized errors occur.
//                "reveal": "silent"
//            },
//            // Use the standard MS compiler pattern to detect errors, warnings and infos
//            "problemMatcher": "$msCompile"
//        }
//    ]
//}
