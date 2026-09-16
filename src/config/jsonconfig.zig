const std = @import("std");
const Io = std.Io;
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

pub fn parseLaunch(io: Io, alloc: Alloc, root_object: JsonValue) !Launch {
    var results: Launch = try .init(alloc);
    errdefer results.deinit(alloc);

    const root = try expectObject(root_object);

    results.version = try alloc.dupe(u8, try launch_.jsonRequiredString(root, "version"));

    const config = root.get("configurations") orelse return error.MissingRequiredField;
    const config_items = switch (config) {
        .array => |a| a.items,
        else => return error.FieldInvalidType,
    };
    if (config_items.len > 0) {
        const allocated_configs: []Configuration = try alloc.alloc(Configuration, config_items.len);
        // Initialise every entry and hand the array to `results` right away, so the
        // `errdefer deinit` above frees whatever was parsed when a later entry fails.
        for (allocated_configs) |*c| c.* = .{};
        results.configurations = allocated_configs;

        for (config_items, 0..) |item, i| {
            const obj = try expectObject(item);

            // non-optional values
            const fields = comptime .{ "name", "type", "request" };
            inline for (fields) |fieldname| {
                const str = try launch_.jsonRequiredString(obj, fieldname);
                @field(allocated_configs[i], fieldname) = try copyAndAttemptExpand(io, alloc, str);
            }

            const optionalfields = comptime .{ "program", "module", "preLaunchTask", "postDebugTask", "consoleTitle", "console", "envFile" };
            inline for (optionalfields) |fieldname| {
                if (try launch_.jsonOptionalString(obj, fieldname)) |value| {
                    @field(allocated_configs[i], fieldname) = try copyAndAttemptExpand(io, alloc, value);
                }
            }

            if (obj.get("args")) |a| switch (a) {
                .array => |arr| allocated_configs[i].args = try utils.parse_config_args(alloc, arr),
                else => return error.FieldInvalidType,
            };

            if (obj.get("env")) |e| switch (e) {
                .object => |map| allocated_configs[i].env = try utils.parse_config_env(alloc, map),
                else => return error.FieldInvalidType,
            };

            if (obj.get("connect")) |connect| {
                const connect_map = try expectObject(connect);
                const host_str = try launch_.jsonRequiredString(connect_map, "host");
                allocated_configs[i].connect.host = try copyAndAttemptExpand(io, alloc, host_str);
                const port = connect_map.get("port") orelse return error.MissingRequiredField;
                allocated_configs[i].connect.port = switch (port) {
                    .integer => |n| std.math.cast(u16, n) orelse return error.InvalidPort,
                    else => return error.FieldInvalidType,
                };
            }
        }
    }

    if (root.get("compounds")) |compoundsObj| {
        const compound_items = switch (compoundsObj) {
            .array => |a| a.items,
            else => return error.FieldInvalidType,
        };
        const compounds = try alloc.alloc(Compound, compound_items.len);
        // As above: attach before parsing so a failing entry frees the ones before it.
        for (compounds) |*c| c.* = .{};
        results.compounds = compounds;

        for (compound_items, 0..) |compoundObj, j| {
            compounds[j] = try Compound.init(io, alloc, compoundObj);
        }
    } else results.compounds = null;

    return results;
}

fn expectObject(value: JsonValue) error{FieldInvalidType}!std.json.ObjectMap {
    return switch (value) {
        .object => |o| o,
        else => error.FieldInvalidType,
    };
}

pub fn parseTasks(io: Io, alloc: Alloc, root_object: JsonValue) !?Tasks {
    const map = try expectObject(root_object);

    var tasks: Tasks = .init();
    errdefer tasks.deinit(alloc);

    //const version_str = root_object.object.get("version").?.string;
    //const versioncopy = try copyAndAttemptExpand(io, alloc, version_str);
    //errdefer alloc.free(versioncopy);
    //
    //self.version = versioncopy;

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
                .object => task_array[i] = try parseTask(io, alloc, task),
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

fn parseTask(io: Io, alloc: Alloc, value: JsonValue) !Task {
    std.debug.assert(value == .object);

    var task: Task = .{};
    errdefer task.deinit(alloc);

    const map = value.object;

    // required field
    if (map.get("label")) |label| switch (label) {
        .string => |s| task.label = try copyAndAttemptExpand(io, alloc, s),
        else => return error.FieldInvalidType,
    } else {
        return error.MissingRequiredField;
    }

    // required field
    if (map.get("type")) |type_value| switch (type_value) {
        .string => |s| task.type = try copyAndAttemptExpand(io, alloc, s),
        else => return error.FieldInvalidType,
    } else {
        return error.MissingRequiredField;
    }

    // required field
    if (map.get("command")) |command| switch (command) {
        .string => |s| task.command = try copyAndAttemptExpand(io, alloc, s),
        else => return error.FieldInvalidType,
    } else {
        return error.MissingRequiredField;
    }

    if (map.get("group")) |group| switch (group) {
        .string => |s| task.group = try copyAndAttemptExpand(io, alloc, s),
        else => return error.FieldInvalidType,
    };

    if (map.get("problemMatcher")) |problemMatcher| switch (problemMatcher) {
        .string => |s| task.problemMatcher = try copyAndAttemptExpand(io, alloc, s),
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
                .string => |s| arg_strs[i] = try copyAndAttemptExpand(io, alloc, s),
                else => return error.FieldInvalidType,
            };

            task.args = arg_strs;
        },
        else => return error.FieldInvalidType,
    };

    return task;
}

