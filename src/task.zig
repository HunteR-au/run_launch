const std = @import("std");
const utils = @import("utils.zig");

pub const TaskPresentation = struct {
    reveal: ?[]const u8,
};

pub const Task = struct {
    label: ?[]const u8 = null,
    type: ?[]const u8 = null,
    command: ?[]const u8 = null,
    args: ?[]const []const u8 = null,
    group: ?[]const u8 = null,
    presentation: ?TaskPresentation = null,
    problemMatcher: ?[]const u8 = null,

    pub fn run_task(self: *const Task, allocator: std.mem.Allocator) !void {
        var argv: [][]const u8 = try allocator.alloc([]const u8, self.args.?.len + 1);
        defer allocator.free(argv);
        argv[0] = self.command.?;
        if (self.args) |args| {
            for (args, 1..) |arg, i| {
                argv[i] = arg;
            }
        }

        var child = std.process.Child.init(argv, allocator);

        child.stdout_behavior = std.process.Child.StdIo.Pipe;
        child.stderr_behavior = std.process.Child.StdIo.Pipe;
        child.spawn() catch |e| {
            std.debug.print("Spawning task {any} failed.\n", .{e});
            return e;
        };

        _ = try std.Thread.spawn(.{}, utils.pullpushLoop, .{ allocator, child, self.label.? });

        const term = child.spawnAndWait() catch |e| {
            std.debug.print("Spawning module {any} failed.\n", .{e});
            return e;
        };

        switch (term) {
            .Exited => |v| {
                std.debug.print("Task exited with code {d}\n", .{v});
            },
            .Signal => |v| {
                std.debug.print("Task signaled with code {d}\n", .{v});
            },
            .Stopped => |v| {
                std.debug.print("Task stopped with code: {d}\n", .{v});
            },
            .Unknown => |v| {
                std.debug.print("Task returned unknown process error: {d}\n", .{v});
            },
        }
    }
};

pub const TaskJson = struct {
    version: []const u8,
    tasks: ?[]const Task,
    arena: std.heap.ArenaAllocator,

    pub fn init(alloc_gpa: std.mem.Allocator) !TaskJson {
        var arena = std.heap.ArenaAllocator.init(alloc_gpa);
        errdefer arena.deinit();

        const task = TaskJson{ .arena = arena, .tasks = null, .version = "" };
        return task;
    }

    pub fn deinit(self: *const TaskJson) void {
        self.arena.deinit();
    }

    pub fn find_by_label(self: *const TaskJson, label: []const u8) ?Task {
        if (self.*.tasks) |tasks| {
            return for (tasks) |*task| {
                if (std.mem.eql(u8, label, task.label.?)) {
                    break task.*;
                }
            } else null;
        } else return null;
    }

    pub fn parse_tasks(self: *TaskJson, filepath: []const u8) !void {
        const alloc = self.arena.allocator();

        // Load the JSON data
        const max_bytes = 1024 * 1024;
        const data = try std.fs.cwd().readFileAlloc(self.arena.child_allocator, filepath, max_bytes);
        defer self.arena.child_allocator.free(data);
        std.debug.print("\n{s}\n", .{data});

        var parsed = try std.json.parseFromSlice(std.json.Value, self.arena.child_allocator, data, .{});
        defer parsed.deinit();

        var root = parsed.value;

        const version_str = root.object.get("version").?.string;
        const versioncopy = try alloc.dupe(u8, version_str);
        errdefer alloc.free(versioncopy);

        self.version = versioncopy;

        const tasks_node = root.object.get("tasks").?.array;
        const tasks = try alloc.alloc(Task, tasks_node.items.len);
        errdefer alloc.free(tasks);

        self.tasks = tasks;
        for (tasks_node.items, 0..) |task_node, i| {
            // non-optional fields
            const fields = comptime .{ "label", "type", "command" };
            const strings = .{
                task_node.object.get("label").?.string,
                task_node.object.get("type").?.string,
                task_node.object.get("command").?.string,
            };
            inline for (fields, 0..) |fieldname, j| {
                @field(tasks[i], fieldname) = try alloc.dupe(u8, strings[j]);
                errdefer if (@field(tasks[i], fieldname)) |x| alloc.free(x);
            }

            // optional fields (TODO: confirm what is optional vs non-optional)
            const group_str = task_node.object.get("group");
            const problemMatcher_str = task_node.object.get("problemMatcher");

            if (group_str) |s| {
                tasks[i].group = try alloc.dupe(u8, s.string);
                errdefer alloc.free(tasks[i].group.?);
            } else tasks[i].group = null;

            if (problemMatcher_str) |s| {
                tasks[i].problemMatcher = try alloc.dupe(u8, s.string);
                errdefer alloc.free(tasks[i].problemMatcher.?);
            } else tasks[i].problemMatcher = null;

            const args_obj = task_node.object.get("args");
            if (args_obj) |arr_node| {
                tasks[i].args = try utils.parse_config_args(alloc, arr_node.array);
                // NOTE: no error defer - will cause mem bug - probably should create a deinit instead of writing the code here
            }

            // TODO: presentation struct

        }
    }
};
