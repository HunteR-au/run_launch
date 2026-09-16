const std = @import("std");
const Io = std.Io;
const utils = @import("utils");
const expand = @import("expand.zig");

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

    pub fn deinit(self: *Task, alloc: std.mem.Allocator) void {
        if (self.command) |p| alloc.free(p);
        if (self.group) |p| alloc.free(p);
        if (self.label) |p| alloc.free(p);
        if (self.problemMatcher) |p| alloc.free(p);
        if (self.type) |p| alloc.free(p);
        if (self.args) |args| {
            for (args) |arg| alloc.free(arg);
            alloc.free(args);
        }
        if (self.presentation) |presentation| {
            if (presentation.reveal) |reveal| {
                alloc.free(reveal);
            }
        }
    }

    /// Builds `argv` (command followed by args). The caller owns the returned slice; the
    /// strings inside are borrowed from the task.
    pub fn buildArgv(self: *const Task, alloc: std.mem.Allocator) ![]const []const u8 {
        const command = self.command orelse return error.MissingCommand;
        const args: []const []const u8 = self.args orelse &.{};

        const argv = try alloc.alloc([]const u8, args.len + 1);
        argv[0] = command;
        @memcpy(argv[1..], args);
        return argv;
    }
};

pub const Tasks = struct {
    tasks: ?[]Task,

    pub fn init() Tasks {
        return .{ .tasks = null };
    }

    pub fn deinit(self: *Tasks, alloc: std.mem.Allocator) void {
        if (self.tasks) |*tasks| {
            for (tasks.*) |*task| {
                task.deinit(alloc);
            }
            alloc.free(tasks.*);
        }
    }

    /// Tasks without a label are skipped.
    pub fn find_by_label(self: *const Tasks, label: []const u8) ?Task {
        const tasks = self.tasks orelse return null;
        for (tasks) |*task| {
            const task_label = task.label orelse continue;
            if (std.mem.eql(u8, label, task_label)) return task.*;
        }
        return null;
    }
};

pub const TaskJson = struct {
    version: []const u8,
    tasks: ?[]const Task,
    arena: std.heap.ArenaAllocator,

    pub fn init(alloc: std.mem.Allocator) !TaskJson {
        var arena = std.heap.ArenaAllocator.init(alloc);
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
                const task_label = task.label orelse continue;
                if (std.mem.eql(u8, label, task_label)) {
                    break task.*;
                }
            } else null;
        } else return null;
    }

    pub fn parse_tasks(self: *TaskJson, filepath: []const u8) !void {
        const alloc = self.arena.allocator();

        // Load the JSON data
        const size_limit = Io.Limit.limited64(1024 * 1024);
        const data = try std.Io.Dir.cwd().readFileAlloc(self.arena.child_allocator, filepath, size_limit);
        defer self.arena.child_allocator.free(data);
        std.log.debug("{s}", .{data});

        var parsed = try std.json.parseFromSlice(std.json.Value, self.arena.child_allocator, data, .{});
        defer parsed.deinit();

        var root = parsed.value;

        const version_str = root.object.get("version").?.string;
        const versioncopy = try copyAndAttemptExpand(alloc, version_str);
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
                @field(tasks[i], fieldname) = try copyAndAttemptExpand(alloc, strings[j]);
                errdefer if (@field(tasks[i], fieldname)) |x| alloc.free(x);
            }

            // optional fields (TODO: confirm what is optional vs non-optional)
            const group_str = task_node.object.get("group");
            const problemMatcher_str = task_node.object.get("problemMatcher");

            if (group_str) |s| {
                tasks[i].group = try copyAndAttemptExpand(alloc, s.string);
                errdefer alloc.free(tasks[i].group.?);
            } else tasks[i].group = null;

            if (problemMatcher_str) |s| {
                tasks[i].problemMatcher = try copyAndAttemptExpand(alloc, s.string);
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

fn copyAndAttemptExpand(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    return expand.expand_string(alloc, input) catch |err| switch (err) {
        expand.ExpandErrors.NoExpansionFound => {
            return try alloc.dupe(u8, input);
        },
        else => return err,
    };
}

test "Tasks.find_by_label skips tasks without a label" {
    var task_array = [_]Task{
        .{ .type = "shell", .command = "echo" }, // no label
        .{ .label = "build", .type = "shell", .command = "make" },
    };
    const tasks: Tasks = .{ .tasks = &task_array };

    try std.testing.expectEqualStrings("make", tasks.find_by_label("build").?.command.?);
    try std.testing.expectEqual(null, tasks.find_by_label("test"));
    try std.testing.expectEqual(null, (Tasks{ .tasks = null }).find_by_label("build"));
}
