const std = @import("std");
const Io = std.Io;
const utils = @import("utils");
const pump_ = @import("pump");
const launch_ = @import("config");
const builtin = @import("builtin");

const LaunchConfiguration = launch_.LaunchConfiguration;
const Pump = pump_.Pump;
const ProcIngest = pump_.reader.ProcIngest;

const python_default_path = switch (builtin.target.os.tag) {
    .windows => "py",
    else => "python3",
};

/// Spawns a python module (`-m module`) or script with unbuffered output and starts its
/// pump readers.
pub fn launch(
    io: Io,
    alloc: std.mem.Allocator,
    pump: *Pump,
    config: *const LaunchConfiguration,
) !*ProcIngest {
    const args: []const []const u8 = config.args orelse &.{};

    var envmap: ?std.process.Environ.Map = null;
    defer if (envmap) |*m| m.deinit();
    if (config.env) |envs| envmap = try utils.create_env_map(alloc, envs);
    const envmap_ptr: ?*std.process.Environ.Map = if (envmap) |*m| m else null;

    // TODO - if module and program set (program points to the python exe to run)
    if (config.module) |module| {
        const prefix = [_][]const u8{ config.program orelse python_default_path, "-u", "-m", module };
        const argv = try alloc.alloc([]const u8, prefix.len + args.len);
        defer alloc.free(argv);
        @memcpy(argv[0..prefix.len], &prefix);
        @memcpy(argv[prefix.len..], args);
        return try pump_.reader.launch(io, alloc, pump, module, argv, envmap_ptr);
    }

    if (config.program) |script| {
        const prefix = [_][]const u8{ python_default_path, "-u", script };
        const argv = try alloc.alloc([]const u8, prefix.len + args.len);
        defer alloc.free(argv);
        @memcpy(argv[0..prefix.len], &prefix);
        @memcpy(argv[prefix.len..], args);
        return try pump_.reader.launch(io, alloc, pump, script, argv, envmap_ptr);
    }

    return error.MissingConfigurationFields;
}
