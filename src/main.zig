const std = @import("std");
const Io = std.Io;
const clap = @import("clap");

const utils = @import("utils");
const config_ = @import("config");
const tui = @import("tui");
const runner = @import("runner");
const ui_debug = @import("debug_ui");
const pump_ = @import("pump");

const ztracy = @import("ztracy");

const builtin = @import("builtin");
const debug = (builtin.mode == std.builtin.OptimizeMode.Debug);

const RunLaunchErrors = error{
    BadPositionals,
    NoConfigWithName,
};

var g_log_file: ?std.Io.File = null;
var g_log_mutex: std.Io.Mutex = .init;
var g_log_buffer: [4096]u8 = undefined;
var g_log_writer: std.Io.File.Writer = undefined;

pub fn initLogger(io: Io, path: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    g_log_file = file;
    g_log_writer = g_log_file.?.writer(io, &g_log_buffer);
}

pub fn deinitLogger() void {
    if (g_log_file) |file| {
        g_log_mutex.lockUncancelable(debug_log_io);
        defer g_log_mutex.unlock(debug_log_io);
        g_log_writer.interface.flush() catch {};
        g_log_file = null;
        file.close(debug_log_io);
    }
}

pub const std_options: std.Options = .{
    .logFn = logFn,
    // the YAML library traces every token at debug level; keep logs.txt readable
    .log_scope_levels = &.{
        .{ .scope = .yaml, .level = .warn },
        .{ .scope = .tokenizer, .level = .warn },
        .{ .scope = .parser, .level = .warn },
    },
};

