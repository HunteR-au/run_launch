//! The launch configuration model: what a config file describes once it is parsed and
//! validated (see `parse.zig` for the file format). Everything referenced from here lives
//! in the configuration's arena; `deinit` frees it all at once, and pointers between
//! entries (a group's members, a process' pre task) stay valid for the configuration's life.

const std = @import("std");
const utils = @import("utils");
const uiconfig = @import("uiconfig");

pub const EnvTuple = utils.EnvTuple;
pub const ColorRule = uiconfig.ColorRule;

/// How a process' command line is turned into something the OS can spawn.
pub const RunnerType = enum {
    /// the first token is the program, the rest its arguments (the default)
    native,
    /// `py -u <command line>` (`python3 -u` off Windows): a script path, or `-m module`
    python,
    /// the whole command line is handed to `cmd.exe /c` (`sh -c` off Windows)
    shell,
};

pub const Process = struct {
    name: []const u8,
    /// the command line as written, `${...}` tokens expanded (what the shell runner uses)
    command: []const u8,
    /// the command line split into tokens, each `${...}` expanded (native/python runners)
    tokens: []const []const u8,
    type: RunnerType = .native,
    /// appended after the command line's own tokens
    args: []const []const u8 = &.{},
    env: []const EnvTuple = &.{},
    /// must exit with code 0 before this process starts (see CONFIG.md)
    pre_task: ?*const Process = null,
    /// started once this process has been stopped at shutdown
    post_task: ?*const Process = null,
    /// script lines joined with '\n'; runs once this process' view exists
    script: ?[]const u8 = null,
    /// applied to this process' view, after the global rules
    color_rules: []const ColorRule = &.{},
    /// true when some entry names this process as its preTask/postTask: running
    /// "everything" leaves it out, since it is started with the entry that needs it
    is_task: bool = false,
};

pub const Group = struct {
    name: []const u8,
    members: []const *const Process,
    /// must exit with code 0 before any member (or a member's own pre task) starts
    pre_task: ?*const Process = null,
    /// started at shutdown along with the members' own post tasks
    post_task: ?*const Process = null,
    /// runs once every member's view exists
    script: ?[]const u8 = null,
    /// applied to every member's view
    color_rules: []const ColorRule = &.{},
};

/// What a name on the command line (or `default:`) refers to.
pub const Target = union(enum) {
    process: *const Process,
    group: *const Group,
    /// every process that is not just somebody's pre/post task: what runs when nothing
    /// is named and the file sets no `default:`
    all: []const *const Process,

    pub fn name(self: Target) []const u8 {
        return switch (self) {
            .process => |p| p.name,
            .group => |g| g.name,
            .all => "everything",
        };
    }
};

pub const Configuration = struct {
    arena: std.heap.ArenaAllocator,
    /// in file order; the slice is never resized after parsing, so `*const Process` is stable
    processes: []Process = &.{},
    groups: []Group = &.{},
    /// `default:` resolved; null when the file sets none
    default: ?Target = null,
    /// every process that is not somebody's pre/post task, in file order
    run_all: []const *const Process = &.{},
    /// script lines joined with '\n'; runs once everything started at launch has a view
    script: ?[]const u8 = null,
    /// applied to every view
    color_rules: []const ColorRule = &.{},

    pub fn init(gpa: std.mem.Allocator) Configuration {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Configuration) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn findProcess(self: *const Configuration, name: []const u8) ?*const Process {
        for (self.processes) |*p| {
            if (std.mem.eql(u8, p.name, name)) return p;
        }
        return null;
    }

    pub fn findGroup(self: *const Configuration, name: []const u8) ?*const Group {
        for (self.groups) |*g| {
            if (std.mem.eql(u8, g.name, name)) return g;
        }
        return null;
    }

    /// The process or group called `name` (the two never share a name).
    pub fn find(self: *const Configuration, name: []const u8) ?Target {
        if (self.findProcess(name)) |p| return .{ .process = p };
        if (self.findGroup(name)) |g| return .{ .group = g };
        return null;
    }

    /// What to start for `name`; with no name, `default:` when set, otherwise everything.
    /// Null when `name` matches nothing.
    pub fn resolve(self: *const Configuration, name: ?[]const u8) ?Target {
        const n = name orelse return self.default orelse Target{ .all = self.run_all };
        return self.find(n);
    }
};

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

const testing = std.testing;

test "find/resolve: processes before groups, no name means default or everything" {
    var processes = [_]Process{
        .{ .name = "a", .command = "a", .tokens = &.{"a"} },
        .{ .name = "build", .command = "b", .tokens = &.{"b"}, .is_task = true },
    };
    const members = [_]*const Process{&processes[0]};
    var groups = [_]Group{.{ .name = "g", .members = &members }};
    const all = [_]*const Process{&processes[0]};

    var config: Configuration = .{
        .arena = undefined,
        .processes = &processes,
        .groups = &groups,
        .run_all = &all,
    };

    try testing.expectEqual(&processes[0], config.find("a").?.process);
    try testing.expectEqual(&groups[0], config.find("g").?.group);
    try testing.expectEqual(null, config.find("zzz"));
    try testing.expectEqual(null, config.resolve("zzz"));
    try testing.expectEqual(&processes[1], config.resolve("build").?.process);

    // nothing named, no default: everything (build is only a task, so it is not in there)
    try testing.expectEqualSlices(*const Process, &all, config.resolve(null).?.all);

    config.default = .{ .group = &groups[0] };
    try testing.expectEqual(&groups[0], config.resolve(null).?.group);
    try testing.expectEqualStrings("g", config.resolve(null).?.name());
}
