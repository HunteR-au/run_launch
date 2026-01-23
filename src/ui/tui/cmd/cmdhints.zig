const std = @import("std");
// TODO: logic for cmd hints

// update(cmdstr)

// find prefix matches for commands
// create a list of all matches
// find matches for a command
// collect options if they exist
// print arg format

// addHandler - called from cmd.zig
// removeHandler - called from cmd.zig

// Q: what should go in a handler

// hint types
// cmd suggestions
// cmd arguments
// previous inputs

pub const Hint = union(enum) {
    command: []const u8,
    argument_desc: []const u8,
    history: []const u8,
};

pub const CommandHintInfo = struct {
    commandName: []const u8,
    argumentDescription: ?[]const u8,
    // something for more dynamic argument assisting...
    // maybe a callback where you get the argument string
    // and you return a hint message
};

const CommandString = struct {
    cmd: []const u8,
    args: []const u8,

    pub fn justCmd(self: CommandString) bool {
        return if (self.args.len == 0) true else false;
    }
};

pub const CommandHinter = struct {
    command_map: std.StringArrayHashMap(?[]const u8),
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) !CommandHinter {
        return .{
            .command_map = .init(alloc),
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *CommandHinter) void {
        const iter = self.command_map.iterator();
        while (iter.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            if (entry.value_ptr.*) |p| self.alloc.free(p);
        }
        self.command_map.deinit();
    }

    fn parseCommand(input: []const u8) CommandString {
        const first_space_idx = std.mem.indexOfScalar(u8, input, ' ');
        if (first_space_idx) |index| {
            // trim whitespace from the arguments
            return .{
                .cmd = input[0..index],
                .args = std.mem.trim(u8, input[index..input.len], " "),
            };
        } else {
            return .{ .cmd = input, .args = &.{} };
        }
    }

    pub fn addCommandInfo(self: *CommandHinter, cmd_info: CommandHintInfo) !void {
        try self.command_map.put(
            try self.alloc.dupe(u8, cmd_info.commandName),
            if (cmd_info.argumentDescription) |str| try self.alloc.dupe(u8, str) else null,
        );
    }

    pub fn generateHints(self: CommandHinter, alloc: std.mem.Allocator, cmd_str: []const u8) ![]Hint {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const scratch = arena.allocator();

        // exit early
        if (cmd_str.len == 0) return &.{};

        // parse input
        const input = parseCommand(cmd_str);

        if (input.justCmd()) {
            // first check if there are any command matches
            var exact_match = false;
            var prefix_matches: std.ArrayList([]const u8) = try .initCapacity(scratch, 1);
            var iter = self.command_map.iterator();
            while (iter.next()) |cmd_entry| {
                if (std.mem.startsWith(u8, cmd_entry.key_ptr.*, input.cmd)) {
                    try prefix_matches.append(scratch, cmd_entry.key_ptr.*);
                    if (exact_match == false and input.cmd.len == cmd_entry.key_ptr.*.len) {
                        exact_match = true;
                    }
                }
            }

            // check if we have an exact cmd written
            if (prefix_matches.items.len == 1 and exact_match) {
                // we have an exact match, list the argument description
                if (self.command_map.get(prefix_matches.items[0])) |value| {
                    if (value) |arg_str| {
                        var hints = try alloc.alloc(Hint, 1);
                        hints[0] = .{ .argument_desc = try alloc.dupe(u8, arg_str) };
                        return hints;
                    } else {
                        return &.{};
                    }
                }
            } else if (prefix_matches.items.len > 0) {
                // return matching commands
                var hints: std.ArrayList(Hint) = try .initCapacity(alloc, prefix_matches.items.len);
                for (prefix_matches.items) |match| {
                    try hints.append(alloc, .{
                        .command = try alloc.dupe(u8, match),
                    });
                }
                return hints.toOwnedSlice(alloc);
            } else {
                // no matches
                return &.{};
            }
        }

        if (self.command_map.get(input.cmd)) |value| {
            if (value) |arg_str| {
                // we have found an argument string
                var hints = try alloc.alloc(Hint, 1);
                hints[0] = .{ .argument_desc = try alloc.dupe(u8, arg_str) };
                return hints;
            } else {
                return &.{};
            }
        } else {
            // no matching command
            return &.{};
        }
    }
};
