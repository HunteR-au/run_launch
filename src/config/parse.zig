//! Reads the YAML launch file into a `Configuration` (CONFIG.md documents the format).
//!
//! Every problem is reported through `Diagnostics` in the user's terms: which entry, which
//! field, what was expected instead. The YAML library keeps no source positions in its
//! untyped tree, so semantic errors name the entry (`configs[2] (Print)`) rather than a line;
//! syntax errors come with the library's line/column report.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Yaml = @import("yaml").Yaml;

const expand = @import("expand.zig");
const cmdline = @import("cmdline.zig");
const model = @import("configuration.zig");

const Configuration = model.Configuration;
const Process = model.Process;
const Group = model.Group;
const Target = model.Target;
const ColorRule = model.ColorRule;
const EnvTuple = model.EnvTuple;
const RunnerType = model.RunnerType;
const Value = Yaml.Value;
const Map = Yaml.Map;

/// Where a failed parse explains itself. Empty until something went wrong.
pub const Diagnostics = struct {
    buf: [2048]u8 = undefined,
    len: usize = 0,

    pub fn set(self: *Diagnostics, comptime fmt: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(&self.buf, fmt, args) catch {
            self.len = self.buf.len; // truncated; the start is what matters
            return;
        };
        self.len = written.len;
    }

    pub fn message(self: *const Diagnostics) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const Error = error{
    /// the text is not valid YAML (`Diagnostics` carries the library's report)
    ParseFailure,
    /// valid YAML that does not describe a usable configuration (`Diagnostics` says why)
    InvalidConfig,
} || Allocator.Error;

/// `${...}` tokens in command lines, args and env values are expanded here, so
/// `expand.init_expand` must have been called.
pub fn parse(io: Io, gpa: Allocator, source: []const u8, diag: *Diagnostics) Error!Configuration {
    if (isBlank(source)) {
        diag.set("the file is empty: it needs at least a `processes:` map", .{});
        return error.InvalidConfig;
    }
    try checkQuotes(source, diag);

    var yaml: Yaml = .{ .source = source };
    defer yaml.deinit(gpa);
    yaml.load(gpa) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseFailure => {
            renderYamlErrors(gpa, &yaml, diag);
            return error.ParseFailure;
        },
        else => {
            diag.set("the file could not be read as YAML: {t}", .{err});
            return error.ParseFailure;
        },
    };

    if (yaml.docs.items.len == 0 or yaml.docs.items[0] == .empty) {
        diag.set("the file is empty: it needs at least a `processes:` map", .{});
        return error.InvalidConfig;
    }
    const root = yaml.docs.items[0].asMap() orelse {
        diag.set("the top level must be a map of settings (`processes:`, `groups:`, `configs:`, ...)", .{});
        return error.InvalidConfig;
    };

    var config: Configuration = .init(gpa);
    errdefer config.deinit();

    var parser: Parser = .{
        .io = io,
        .alloc = config.arena.allocator(),
        .diag = diag,
        .config = &config,
    };
    try parser.root(root);
    return config;
}

/// Nothing but whitespace and `#` comments (the YAML library chokes on a comment-only file).
fn isBlank(source: []const u8) bool {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (t.len > 0 and t[0] != '#') return false;
    }
    return true;
}

/// The YAML library crashes on a quoted scalar that never closes, so those are caught
/// here first. Its tokenizer opens a quoted scalar at any `'` or `"`, even inside a word
/// (`it's` is `it` followed by an unterminated quote), and this check mirrors that. A `#`
/// at the start of a word begins a comment. Quoted scalars spanning lines are not
/// supported (they are never needed in this file).
fn checkQuotes(source: []const u8, diag: *Diagnostics) Error!void {
    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_no: usize = 1;
    while (lines.next()) |line| : (line_no += 1) {
        var i: usize = 0;
        while (i < line.len) : (i += 1) {
            const c = line[i];
            if (c == '#' and (i == 0 or std.ascii.isWhitespace(line[i - 1]))) break; // comment
            if (c != '"' and c != '\'') continue;

            // find the closing quote on this line (`''` and `\"` are escapes)
            var j = i + 1;
            const closed = while (j < line.len) : (j += 1) {
                if (c == '"' and line[j] == '\\') {
                    j += 1;
                    continue;
                }
                if (line[j] != c) continue;
                if (c == '\'' and j + 1 < line.len and line[j + 1] == '\'') {
                    j += 1;
                    continue;
                }
                break true;
            } else false;
            if (!closed) {
                diag.set("line {d}: the quote at column {d} is never closed (an apostrophe in an unquoted value counts too; quote the whole value): {s}", .{ line_no, i + 1, std.mem.trim(u8, line, "\r") });
                return error.InvalidConfig;
            }
            i = j;
        }
    }
}

fn renderYamlErrors(gpa: Allocator, yaml: *const Yaml, diag: *Diagnostics) void {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    yaml.parse_errors.renderToWriter(.{
        .include_reference_trace = false,
        .include_log_text = false,
    }, &aw.writer) catch {};
    const text = std.mem.trim(u8, aw.written(), &std.ascii.whitespace);
    if (text.len == 0) {
        diag.set("YAML syntax error", .{});
    } else {
        diag.set("YAML syntax error:\n{s}", .{text});
    }
}

