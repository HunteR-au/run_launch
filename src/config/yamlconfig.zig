const std = @import("std");
const Yaml = @import("yaml").Yaml;
const utils = @import("utils");

const launch_ = @import("launch.zig");
const Launch = launch_.Launch;
const Configuration = launch_.Configuration;
const Compound = launch_.Compound;
const Task = @import("task.zig").Task;
const Tasks = @import("task.zig").Tasks;
const expand = @import("expand.zig");

pub fn parseLaunch(alloc: std.mem.Allocator, yaml: Yaml) !Launch {
    var launch: Launch = try .init(alloc);
    errdefer launch.deinit(alloc);

    // expect one document
    const root = yaml.docs.items[0];
    const root_map = root.asMap() orelse {
        return error.ParseFailure;
    };

    if (root_map.get("configurations")) |config_value| switch (config_value) {
        .list => |config_list| {
            var configs: []Configuration = try alloc.alloc(Configuration, config_list.len);
            errdefer {
                for (configs) |*c| c.deinit(alloc);
                alloc.free(configs);
            }

            // init each struct
            for (configs) |*config| config.* = .{};

            for (config_list, 0..) |config, i| {
                // parse each config map
                configs[i] = parseConfiguration(alloc, config) catch {
                    return error.ParseFailure;
                };
            }
            launch.configurations = configs;
        },
        else => {
            std.debug.print("'configurations' field is not a list\n", .{});
            return error.ParseFailure;
        },
    } else {
        std.debug.print("No 'configurations' field\n", .{});
        return error.ParseFailure;
    }

    if (root_map.get("compounds")) |compounds| switch (compounds) {
        .list => |list| {
            var compound_list = try alloc.alloc(Compound, list.len);
            errdefer {
                for (compound_list) |*c| c.deinit(alloc);
                alloc.free(compound_list);
            }

            // init the array
            for (compound_list) |*c| c.* = .{};

            for (list, 0..) |list_entry, i| switch (list_entry) {
                .map => compound_list[i] = try parseCompound(alloc, list_entry),
                else => return error.FieldInvalidType,
            };
            launch.compounds = compound_list;
        },
        else => {
            std.debug.print("'configurations' field is not a list\n", .{});
            return error.ParseFailure;
        },
    };

    return launch;
}

pub fn parseTasks(alloc: std.mem.Allocator, yaml: Yaml) !?Tasks {
    var tasks: Tasks = .init();
    errdefer tasks.deinit(alloc);

    // expect one document
    const root = yaml.docs.items[0];
    const root_map = root.asMap() orelse {
        return error.ParseFailure;
    };

    if (root_map.get("tasks")) |tasks_value| switch (tasks_value) {
        .list => |list| {
            var task_array: []Task = try alloc.alloc(Task, list.len);
            errdefer {
                for (task_array) |*t| t.deinit(alloc);
                alloc.free(task_array);
            }

            // init each Task
            for (task_array) |*task| task.* = .{};

            for (list, 0..) |task, i| switch (task) {
                .map => task_array[i] = try parseTask(alloc, task),
                else => return error.FieldInvalidType,
            };

            tasks.tasks = task_array;
        },
        else => {
            std.debug.print("'configurations' field is not a list\n", .{});
            return error.ParseFailure;
        },
    } else {
        return null;
    }

    return tasks;
}

