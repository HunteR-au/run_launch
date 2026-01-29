const std = @import("std");
const utils = @import("utils");

const JsonValue = std.json.Value;
const Alloc = std.mem.Allocator;

const launch_ = @import("launch.zig");
const Launch = launch_.Launch;
const Configuration = launch_.Configuration;
const Compound = launch_.Compound;
const Task = @import("task.zig").Task;
const Tasks = @import("task.zig").Tasks;
const expand = @import("expand.zig");

pub fn parseLaunch(alloc: Alloc, root_object: JsonValue) !Launch {
    var results: Launch = undefined;

    const version_str = root_object.object.get("version").?.string;
    results.version = try alloc.dupe(u8, version_str);
    errdefer alloc.free(results.version);

    const config = root_object.object.get("configurations").?;
    if (config.array.items.len > 0) {
        var allocated_configs: []Configuration = try alloc.alloc(Configuration, config.array.items.len);

        for (config.array.items, 0..) |item, i| {
            // Need to initialize the fields
            allocated_configs[i] = Configuration{};

            // non-optional values: Allocate strings for field and free if anything goes wrong
            const fields = comptime .{ "name", "type", "request" };
            const strings = .{
                item.object.get("name").?.string,
                item.object.get("type").?.string,
                item.object.get("request").?.string,
            };
            inline for (fields, 0..) |fieldname, j| {
                @field(allocated_configs[i], fieldname) = try copyAndAttemptExpand(alloc, strings[j]);
                errdefer if (@field(allocated_configs[i], fieldname)) |x| alloc.free(x);
            }

            const optionalfields = comptime .{ "program", "module", "preLaunchTask", "postDebugTask", "consoleTitle", "console", "envFile" };
            inline for (optionalfields) |fieldname| {
                if (item.object.get(fieldname)) |value| {
                    @field(allocated_configs[i], fieldname) = try copyAndAttemptExpand(alloc, value.string);
                }
                errdefer {
                    if (@field(allocated_configs[i], fieldname)) |p| alloc.free(p);
                }
            }

            if (item.object.get("args")) |a| {
                allocated_configs[i].args = try utils.parse_config_args(alloc, a.array);
                // NOTE: no error defer - will cause mem bug - probably should create a deinit instead of writing the code here
            }

            // Parse the env arguments if they are present
            if (item.object.get("env")) |e| {
                allocated_configs[i].env = try utils.parse_config_env(alloc, e.object);
                // NOTE: no error defer - will cause mem bug - probably should create a deinit instead of writing the code here
            }

            if (item.object.get("connect")) |connect| {
                const host_str = connect.object.get("host").?.string;
                allocated_configs[i].connect.host = try copyAndAttemptExpand(alloc, host_str);
                errdefer if (allocated_configs[i].connect.host) |t| alloc.free(t);
                allocated_configs[i].connect.port = @intCast(connect.object.get("port").?.integer);
            }
        }
        results.configurations = allocated_configs;
    }

    if (root_object.object.get("compounds")) |compoundsObj| {
        const compounds = try alloc.alloc(Compound, compoundsObj.array.items.len);
        for (compoundsObj.array.items, 0..) |compoundObj, j| {
            compounds[j] = try Compound.init(alloc, compoundObj);
            errdefer compounds[j].deinit(alloc);
        }
        results.compounds = compounds;
    } else results.compounds = null;

    return results;
}

pub fn parseTasks(alloc: Alloc, root_object: JsonValue) !?Tasks {
    std.debug.assert(root_object == .object);

    var tasks: Tasks = .init();
    errdefer tasks.deinit(alloc);

    //const version_str = root_object.object.get("version").?.string;
    //const versioncopy = try copyAndAttemptExpand(alloc, version_str);
    //errdefer alloc.free(versioncopy);
    //
    //self.version = versioncopy;

    const map = root_object.object;

    if (map.get("tasks")) |tasks_value| switch (tasks_value) {
        .array => |list| {
            var task_array = try alloc.alloc(Task, list.items.len);
            errdefer {
                for (task_array) |*t| t.deinit(alloc);
                alloc.free(task_array);
            }

            // init each Task
            for (task_array) |*config| config.* = .{};

            for (list.items, 0..) |task, i| switch (task) {
                .object => task_array[i] = try parseTask(alloc, task),
                else => return error.FieldInvalidType,
            };

            tasks.tasks = task_array;
        },
        else => {
            std.log.debug("'configurations' field is not an array\n", .{});
            return error.ParseFailure;
        },
    } else {
        return null;
    }

    return tasks;
}

