const std = @import("std");
const builtin = @import("builtin");

const ColorRule = struct {
    pattern: ?[]u8 = null,
    foreground_color: ?[]u8 = null,
    background_color: ?[]u8 = null,
    just_pattern: bool = false,

    const ColorRuleParseError = error{
        ValidationFailed,
    };

    pub fn deinit(self: *ColorRule, alloc: std.mem.Allocator) void {
        if (self.pattern) |p| {
            alloc.free(p);
        }
        if (self.foreground_color) |p| {
            alloc.free(p);
        }
        if (self.background_color) |p| {
            alloc.free(p);
        }
    }

    pub fn parse(alloc: std.mem.Allocator, object: std.json.ObjectMap) !ColorRule {
        var rule = ColorRule{};
        errdefer rule.deinit(alloc);

        // parse each field
        inline for (std.meta.fields(ColorRule)) |field| {
            switch (field.type) {
                ?[]u8 => {
                    if (object.contains(field.name)) {
                        @field(rule, field.name) = try alloc.dupe(u8, object.get(field.name).?.string);
                    }
                },
                bool => {
                    @field(rule, field.name) = object.get(field.name).?.bool;
                },
                else => unreachable,
            }
        }

        // validation
        if (rule.background_color == null and rule.foreground_color == null) {
            rule.deinit(alloc);
            return ColorRuleParseError.ValidationFailed;
        }
        // TODO: validate strings are in a valid format
        return rule;
    }
};

const ProcessConfig = struct {
    processName: []u8,
    colorRules: []ColorRule,

    const ProcessConfigError = error{
        MissingProcessConfigKey,
    };

    pub fn deinit(self: *const ProcessConfig, alloc: std.mem.Allocator) void {
        alloc.free(self.processName);
        for (self.colorRules) |*c| {
            c.deinit(alloc);
        }
        alloc.free(self.colorRules);
    }

    pub fn parse(alloc: std.mem.Allocator, object: std.json.ObjectMap) !ProcessConfig {
        var processConfig = ProcessConfig{ .processName = undefined, .colorRules = undefined };

        // parse each field
        inline for (std.meta.fields(ProcessConfig)) |field| {
            switch (field.type) {
                []u8 => {
                    if (object.contains(field.name)) {
                        @field(processConfig, field.name) = try alloc.dupe(u8, object.get(field.name).?.string);
                    } else {
                        return ProcessConfigError.MissingProcessConfigKey;
                    }
                },
                []ColorRule => {
                    if (!object.contains(field.name)) {
                        return ProcessConfigError.MissingProcessConfigKey;
                    }

                    const numOfItems = object.get(field.name).?.array.items.len;
                    var colorRuleList: []ColorRule = try alloc.alloc(ColorRule, numOfItems);
                    errdefer {
                        for (colorRuleList) |*c| {
                            c.deinit(alloc);
                        }
                        alloc.free(colorRuleList);
                    }

                    // we need to parse a list of objects (being colorRules)
                    for (object.get(field.name).?.array.items, 0..) |value, i| {
                        colorRuleList[i] = try ColorRule.parse(alloc, value.object);
                    }

                    @field(processConfig, field.name) = colorRuleList;
                },
                else => unreachable,
            }
        }
        return processConfig;
    }
};

