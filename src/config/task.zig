const std = @import("std");
const utils = @import("utils");
const expand = @import("expand.zig");

const uuid = utils.uuid;

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
        std.debug.print("Task:deinit()\n", .{});
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

    pub fn run_task(self: *const Task, allocator: std.mem.Allocator, id: uuid.UUID, pushfn: *const utils.PushFnProto) !std.process.Child {
        var argv: [][]const u8 = undefined;
        if (self.args != null) {
            argv = try allocator.alloc([]const u8, self.args.?.len + 1);
        } else {
            argv = try allocator.alloc([]const u8, 1);
        }

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
        child.stdin_behavior = .Ignore;
        child.spawn() catch |e| {
            //std.debug.print("Spawning task {any} failed.\n", .{e});
            return e;
        };

        // TODO: either pass child OR return it: DON"T DO BOTH WITHOUT MUTEX
        _ = try std.Thread.spawn(.{}, utils.pullpushLoop, .{ allocator, pushfn, child, id });

        // TODO: BUG BUG BUG - child.wait will clean up and remove pipes. We probably only want to remove pipes once process ends AND
        // we have confirmed the pipe is drained

        // Q: should we leave the process clean up in the pullpushloop
        // A: probably not, less control there
        // Q: should we check on process status in pullpushloop...
        // A: I think it would be nice to push pipe status / something when process fails

        //_ = child.wait() catch |e| {
        //    //std.debug.print("Spawning module {any} failed.\n", .{e});
        //    return e;
        //};
        return child;
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

    pub fn find_by_label(self: *const Tasks, label: []const u8) ?Task {
        std.debug.print("find_by_label:\n", .{});
        if (self.tasks) |tasks| {
            std.debug.print("HELLO\n", .{});
            return for (tasks) |*task| {
                std.debug.print("find_by_label: {s} : {s}\n", .{ label, task.label.? });
                if (std.mem.eql(u8, label, task.label.?)) {
                    break task.*;
                }
            } else null;
        } else return null;
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