fn parseTask(alloc: Alloc, value: JsonValue) !Task {
    std.debug.assert(value == .object);

    var task: Task = .{};
    errdefer task.deinit(alloc);

    const map = value.object;

    // required field
    if (map.get("label")) |label| switch (label) {
        .string => |s| task.label = try copyAndAttemptExpand(alloc, s),
        else => return error.FieldInvalidType,
    } else {
        return error.MissingRequiredField;
    }

    // required field
    if (map.get("type")) |type_value| switch (type_value) {
        .string => |s| task.type = try copyAndAttemptExpand(alloc, s),
        else => return error.FieldInvalidType,
    } else {
        return error.MissingRequiredField;
    }

    // required field
    if (map.get("command")) |command| switch (command) {
        .string => |s| task.command = try copyAndAttemptExpand(alloc, s),
        else => return error.FieldInvalidType,
    } else {
        return error.MissingRequiredField;
    }

    if (map.get("group")) |group| switch (group) {
        .string => |s| task.group = try copyAndAttemptExpand(alloc, s),
        else => return error.FieldInvalidType,
    };

    if (map.get("problemMatcher")) |problemMatcher| switch (problemMatcher) {
        .string => |s| task.problemMatcher = try copyAndAttemptExpand(alloc, s),
        else => return error.FieldInvalidType,
    };

    if (map.get("args")) |args| switch (args) {
        .array => |list| {
            var arg_strs = try alloc.alloc([]u8, list.items.len);
            errdefer {
                for (arg_strs) |str| if (str.len > 0) alloc.free(str);
                alloc.free(arg_strs);
            }

            // init str array
            for (arg_strs) |*s| s.* = &.{};

            for (list.items, 0..) |item, i| switch (item) {
                .string => |s| arg_strs[i] = try copyAndAttemptExpand(alloc, s),
                else => return error.FieldInvalidType,
            };

            task.args = arg_strs;
        },
        else => return error.FieldInvalidType,
    };

    return task;
}

fn parseCompound(alloc: Alloc, value: JsonValue) !Compound {
    std.debug.assert(value == .object);

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

    const map = value.object;

    if (map.get("name")) |name| switch (name) {
        .string => |s| compound.name = try copyAndAttemptExpand(alloc, s),
        else => return error.FieldInvalidType,
    } else {
        return Compound.CompoundParsingErrors.NoNameField;
    }

    if (map.get("preLaunchTask")) |pre_task| switch (pre_task) {
        .string => |s| compound.preLaunchTask = try copyAndAttemptExpand(alloc, s),
        else => return error.FieldInvalidType,
    };

    if (map.get("postDebugTask")) |pre_task| switch (pre_task) {
        .string => |s| compound.postDebugTask = try copyAndAttemptExpand(alloc, s),
        else => return error.FieldInvalidType,
    };

    if (map.get("stopAll")) |pre_task| switch (pre_task) {
        .bool => |b| compound.stopAll = b,
        else => return error.FieldInvalidType,
    } else {
        // set default value
        compound.stopAll = null;
    }

    if (map.get("configurations")) |configs| switch (configs) {
        .array => |list| {
            compound.configurations = try alloc.alloc([]const u8, list.items.len);
            for (compound.configurations) |entry| entry = &.{};

            for (list.items, 0..) |entry, i| switch (entry) {
                .string => |s| {
                    compound.configurations.?[i] = try copyAndAttemptExpand(alloc, s);
                },
                else => return error.FieldInvalidType,
            };
        },
        else => return error.FieldInvalidType,
    };

    return compound;
}