const UiConfig = struct {
    _alloc: std.mem.Allocator,
    globalConfig: ?ProcessConfig = null,
    otherProcesses: std.ArrayList(ProcessConfig),

    pub fn get(self: *const UiConfig, name: []const u8) ?*ProcessConfig {
        return for (self.otherProcesses.items) |*process| {
            if (std.mem.eql(u8, process.processName, name)) {
                break process;
            }
        } else null;
    }

    pub fn init(alloc: std.mem.Allocator) UiConfig {
        return UiConfig{ ._alloc = alloc, .otherProcesses = std.ArrayList(ProcessConfig).init(alloc) };
    }

    pub fn deinit(self: UiConfig) void {
        for (self.otherProcesses.items) |*i| {
            i.deinit(self._alloc);
        }
        self.otherProcesses.deinit();
        if (self.globalConfig) |*p| {
            p.deinit(self._alloc);
        }
    }

    pub fn parse(self: *UiConfig, object: std.json.ObjectMap) !void {
        for (object.get("processes").?.array.items) |v| {
            const processConfig = try ProcessConfig.parse(self._alloc, v.object);

            if (std.mem.eql(u8, processConfig.processName, "GLOBAL")) {
                // check if a global object already exists, if so remove it
                if (self.globalConfig) |*p| {
                    p.deinit(self._alloc);
                }
                self.globalConfig = processConfig;
            } else {
                // check that name doesn't exist, else overwrite
                var bMatch = false;
                for (self.otherProcesses.items, 0..) |item, i| {
                    if (std.mem.eql(u8, item.processName, processConfig.processName)) {
                        // Clean up the clash and then replace
                        self.otherProcesses.items[i].deinit(self._alloc);
                        self.otherProcesses.items[i] = processConfig;
                        bMatch = true;
                        break;
                    }
                }

                if (!bMatch) {
                    try self.otherProcesses.append(processConfig);
                }
            }
        }
    }

    pub fn dumps(self: *const UiConfig, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        var numProcessItems: usize = undefined;
        var processSlice: []ProcessConfig = undefined;

        if (self.globalConfig != null) {
            numProcessItems = self.otherProcesses.items.len + 1;
            processSlice = try allocator.alloc(ProcessConfig, numProcessItems);
            // @memcpy(processSlice, self.otherProcesses.items);
            std.mem.copyForwards(ProcessConfig, processSlice, self.otherProcesses.items);

            // Create a 1-element slice from the config
            const source: []const ProcessConfig = &[_]ProcessConfig{self.globalConfig.?};
            std.mem.copyForwards(ProcessConfig, processSlice[processSlice.len - 1 .. processSlice.len], source);
            @memcpy(processSlice[processSlice.len - 1 .. processSlice.len], source);
        } else {
            numProcessItems = self.otherProcesses.items.len;
            processSlice = try allocator.alloc(ProcessConfig, numProcessItems);
            @memcpy(processSlice, self.otherProcesses.items);
        }
        defer allocator.free(processSlice);

        const jsonstr = try std.json.stringifyAlloc(allocator, .{ .processes = processSlice }, .{});
        return jsonstr;
    }
};

// Parse configs
pub fn parseConfigs(
    alloc: std.mem.Allocator,
) !UiConfig {
    var uiconfig = UiConfig.init(alloc);
    const max_bytes = 1024 * 1024;

    const userConfigPath = switch (builtin.target.os.tag) {
        .windows => "\\%userprofile%\\.debugUi.json",
        else => "~\\.debugUi.json",
    };

    const userConfig: ?std.fs.File = blk2: {
        const file = std.fs.openFileAbsolute(
            userConfigPath,
            .{ .mode = .read_only },
        ) catch |err| switch (err) {
            std.fs.File.OpenError.FileNotFound => break :blk2 null,
            else => return err,
        };
        break :blk2 file;
    };

    if (userConfig) |file| {
        const userConfigData = try file.readToEndAlloc(alloc, max_bytes);
        defer alloc.free(userConfigData);

        // parse userConfigData
        var parsedUserConfig = try std.json.parseFromSlice(
            std.json.Value,
            alloc,
            userConfigData,
            .{},
        );
        defer parsedUserConfig.deinit();
        try uiconfig.parse(parsedUserConfig.value.object);
    }

    const localConfigBytes: ?[]u8 = blk1: {
        const bytes = std.fs.cwd().readFileAlloc(
            alloc,
            ".debugUi.json",
            max_bytes,
        ) catch |err| switch (err) {
            std.fs.File.OpenError.FileNotFound => break :blk1 null,
            else => return err,
        };
        break :blk1 bytes;
    };

    if (localConfigBytes) |bytes| {
        defer alloc.free(bytes);

        // parse localConfigBytes
        var parsedLocalConfig = try std.json.parseFromSlice(
            std.json.Value,
            alloc,
            bytes,
            .{},
        );
        defer parsedLocalConfig.deinit();
        try uiconfig.parse(parsedLocalConfig.value.object);
    }

    return uiconfig;
}

test "Valid input with 1 rule" {
    const alloc = std.testing.allocator;
    const jsonStr =
        \\{
        \\    "processes": [
        \\        {
        \\            "processName": "Process1",
        \\            "colorRules": [
        \\                {
        \\                    "pattern": "TEST_PATTERN",
        \\                    "foreground_color": "220,6,6",
        \\                    "background_color": "220,6,7",
        \\                    "just_pattern": true
        \\                }
        \\            ]
        \\        }
        \\    ]
        \\}
    ;
    const jsonValue = try std.json.parseFromSlice(std.json.Value, alloc, jsonStr, .{});
    defer jsonValue.deinit();

    // check if parsing passes with a simple valid case
    var config = UiConfig.init(alloc);
    defer config.deinit();

    try config.parse(jsonValue.value.object);

    try std.testing.expectEqual(config.globalConfig, null);
    try std.testing.expectEqual(config.otherProcesses.items.len, 1);
    try std.testing.expectEqualSlices(u8, config.get("Process1").?.processName, "Process1");
    try std.testing.expectEqualSlices(u8, config.get("Process1").?.colorRules[0].pattern.?, "TEST_PATTERN");
    try std.testing.expectEqualSlices(u8, config.get("Process1").?.colorRules[0].foreground_color.?, "220,6,6");
    try std.testing.expectEqualSlices(u8, config.get("Process1").?.colorRules[0].background_color.?, "220,6,7");
    try std.testing.expectEqual(config.get("Process1").?.colorRules[0].just_pattern, true);
}