// ------------------------------------------------------------------
// The keys each map may carry. An unknown key is an error (it is nearly always a typo).
// ------------------------------------------------------------------

const root_keys = [_][]const u8{ "default", "processes", "groups", "configs", "colorRules", "script" };
const process_config_keys = [_][]const u8{ "name", "type", "args", "env", "preTask", "postTask", "script", "colorRules" };
const group_config_keys = [_][]const u8{ "name", "preTask", "postTask", "script", "colorRules" };
const color_rule_keys = [_][]const u8{ "pattern", "foreground_color", "background_color", "just_pattern" };

fn keyList(comptime keys: []const []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (keys, 0..) |k, i| out = out ++ (if (i == 0) "" else ", ") ++ k;
        return out;
    }
}

const runner_type_list = blk: {
    var out: []const u8 = "";
    for (std.meta.fieldNames(RunnerType), 0..) |n, i| out = out ++ (if (i == 0) "" else ", ") ++ n;
    break :blk out;
};

// ------------------------------------------------------------------
// Value helpers
// ------------------------------------------------------------------

fn strEql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Map keys come back as raw source text, quotes included, so `"processes"` (JSON style)
/// and `processes` are the same key.
fn keyName(raw: []const u8) []const u8 {
    const t = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (t.len >= 2) {
        const first = t[0];
        const last = t[t.len - 1];
        if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) return t[1 .. t.len - 1];
    }
    return t;
}

fn getKey(map: Map, name: []const u8) ?Value {
    for (map.keys(), map.values()) |k, v| {
        if (strEql(keyName(k), name)) return v;
    }
    return null;
}

/// The string of a scalar value. A bare `true`/`false` is a string too: `true` is a
/// perfectly good command.
fn scalarOf(value: Value) ?[]const u8 {
    return switch (value) {
        .scalar => |s| s,
        .boolean => |b| if (b) "true" else "false",
        else => null,
    };
}

fn boolOf(value: Value) ?bool {
    return switch (value) {
        .boolean => |b| b,
        .scalar => |s| {
            const truthy = [_][]const u8{ "true", "yes", "on" };
            const falsy = [_][]const u8{ "false", "no", "off" };
            for (truthy) |t| if (std.ascii.eqlIgnoreCase(s, t)) return true;
            for (falsy) |f| if (std.ascii.eqlIgnoreCase(s, f)) return false;
            return null;
        },
        else => null,
    };
}

/// A short "where am I" label for messages, formatted into the caller's buffer.
fn label(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, fmt, args) catch buf;
}

// ------------------------------------------------------------------
// The parser proper
// ------------------------------------------------------------------