fn parseCompound(io: Io, alloc: Alloc, value: JsonValue) !Compound {
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
        .string => |s| compound.name = try copyAndAttemptExpand(io, alloc, s),
        else => return error.FieldInvalidType,
    } else {
        return Compound.CompoundParsingErrors.NoNameField;
    }

    if (map.get("preLaunchTask")) |pre_task| switch (pre_task) {
        .string => |s| compound.preLaunchTask = try copyAndAttemptExpand(io, alloc, s),
        else => return error.FieldInvalidType,
    };

    if (map.get("postDebugTask")) |pre_task| switch (pre_task) {
        .string => |s| compound.postDebugTask = try copyAndAttemptExpand(io, alloc, s),
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
                    compound.configurations.?[i] = try copyAndAttemptExpand(io, alloc, s);
                },
                else => return error.FieldInvalidType,
            };
        },
        else => return error.FieldInvalidType,
    };

    return compound;
}

fn parseConfiguration(io: Io, alloc: Alloc, value: JsonValue) !Configuration {
    std.debug.assert(value == .object);

    var config: Configuration = .{};

    const map = value.object;

    // required field
    if (map.get("name")) |name| switch (name) {
        .string => |s| config.name = try copyAndAttemptExpand(io, alloc, s.scalar),
        else => return error.FieldInvalidType,
    } else {
        return error.MissingRequiredField;
    }

    // required field
    if (map.get("type")) |type_value| switch (type_value) {
        .string => |s| config.type = try copyAndAttemptExpand(io, alloc, s.scalar),
        else => return error.FieldInvalidType,
    } else {
        return error.MissingRequiredField;
    }

    if (map.get("request")) |request| switch (request) {
        .string => |s| config.type = try copyAndAttemptExpand(io, alloc, s),
        else => return error.FieldInvalidType,
    };

    if (map.get("consoleTitle")) |consoleTitle| switch (consoleTitle) {
        .string => |s| config.type = try copyAndAttemptExpand(io, alloc, s),
        else => return error.FieldInvalidType,
    };

    if (map.get("module")) |module| switch (module) {
        .string => |s| config.module = try copyAndAttemptExpand(io, alloc, s),
        else => return error.FieldInvalidType,
    };

    if (map.get("program")) |program| switch (program) {
        .string => |s| config.type = try copyAndAttemptExpand(io, alloc, s),
        else => return error.FieldInvalidType,
    };

    if (map.get("console")) |console| switch (console) {
        .string => |s| config.type = try copyAndAttemptExpand(io, alloc, s),
        else => return error.FieldInvalidType,
    };

    if (map.get("stopOnEntry")) |stopOnEntry| switch (stopOnEntry) {
        .string => |s| config.type = try copyAndAttemptExpand(io, alloc, s),
        else => return error.FieldInvalidType,
    };

    if (map.get("preLaunchTask")) |preLaunchTask| switch (preLaunchTask) {
        .string => |s| config.type = try copyAndAttemptExpand(io, alloc, s),
        else => return error.FieldInvalidType,
    };

    if (map.get("postDebugTask")) |postDebugTask| switch (postDebugTask) {
        .string => |s| config.type = try copyAndAttemptExpand(io, alloc, s),
        else => return error.FieldInvalidType,
    };

    if (map.get("envFile")) |envFile| switch (envFile) {
        .string => |s| config.type = try copyAndAttemptExpand(io, alloc, s),
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
                .string => |s| config.connect.host = try copyAndAttemptExpand(io, alloc, s),
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
            else => return error.FieldInvalidType,
        }
    }
    return envs;
}

fn copyAndAttemptExpand(io: Io, alloc: Alloc, input: []const u8) ![]u8 {
    return expand.expand_string(io, alloc, input) catch |err| switch (err) {
        expand.ExpandErrors.NoExpansionFound => {
            return try alloc.dupe(u8, input);
        },
        else => return err,
    };
}

test "parseLaunch: an empty configurations array yields a fully initialised Launch" {
    const alloc = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(JsonValue, alloc, "{\"version\": \"0.2.0\", \"configurations\": []}", .{});
    defer parsed.deinit();

    const launch = try parseLaunch(std.testing.io, alloc, parsed.value);
    defer launch.deinit(alloc);

    try std.testing.expectEqualStrings("0.2.0", launch.version);
    try std.testing.expectEqual(0, launch.configurations.len);
    try std.testing.expectEqual(null, launch.compounds);
    try std.testing.expectEqual(null, launch.find_by_name("anything"));
}