fn parseConfiguration(alloc: Alloc, value: JsonValue) !Configuration {
    std.debug.assert(value == .object);

    var config: Configuration = .{};

    const map = value.object;

    // required field
    if (map.get("name")) |name| switch (name) {
        .string => |s| config.name = try copyAndAttemptExpand(alloc, s.scalar),
        else => return error.FieldInvalidType,
    } else {
        return error.MissingRequiredField;
    }

    // required field
    if (map.get("type")) |type_value| switch (type_value) {
        .string => |s| config.type = try copyAndAttemptExpand(alloc, s.scalar),
        else => return error.FieldInvalidType,
    } else {
        return error.MissingRequiredField;
    }

    if (map.get("request")) |request| switch (request) {
        .string => |s| config.type = try copyAndAttemptExpand(alloc, s),
        else => return error.FieldInvalidType,
    };

    if (map.get("consoleTitle")) |consoleTitle| switch (consoleTitle) {
        .string => |s| config.type = try copyAndAttemptExpand(alloc, s),
        else => return error.FieldInvalidType,
    };

    if (map.get("module")) |module| switch (module) {
        .string => |s| config.module = try copyAndAttemptExpand(alloc, s),
        else => return error.FieldInvalidType,
    };

    if (map.get("program")) |program| switch (program) {
        .string => |s| config.type = try copyAndAttemptExpand(alloc, s),
        else => return error.FieldInvalidType,
    };

    if (map.get("console")) |console| switch (console) {
        .string => |s| config.type = try copyAndAttemptExpand(alloc, s),
        else => return error.FieldInvalidType,
    };

    if (map.get("stopOnEntry")) |stopOnEntry| switch (stopOnEntry) {
        .string => |s| config.type = try copyAndAttemptExpand(alloc, s),
        else => return error.FieldInvalidType,
    };

    if (map.get("preLaunchTask")) |preLaunchTask| switch (preLaunchTask) {
        .string => |s| config.type = try copyAndAttemptExpand(alloc, s),
        else => return error.FieldInvalidType,
    };

    if (map.get("postDebugTask")) |postDebugTask| switch (postDebugTask) {
        .string => |s| config.type = try copyAndAttemptExpand(alloc, s),
        else => return error.FieldInvalidType,
    };

    if (map.get("envFile")) |envFile| switch (envFile) {
        .string => |s| config.type = try copyAndAttemptExpand(alloc, s),
        else => return error.FieldInvalidType,
    };
    //
    if (map.get("args")) |args| switch (args) {
        .array => config.args = try parseArgsMap(alloc, args),
        else => return error.FieldInvalidType,
    };

    if (map.get("env")) |env| switch (env) {
        .object => config.env = try parseConfigEnv(alloc, env),
        else => return error.FieldInvalidType,
    };

    if (map.get("connect")) |connect| switch (connect) {
        .object => |m| {
            if (m.get("host")) |host| switch (host) {
                .string => |s| config.connect.host = try copyAndAttemptExpand(alloc, s),
                else => return error.FieldInvalidType,
            };
            //const port = connect_map.get("port");
            // TODO: get port
        },
        else => return error.FieldInvalidType,
    };

    return config;
}

fn parseArgsMap(alloc: Alloc, value: JsonValue) ![]const []const u8 {
    std.debug.assert(value == .array);

    var args = try alloc.alloc([]u8, value.array.items.len);
    errdefer {
        // Free all successfully-duped strings
        for (args) |arg| {
            if (arg.len > 0) alloc.free(arg);
        }
        alloc.free(args);
    }

    // Initialize entries so cleanup is always safe
    for (args) |*arg| arg.* = &.{};

    for (value.array.items, 0..) |item, i| {
        switch (item) {
            .string => |s| {
                args[i] = try alloc.dupe(u8, s);
                errdefer alloc.free(args[i]);
            },
            else => return error.FieldInvalidType,
        }
    }

    return args;
}

fn parseConfigEnv(alloc: Alloc, value: JsonValue) ![]const utils.EnvTuple {
    std.debug.assert(value == .object);
    const map = value.object;

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
            .string => |str| {
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

fn copyAndAttemptExpand(alloc: Alloc, input: []const u8) ![]u8 {
    return expand.expand_string(alloc, input) catch |err| switch (err) {
        expand.ExpandErrors.NoExpansionFound => {
            return try alloc.dupe(u8, input);
        },
        else => return err,
    };
}