const Parser = struct {
    io: Io,
    /// the configuration's arena: nothing allocated here is freed individually
    alloc: Allocator,
    diag: *Diagnostics,
    config: *Configuration,

    fn fail(self: *Parser, comptime fmt: []const u8, args: anytype) Error {
        self.diag.set(fmt, args);
        return error.InvalidConfig;
    }

    fn root(self: *Parser, map: Map) Error!void {
        try self.rejectUnknownKeys(map, &root_keys, "the top level");

        const processes = getKey(map, "processes") orelse {
            return self.fail("`processes:` is missing: it maps each process name to its command line", .{});
        };
        try self.parseProcesses(processes);
        if (getKey(map, "groups")) |v| try self.parseGroups(v);
        if (getKey(map, "configs")) |v| try self.parseConfigs(v);
        if (getKey(map, "colorRules")) |v| self.config.color_rules = try self.parseColorRules(v, "colorRules");
        if (getKey(map, "script")) |v| self.config.script = try self.parseScript(v, "script");
        if (getKey(map, "default")) |v| try self.parseDefault(v);
        try self.computeRunAll();
    }

    fn rejectUnknownKeys(self: *Parser, map: Map, comptime allowed: []const []const u8, where: []const u8) Error!void {
        for (map.keys()) |raw| {
            const key = keyName(raw);
            const known = for (allowed) |a| {
                if (strEql(a, key)) break true;
            } else false;
            if (!known) {
                return self.fail("{s} has an unknown field `{s}` (valid: {s})", .{ where, key, comptime keyList(allowed) });
            }
        }
    }

    fn checkName(self: *Parser, name: []const u8, kind: []const u8) Error!void {
        if (name.len == 0) return self.fail("a {s} has an empty name", .{kind});
        if (strEql(name, "_")) return self.fail("`_` cannot be a {s} name: scripts use it for \"every view\"", .{kind});
        if (name[0] == '~') return self.fail("{s} name \"{s}\" cannot start with `~`: scripts use `~n` for view numbers", .{ kind, name });
        if (std.mem.findScalar(u8, name, ':') != null) return self.fail("{s} name \"{s}\" cannot contain `:`: script lines use it as the separator", .{ kind, name });
    }

    fn processMut(self: *Parser, name: []const u8) ?*Process {
        for (self.config.processes) |*p| {
            if (strEql(p.name, name)) return p;
        }
        return null;
    }

    fn groupMut(self: *Parser, name: []const u8) ?*Group {
        for (self.config.groups) |*g| {
            if (strEql(g.name, name)) return g;
        }
        return null;
    }

    /// `${...}` tokens resolved; the result lives in the arena.
    fn expandStr(self: *Parser, s: []const u8, where: []const u8) Error![]u8 {
        return expand.expand_string(self.io, self.alloc, s) catch |err| switch (err) {
            error.NoExpansionFound => try self.alloc.dupe(u8, s),
            error.OutOfMemory => error.OutOfMemory,
            error.TokenExpectedEnvVar => self.fail("{s}: \"{s}\" names an environment variable that is not set", .{ where, s }),
            error.UnknownExpandToken, error.UnsupportedExpansionToken => self.fail("{s}: \"{s}\" uses an unknown `${{...}}` token (try `${{env:NAME}}` or `${{cwd}}`)", .{ where, s }),
            else => self.fail("{s}: cannot expand \"{s}\": {t}", .{ where, s, err }),
        };
    }

    fn tokensOf(self: *Parser, command: []const u8, where: []const u8) Error![]const []const u8 {
        const tokens = cmdline.split(self.alloc, command) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.EmptyCommandLine => return self.fail("{s}: the command line is empty", .{where}),
            error.UnterminatedQuote => return self.fail("{s}: the command line has an unterminated quote: {s}", .{ where, command }),
        };
        const expanded = try self.alloc.alloc([]const u8, tokens.len);
        for (tokens, 0..) |t, i| expanded[i] = try self.expandStr(t, where);
        return expanded;
    }

    fn parseProcesses(self: *Parser, value: Value) Error!void {
        const map = value.asMap() orelse return self.fail("`processes:` must be a map of `name: command line`", .{});
        if (map.count() == 0) return self.fail("`processes:` is empty: add at least one `name: command line`", .{});

        const processes = try self.alloc.alloc(Process, map.count());
        for (map.keys(), map.values(), 0..) |raw_key, cmd_value, i| {
            const name = keyName(raw_key);
            try self.checkName(name, "process");
            for (processes[0..i]) |prev| {
                if (strEql(prev.name, name)) return self.fail("process \"{s}\" is listed twice", .{name});
            }
            const command = scalarOf(cmd_value) orelse {
                return self.fail("process \"{s}\" needs a command line string, e.g. `{s}: python app.py`", .{ name, name });
            };
            var where_buf: [256]u8 = undefined;
            const where = label(&where_buf, "processes.{s}", .{name});
            processes[i] = .{
                .name = try self.alloc.dupe(u8, name),
                .command = try self.expandStr(command, where),
                .tokens = try self.tokensOf(command, where),
            };
        }
        self.config.processes = processes;
    }

    fn parseGroups(self: *Parser, value: Value) Error!void {
        const map = value.asMap() orelse return self.fail("`groups:` must be a map of `name: [process, ...]`", .{});

        const groups = try self.alloc.alloc(Group, map.count());
        for (map.keys(), map.values(), 0..) |raw_key, members_value, i| {
            const name = keyName(raw_key);
            try self.checkName(name, "group");
            if (self.config.findProcess(name) != null) {
                return self.fail("\"{s}\" is both a process and a group: names must be unique across the two", .{name});
            }
            for (groups[0..i]) |prev| {
                if (strEql(prev.name, name)) return self.fail("group \"{s}\" is listed twice", .{name});
            }
            const list = members_value.asList() orelse {
                return self.fail("group \"{s}\" must be a list of process names, e.g. `{s}: [a, b]`", .{ name, name });
            };
            if (list.len == 0) return self.fail("group \"{s}\" is empty", .{name});

            const members = try self.alloc.alloc(*const Process, list.len);
            for (list, 0..) |item, j| {
                const member_name = scalarOf(item) orelse return self.fail("group \"{s}\": entry {d} is not a process name", .{ name, j + 1 });
                const p = self.config.findProcess(member_name) orelse {
                    return self.fail("group \"{s}\" lists \"{s}\", which is not in `processes:`", .{ name, member_name });
                };
                for (members[0..j]) |prev| {
                    if (prev == p) return self.fail("group \"{s}\" lists \"{s}\" twice", .{ name, member_name });
                }
                members[j] = p;
            }
            groups[i] = .{ .name = try self.alloc.dupe(u8, name), .members = members };
        }
        self.config.groups = groups;
    }

    fn parseConfigs(self: *Parser, value: Value) Error!void {
        const list = value.asList() orelse return self.fail("`configs:` must be a list of `- name: ...` entries", .{});
        for (list, 0..) |entry, i| {
            var where_buf: [64]u8 = undefined;
            const where = label(&where_buf, "configs[{d}]", .{i + 1});
            const map = entry.asMap() orelse return self.fail("{s} must be a map starting with `name:`", .{where});
            const name_value = getKey(map, "name") orelse return self.fail("{s} has no `name:` (the process or group it configures)", .{where});
            const name = scalarOf(name_value) orelse return self.fail("{s}: `name:` must be a process or group name", .{where});

            for (list[0..i]) |prev| {
                const prev_map = prev.asMap() orelse continue;
                const prev_name = scalarOf(getKey(prev_map, "name") orelse continue) orelse continue;
                if (strEql(prev_name, name)) return self.fail("{s}: \"{s}\" already has a config entry above; merge the two", .{ where, name });
            }

            var named_buf: [256]u8 = undefined;
            const where_named = label(&named_buf, "configs[{d}] ({s})", .{ i + 1, name });
            if (self.processMut(name)) |p| {
                try self.parseProcessConfig(map, p, where_named);
            } else if (self.groupMut(name)) |g| {
                try self.parseGroupConfig(map, g, where_named);
            } else {
                return self.fail("{s}: \"{s}\" is not a process or group (check the spelling)", .{ where, name });
            }
        }
    }

    fn parseProcessConfig(self: *Parser, map: Map, p: *Process, where: []const u8) Error!void {
        try self.rejectUnknownKeys(map, &process_config_keys, where);
        if (getKey(map, "type")) |v| {
            const s = scalarOf(v) orelse return self.fail("{s}: `type:` must be one of {s}", .{ where, runner_type_list });
            p.type = std.meta.stringToEnum(RunnerType, s) orelse {
                return self.fail("{s}: unknown type \"{s}\" (one of {s})", .{ where, s, runner_type_list });
            };
        }
        if (getKey(map, "args")) |v| p.args = try self.parseStringList(v, where, "args");
        if (getKey(map, "env")) |v| p.env = try self.parseEnv(v, where);
        if (getKey(map, "preTask")) |v| p.pre_task = try self.parseTaskRef(v, p.name, where, "preTask");
        if (getKey(map, "postTask")) |v| p.post_task = try self.parseTaskRef(v, p.name, where, "postTask");
        if (getKey(map, "script")) |v| p.script = try self.parseScript(v, where);
        if (getKey(map, "colorRules")) |v| p.color_rules = try self.parseColorRules(v, where);
    }

    fn parseGroupConfig(self: *Parser, map: Map, g: *Group, where: []const u8) Error!void {
        try self.rejectUnknownKeys(map, &group_config_keys, where);
        if (getKey(map, "preTask")) |v| g.pre_task = try self.parseTaskRef(v, g.name, where, "preTask");
        if (getKey(map, "postTask")) |v| g.post_task = try self.parseTaskRef(v, g.name, where, "postTask");
        if (getKey(map, "script")) |v| g.script = try self.parseScript(v, where);
        if (getKey(map, "colorRules")) |v| g.color_rules = try self.parseColorRules(v, where);
    }

    /// `preTask: name` / `postTask: name`: the named process is marked as a task.
    fn parseTaskRef(self: *Parser, value: Value, owner: []const u8, where: []const u8, field: []const u8) Error!*const Process {
        const name = scalarOf(value) orelse return self.fail("{s}: `{s}:` must name a process", .{ where, field });
        const task = self.processMut(name) orelse {
            return self.fail("{s}: `{s}: {s}` does not name a process in `processes:`", .{ where, field, name });
        };
        if (strEql(task.name, owner)) return self.fail("{s}: `{s}:` cannot point at the entry itself", .{ where, field });
        task.is_task = true;
        return task;
    }

    fn parseStringList(self: *Parser, value: Value, where: []const u8, field: []const u8) Error![]const []const u8 {
        const list = value.asList() orelse return self.fail("{s}: `{s}:` must be a list of strings", .{ where, field });
        const out = try self.alloc.alloc([]const u8, list.len);
        for (list, 0..) |item, i| {
            const s = scalarOf(item) orelse return self.fail("{s}: `{s}:` entry {d} is not a string", .{ where, field, i + 1 });
            out[i] = try self.expandStr(s, where);
        }
        return out;
    }

    /// `env:` is a map (`env: {DEBUG: '1'}`) or a list of `KEY=VALUE` strings.
    fn parseEnv(self: *Parser, value: Value, where: []const u8) Error![]const EnvTuple {
        switch (value) {
            .map => |m| {
                const out = try self.alloc.alloc(EnvTuple, m.count());
                for (m.keys(), m.values(), 0..) |raw_key, v, i| {
                    const key = keyName(raw_key);
                    const val = scalarOf(v) orelse return self.fail("{s}: `env: {s}:` must be a string", .{ where, key });
                    out[i] = .{ .key = try self.alloc.dupe(u8, key), .val = try self.expandStr(val, where) };
                }
                return out;
            },
            .list => |l| {
                const out = try self.alloc.alloc(EnvTuple, l.len);
                for (l, 0..) |item, i| {
                    const s = scalarOf(item) orelse return self.fail("{s}: `env:` entry {d} is not a `KEY=VALUE` string", .{ where, i + 1 });
                    const eq = std.mem.findScalar(u8, s, '=') orelse return self.fail("{s}: `env:` entry \"{s}\" is not KEY=VALUE", .{ where, s });
                    if (eq == 0) return self.fail("{s}: `env:` entry \"{s}\" has an empty name", .{ where, s });
                    out[i] = .{ .key = try self.alloc.dupe(u8, s[0..eq]), .val = try self.expandStr(s[eq + 1 ..], where) };
                }
                return out;
            },
            else => return self.fail("{s}: `env:` must be a map (`env: {{DEBUG: '1'}}`) or a list of `KEY=VALUE` strings", .{where}),
        }
    }

    /// A list of `select: command` lines, returned joined with '\n' (null when empty).
    fn parseScript(self: *Parser, value: Value, where: []const u8) Error!?[]const u8 {
        const list = value.asList() orelse return self.fail("{s}: `script:` must be a list of `select: command` lines", .{where});
        if (list.len == 0) return null;
        const lines = try self.alloc.alloc([]const u8, list.len);
        for (list, 0..) |item, i| {
            const s = scalarOf(item) orelse return self.fail("{s}: script line {d} is not a string", .{ where, i + 1 });
            const line = std.mem.trim(u8, s, &std.ascii.whitespace);
            const sep = std.mem.findScalar(u8, line, ':') orelse {
                return self.fail("{s}: script line {d} \"{s}\" needs a `:` (`: cmd`, `_: cmd`, `name: cmd`)", .{ where, i + 1, s });
            };
            if (std.mem.trim(u8, line[sep + 1 ..], &std.ascii.whitespace).len == 0) {
                return self.fail("{s}: script line {d} \"{s}\" has no command after the `:`", .{ where, i + 1, s });
            }
            lines[i] = line;
        }
        return try std.mem.join(self.alloc, "\n", lines);
    }

    fn parseColorRules(self: *Parser, value: Value, where: []const u8) Error![]const ColorRule {
        const list = value.asList() orelse return self.fail("{s}: `colorRules:` must be a list of rules (`- pattern: ...`)", .{where});
        const rules = try self.alloc.alloc(ColorRule, list.len);
        for (list, 0..) |item, i| {
            var where_buf: [300]u8 = undefined;
            const rule_where = label(&where_buf, "{s}: colorRules[{d}]", .{ where, i + 1 });
            const m = item.asMap() orelse return self.fail("{s} must be a map with `pattern:` and a colour", .{rule_where});
            try self.rejectUnknownKeys(m, &color_rule_keys, rule_where);

            var rule: ColorRule = .{};
            const pattern_value = getKey(m, "pattern") orelse return self.fail("{s} has no `pattern:`", .{rule_where});
            const pattern = scalarOf(pattern_value) orelse return self.fail("{s}: `pattern:` must be a string", .{rule_where});
            rule.pattern = try self.alloc.dupe(u8, pattern);
            if (getKey(m, "foreground_color")) |c| {
                const s = scalarOf(c) orelse return self.fail("{s}: `foreground_color:` must be a string like '220,6,6'", .{rule_where});
                rule.foreground_color = try self.alloc.dupe(u8, s);
            }
            if (getKey(m, "background_color")) |c| {
                const s = scalarOf(c) orelse return self.fail("{s}: `background_color:` must be a string like '220,6,6'", .{rule_where});
                rule.background_color = try self.alloc.dupe(u8, s);
            }
            if (getKey(m, "just_pattern")) |b| {
                rule.just_pattern = boolOf(b) orelse return self.fail("{s}: `just_pattern:` must be true or false", .{rule_where});
            }
            if (rule.foreground_color == null and rule.background_color == null) {
                return self.fail("{s} needs a `foreground_color:` or a `background_color:`", .{rule_where});
            }
            rules[i] = rule;
        }
        return rules;
    }

    fn parseDefault(self: *Parser, value: Value) Error!void {
        const name = scalarOf(value) orelse return self.fail("`default:` must name a process or group", .{});
        self.config.default = self.config.find(name) orelse {
            return self.fail("`default: {s}` does not name a process or group", .{name});
        };
    }

    fn computeRunAll(self: *Parser) Error!void {
        var count: usize = 0;
        for (self.config.processes) |p| {
            if (!p.is_task) count += 1;
        }
        const all = try self.alloc.alloc(*const Process, count);
        var i: usize = 0;
        for (self.config.processes) |*p| {
            if (p.is_task) continue;
            all[i] = p;
            i += 1;
        }
        self.config.run_all = all;
    }
};

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

