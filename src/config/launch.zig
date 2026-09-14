const std = @import("std");
const Io = std.Io;
const utils = @import("utils");
const expand = @import("expand.zig");

const EnvTuple = utils.EnvTuple;

// TODO: redo the configuration
pub const Configuration = struct {
    name: ?[]const u8 = null, // mandatory
    type: ?[]const u8 = null, // mandatory
    request: ?[]const u8 = null, // mandatory
    consoleTitle: ?[]const u8 = null,
    module: ?[]const u8 = null,
    program: ?[]const u8 = null,
    console: ?[]const u8 = null,
    stopOnEntry: ?[]const u8 = null,
    preLaunchTask: ?[]const u8 = null,
    postDebugTask: ?[]const u8 = null,
    args: ?[]const []const u8 = null,
    env: ?[]const EnvTuple = null,
    envFile: ?[]const u8 = null,
    connect: struct {
        host: ?[]const u8 = null,
        port: u16 = 0,
    } = .{},

    pub fn deinit(self: *Configuration, alloc: std.mem.Allocator) void {
        if (self.name) |p| alloc.free(p);
        if (self.type) |p| alloc.free(p);
        if (self.request) |p| alloc.free(p);
        if (self.consoleTitle) |p| alloc.free(p);
        if (self.module) |p| alloc.free(p);
        if (self.program) |p| alloc.free(p);
        if (self.console) |p| alloc.free(p);
        if (self.stopOnEntry) |p| alloc.free(p);
        if (self.preLaunchTask) |p| alloc.free(p);
        if (self.postDebugTask) |p| alloc.free(p);
        if (self.envFile) |p| alloc.free(p);

        if (self.connect.host) |p| alloc.free(p);

        // Free args if it exists
        if (self.args) |args| {
            for (args) |*s| {
                alloc.free(s.*);
            }
            alloc.free(args);
        }
        // Free env if it exists
        if (self.env) |env| {
            for (env) |*tuple| {
                alloc.free(tuple.key);
                alloc.free(tuple.val);
            }
            alloc.free(env);
        }

        // wipe fields to prevent accidental reuse
        self.* = .{};
    }
};

fn copyAndAttemptExpand(io: Io, alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    return expand.expand_string(io, alloc, input) catch |err| switch (err) {
        expand.ExpandErrors.NoExpansionFound => {
            return try alloc.dupe(u8, input);
        },
        else => return err,
    };
}

pub const Compound = struct {
    name: ?[]const u8 = null,
    configurations: ?[][]const u8 = null,
    preLaunchTask: ?[]const u8 = null,
    postDebugTask: ?[]const u8 = null,
    stopAll: ?bool = null,

    pub const CompoundParsingErrors = error{ NoNameField, NoConfigurationsField };

    pub fn init(io: Io, allocator: std.mem.Allocator, compoundNode: std.json.Value) !Compound {
        var self = Compound{};
        const nameobj = compoundNode.object.get("name") orelse {
            return CompoundParsingErrors.NoNameField;
        };
        self.name = try copyAndAttemptExpand(io, allocator, nameobj.string);
        errdefer allocator.free(self.name.?);

        const prelaunchtaskObj = compoundNode.object.get("preLaunchTask");
        if (prelaunchtaskObj) |obj| {
            self.preLaunchTask = try copyAndAttemptExpand(io, allocator, obj.string);
            errdefer allocator.free(self.preLaunchTask.?);
        } else self.preLaunchTask = null;

        const stopAllObj = compoundNode.object.get("stopAll");
        if (stopAllObj) |obj| {
            self.stopAll = obj.bool;
        } else self.stopAll = null;

        const configurationsObj = compoundNode.object.get("configurations") orelse {
            return CompoundParsingErrors.NoConfigurationsField;
        };
        self.configurations = try allocator.alloc([]const u8, configurationsObj.array.items.len);
        errdefer allocator.free(self.configurations.?);
        for (configurationsObj.array.items, 0..) |obj, i| {
            self.configurations.?[i] = try copyAndAttemptExpand(io, allocator, obj.string);
            errdefer allocator.free(self.configurations.?[i]);
        }
        return self;
    }

    pub fn deinit(self: *const Compound, alloc: std.mem.Allocator) void {
        if (self.name) |str| {
            alloc.free(str);
        }
        if (self.preLaunchTask) |str| {
            alloc.free(str);
        }
        if (self.configurations) |configs| {
            for (configs) |config| {
                alloc.free(config);
            }
            alloc.free(configs);
        }
    }
};

pub const Launch = struct {
    arena: std.heap.ArenaAllocator,

    version: []const u8,
    configurations: []Configuration,
    compounds: ?[]const Compound = null,

    pub const ConfigOrCompound = union(enum) {
        config: *const Configuration,
        compound: *const Compound,
    };

    pub fn init(alloc_gpa: std.mem.Allocator) !Launch {
        var arena = std.heap.ArenaAllocator.init(alloc_gpa);
        errdefer arena.deinit();

        const task = Launch{ .arena = arena, .configurations = &.{}, .compounds = null, .version = "" };
        return task;
    }

    pub fn find_config_by_name(self: *const Launch, name: []const u8) ?*Configuration {
        for (self.configurations) |*config| {
            if (std.mem.eql(u8, name, config.name.?)) {
                return config;
            }
        }
        return null;
    }

    pub fn find_by_name(self: *const Launch, name: []const u8) ?ConfigOrCompound {
        var result: ConfigOrCompound = undefined;

        for (self.configurations) |*config| {
            if (std.mem.eql(u8, name, config.name.?)) {
                result = .{ .config = config };
                return result;
            }
        }

        if (self.compounds) |compounds| {
            for (compounds) |*compound| {
                if (std.mem.eql(u8, name, compound.name.?)) {
                    result = .{ .compound = compound };
                    return result;
                }
            }
        }

        return null;
    }

    pub fn deinit(self: *const Launch, allocator: std.mem.Allocator) void {
        if (self.*.configurations.len > 0) {
            for (self.*.configurations) |*i| {
                i.deinit(allocator);
            }
        }

        if (self.compounds) |compounds| {
            for (compounds) |*compound| {
                compound.deinit(allocator);
            }
            allocator.free(compounds);
        }

        allocator.free(self.*.version);
        allocator.free(self.*.configurations);
    }
};
