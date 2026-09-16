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

/// The string in `value`, or `error.FieldInvalidType` when it is not a JSON string.
pub fn jsonString(value: std.json.Value) error{FieldInvalidType}![]const u8 {
    return switch (value) {
        .string => |str| str,
        else => error.FieldInvalidType,
    };
}

/// `map[key]` as a string; null when the key is absent, an error when it is not a string.
pub fn jsonOptionalString(map: std.json.ObjectMap, key: []const u8) error{FieldInvalidType}!?[]const u8 {
    const value = map.get(key) orelse return null;
    return try jsonString(value);
}

/// `map[key]` as a string; an error when the key is absent or not a string.
pub fn jsonRequiredString(map: std.json.ObjectMap, key: []const u8) error{ FieldInvalidType, MissingRequiredField }![]const u8 {
    return (try jsonOptionalString(map, key)) orelse error.MissingRequiredField;
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
        const map = switch (compoundNode) {
            .object => |o| o,
            else => return error.FieldInvalidType,
        };

        const nameobj = map.get("name") orelse {
            return CompoundParsingErrors.NoNameField;
        };
        self.name = try copyAndAttemptExpand(io, allocator, try jsonString(nameobj));
        errdefer allocator.free(self.name.?);

        if (try jsonOptionalString(map, "preLaunchTask")) |str| {
            self.preLaunchTask = try copyAndAttemptExpand(io, allocator, str);
        } else self.preLaunchTask = null;
        errdefer if (self.preLaunchTask) |p| allocator.free(p);

        if (map.get("stopAll")) |obj| {
            self.stopAll = switch (obj) {
                .bool => |b| b,
                else => return error.FieldInvalidType,
            };
        } else self.stopAll = null;

        const configurationsObj = map.get("configurations") orelse {
            return CompoundParsingErrors.NoConfigurationsField;
        };
        const config_items = switch (configurationsObj) {
            .array => |a| a.items,
            else => return error.FieldInvalidType,
        };
        self.configurations = try allocator.alloc([]const u8, config_items.len);
        for (self.configurations.?) |*entry| entry.* = &.{};
        errdefer {
            for (self.configurations.?) |entry| if (entry.len > 0) allocator.free(entry);
            allocator.free(self.configurations.?);
        }
        for (config_items, 0..) |obj, i| {
            self.configurations.?[i] = try copyAndAttemptExpand(io, allocator, try jsonString(obj));
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

    /// Entries without a name are skipped.
    pub fn find_config_by_name(self: *const Launch, name: []const u8) ?*Configuration {
        for (self.configurations) |*config| {
            const config_name = config.name orelse continue;
            if (std.mem.eql(u8, name, config_name)) {
                return config;
            }
        }
        return null;
    }

    /// Configurations are searched before compounds. Entries without a name are skipped.
    pub fn find_by_name(self: *const Launch, name: []const u8) ?ConfigOrCompound {
        if (self.find_config_by_name(name)) |config| {
            return .{ .config = config };
        }

        if (self.compounds) |compounds| {
            for (compounds) |*compound| {
                const compound_name = compound.name orelse continue;
                if (std.mem.eql(u8, name, compound_name)) {
                    return .{ .compound = compound };
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

test "find_by_name skips nameless entries and prefers configurations over compounds" {
    var configs = [_]Configuration{
        .{}, // nameless
        .{ .name = "b", .type = "python", .request = "launch" },
    };
    const compounds = [_]Compound{
        .{}, // nameless
        .{ .name = "c" },
        .{ .name = "b" }, // shadowed by the configuration of the same name
    };
    const launch: Launch = .{
        .arena = undefined,
        .version = "0.2.0",
        .configurations = &configs,
        .compounds = &compounds,
    };

    try std.testing.expectEqual(&configs[1], launch.find_config_by_name("b"));
    try std.testing.expectEqual(null, launch.find_config_by_name("c"));
    try std.testing.expectEqual(null, launch.find_config_by_name("zzz"));

    try std.testing.expectEqual(&configs[1], launch.find_by_name("b").?.config);
    try std.testing.expectEqual(&compounds[1], launch.find_by_name("c").?.compound);
    try std.testing.expectEqual(null, launch.find_by_name("zzz"));
}