const testing = std.testing;

fn parseOk(source: []const u8) !Configuration {
    var diag: Diagnostics = .{};
    return parse(testing.io, testing.allocator, source, &diag) catch |err| {
        std.debug.print("unexpected parse failure: {t}: {s}\n", .{ err, diag.message() });
        return err;
    };
}

/// Expects `source` to fail with `expected`, and the message to mention `needle`.
fn expectFails(source: []const u8, expected: anyerror, needle: []const u8) !void {
    var diag: Diagnostics = .{};
    const result = parse(testing.io, testing.allocator, source, &diag);
    if (result) |config| {
        var c = config;
        c.deinit();
        std.debug.print("expected failure ({t}) for:\n{s}\n", .{ expected, source });
        return error.TestUnexpectedResult;
    } else |err| {
        try testing.expectEqual(expected, err);
        if (std.mem.find(u8, diag.message(), needle) == null) {
            std.debug.print("message \"{s}\" does not mention \"{s}\"\n", .{ diag.message(), needle });
            return error.TestUnexpectedResult;
        }
    }
}

test "parse: the full format" {
    const source =
        \\default: Demo
        \\
        \\processes:
        \\  List: ls .
        \\  Print: '.\data\printlines.py'
        \\  Server: -m http.server 8000
        \\  Build: zig build
        \\  Clean: "rm -rf zig-out"
        \\
        \\groups:
        \\  Demo: [Print, Server]
        \\
        \\configs:
        \\  - name: Print
        \\    type: python
        \\    args: ['--count', "10"]
        \\    env:
        \\      DEBUG: '1'
        \\      LEVEL: info
        \\    preTask: Build
        \\    postTask: Clean
        \\    script:
        \\      - ': hide Warning'
        \\      - '_: wrap on'
        \\    colorRules:
        \\      - pattern: error
        \\        foreground_color: '220,6,6'
        \\        just_pattern: true
        \\  - name: Server
        \\    type: python
        \\    env: ['PORT=8000', 'HOST=localhost']
        \\  - name: Clean
        \\    type: shell
        \\  - name: Demo
        \\    preTask: Build
        \\    script: ['Print: keep started']
        \\    colorRules:
        \\      - pattern: data
        \\        background_color: '1,2,3'
        \\
        \\colorRules:
        \\  - pattern: '\[Info\]'
        \\    foreground_color: '39,174,96'
        \\
        \\script:
        \\  - '_: color debug red'
        \\  - ': merge merged --all'
    ;
    var config = try parseOk(source);
    defer config.deinit();

    try testing.expectEqual(5, config.processes.len);
    const list = config.findProcess("List").?;
    try testing.expectEqualStrings("ls .", list.command);
    try testing.expectEqualStrings("ls", list.tokens[0]);
    try testing.expectEqualStrings(".", list.tokens[1]);
    try testing.expectEqual(RunnerType.native, list.type);
    try testing.expectEqual(0, list.args.len);
    try testing.expectEqual(null, list.pre_task);
    try testing.expectEqual(null, list.script);

    const print = config.findProcess("Print").?;
    try testing.expectEqualStrings(".\\data\\printlines.py", print.command);
    try testing.expectEqual(1, print.tokens.len);
    try testing.expectEqualStrings(".\\data\\printlines.py", print.tokens[0]);
    try testing.expectEqual(RunnerType.python, print.type);
    try testing.expectEqual(2, print.args.len);
    try testing.expectEqualStrings("--count", print.args[0]);
    try testing.expectEqualStrings("10", print.args[1]);
    try testing.expectEqual(2, print.env.len);
    try testing.expectEqualStrings("DEBUG", print.env[0].key);
    try testing.expectEqualStrings("1", print.env[0].val);
    try testing.expectEqualStrings("LEVEL", print.env[1].key);
    try testing.expectEqualStrings("info", print.env[1].val);
    try testing.expectEqual(config.findProcess("Build").?, print.pre_task.?);
    try testing.expectEqual(config.findProcess("Clean").?, print.post_task.?);
    try testing.expectEqualStrings(": hide Warning\n_: wrap on", print.script.?);
    try testing.expectEqual(1, print.color_rules.len);
    try testing.expectEqualStrings("error", print.color_rules[0].pattern.?);
    try testing.expectEqualStrings("220,6,6", print.color_rules[0].foreground_color.?);
    try testing.expectEqual(null, print.color_rules[0].background_color);
    try testing.expect(print.color_rules[0].just_pattern);

    const server = config.findProcess("Server").?;
    try testing.expectEqual(3, server.tokens.len);
    try testing.expectEqualStrings("-m", server.tokens[0]);
    try testing.expectEqualStrings("http.server", server.tokens[1]);
    try testing.expectEqual(2, server.env.len);
    try testing.expectEqualStrings("PORT", server.env[0].key);
    try testing.expectEqualStrings("8000", server.env[0].val);
    try testing.expectEqualStrings("HOST", server.env[1].key);
    try testing.expectEqualStrings("localhost", server.env[1].val);

    const clean = config.findProcess("Clean").?;
    try testing.expectEqual(RunnerType.shell, clean.type);
    try testing.expectEqualStrings("rm -rf zig-out", clean.command);

    // tasks are marked and left out of "everything"
    try testing.expect(config.findProcess("Build").?.is_task);
    try testing.expect(clean.is_task);
    try testing.expect(!print.is_task);
    try testing.expectEqual(3, config.run_all.len);
    try testing.expectEqualStrings("List", config.run_all[0].name);
    try testing.expectEqualStrings("Print", config.run_all[1].name);
    try testing.expectEqualStrings("Server", config.run_all[2].name);

    try testing.expectEqual(1, config.groups.len);
    const demo = config.findGroup("Demo").?;
    try testing.expectEqual(2, demo.members.len);
    try testing.expectEqual(print, demo.members[0]);
    try testing.expectEqual(server, demo.members[1]);
    try testing.expectEqual(config.findProcess("Build").?, demo.pre_task.?);
    try testing.expectEqual(null, demo.post_task);
    try testing.expectEqualStrings("Print: keep started", demo.script.?);
    try testing.expectEqual(1, demo.color_rules.len);
    try testing.expectEqualStrings("1,2,3", demo.color_rules[0].background_color.?);
    try testing.expect(!demo.color_rules[0].just_pattern);

    try testing.expectEqual(demo, config.default.?.group);
    try testing.expectEqual(demo, config.resolve(null).?.group);
    try testing.expectEqual(1, config.color_rules.len);
    try testing.expectEqualStrings("\\[Info\\]", config.color_rules[0].pattern.?);
    try testing.expectEqualStrings("_: color debug red\n: merge merged --all", config.script.?);
}