var debug_log_io: Io = undefined;

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    if (g_log_file) |_| {
        g_log_mutex.lockUncancelable(debug_log_io);
        defer g_log_mutex.unlock(debug_log_io);

        var writer = &g_log_writer.interface;
        writer.print("[{s}] [{s}] " ++ format ++ "\n", .{
            @tagName(level),
            @tagName(scope),
        } ++ args) catch |e| {
            std.debug.print("ERROR: {any}", .{e});
        };

        writer.flush() catch |e| {
            std.debug.print("ERROR: {any}", .{e});
        };
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    debug_log_io = io;

    const tracy_zone = ztracy.ZoneNC(@src(), "Compute Magic", 0x00_ff_00_00);
    defer tracy_zone.End();

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    // Required to push buffered output to the terminal
    defer stdout.flush() catch {};

    if (debug) {
        try initLogger(io, "logs.txt");
    }
    defer if (debug) deinitLogger();

    const alloc = gpa;

    const params = comptime clap.parseParamsComptime(
        \\-h, --help                    Display this help and exit
        \\-d, --dry-run                 Print out actions without executing them
        \\-w, --web-ui                  Render the web ui interface
        \\<str>                         The path to the launch file (see CONFIG.md)
        \\<str>                         The process or group to start; without it the
        \\                              file's `default:`, or everything
    );

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, init.minimal.args, .{
        .diagnostic = &diag,
        .allocator = alloc,
    }) catch |err| {
        diag.report(stdout, err) catch {};
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0)
        return clap.help(stdout, clap.Help, &params, .{});
    if (res.args.@"dry-run" != 0)
        try stdout.print("dry run set\n", .{});
    if (res.positionals[0] == null) {
        try stdout.print("Invalid format: use \"runlaunch.exe path [name]\"\n", .{});
        return RunLaunchErrors.BadPositionals;
    }
    if (res.args.@"web-ui" != 0) {
        try stdout.print("The web ui is not currently supported\n", .{});
        return;
    }

    // we have parsed what we need from the arguments...lets go!
    const launchPath = res.positionals[0].?;
    const nameToRun: ?[]const u8 = res.positionals[1];

    // parse configuration (`${...}` tokens resolve against the process environment)
    config_.expand.init_expand(init.environ_map);
    defer config_.expand.deinit_expand();
    var config_diag: config_.Diagnostics = .{};
    var config = config_.parseFile(io, alloc, launchPath, &config_diag) catch |err| {
        if (config_diag.message().len > 0) {
            try stdout.print("could not load {s}: {s}\n", .{ launchPath, config_diag.message() });
        } else {
            try stdout.print("could not load {s}: {t}\n", .{ launchPath, err });
        }
        // a usage error: the message is the whole story, no error trace behind it
        try stdout.flush();
        std.process.exit(1);
    };
    // ours until the runner takes it
    var config_moved = false;
    errdefer if (!config_moved) config.deinit();

    const target = config.resolve(nameToRun) orelse {
        try stdout.print("{s} has no process or group called \"{s}\". It has:", .{ launchPath, nameToRun.? });
        for (config.processes) |p| try stdout.print(" {s}", .{p.name});
        for (config.groups) |g| try stdout.print(" {s}", .{g.name});
        try stdout.print("\n", .{});
        try stdout.flush();
        std.process.exit(1);
    };
    if (target == .all and target.all.len == 0) {
        try stdout.print("{s} has nothing to start: every process is another one's preTask/postTask. Add `default:` or name a process or group.\n", .{launchPath});
        try stdout.flush();
        std.process.exit(1);
    }

    // The store owns every buffer; the pump feeds it; the runner produces; the TUI reads
    // snapshots and posts commands.
    const store = try tui.IngestStore.init(alloc, io);
    defer store.deinit();
    const pump = try pump_.Pump.init(alloc, io, store.sink(), .{});
    defer pump.deinit();
    store.attach(pump);

    // the runner owns the configuration from here on
    const executor = try runner.ConfiguredRunner.init(alloc, config, pump);
    config_moved = true;
    defer executor.deinit(io);

    var tui_env_map = try init.environ_map.clone(alloc);
    defer tui_env_map.deinit();

    try tui.start_tui(io, alloc, executor, pump, store, &tui_env_map);
    try pump.start();

    std.log.debug("launch file: {s}\n", .{launchPath});
    std.log.debug("processes: {d}, groups: {d}\n", .{ executor.config.processes.len, executor.config.groups.len });

    var run_handle: ?runner.WorkHandle = null;
    var post_handle: ?runner.WorkHandle = null;

    defer if (run_handle) |*h| h.deinit();
    defer if (post_handle) |*h| h.deinit();

    if (debug) {
        try ui_debug.init(io, pump);
    }
    // pre tasks are spawned here; the processes behind them start from the TUI's tick once
    // those tasks have finished (`ConfiguredRunner.startReady`)
    run_handle = try executor.runStartup(io, nameToRun);

    try tui.waitForTUIClose(io);
    std.log.info("shutdown: tui closed", .{});

    // Shutdown order:
    // 1. children are terminated and their readers joined (the model is still alive, so any
    //    last output is delivered);
    // 2. post tasks run to completion, their output fully read;
    // 3. the pump is closed and drained, so nothing can write into the buffers any more;
    // 4. the TUI thread is joined and the model freed;
    // 5. deferred: runner, pump, store (frees the buffers), logger.
    if (debug) ui_debug.deinit();

    try executor.killAll(io);
    std.log.info("shutdown: children stopped", .{});
    post_handle = try executor.runPostTasks(io, nameToRun, .blocking);
    if (post_handle) |*h| try h.waitAllDone(io);
    std.log.info("shutdown: post tasks done", .{});

    pump.stop();
    std.log.info("shutdown: pump stopped", .{});
    tui.stop_tui(io);
    std.log.info("shutdown: tui thread joined", .{});
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

// further ideas for driving the program beyond launch.json
// - a custom yml format which I can add what I want
//      - etw events, other IPC??
// - the ability to launch more programs after starting
// -

// TODO: python - force no debug (ie no debugpy in process execute)
// TODO: python - deal with connect fields
// TODO: Add env dot file arg!!!!!!! (envFile) (DONE)
// TODO: Add support for dry-run
// TODO: tasks
// TODO: tasks - problemMatcher - pretty complex data and logic...
// TODO: make the main thread tear down if webui clicks exit

// TODO: BUG - current settings don't apply to non-active outputs (need to refresh)
// TODO: BUG - there is an extra count in the last fold that shouldn't be there
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
