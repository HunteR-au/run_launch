const std = @import("std");
const Io = std.Io;
const utils = @import("utils");
const pump_ = @import("pump");
const launch_ = @import("config");

const LaunchConfiguration = launch_.LaunchConfiguration;
const Pump = pump_.Pump;
const ProcIngest = pump_.reader.ProcIngest;

/// Spawns `config.program` with `config.args` and starts its pump readers.
pub fn launch(
    io: Io,
    alloc: std.mem.Allocator,
    pump: *Pump,
    config: *const LaunchConfiguration,
) !*ProcIngest {
    const program = config.program orelse return error.MissingConfigurationFields;
    const args: []const []const u8 = config.args orelse &.{};

    var envmap: ?std.process.Environ.Map = null;
    defer if (envmap) |*m| m.deinit();
    if (config.env) |envs| envmap = try utils.create_env_map(alloc, envs);
    const envmap_ptr: ?*std.process.Environ.Map = if (envmap) |*m| m else null;

    const argv = try alloc.alloc([]const u8, args.len + 1);
    defer alloc.free(argv);
    argv[0] = program;
    @memcpy(argv[1..], args);

    return try pump_.reader.launch(io, alloc, pump, program, argv, envmap_ptr);
}
