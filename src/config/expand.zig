const std = @import("std");

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
} || std.mem.Allocator.Error || std.fs.Dir.RealPathError;

// TODO: we should update this to ignore case!
fn expansion_replace(alloc: std.mem.Allocator, input: []const u8, begin_idx: usize, end_idx: usize) ExpandErrors![]u8 {
    const token = input[begin_idx..end_idx];
    std.debug.print("Token: {s}\n", .{token});

    var list = std.ArrayList(u8).init(alloc);
    defer list.deinit();

    const env_prefix = "env:";
    if (token.len > env_prefix.len) {
        const actual_token = token[env_prefix.len..token.len];
        if (std.process.getEnvVarOwned(alloc, actual_token)) |value| {
            defer alloc.free(value);
            try list.appendSlice(input[0 .. begin_idx - 2]);
            try list.appendSlice(value);
            try list.appendSlice(input[end_idx + 1 .. input.len]);
            std.debug.print("result: {s}\n", .{input[0..begin_idx]});
            std.debug.print("result: {s}\n", .{value});
            std.debug.print("result: {s}\n", .{input[end_idx..input.len]});
            return list.toOwnedSlice();
        } else |_| {}
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
            const value = std.process.getEnvVarOwned(alloc, token) catch {
                // TODO create uiconfig diagnostics instead of returning an error
                return ExpandErrors.TokenExpectedEnvVar;
            };
            defer alloc.free(value);
            try list.appendSlice(input[0 .. begin_idx - 2]);
            try list.appendSlice(value);
            try list.appendSlice(input[end_idx + 1 .. input.len]);
            return list.toOwnedSlice();
        },
        .cwd => {
            const value = try std.fs.cwd().realpathAlloc(alloc, ".");
            defer alloc.free(value);
            try list.appendSlice(input[0 .. begin_idx - 2]);
            try list.appendSlice(value);
            try list.appendSlice(input[end_idx + 1 .. input.len]);
            std.debug.print("result: {s}\n", .{input[0..begin_idx]});
            std.debug.print("result: {s}\n", .{value});
            std.debug.print("result: {s}\n", .{input[end_idx..input.len]});
            return list.toOwnedSlice();
        },
        else => {
            return ExpandErrors.UnsupportedExpansionToken;
        },
    }
}

pub fn expand_string(alloc: std.mem.Allocator, str: []const u8) ExpandErrors![]u8 {
    var start: usize = 0;
    while (start < str.len) {
        const needle = "${";
        const needle_len = needle.len;
        const found = std.mem.indexOf(u8, str[start..str.len], needle);
        if (found) |rel_idx| {
            const abs_idx = start + rel_idx + needle_len;
            std.debug.print("index of start = {d}\n", .{abs_idx});
            for (abs_idx..str.len) |idx| {
                if (str[idx] == '}') {
                    std.debug.print("index of end = {d}\n", .{idx});
                    // we found a match
                    // TODO: we should continue to look for more expansion strs
                    return try expansion_replace(alloc, str, abs_idx, idx);
                }
            }
            start = abs_idx + 1;
        } else {
            break;
        }
    }

    return ExpandErrors.NoExpansionFound;
}

test "Expand String" {
    const builtin = @import("builtin");
    const alloc = std.testing.allocator;
    const str_with_expand_test1 = "C:\\path\\${workspaceFolder}\\script.py";
    const str_with_expand_test2 = "C:\\path\\${workspaceFolder}";
    const str_with_expand_test3 = "${workspaceFolder}\\script.py";

    switch (builtin.target.os.tag) {
        .windows => {
            // zig test .\src\config\expand.zig -lc -target native
            const windows = @cImport({
                @cInclude("windows.h");
            });

            const name_w = try std.unicode.utf8ToUtf16LeAlloc(std.heap.page_allocator, "workspaceFolder");
            defer std.heap.page_allocator.free(name_w);

            const value_w = try std.unicode.utf8ToUtf16LeAlloc(std.heap.page_allocator, "wow");
            defer std.heap.page_allocator.free(value_w);

            const success = windows.SetEnvironmentVariableW(
                @ptrCast(name_w.ptr),
                @ptrCast(value_w.ptr),
            );

            if (success == 0) {
                return error.SetEnvFailed;
            }

            const expanded_str_test1 = try expand_string(alloc, str_with_expand_test1);
            const expanded_str_test2 = try expand_string(alloc, str_with_expand_test2);
            const expanded_str_test3 = try expand_string(alloc, str_with_expand_test3);
            defer alloc.free(expanded_str_test1);
            defer alloc.free(expanded_str_test2);
            defer alloc.free(expanded_str_test3);
            try std.testing.expectEqualStrings("C:\\path\\wow\\script.py", expanded_str_test1);
            try std.testing.expectEqualStrings("C:\\path\\wow", expanded_str_test2);
            try std.testing.expectEqualStrings("wow\\script.py", expanded_str_test3);
        },
        else => {
            // No test for nix as of yet
        },
    }
}
