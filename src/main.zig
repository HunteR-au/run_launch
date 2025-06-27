const std = @import("std");
const clap = @import("clap");

const utils = @import("utils.zig");
const Launch = @import("launch.zig");
const Task = @import("task.zig");
const uiview = @import("ui/uiview.zig");
const tui = @import("tui");
const runner = @import("runner/runner.zig");

const vaxis = @import("dependencies/vaxis");

const RunLaunchErrors = error{
    BadPositionals,
    NoConfigWithName,
};

pub fn main() !void {
    const writer = std.io.getStdOut().writer();
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help                    Display this help and exit
        \\-d, --dry-run                 Print out actions without executing them
        \\-w, --web-ui                  Render the web ui interface
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

    if (res.args.@"web-ui" != 0) {
        try uiview.setupWebUI(allocator);
    } else {
        try tui.start_tui(allocator);
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

    //try writer.print("first positional arg: {s}\n", .{res.positionals[0].?});
    //try writer.print("version: {s}\n", .{launchdata.version});
    //try writer.print("first config name: {?s}\n", .{launchdata.configurations[0].name});

    //_ = taskNameToRun;
    if (res.args.@"web-ui" != 0) {
        _ = try runner.run(allocator, taskNameToRun, launchdata, tasks, uiview.createProcessView, uiview.pushLogging);
    } else {
        _ = try runner.run(allocator, taskNameToRun, launchdata, tasks, tui.createProcessView, tui.pushLogging);
    }

    if (res.args.@"web-ui" != 0) {
        uiview.closeWebUI();
    } else {
        tui.stop_tui();
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

// TODO: python - force no debug (ie no debugpy in process execute)
// TODO: python - deal with connect fields
// TODO: Add env dot file arg!!!!!!! (envFile) (DONE)
// TODO: Add support for dry-run
// TODO: tasks
// TODO: tasks - problemMatcher - pretty complex data and logic...
// TODO: make the main thread tear down if webui clicks exit
//
// TODO: create code to parse and run envFile (DONE)
// TODO: add labels to configuration logic (DONE)
// TODO: try webview-zig
// TODO: for tui mode try - libvaxis

// TODO: BUG - current settings don't apply to non-active outputs (need to refresh)
// TODO: BUG - there is an extra count in the last fold that shouldn't be there
// TODO: BUG - there is an issue with cmd.exe /c dir C:\Windows blocking on pipes
//                something is wrong with pushpull
// TODO: add grep notifications to the UI with config (pattern, contification color)
// TODO: add line numbers to each debug view
// TODO: add the ability to jump to a line via js
// TODO: add the ability to fold between lines with a pattern (DONE)
// TODO: add config on disk to read from user folder or local folder (DONE)
// TODO: create command line at the bottom to do actions such as search, jump, add colorgrep
// TODO: format process names in some more useful way...
// TODO: expand/collapse settings by clicking on the process headers on the sidebar
// TODO: signal to the UI when a process ends!!!
// TODO: add timestamp to lines so that you can merge two or more feeds into 1 view merge: name name
// TODO: help command that shows a debug view with all the help output
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
