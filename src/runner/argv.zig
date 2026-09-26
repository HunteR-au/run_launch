//! Turns a configured process into the argv the OS spawns.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const config_ = @import("config");

const Process = config_.Process;

/// The interpreter the `python` runner type uses.
pub const python_exe = switch (builtin.target.os.tag) {
    .windows => "py",
    else => "python3",
};

const shell_prefix: []const []const u8 = switch (builtin.target.os.tag) {
    .windows => &.{ "cmd.exe", "/c" },
    else => &.{ "sh", "-c" },
};

pub const Argv = struct {
    items: []const []const u8,
    /// the joined command a shell runs; null for the other runner types
    shell_command: ?[]u8 = null,

    pub fn deinit(self: *Argv, alloc: Allocator) void {
        alloc.free(self.items);
        if (self.shell_command) |s| alloc.free(s);
        self.* = undefined;
    }
};

/// `native`: the command line's tokens, then the args. `python`: `py -u` in front of that.
/// `shell`: the command line as written with the args appended, handed to `cmd.exe /c`
/// (`sh -c` off Windows). The strings are borrowed from `p` except the shell command.
pub fn build(alloc: Allocator, p: *const Process) Allocator.Error!Argv {
    switch (p.type) {
        .native => return .{ .items = try concat(alloc, &.{}, p.tokens, p.args) },
        .python => return .{ .items = try concat(alloc, &.{ python_exe, "-u" }, p.tokens, p.args) },
        .shell => {
            const parts = try alloc.alloc([]const u8, 1 + p.args.len);
            defer alloc.free(parts);
            parts[0] = p.command;
            @memcpy(parts[1..], p.args);
            const command = try std.mem.join(alloc, " ", parts);
            errdefer alloc.free(command);

            const items = try alloc.alloc([]const u8, shell_prefix.len + 1);
            @memcpy(items[0..shell_prefix.len], shell_prefix);
            items[shell_prefix.len] = command;
            return .{ .items = items, .shell_command = command };
        },
    }
}

fn concat(alloc: Allocator, prefix: []const []const u8, tokens: []const []const u8, args: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try alloc.alloc([]const u8, prefix.len + tokens.len + args.len);
    @memcpy(out[0..prefix.len], prefix);
    @memcpy(out[prefix.len..][0..tokens.len], tokens);
    @memcpy(out[prefix.len + tokens.len ..], args);
    return out;
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

const testing = std.testing;

fn expectArgv(p: *const Process, expected: []const []const u8) !void {
    var argv = try build(testing.allocator, p);
    defer argv.deinit(testing.allocator);
    try testing.expectEqual(expected.len, argv.items.len);
    for (expected, argv.items) |e, g| try testing.expectEqualStrings(e, g);
}

test "build: each runner type shapes the argv its own way" {
    const tokens = [_][]const u8{ "app.py", "--port", "80" };
    const args = [_][]const u8{ "-v", "extra arg" };

    const native: Process = .{ .name = "n", .command = "app.py --port 80", .tokens = &tokens, .args = &args };
    try expectArgv(&native, &.{ "app.py", "--port", "80", "-v", "extra arg" });

    const python: Process = .{ .name = "p", .command = "app.py --port 80", .tokens = &tokens, .args = &args, .type = .python };
    try expectArgv(&python, &.{ python_exe, "-u", "app.py", "--port", "80", "-v", "extra arg" });

    const module: Process = .{ .name = "m", .command = "-m http.server", .tokens = &.{ "-m", "http.server" }, .type = .python };
    try expectArgv(&module, &.{ python_exe, "-u", "-m", "http.server" });

    const shell: Process = .{ .name = "s", .command = "ls -la | sort", .tokens = &.{ "ls", "-la", "|", "sort" }, .args = &.{"-r"}, .type = .shell };
    const shell_expected: []const []const u8 = switch (builtin.target.os.tag) {
        .windows => &.{ "cmd.exe", "/c", "ls -la | sort -r" },
        else => &.{ "sh", "-c", "ls -la | sort -r" },
    };
    try expectArgv(&shell, shell_expected);

    const bare: Process = .{ .name = "b", .command = "true", .tokens = &.{"true"} };
    try expectArgv(&bare, &.{"true"});
}
