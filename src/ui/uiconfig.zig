const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const utils = @import("utils");

pub const ColorRule = struct {
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

    /// A copy whose strings are owned by `alloc`.
    pub fn dupe(self: *const ColorRule, alloc: std.mem.Allocator) std.mem.Allocator.Error!ColorRule {
        var copy: ColorRule = .{ .just_pattern = self.just_pattern };
        errdefer copy.deinit(alloc);
        if (self.pattern) |p| copy.pattern = try alloc.dupe(u8, p);
        if (self.foreground_color) |p| copy.foreground_color = try alloc.dupe(u8, p);
        if (self.background_color) |p| copy.background_color = try alloc.dupe(u8, p);
        return copy;
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

pub const ProcessConfig = struct {
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

pub const UiConfig = struct {
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

    pub fn init(alloc: std.mem.Allocator) !UiConfig {
        return UiConfig{ ._alloc = alloc, .otherProcesses = try std.ArrayList(ProcessConfig).initCapacity(alloc, 10) };
    }

    /// Appends copies of `rules` to the process called `name`, after whatever it already
    /// has (an unknown name gets a new entry). Rules from the launch file land here.
    pub fn addRules(self: *UiConfig, name: []const u8, rules: []const ColorRule) std.mem.Allocator.Error!void {
        if (rules.len == 0) return;
        if (self.get(name)) |existing| {
            existing.colorRules = try appendRules(self._alloc, existing.colorRules, rules);
            return;
        }
        const process_name = try self._alloc.dupe(u8, name);
        errdefer self._alloc.free(process_name);
        const copies = try appendRules(self._alloc, &.{}, rules);
        errdefer freeRules(self._alloc, copies);
        try self.otherProcesses.append(self._alloc, .{ .processName = process_name, .colorRules = copies });
    }

    /// Like `addRules`, for the rules every view gets.
    pub fn addGlobalRules(self: *UiConfig, rules: []const ColorRule) std.mem.Allocator.Error!void {
        if (rules.len == 0) return;
        if (self.globalConfig) |*global| {
            global.colorRules = try appendRules(self._alloc, global.colorRules, rules);
            return;
        }
        const process_name = try self._alloc.dupe(u8, "GLOBAL");
        errdefer self._alloc.free(process_name);
        const copies = try appendRules(self._alloc, &.{}, rules);
        self.globalConfig = .{ .processName = process_name, .colorRules = copies };
    }

    /// `existing` ++ copies of `extra`; `existing` (the slice, not its rules) is freed.
    fn appendRules(alloc: std.mem.Allocator, existing: []const ColorRule, extra: []const ColorRule) std.mem.Allocator.Error![]ColorRule {
        const out = try alloc.alloc(ColorRule, existing.len + extra.len);
        errdefer alloc.free(out);
        @memcpy(out[0..existing.len], existing);
        var copied: usize = 0;
        errdefer for (out[existing.len..][0..copied]) |*c| c.deinit(alloc);
        for (extra, existing.len..) |*rule, i| {
            out[i] = try rule.dupe(alloc);
            copied += 1;
        }
        if (existing.len > 0) alloc.free(existing);
        return out;
    }

    fn freeRules(alloc: std.mem.Allocator, rules: []ColorRule) void {
        for (rules) |*c| c.deinit(alloc);
        alloc.free(rules);
    }

    pub fn deinit(self: *UiConfig) void {
        for (self.otherProcesses.items) |*i| {
            i.deinit(self._alloc);
        }
        self.otherProcesses.deinit(self._alloc);
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
                    try self.otherProcesses.append(self._alloc, processConfig);
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

        //const jsonstr = try std.json.stringifyAlloc(allocator, .{ .processes = processSlice }, .{});
        const jsonstr = try std.json.Stringify.valueAlloc(allocator, .{ .processes = processSlice }, .{});
        return jsonstr;
    }
};

// Parse configs
pub fn parseConfigs(
    io: Io,
    alloc: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
) !UiConfig {
    var uiconfig = try UiConfig.init(alloc);
    const max_bytes = 1024 * 1024;

    const userConfig: ?std.Io.File = blk2: switch (builtin.target.os.tag) {
        .windows => {
            const file = std.Io.Dir.openFileAbsolute(
                io,
                "\\%userprofile%\\.debugUi.json",
                .{ .mode = .read_only },
            ) catch {
                break :blk2 null;
            };
            break :blk2 file;
        },
        else => {
            // attempt to open file ~/.debugUi.json
            const home_path = utils.get_home_path(env_map);
            if (home_path) |prefix| {
                const path = try std.fmt.allocPrint(alloc, "{s}/.debugUi.json", .{prefix});
                defer alloc.free(path);
                const file = std.Io.Dir.openFileAbsolute(
                    io,
                    path,
                    .{ .mode = .read_only },
                ) catch {
                    break :blk2 null;
                };
                break :blk2 file;
            } else break :blk2 null;
        },
    };

    if (userConfig) |file| {
        var file_reader = file.reader(io, &.{});
        const userConfigData = try file_reader.interface.allocRemaining(alloc, .limited(max_bytes));
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
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            io,
            ".debugUi.json",
            alloc,
            .limited(max_bytes),
        ) catch {
            break :blk1 null;
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
    var config = try UiConfig.init(alloc);
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
    var config = try UiConfig.init(alloc);
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
    var config = try UiConfig.init(alloc);
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
    var config = try UiConfig.init(alloc);
    defer config.deinit();

    try config.parse(jsonValue.value.object);

    try std.testing.expectEqual(config.otherProcesses.items.len, 1);
    try std.testing.expectEqualSlices(u8, config.get("Process1").?.colorRules[0].pattern.?, "TEST_PATTERN2");
}

test "addRules/addGlobalRules: launch-file rules go after the file's, copied" {
    const alloc = std.testing.allocator;
    const jsonStr =
        \\{
        \\    "processes": [
        \\        {
        \\            "processName": "GLOBAL",
        \\            "colorRules": [ { "pattern": "g0", "foreground_color": "1,1,1", "just_pattern": true } ]
        \\        },
        \\        {
        \\            "processName": "Print",
        \\            "colorRules": [ { "pattern": "p0", "foreground_color": "2,2,2", "just_pattern": false } ]
        \\        }
        \\    ]
        \\}
    ;
    const jsonValue = try std.json.parseFromSlice(std.json.Value, alloc, jsonStr, .{});
    defer jsonValue.deinit();
    var config = try UiConfig.init(alloc);
    defer config.deinit();
    try config.parse(jsonValue.value.object);

    // the caller keeps ownership of what it passes in
    var pattern = [_]u8{ 'x', '1' };
    var colour = [_]u8{ '3', ',', '3', ',', '3' };
    const extra = [_]ColorRule{
        .{ .pattern = &pattern, .background_color = &colour, .just_pattern = true },
        .{ .pattern = &pattern, .foreground_color = &colour },
    };

    try config.addRules("Print", &extra);
    try config.addRules("New", extra[0..1]);
    try config.addRules("Empty", &.{});
    try config.addGlobalRules(extra[1..]);
    pattern[1] = '9'; // the copies must not see this

    const print = config.get("Print").?;
    try std.testing.expectEqual(3, print.colorRules.len);
    try std.testing.expectEqualStrings("p0", print.colorRules[0].pattern.?);
    try std.testing.expectEqualStrings("x1", print.colorRules[1].pattern.?);
    try std.testing.expectEqualStrings("3,3,3", print.colorRules[1].background_color.?);
    try std.testing.expect(print.colorRules[1].just_pattern);
    try std.testing.expectEqualStrings("x1", print.colorRules[2].pattern.?);
    try std.testing.expectEqual(null, print.colorRules[2].background_color);

    try std.testing.expectEqual(1, config.get("New").?.colorRules.len);
    try std.testing.expectEqual(null, config.get("Empty"));

    const global = config.globalConfig.?;
    try std.testing.expectEqual(2, global.colorRules.len);
    try std.testing.expectEqualStrings("g0", global.colorRules[0].pattern.?);
    try std.testing.expectEqualStrings("x1", global.colorRules[1].pattern.?);

    // with no file at all, the global entry is created on demand
    var fresh = try UiConfig.init(alloc);
    defer fresh.deinit();
    try fresh.addGlobalRules(&extra);
    try std.testing.expectEqualStrings("GLOBAL", fresh.globalConfig.?.processName);
    try std.testing.expectEqual(2, fresh.globalConfig.?.colorRules.len);
}