test "parseLaunch: an invalid entry fails without leaking what was parsed before it" {
    const alloc = std.testing.allocator;
    const src =
        \\{"version": "0.2.0", "configurations": [
        \\  {"name": "a", "type": "python", "request": "launch", "args": ["ok", 42]}
        \\]}
    ;
    var parsed = try std.json.parseFromSlice(JsonValue, alloc, src, .{});
    defer parsed.deinit();

    try std.testing.expectError(error.FieldInvalidType, parseLaunch(std.testing.io, alloc, parsed.value));
}


test "parseLaunch: malformed documents are reported as errors, not panics" {
    const alloc = std.testing.allocator;
    const cases = .{
        .{ error.FieldInvalidType, "[]" },
        .{ error.MissingRequiredField, "{\"configurations\": []}" },
        .{ error.FieldInvalidType, "{\"version\": 2, \"configurations\": []}" },
        .{ error.MissingRequiredField, "{\"version\": \"0.2.0\"}" },
        .{ error.FieldInvalidType, "{\"version\": \"0.2.0\", \"configurations\": {}}" },
        .{ error.FieldInvalidType, "{\"version\": \"0.2.0\", \"configurations\": [7]}" },
        .{ error.MissingRequiredField, "{\"version\": \"0.2.0\", \"configurations\": [{\"type\": \"python\", \"request\": \"launch\"}]}" },
        .{ error.FieldInvalidType, "{\"version\": \"0.2.0\", \"configurations\": [{\"name\": 1, \"type\": \"python\", \"request\": \"launch\"}]}" },
        .{ error.FieldInvalidType, "{\"version\": \"0.2.0\", \"configurations\": [{\"name\": \"a\", \"type\": \"python\", \"request\": \"launch\", \"program\": 3}]}" },
        .{ error.FieldInvalidType, "{\"version\": \"0.2.0\", \"configurations\": [{\"name\": \"a\", \"type\": \"python\", \"request\": \"launch\", \"args\": \"x\"}]}" },
        .{ error.FieldInvalidType, "{\"version\": \"0.2.0\", \"configurations\": [{\"name\": \"a\", \"type\": \"python\", \"request\": \"launch\", \"env\": []}]}" },
        .{ error.FieldInvalidType, "{\"version\": \"0.2.0\", \"configurations\": [{\"name\": \"a\", \"type\": \"python\", \"request\": \"launch\", \"connect\": \"h:1\"}]}" },
        .{ error.MissingRequiredField, "{\"version\": \"0.2.0\", \"configurations\": [{\"name\": \"a\", \"type\": \"python\", \"request\": \"launch\", \"connect\": {\"host\": \"h\"}}]}" },
        .{ error.FieldInvalidType, "{\"version\": \"0.2.0\", \"configurations\": [{\"name\": \"a\", \"type\": \"python\", \"request\": \"launch\", \"connect\": {\"host\": \"h\", \"port\": \"5678\"}}]}" },
        .{ error.InvalidPort, "{\"version\": \"0.2.0\", \"configurations\": [{\"name\": \"a\", \"type\": \"python\", \"request\": \"launch\", \"connect\": {\"host\": \"h\", \"port\": 70000}}]}" },
        .{ error.FieldInvalidType, "{\"version\": \"0.2.0\", \"configurations\": [{\"name\": \"a\", \"type\": \"python\", \"request\": \"launch\"}], \"compounds\": {}}" },
        .{ error.FieldInvalidType, "{\"version\": \"0.2.0\", \"configurations\": [{\"name\": \"a\", \"type\": \"python\", \"request\": \"launch\"}], \"compounds\": [{\"name\": \"c\", \"stopAll\": \"yes\", \"configurations\": []}]}" },
        .{ error.FieldInvalidType, "{\"version\": \"0.2.0\", \"configurations\": [{\"name\": \"a\", \"type\": \"python\", \"request\": \"launch\"}], \"compounds\": [{\"name\": \"c\", \"configurations\": [\"a\", 2]}]}" },
        .{ error.FieldInvalidType, "{\"version\": \"0.2.0\", \"configurations\": [{\"name\": \"a\", \"type\": \"python\", \"request\": \"launch\"}], \"compounds\": [{\"name\": \"ok\", \"configurations\": [\"a\"]}, {\"name\": 5, \"configurations\": []}]}" },
    };
    inline for (cases) |case| {
        var parsed = try std.json.parseFromSlice(JsonValue, alloc, case[1], .{});
        defer parsed.deinit();
        try std.testing.expectError(case[0], parseLaunch(std.testing.io, alloc, parsed.value));
    }
}
