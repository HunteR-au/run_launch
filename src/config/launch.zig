const std = @import("std");
const utils = @import("utils");
const expand = @import("expand.zig");

const EnvTuple = utils.EnvTuple;

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
};

fn copyAndAttemptExand(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    return expand.expand_string(alloc, input) catch |err| switch (err) {
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

    const CompoundParsingErrors = error{ NoNameField, NoConfigurationsField };

    pub fn init(allocator: std.mem.Allocator, compoundNode: std.json.Value) !Compound {
        var self = Compound{};
        const nameobj = compoundNode.object.get("name") orelse {
            return CompoundParsingErrors.NoNameField;
        };
        self.name = try copyAndAttemptExand(allocator, nameobj.string);
        errdefer allocator.free(self.name.?);

        const prelaunchtaskObj = compoundNode.object.get("preLaunchTask");
        if (prelaunchtaskObj) |obj| {
            self.preLaunchTask = try copyAndAttemptExand(allocator, obj.string);
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
            self.configurations.?[i] = try copyAndAttemptExand(allocator, obj.string);
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

        const task = Launch{ .arena = arena, .configurations = .{}, .compound = null, .version = "" };
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
                // free each []const u8 in Configuration
                inline for (@typeInfo(Configuration).@"struct".fields) |field| {
                    switch (field.type) {
                        ?[]const u8 => {
                            if (@field(i.*, field.name)) |p| {
                                allocator.free(p);
                            }
                        },
                        else => {},
                    }
                }
                if (i.connect.host) |p| allocator.free(p);

                // Free args if it exists
                if (i.args) |a| {
                    for (a) |*s| {
                        allocator.free(s.*);
                    }
                    allocator.free(a);
                }
                // Free env if it exists
                if (i.env) |e| {
                    for (e) |*tuple| {
                        allocator.free(tuple.key);
                        allocator.free(tuple.val);
                    }
                    allocator.free(e);
                }
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

pub fn parse_json(allocator: std.mem.Allocator, filepath: []const u8) !Launch {
    var results: Launch = undefined;

    // Load the JSON data
    const max_bytes = 1024 * 1024;
    const data = try std.fs.cwd().readFileAlloc(allocator, filepath, max_bytes);
    std.debug.print("\n{s}\n", .{data});
    defer allocator.free(data);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();

    var root = parsed.value;

    const version_str = root.object.get("version").?.string;
    results.version = try allocator.dupe(u8, version_str);
    errdefer allocator.free(results.version);

    const config = root.object.get("configurations").?;
    if (config.array.items.len > 0) {
        var allocated_configs: []Configuration = try allocator.alloc(Configuration, config.array.items.len);

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
                @field(allocated_configs[i], fieldname) = try copyAndAttemptExand(allocator, strings[j]);
                errdefer if (@field(allocated_configs[i], fieldname)) |x| allocator.free(x);
            }

            const optionalfields = comptime .{ "program", "module", "preLaunchTask", "postDebugTask", "consoleTitle", "console", "envFile" };
            inline for (optionalfields) |fieldname| {
                if (item.object.get(fieldname)) |value| {
                    @field(allocated_configs[i], fieldname) = try copyAndAttemptExand(allocator, value.string);
                }
                errdefer {
                    if (@field(allocated_configs[i], fieldname)) |p| allocator.free(p);
                }
            }

            if (item.object.get("args")) |a| {
                allocated_configs[i].args = try utils.parse_config_args(allocator, a.array);
                // NOTE: no error defer - will cause mem bug - probably should create a deinit instead of writing the code here
            }

            // Parse the env arguments if they are present
            if (item.object.get("env")) |e| {
                allocated_configs[i].env = try utils.parse_config_env(allocator, e.object);
                // NOTE: no error defer - will cause mem bug - probably should create a deinit instead of writing the code here
            }

            if (item.object.get("connect")) |connect| {
                const host_str = connect.object.get("host").?.string;
                allocated_configs[i].connect.host = try copyAndAttemptExand(allocator, host_str);
                errdefer if (allocated_configs[i].connect.host) |t| allocator.free(t);
                allocated_configs[i].connect.port = @intCast(connect.object.get("port").?.integer);
            }
        }
        results.configurations = allocated_configs;
    }

    if (root.object.get("compounds")) |compoundsObj| {
        const compounds = try allocator.alloc(Compound, compoundsObj.array.items.len);
        for (compoundsObj.array.items, 0..) |compoundObj, j| {
            compounds[j] = try Compound.init(allocator, compoundObj);
            errdefer compounds[j].deinit(allocator);
        }
        results.compounds = compounds;
    } else results.compounds = null;

    return results;
}