fn parseTask(alloc: std.mem.Allocator, value: Yaml.Value) !Task {
    std.debug.assert(value == .map);

    var task: Task = .{};
    errdefer task.deinit(alloc);

    const map = value.asMap().?;

    // required field
    if (map.get("label")) |label| switch (label) {
        .scalar => |s| task.label = try copyAndAttemptExpand(alloc, s),
        else => return error.FieldInvalidType,
    } else {
        return error.MissingRequiredField;
    }

    // required field
    if (map.get("type")) |type_value| switch (type_value) {
        .scalar => |s| task.type = try copyAndAttemptExpand(alloc, s),
        else => return error.FieldInvalidType,
    } else {
        return error.MissingRequiredField;
    }

    // required field
    if (map.get("command")) |command| switch (command) {
        .scalar => |s| task.command = try copyAndAttemptExpand(alloc, s),
        else => return error.FieldInvalidType,
    } else {
        return error.MissingRequiredField;
    }

    if (map.get("group")) |group| switch (group) {
        .scalar => |s| task.group = try copyAndAttemptExpand(alloc, s),
        else => return error.FieldInvalidType,
    };

    if (map.get("problemMatcher")) |problemMatcher| switch (problemMatcher) {
        .scalar => |s| task.problemMatcher = try copyAndAttemptExpand(alloc, s),
        else => return error.FieldInvalidType,
    };

    if (map.get("args")) |args| switch (args) {
        .list => |list| {
            var arg_strs = try alloc.alloc([]u8, list.len);
            errdefer {
                for (arg_strs) |str| if (str.len > 0) alloc.free(str);
                alloc.free(arg_strs);
            }

            // init str array
            for (arg_strs) |*s| s.* = &.{};

            for (list, 0..) |item, i| switch (item) {
                .scalar => |s| arg_strs[i] = try copyAndAttemptExpand(alloc, s),
                else => return error.FieldInvalidType,
            };

            task.args = arg_strs;
        },
        else => return error.FieldInvalidType,
    };

    return task;
}

fn parseCompound(alloc: std.mem.Allocator, value: Yaml.Value) !Compound {
    std.debug.assert(value == .map);

    var compound: Compound = .{};
    errdefer {
        if (compound.name) |p| alloc.free(p);
        if (compound.postDebugTask) |p| alloc.free(p);
        if (compound.preLaunchTask) |p| alloc.free(p);
        if (compound.configurations) |p| {
            for (p) |entry| {
                if (entry.len > 0) alloc.free(entry);
            }
            alloc.free(p);
        }
    }

    const map = value.asMap().?;

    if (map.get("name")) |name| switch (name) {
        .scalar => |s| compound.name = try copyAndAttemptExpand(alloc, s),
        else => return error.FieldInvalidType,
    } else {
        return Compound.CompoundParsingErrors.NoNameField;
    }

    if (map.get("preLaunchTask")) |pre_task| switch (pre_task) {
        .scalar => |s| compound.preLaunchTask = try copyAndAttemptExpand(alloc, s),
        else => return error.FieldInvalidType,
    };

    if (map.get("postDebugTask")) |pre_task| switch (pre_task) {
        .scalar => |s| compound.postDebugTask = try copyAndAttemptExpand(alloc, s),
        else => return error.FieldInvalidType,
    };

    if (map.get("stopAll")) |pre_task| switch (pre_task) {
        .boolean => |b| compound.stopAll = b,
        else => return error.FieldInvalidType,
    } else {
        // set default value
        compound.stopAll = null;
    }

    if (map.get("configurations")) |configs| switch (configs) {
        .list => |list| {
            compound.configurations = try alloc.alloc([]const u8, list.len);
            for (compound.configurations.?) |*entry| entry.* = &.{};

            for (list, 0..) |entry, i| switch (entry) {
                .scalar => |s| {
                    compound.configurations.?[i] = try copyAndAttemptExpand(alloc, s);
                },
                else => return error.FieldInvalidType,
            };
        },
        else => return error.FieldInvalidType,
    };

    return compound;
}