test "parse: the smallest file" {
    var config = try parseOk("processes:\n  hello: echo hi\n");
    defer config.deinit();
    try testing.expectEqual(1, config.processes.len);
    try testing.expectEqualStrings("hello", config.processes[0].name);
    try testing.expectEqual(RunnerType.native, config.processes[0].type);
    try testing.expectEqual(0, config.groups.len);
    try testing.expectEqual(null, config.default);
    try testing.expectEqual(null, config.script);
    try testing.expectEqual(0, config.color_rules.len);
    const all = config.resolve(null).?.all;
    try testing.expectEqual(1, all.len);
    try testing.expectEqual(&config.processes[0], all[0]);
    try testing.expectEqual(null, config.resolve("nope"));
}

test "parse: quoted values are unquoted (the YAML library takes no quoted keys)" {
    var config = try parseOk(
        \\processes:
        \\  a: "echo hi"
        \\  b: 'echo there'
        \\groups:
        \\  g: ["a", 'b']
        \\configs:
        \\  - name: "a"
        \\    type: 'shell'
        \\default: "g"
    );
    defer config.deinit();
    try testing.expectEqual(2, config.processes.len);
    try testing.expectEqualStrings("a", config.processes[0].name);
    try testing.expectEqualStrings("echo hi", config.processes[0].command);
    try testing.expectEqualStrings("b", config.processes[1].name);
    try testing.expectEqual(RunnerType.shell, config.processes[0].type);
    try testing.expectEqual(2, config.findGroup("g").?.members.len);
    try testing.expectEqualStrings("g", config.default.?.name());
}

