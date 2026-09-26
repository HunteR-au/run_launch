//! Splits a process command line into argv tokens.
//!
//! Tokens are separated by whitespace. A double-quoted group keeps its spaces; inside it
//! `\"` is a literal quote and every other backslash is kept as written, so Windows paths
//! survive. A single-quoted group has no escapes at all. Quotes may sit inside a token
//! (`a"b c"d` is one token, `ab cd`).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const SplitError = error{ EmptyCommandLine, UnterminatedQuote } || Allocator.Error;

/// The caller owns the returned slice and every string in it (see `free`).
pub fn split(alloc: Allocator, line: []const u8) SplitError![]const []const u8 {
    var tokens: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (tokens.items) |t| alloc.free(t);
        tokens.deinit(alloc);
    }

    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(alloc);

    var i: usize = 0;
    var in_token = false;
    while (i < line.len) {
        const c = line[i];
        if (std.ascii.isWhitespace(c)) {
            if (in_token) {
                try tokens.append(alloc, try current.toOwnedSlice(alloc));
                in_token = false;
            }
            i += 1;
            continue;
        }

        in_token = true;
        switch (c) {
            '"' => {
                i += 1;
                while (true) {
                    if (i >= line.len) return error.UnterminatedQuote;
                    const q = line[i];
                    if (q == '"') {
                        i += 1;
                        break;
                    }
                    if (q == '\\' and i + 1 < line.len and line[i + 1] == '"') {
                        try current.append(alloc, '"');
                        i += 2;
                        continue;
                    }
                    try current.append(alloc, q);
                    i += 1;
                }
            },
            '\'' => {
                i += 1;
                const start = i;
                while (i < line.len and line[i] != '\'') : (i += 1) {}
                if (i >= line.len) return error.UnterminatedQuote;
                try current.appendSlice(alloc, line[start..i]);
                i += 1;
            },
            else => {
                try current.append(alloc, c);
                i += 1;
            },
        }
    }
    if (in_token) try tokens.append(alloc, try current.toOwnedSlice(alloc));

    if (tokens.items.len == 0) return error.EmptyCommandLine;
    return try tokens.toOwnedSlice(alloc);
}

pub fn free(alloc: Allocator, tokens: []const []const u8) void {
    for (tokens) |t| alloc.free(t);
    alloc.free(tokens);
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

const testing = std.testing;

fn expectSplit(line: []const u8, expected: []const []const u8) !void {
    const alloc = testing.allocator;
    const got = try split(alloc, line);
    defer free(alloc, got);
    try testing.expectEqual(expected.len, got.len);
    for (expected, got) |e, g| try testing.expectEqualStrings(e, g);
}

test "split: whitespace separates, quotes group, backslashes survive" {
    try expectSplit("a b  c", &.{ "a", "b", "c" });
    try expectSplit("  ls   .  ", &.{ "ls", "." });
    try expectSplit(".\\data\\printlines.py", &.{".\\data\\printlines.py"});
    try expectSplit("py \"C:\\Program Files\\x.exe\" --flag", &.{ "py", "C:\\Program Files\\x.exe", "--flag" });
    try expectSplit("echo \"say \\\"hi\\\"\"", &.{ "echo", "say \"hi\"" });
    try expectSplit("'a b' c", &.{ "a b", "c" });
    try expectSplit("a\"b c\"d", &.{"ab cd"});
    try expectSplit("x \"\" y", &.{ "x", "", "y" });
    try expectSplit("-m http.server 8000", &.{ "-m", "http.server", "8000" });
}

test "split: empty and unterminated command lines are errors, not panics" {
    try testing.expectError(error.EmptyCommandLine, split(testing.allocator, ""));
    try testing.expectError(error.EmptyCommandLine, split(testing.allocator, "   \t "));
    try testing.expectError(error.UnterminatedQuote, split(testing.allocator, "\"abc"));
    try testing.expectError(error.UnterminatedQuote, split(testing.allocator, "a 'bc"));
}