fn parseConfiguration(alloc: std.mem.Allocator, value: Yaml.Value) !Configuration {
    std.debug.assert(value == .map);

    var config: Configuration = .{};

    const map = value.asMap().?;

    // required field
    if (map.get("name")) |name| switch (name) {
        .scalar => |s| config.name = try copyAndAttemptExpand(alloc, s),
        else => return error.FieldInvalidType,
    } else {
        return error.MissingRequiredField;
    }

    // required field
    if (map.get("type")) |type_value| switch (type_value) {
        .scalar => |s| config.type = try copyAndAttemptExpand(alloc, s),
        else => return error.FieldInvalidType,
    } else {
        return error.MissingRequiredField;
    }

    if (map.get("request")) |request| switch (request) {
        .scalar => |s| config.request = try copyAndAttemptExpand(alloc, s),
        else => return error.FieldInvalidType,
    };

    if (map.get("consoleTitle")) |consoleTitle| switch (consoleTitle) {
        .scalar => |s| config.consoleTitle = try copyAndAttemptExpand(alloc, s),
        else => return error.FieldInvalidType,
    };

    if (map.get("module")) |module| switch (module) {
        .scalar => |s| config.module = try copyAndAttemptExpand(alloc, s),
        else => return error.FieldInvalidType,
    };

    if (map.get("program")) |program| switch (program) {
        .scalar => |s| config.program = try copyAndAttemptExpand(alloc, s),
        else => return error.FieldInvalidType,
    };

    if (map.get("console")) |console| switch (console) {
        .scalar => |s| config.console = try copyAndAttemptExpand(alloc, s),
        else => return error.FieldInvalidType,
    };

    if (map.get("stopOnEntry")) |stopOnEntry| switch (stopOnEntry) {
        .scalar => |s| config.stopOnEntry = try copyAndAttemptExpand(alloc, s),
        else => return error.FieldInvalidType,
    };

    if (map.get("preLaunchTask")) |preLaunchTask| switch (preLaunchTask) {
        .scalar => |s| config.preLaunchTask = try copyAndAttemptExpand(alloc, s),
        else => return error.FieldInvalidType,
    };

    if (map.get("postDebugTask")) |postDebugTask| switch (postDebugTask) {
        .scalar => |s| config.postDebugTask = try copyAndAttemptExpand(alloc, s),
        else => return error.FieldInvalidType,
    };

    if (map.get("envFile")) |envFile| switch (envFile) {
        .scalar => |s| config.envFile = try copyAndAttemptExpand(alloc, s),
        else => return error.FieldInvalidType,
    };

    if (map.get("args")) |args| switch (args) {
        .list => config.args = try parseArgsMap(alloc, args),
        else => return error.FieldInvalidType,
    };

    if (map.get("env")) |env| switch (env) {
        .map => config.env = try parseConfigEnv(alloc, env),
        else => return error.FieldInvalidType,
    };

    if (map.get("connect")) |connect| switch (connect) {
        .map => |m| {
            if (m.get("host")) |host| switch (host) {
                .scalar => |s| config.connect.host = try copyAndAttemptExpand(alloc, s),
                else => return error.FieldInvalidType,
            };
            //const port = connect_map.get("port");
            // TODO: get port
        },
        else => return error.FieldInvalidType,
    };

    return config;
}

fn parseArgsMap(alloc: std.mem.Allocator, value: Yaml.Value) ![]const []const u8 {
    std.debug.assert(value == .list);

    var args = try alloc.alloc([]u8, value.list.len);
    errdefer {
        // Free all successfully-duped strings
        for (args) |arg| {
            if (arg.len > 0) alloc.free(arg);
        }
        alloc.free(args);
    }

    // Initialize entries so cleanup is always safe
    for (args) |*arg| arg.* = &.{};

    for (value.list, 0..) |item, i| {
        switch (item) {
            .scalar => |s| {
                args[i] = try alloc.dupe(u8, s);
                errdefer alloc.free(args[i]);
            },
            else => return error.FieldInvalidType,
        }
    }

    return args;
}

fn parseConfigEnv(alloc: std.mem.Allocator, value: Yaml.Value) ![]const utils.EnvTuple {
    std.debug.assert(value == .map);
    const map = value.map;

    var envs = try alloc.alloc(utils.EnvTuple, map.count());
    errdefer {
        // Free all duped strings for entries that were initialized
        for (envs) |env| {
            if (env.key.len > 0) alloc.free(env.key);
            if (env.val.len > 0) alloc.free(env.val);
        }
        alloc.free(envs);
    }

    // Initialize to empty so cleanup logic is safe
    for (envs) |*env| env.* = .{ .key = &.{}, .val = &.{} };

    for (map.keys(), map.values(), 0..) |key, val, i| {
        switch (val) {
            .scalar => |str| {
                envs[i].key = try alloc.dupe(u8, key);
                errdefer alloc.free(envs[i].key);
                envs[i].val = try alloc.dupe(u8, str);
                errdefer alloc.free(envs[i].val);
            },
            else => {},
        }
    }
    return envs;
}

fn copyAndAttemptExpand(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    return expand.expand_string(alloc, input) catch |err| switch (err) {
        expand.ExpandErrors.NoExpansionFound => {
            return try alloc.dupe(u8, input);
        },
        else => return err,
    };
}