test "Valid input with 2 rules" {
    const alloc = std.testing.allocator;
    const jsonStr =
        \\{
        \\    "processes": [
        \\        {
        \\            "processName": "Process1",
        \\            "colorRules": [
        \\                {
        \\                    "pattern": "TEST_PATTERN",
        \\                    "foreground_color": "220,6,6",
        \\                    "background_color": "220,6,6",
        \\                    "just_pattern": true
        \\                },
        \\                {
        \\                    "pattern": "TEST_PATTERN",
        \\                    "foreground_color": "220,6,7",
        \\                    "background_color": "220,6,7",
        \\                    "just_pattern": false
        \\                }
        \\            ]
        \\        }
        \\    ]
        \\}
    ;
    const jsonValue = try std.json.parseFromSlice(std.json.Value, alloc, jsonStr, .{});
    defer jsonValue.deinit();

    // check if parsing passes with a simple valid case
    var config = UiConfig.init(alloc);
    defer config.deinit();

    try config.parse(jsonValue.value.object);

    try std.testing.expectEqual(config.otherProcesses.items.len, 1);
}

test "Valid input with 2 rules and 2 processes" {
    const alloc = std.testing.allocator;
    const jsonStr =
        \\{
        \\    "processes": [
        \\        {
        \\            "processName": "Process1",
        \\            "colorRules": [
        \\                {
        \\                    "pattern": "TEST_PATTERN",
        \\                    "foreground_color": "220,6,6",
        \\                    "background_color": "220,6,6",
        \\                    "just_pattern": true
        \\                },
        \\                {
        \\                    "pattern": "TEST_PATTERN",
        \\                    "foreground_color": "220,6,7",
        \\                    "background_color": "220,6,7",
        \\                    "just_pattern": false
        \\                }
        \\            ]
        \\        },
        \\        {
        \\            "processName": "Process2",
        \\            "colorRules": [
        \\                {
        \\                    "pattern": "TEST_PATTERN",
        \\                    "foreground_color": "220,6,6",
        \\                    "background_color": "220,6,6",
        \\                    "just_pattern": true
        \\                },
        \\                {
        \\                    "pattern": "TEST_PATTERN",
        \\                    "foreground_color": "220,6,7",
        \\                    "background_color": "220,6,7",
        \\                    "just_pattern": false
        \\                }
        \\            ]
        \\        }
        \\    ]
        \\}
    ;
    const jsonValue = try std.json.parseFromSlice(std.json.Value, alloc, jsonStr, .{});
    defer jsonValue.deinit();

    // check if parsing passes with a simple valid case
    var config = UiConfig.init(alloc);
    defer config.deinit();

    try config.parse(jsonValue.value.object);

    try std.testing.expectEqual(config.otherProcesses.items.len, 2);

    // dump the resulting config to a string
    const str = try config.dumps(alloc);
    defer alloc.free(str);
}

test "Two processes with same name" {
    const alloc = std.testing.allocator;
    const jsonStr =
        \\{
        \\    "processes": [
        \\        {
        \\            "processName": "Process1",
        \\            "colorRules": [
        \\                {
        \\                    "pattern": "TEST_PATTERN",
        \\                    "foreground_color": "220,6,6",
        \\                    "background_color": "220,6,6",
        \\                    "just_pattern": true
        \\                }
        \\            ]
        \\        },
        \\        {
        \\            "processName": "Process1",
        \\            "colorRules": [
        \\                {
        \\                    "pattern": "TEST_PATTERN2",
        \\                    "foreground_color": "220,6,6",
        \\                    "background_color": "220,6,6",
        \\                    "just_pattern": true
        \\                }
        \\            ]
        \\        }
        \\    ]
        \\}
    ;
    const jsonValue = try std.json.parseFromSlice(std.json.Value, alloc, jsonStr, .{});
    defer jsonValue.deinit();

    // check if parsing passes with a simple valid case
    var config = UiConfig.init(alloc);
    defer config.deinit();

    try config.parse(jsonValue.value.object);

    try std.testing.expectEqual(config.otherProcesses.items.len, 1);
    try std.testing.expectEqualSlices(u8, config.get("Process1").?.colorRules[0].pattern.?, "TEST_PATTERN2");
}