test "parse: `${...}` tokens expand in command lines, args and env values" {
    var map = std.process.Environ.Map.init(testing.allocator);
    defer map.deinit();
    try map.put("FOO", "bar baz");
    expand.init_expand(&map);
    defer expand.deinit_expand();

    // quoted: the YAML library reads an unquoted `${env:FOO}` as a map key
    var config = try parseOk(
        \\processes:
        \\  a: 'run ${env:FOO} now'
        \\configs:
        \\  - name: a
        \\    args: ['--x=${env:FOO}']
        \\    env:
        \\      Y: '${env:FOO}'
    );
    defer config.deinit();
    const a = config.processes[0];
    try testing.expectEqualStrings("run bar baz now", a.command);
    // expanded per token: the value's space does not split it
    try testing.expectEqual(3, a.tokens.len);
    try testing.expectEqualStrings("bar baz", a.tokens[1]);
    try testing.expectEqualStrings("--x=bar baz", a.args[0]);
    try testing.expectEqualStrings("bar baz", a.env[0].val);

    try expectFails("processes:\n  a: 'run ${env:NOT_SET_ANYWHERE}'\n", error.InvalidConfig, "environment variable that is not set");
    try expectFails("processes:\n  a: 'run ${bogus}'\n", error.InvalidConfig, "unknown `${...}` token");
}

