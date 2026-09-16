const std = @import("std");
const Io = std.Io;

var environ: ?*const std.process.Environ.Map = null;

/// `env_map` is borrowed for as long as expansion is used (main owns `init.environ_map`).
pub fn init_expand(env_map: *const std.process.Environ.Map) void {
    environ = env_map;
}

pub fn deinit_expand() void {
    environ = null;
}

pub const ExpandTokens = enum {
    workspaceFolder,
    workspaceFolderBasename,
    pathSeparator,
    defaultBuildTask,
    relativeFile,
    relativeFileDirname,
    fileWorkspaceFolderBasename,
    fileDirnameBasename,
    fileBasename,
    fileDirname,
    fileExtname,
    selectedText,
    file,
    lineNumber,
    cwd,
};

pub const ExpandErrors = error{
    UnknownExpandToken,
    TokenExpectedEnvVar,
    UnsupportedExpansionToken,
    NoExpansionFound,
} || std.mem.Allocator.Error || std.Io.Dir.RealPathFileAllocError;

// TODO: we should update this to ignore case!
fn expansion_replace(io: Io, alloc: std.mem.Allocator, input: []const u8, begin_idx: usize, end_idx: usize) ExpandErrors![]u8 {
    const token = input[begin_idx..end_idx];
    std.log.debug("Token: {s}\n", .{token});

    var list = try std.ArrayList(u8).initCapacity(alloc, 100);
    defer list.deinit(alloc);

    const env_prefix = "env:";
    if (std.mem.startsWith(u8, token, env_prefix)) {
        const actual_token = token[env_prefix.len..];
        const value = environ.?.get(actual_token) orelse return ExpandErrors.TokenExpectedEnvVar;
        // `value` is borrowed from the map: not freed
        try list.appendSlice(alloc, input[0 .. begin_idx - 2]);
        try list.appendSlice(alloc, value);
        try list.appendSlice(alloc, input[end_idx + 1 .. input.len]);
        std.log.debug("result: {s}\n", .{input[0..begin_idx]});
        std.log.debug("result: {s}\n", .{value});
        std.log.debug("result: {s}\n", .{input[end_idx..input.len]});
        return list.toOwnedSlice(alloc);
    }

    const case = std.meta.stringToEnum(ExpandTokens, token) orelse {
        return ExpandErrors.UnknownExpandToken;
    };
    switch (case) {
        .workspaceFolder,
        .workspaceFolderBasename,
        .defaultBuildTask,
        .fileWorkspaceFolderBasename,
        .fileDirnameBasename,
        .fileBasename,
        .fileDirname,
        .fileExtname,
        .file,
        => {
            // search environment vars
            const value = environ.?.get(token) orelse return ExpandErrors.TokenExpectedEnvVar;

            try list.appendSlice(alloc, input[0 .. begin_idx - 2]);
            try list.appendSlice(alloc, value);
            try list.appendSlice(alloc, input[end_idx + 1 .. input.len]);
            return list.toOwnedSlice(alloc);
        },
        .cwd => {
            const value = try std.Io.Dir.realPathFileAbsoluteAlloc(io, ".", alloc);
            defer alloc.free(value);

            try list.appendSlice(alloc, input[0 .. begin_idx - 2]);
            try list.appendSlice(alloc, value);
            try list.appendSlice(alloc, input[end_idx + 1 .. input.len]);
            std.log.debug("result: {s}\n", .{input[0..begin_idx]});
            std.log.debug("result: {s}\n", .{value});
            std.log.debug("result: {s}\n", .{input[end_idx..input.len]});
            return list.toOwnedSlice(alloc);
        },
        else => {
            return ExpandErrors.UnsupportedExpansionToken;
        },
    }
}

pub fn expand_string(io: Io, alloc: std.mem.Allocator, str: []const u8) ExpandErrors![]u8 {
    var start: usize = 0;
    while (start < str.len) {
        const needle = "${";
        const needle_len = needle.len;
        const found = std.mem.indexOf(u8, str[start..str.len], needle);
        if (found) |rel_idx| {
            const abs_idx = start + rel_idx + needle_len;
            std.log.debug("index of start = {d}\n", .{abs_idx});
            for (abs_idx..str.len) |idx| {
                if (str[idx] == '}') {
                    std.log.debug("index of end = {d}\n", .{idx});
                    // we found a match
                    // TODO: we should continue to look for more expansion strs
                    return try expansion_replace(io, alloc, str, abs_idx, idx);
                }
            }
            start = abs_idx + 1;
        } else {
            break;
        }
    }

    return ExpandErrors.NoExpansionFound;
}

test "expand_string: named tokens and env: prefix resolve from the map" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var map = std.process.Environ.Map.init(alloc);
    defer map.deinit();
    try map.put("workspaceFolder", "wow");
    try map.put("FOO", "bar");

    init_expand(&map);
    defer deinit_expand();

    const cases = .{
        .{ "C:\\path\\${workspaceFolder}\\script.py", "C:\\path\\wow\\script.py" },
        .{ "C:\\path\\${workspaceFolder}", "C:\\path\\wow" },
        .{ "${workspaceFolder}\\script.py", "wow\\script.py" },
        .{ "x ${env:FOO} y", "x bar y" },
    };
    inline for (cases) |case| {
        const got = try expand_string(io, alloc, case[0]);
        defer alloc.free(got);
        try std.testing.expectEqualStrings(case[1], got);
    }

    try std.testing.expectError(ExpandErrors.TokenExpectedEnvVar, expand_string(io, alloc, "${env:MISSING}"));
    try std.testing.expectError(ExpandErrors.NoExpansionFound, expand_string(io, alloc, "plain"));
}