test "parse: every mistake is an error with a message that names it" {
    try expectFails("", error.InvalidConfig, "empty");
    try expectFails("  \n# just a comment\n", error.InvalidConfig, "empty");
    try expectFails("- a\n- b\n", error.InvalidConfig, "top level must be a map");
    try expectFails("groups:\n  g: [x]\n", error.InvalidConfig, "`processes:` is missing");
    try expectFails("processes: [a, b]\n", error.InvalidConfig, "must be a map");
    try expectFails("procesess:\n  a: x\n", error.InvalidConfig, "unknown field `procesess`");
    try expectFails("processes:\n  a: ''\n", error.InvalidConfig, "command line");
    try expectFails("processes:\n  a: 'echo \"unterminated'\n", error.InvalidConfig, "unterminated quote");
    try expectFails("processes:\n  _: x\n", error.InvalidConfig, "`_` cannot be a process name");
    try expectFails("processes:\n  ~1: x\n", error.InvalidConfig, "cannot start with `~`");

    try expectFails("processes:\n  a: x\ngroups:\n  g: [a, nope]\n", error.InvalidConfig, "\"nope\", which is not in `processes:`");
    try expectFails("processes:\n  a: x\ngroups:\n  a: [a]\n", error.InvalidConfig, "both a process and a group");
    try expectFails("processes:\n  a: x\ngroups:\n  g: []\n", error.InvalidConfig, "group \"g\" is empty");
    try expectFails("processes:\n  a: x\ngroups:\n  g: [a, a]\n", error.InvalidConfig, "lists \"a\" twice");
    try expectFails("processes:\n  a: x\ngroups:\n  g: a\n", error.InvalidConfig, "must be a list of process names");

    try expectFails("processes:\n  a: x\nconfigs:\n  - name: b\n", error.InvalidConfig, "\"b\" is not a process or group");
    try expectFails("processes:\n  a: x\nconfigs:\n  - type: shell\n", error.InvalidConfig, "has no `name:`");
    try expectFails("processes:\n  a: x\nconfigs:\n  - name: a\n    typo: 1\n", error.InvalidConfig, "unknown field `typo`");
    try expectFails("processes:\n  a: x\nconfigs:\n  - name: a\n    type: debugpy\n", error.InvalidConfig, "unknown type \"debugpy\"");
    try expectFails("processes:\n  a: x\nconfigs:\n  - name: a\n  - name: a\n", error.InvalidConfig, "already has a config entry");
    try expectFails("processes:\n  a: x\nconfigs:\n  - name: a\n    preTask: a\n", error.InvalidConfig, "cannot point at the entry itself");
    try expectFails("processes:\n  a: x\nconfigs:\n  - name: a\n    postTask: nope\n", error.InvalidConfig, "`postTask: nope` does not name a process");
    try expectFails("processes:\n  a: x\nconfigs:\n  - name: a\n    args: --flag\n", error.InvalidConfig, "`args:` must be a list");
    try expectFails("processes:\n  a: x\nconfigs:\n  - name: a\n    env: ['NOEQUALS']\n", error.InvalidConfig, "is not KEY=VALUE");
    try expectFails("processes:\n  a: x\nconfigs:\n  - name: a\n    env: 'X=1'\n", error.InvalidConfig, "`env:` must be a map");
    try expectFails("processes:\n  a: x\nconfigs:\n  - name: a\n    script: ['no separator here']\n", error.InvalidConfig, "needs a `:`");
    try expectFails("processes:\n  a: x\nconfigs:\n  - name: a\n    script: ['a:']\n", error.InvalidConfig, "no command after the `:`");
    try expectFails("processes:\n  a: x\ngroups:\n  g: [a]\nconfigs:\n  - name: g\n    args: [x]\n", error.InvalidConfig, "unknown field `args`");

    try expectFails("processes:\n  a: x\ncolorRules:\n  - pattern: p\n", error.InvalidConfig, "needs a `foreground_color:` or a `background_color:`");
    try expectFails("processes:\n  a: x\ncolorRules:\n  - foreground_color: '1,2,3'\n", error.InvalidConfig, "has no `pattern:`");
    try expectFails("processes:\n  a: x\ncolorRules:\n  - pattern: p\n    foreground_color: '1,2,3'\n    just_pattern: maybe\n", error.InvalidConfig, "must be true or false");
    try expectFails("processes:\n  a: x\ncolorRules:\n  - pattern: p\n    colour: '1,2,3'\n", error.InvalidConfig, "unknown field `colour`");

    try expectFails("processes:\n  a: x\ndefault: nope\n", error.InvalidConfig, "`default: nope` does not name");
    try expectFails("processes:\n  a: x\nscript: ': cmd'\n", error.InvalidConfig, "must be a list");
}

test "parse: broken YAML is a parse error with the library's report, not a panic" {
    var diag: Diagnostics = .{};
    // a flow map with several entries: valid YAML the library does not understand
    const result = parse(testing.io, testing.allocator, "processes:\n  a: { x: 1, y: 2 }\n", &diag);
    try testing.expectError(error.ParseFailure, result);
    try testing.expect(std.mem.startsWith(u8, diag.message(), "YAML syntax error"));
    try testing.expect(std.mem.find(u8, diag.message(), ":2:") != null); // line 2

    // an unterminated quote would crash the library: caught before it gets there
    try expectFails("processes:\n  a: \"unterminated\n  b: x\n", error.InvalidConfig, "line 2: the quote at column 6 is never closed");
    try expectFails("processes:\n  a: 'unterminated\n", error.InvalidConfig, "line 2");
    try expectFails("processes:\n  a: [\"x\", 'y]\n", error.InvalidConfig, "line 2");
    try expectFails("processes:\n  c: it's fine\n", error.InvalidConfig, "line 2: the quote at column 8 is never closed");
    // ... while quotes that do close, and quotes inside comments, are fine
    // (the command line splitter reads quotes the same way, hence the double quotes in b)
    var ok = try parseOk("# a 'comment'\nprocesses:\n  a: 'say \"hi there\"'\n  b: 'echo \"it''s\"'\n  c: fine # it's \"ok\"\n");
    defer ok.deinit();
    try testing.expectEqual(3, ok.processes.len);
    try testing.expectEqualStrings("say \"hi there\"", ok.processes[0].command);
    try testing.expectEqual(2, ok.processes[0].tokens.len);
    try testing.expectEqualStrings("hi there", ok.processes[0].tokens[1]);
    try testing.expectEqualStrings("echo \"it's\"", ok.processes[1].command);
    try testing.expectEqualStrings("it's", ok.processes[1].tokens[1]);
    try testing.expectEqualStrings("fine", ok.processes[2].command);
}
